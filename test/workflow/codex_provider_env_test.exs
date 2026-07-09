defmodule Workflow.CodexProviderEnvTest do
  use ExUnit.Case, async: false

  alias Workflow.Journal
  alias Workflow.Provider
  alias Workflow.Provider.Codex
  alias Workflow.Run
  alias Workflow.Status

  @codex_bin_env "CODEX_LOOPS_CODEX_BIN"
  @codex_model_env "CODEX_LOOPS_CODEX_MODEL"

  defmodule EchoWorkflow do
    @moduledoc false
    use Workflow

    workflow "codex_env_echo" do
      agent("say hello")
      return(:ok)
    end
  end

  setup do
    previous_path = System.get_env("PATH")
    previous_codex_bin = System.get_env(@codex_bin_env)
    previous_codex_model = System.get_env(@codex_model_env)

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env(@codex_bin_env, previous_codex_bin)
      restore_env(@codex_model_env, previous_codex_model)
    end)

    :ok
  end

  test "CODEX_LOOPS_CODEX_BIN selects the production codex command without PATH lookup" do
    bin = executable_stub("codex-bin")
    System.put_env(@codex_bin_env, bin)

    assert {^bin,
            [
              "exec",
              "--json",
              "--dangerously-bypass-approvals-and-sandbox",
              "--skip-git-repo-check"
            ]} = Codex.default_command()
  end

  test "CODEX_LOOPS_CODEX_MODEL overrides an incompatible user-configured model" do
    bin = executable_stub("codex-model")
    System.put_env(@codex_bin_env, bin)
    System.put_env(@codex_model_env, "gpt-5.5")

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

  test "a missing codex CLI is journaled as an unavailable provider failure" do
    System.put_env("PATH", empty_dir())
    System.delete_env(@codex_bin_env)

    id = "codex_env_missing_#{System.unique_integer([:positive])}"

    assert {:error, {:provider_failure, [0], :unavailable, detail}} =
             Run.run(EchoWorkflow, run_id: id, provider: Provider.select(:codex, []))

    assert detail["env"] == @codex_bin_env
    assert detail["message"] =~ "no `codex` executable"
    assert detail["hint"] =~ @codex_bin_env

    assert id |> Journal.fold() |> Enum.map(& &1.type) == [:run_started, :agent_failed]

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
             Run.run(EchoWorkflow,
               run_id: id,
               provider: {Codex, command: {"/bin/sh", ["-c", "exit 127"]}}
             )

    assert detail["env"] == @codex_bin_env
    assert detail["message"] =~ "exit status 127"
    assert id |> Journal.fold() |> Enum.map(& &1.type) == [:run_started, :agent_failed]
    assert Status.of(id).state == :failed
  end

  defp executable_stub(name) do
    path = Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}")
    File.write!(path, "#!/bin/sh\nexit 0\n")
    File.chmod!(path, 0o755)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp empty_dir do
    path = Path.join(System.tmp_dir!(), "empty-path-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
