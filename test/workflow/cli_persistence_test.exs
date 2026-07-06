defmodule Workflow.CLIPersistenceTest do
  use ExUnit.Case, async: false

  defp tmp_path(name),
    do: Path.join(System.tmp_dir!(), "#{name}_#{System.unique_integer([:positive])}")

  defp write_workflow do
    path = tmp_path("agent_loops_cli_persist_workflow") <> ".exs"

    File.write!(path, """
    defmodule CLIPersistFixture#{System.unique_integer([:positive])} do
      use Workflow

      workflow "cli-persist" do
        agent "say hi"
        return :ok
      end
    end
    """)

    path
  end

  defp run_cli(argv, journal_path) do
    encoded = inspect(argv)

    System.cmd(
      "mix",
      ["run", "--no-compile", "-e", "System.halt(Workflow.CLI.exec(#{encoded}))"],
      cd: File.cwd!(),
      env: [{"MIX_ENV", "test"}, {"CODEX_LOOPS_JOURNAL_PATH", journal_path}],
      stderr_to_stdout: true
    )
  end

  defp json_payload(output) do
    output
    |> String.split("\n", trim: true)
    |> List.last()
    |> Jason.decode!()
  end

  test "status can read a run journaled by a separate cli invocation" do
    journal_path = tmp_path("agent_loops_cli_persist") <> ".sqlite"
    script = write_workflow()
    run_id = "run_cli_persist_#{System.unique_integer([:positive])}"

    {run_output, 0} =
      run_cli(["run", script, "--run-id", run_id, "--provider", "mock", "--json"], journal_path)

    assert json_payload(run_output)["state"] == "completed"

    {status_output, 0} = run_cli(["status", "--run-id", run_id, "--json"], journal_path)
    payload = json_payload(status_output)

    assert payload["command"] == "status"
    assert payload["runId"] == run_id
    assert payload["state"] == "completed"
    assert payload["treeName"] == "cli-persist"
  end
end
