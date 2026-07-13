defmodule Workflow.CodexProviderEnvTest do
  use ExUnit.Case, async: false

  alias Workflow.Journal
  alias Workflow.Provider.Codex
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
    previous_codex_model = Application.get_env(:codex_loops, :codex_model)

    on_exit(fn ->
      restore_config(:codex_command, previous_codex_command)
      restore_config(:codex_model, previous_codex_model)
    end)

    :ok
  end

  test "the normalized application config selects the production codex command" do
    bin = executable_stub("codex-bin")
    Application.put_env(:codex_loops, :codex_command, {bin, []})

    assert {^bin,
            [
              "exec",
              "--json",
              "--dangerously-bypass-approvals-and-sandbox",
              "--skip-git-repo-check"
            ]} = Codex.default_command()
  end

  test "the normalized application config selects the Codex model" do
    bin = executable_stub("codex-model")
    Application.put_env(:codex_loops, :codex_command, {bin, []})
    Application.put_env(:codex_loops, :codex_model, "gpt-5.5")

    assert {^bin,
            [
              "exec",
              "--json",
              "--dangerously-bypass-approvals-and-sandbox",
              "--skip-git-repo-check",
              "--model",
              "gpt-5.5"
            ]} = Codex.default_command()
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
    assert detail["message"] =~ "exit status 127"

    assert id |> Journal.fold() |> Enum.map(& &1.type) == [
             :run_started,
             :agent_started,
             :agent_failed
           ]

    assert Status.of(id).state == :failed
  end

  defp executable_stub(name) do
    path = Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}")
    File.write!(path, "#!/bin/sh\nexit 0\n")
    File.chmod!(path, 0o755)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp restore_config(key, nil), do: Application.delete_env(:codex_loops, key)
  defp restore_config(key, value), do: Application.put_env(:codex_loops, key, value)
end
