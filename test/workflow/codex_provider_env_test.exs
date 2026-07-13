defmodule Workflow.CodexProviderEnvTest do
  use ExUnit.Case, async: false

  alias Workflow.Journal
  alias Workflow.Provider.Codex
  alias Workflow.Provider.Codex.AppServer
  alias Workflow.Run
  alias Workflow.Status

  defmodule EchoWorkflow do
    @moduledoc false

    def tree do
      Workflow.Test.tree!(
        "codex_env_echo",
        quote do
          agent("say hello")
          return(:ok)
        end,
        __ENV__
      )
    end
  end

  setup do
    previous_codex_command = Application.get_env(:codex_loops, :codex_command)
    previous_codex_binding_path = Application.get_env(:codex_loops, :codex_binding_path)
    previous_codex_model = Application.get_env(:codex_loops, :codex_model)
    previous_codex_execution = Application.get_env(:codex_loops, :codex_execution)
    AppServer.reset()

    on_exit(fn ->
      restore_config(:codex_command, previous_codex_command)
      restore_config(:codex_binding_path, previous_codex_binding_path)
      restore_config(:codex_model, previous_codex_model)
      restore_config(:codex_execution, previous_codex_execution)
      AppServer.reset()
    end)

    :ok
  end

  test "the normalized application config selects the production codex command" do
    bin = executable_stub("codex-bin")
    Application.put_env(:codex_loops, :codex_command, {bin, []})

    assert {^bin, ["app-server"]} = Codex.default_command()
  end

  test "the model remains a per-turn setting rather than a process argument" do
    bin = executable_stub("codex-model")
    Application.put_env(:codex_loops, :codex_command, {bin, []})
    Application.put_env(:codex_loops, :codex_model, "gpt-5.5")

    assert {^bin, ["app-server"]} = Codex.default_command()
  end

  test "the sandbox remains a per-turn setting rather than a process argument" do
    bin = executable_stub("codex-sandbox")
    Application.put_env(:codex_loops, :codex_command, {bin, []})
    Application.put_env(:codex_loops, :codex_execution, {:sandboxed, "/tmp/review-worktree"})

    assert {^bin, ["app-server"]} = Codex.default_command()
  end

  test "a missing normalized Codex command is journaled as an unavailable provider failure" do
    Application.delete_env(:codex_loops, :codex_command)

    id = "codex_env_missing_#{System.unique_integer([:positive])}"

    assert {:error, {:provider_failure, [0], :unavailable, detail}} =
             Run.run(EchoWorkflow.tree(), run_id: id, provider: {Codex, []})

    assert detail["config"] == "codex_command"
    assert detail["message"] =~ "Codex command was not configured"
    assert detail["hint"] =~ "codex-loops install --codex"

    assert id |> Journal.fold() |> Enum.map(& &1.type) == [
             :run_started,
             :agent_started,
             :agent_failed
           ]

    failed = Enum.find(Journal.fold(id), &(&1.type == :agent_failed))
    assert failed.payload.reason == {:provider_failure, :unavailable, detail}
    assert failed.payload.usage == nil
    assert failed.payload.activity == []

    status = Status.of(id)
    assert status.state == :failed
    assert status.failure.reason == {:provider_failure, :unavailable, detail}
  end

  test "a codex command that cannot start is journaled as unavailable" do
    id = "codex_env_backend_exit_#{System.unique_integer([:positive])}"

    assert {:error, {:provider_failure, [0], :unavailable, detail}} =
             Run.run(EchoWorkflow.tree(),
               run_id: id,
               provider: {Codex, command: {"/bin/sh", ["-c", "exit 127"]}}
             )

    assert detail["config"] == "codex_command"
    assert detail["message"] =~ "Codex app-server"

    assert id |> Journal.fold() |> Enum.map(& &1.type) == [
             :run_started,
             :agent_started,
             :agent_failed
           ]

    assert Status.of(id).state == :failed
  end

  test "a changed Codex binding fails before the app-server executable is opened" do
    marker = temporary_path("opened")
    binding_path = temporary_path("binding.json")

    bin =
      executable_stub(
        "codex-binding-changed",
        """
        #!/bin/sh
        case "$1" in
          --version) printf 'codex-cli 2.0.0\n' ;;
          app-server) touch #{inspect(marker)}; exit 99 ;;
          *) exit 98 ;;
        esac
        """
      )

    File.write!(binding_path, Jason.encode!(%{"path" => bin, "version" => "codex-cli 1.0.0"}))
    on_exit(fn -> File.rm(binding_path) end)

    Application.put_env(:codex_loops, :codex_command, {bin, []})
    Application.put_env(:codex_loops, :codex_binding_path, binding_path)

    id = "codex_binding_changed_#{System.unique_integer([:positive])}"

    assert {:error, {:provider_failure, [0], :unavailable, detail}} =
             Run.run(EchoWorkflow.tree(), run_id: id, provider: {Codex, []})

    assert detail["message"] == "Codex binding verification failed"
    assert detail["error"]["code"] == "codex_binding_changed"
    refute File.exists?(marker)
  end

  test "an exact Codex binding is verified before the shared app-server opens" do
    python = System.find_executable("python3")
    stub = Path.expand("../support/codex_app_server_stub.py", __DIR__)
    marker = temporary_path("opened")
    binding_path = temporary_path("binding.json")

    bin =
      executable_stub(
        "codex-binding-exact",
        """
        #!/bin/sh
        case "$1" in
          --version) printf 'codex-cli 1.0.0\n' ;;
          app-server) touch #{inspect(marker)}; exec #{inspect(python)} #{inspect(stub)} echo ;;
          *) exit 98 ;;
        esac
        """
      )

    File.write!(binding_path, Jason.encode!(%{"path" => bin, "version" => "codex-cli 1.0.0"}))

    Application.put_env(:codex_loops, :codex_command, {bin, []})
    Application.put_env(:codex_loops, :codex_binding_path, binding_path)

    id = "codex_binding_exact_#{System.unique_integer([:positive])}"

    assert {:ok, ^id} = Run.run(EchoWorkflow.tree(), run_id: id, provider: {Codex, []})
    assert File.exists?(marker)
  end

  defp executable_stub(name, body \\ "#!/bin/sh\nexit 0\n") do
    path = Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}")
    File.write!(path, body)
    File.chmod!(path, 0o755)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp temporary_path(name) do
    path = Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp restore_config(key, nil), do: Application.delete_env(:codex_loops, key)
  defp restore_config(key, value), do: Application.put_env(:codex_loops, key, value)
end
