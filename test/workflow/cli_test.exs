defmodule Workflow.CLITest do
  @moduledoc """
  Slice #12: the `agent-loops` command surface, exercised at the real CLI seam —
  `Workflow.CLI.exec/1` (argv in, printed envelope + exit code out). Every assertion
  is on external behaviour: the JSON payload, the exit code, and the folded journal.
  No CLI internals are inspected.

  Workflows are written to disk and loaded through the same compile-time gate the
  runner uses, so `validate` and `run` share one path. Runs use the offline mock
  provider; call counts are read from the journal (the source of truth), which
  records one `agent_committed` per paid turn.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Workflow.{Journal, Status}

  @moduletag :capture_log

  # --- Fixtures: real workflow scripts compiled by the CLI ---

  defp write_workflow(block) do
    mod = "CLIFixture#{System.unique_integer([:positive])}"

    source = """
    defmodule #{mod} do
      use Workflow
      #{block}
    end
    """

    dir = Path.join(System.tmp_dir!(), "agent_loops_cli_test")
    File.mkdir_p!(dir)
    path = Path.join(dir, "wf_#{System.unique_integer([:positive])}.exs")
    File.write!(path, source)
    path
  end

  defp demo_workflow do
    write_workflow(~S"""
    workflow "cli-demo" do
      phase "p"
      log "hello"
      agent "say hi"
      return :ok
    end
    """)
  end

  # A schema-backed turn the echo mock cannot satisfy: it echoes {"echo" => prompt},
  # which lacks the required "answer" key, so the node fails closed (exit 8).
  defp schema_fail_workflow do
    write_workflow(~S"""
    workflow "cli-schema-fail" do
      agent "answer me",
        schema: %{
          "type" => "object",
          "properties" => %{"answer" => %{"type" => "string"}},
          "required" => ["answer"]
        },
        retries: 0
      return :ok
    end
    """)
  end

  defp bad_workflow do
    write_workflow(~S"""
    workflow "cli-bad" do
      frobnicate "nope"
      return :ok
    end
    """)
  end

  defp run_id, do: "run_cli_#{System.unique_integer([:positive])}"

  # --- Seam helpers: capture stdout / stderr and the returned exit code ---

  defp on_stdout(argv), do: with_io(fn -> Workflow.CLI.exec(argv) end)
  defp on_stderr(argv), do: with_io(:stderr, fn -> Workflow.CLI.exec(argv) end)

  # The JSON discipline: exactly one final payload line, decoded, always with a
  # `command` field.
  defp sole_payload(stdout) do
    lines = stdout |> String.trim() |> String.split("\n", trim: true)
    assert length(lines) == 1, "expected exactly one stdout payload, got: #{inspect(lines)}"
    payload = Jason.decode!(hd(lines))
    assert Map.has_key?(payload, "command")
    payload
  end

  # The failure contract: the last stderr line is a single-line JSON error object.
  defp last_error(stderr) do
    stderr |> String.trim_trailing() |> String.split("\n") |> List.last() |> Jason.decode!()
  end

  # --- validate ---

  test "validate accepts a well-formed workflow (json: one payload, exit 0)" do
    {code, out} = on_stdout(["validate", demo_workflow(), "--json"])

    assert code == 0
    payload = sole_payload(out)
    assert payload["command"] == "validate"
    assert payload["valid"] == true
    assert payload["name"] == "cli-demo"
    assert payload["nodeCount"] == 4
  end

  test "validate without --json prints human text and exits 0" do
    {code, out} = on_stdout(["validate", demo_workflow()])

    assert code == 0
    assert out =~ "valid"
    assert out =~ "cli-demo"
  end

  test "validate rejects a malformed workflow with the #2 findings and exit 6" do
    {code, err} = on_stderr(["validate", bad_workflow(), "--json"])

    assert code == 6
    error = last_error(err)
    assert error["code"] == "validation"
    assert error["exitCode"] == 6
    # The rustc-style finding from the compile-time gate is carried through.
    assert error["message"] =~ "unknown combinator `frobnicate`"
  end

  # --- run / test ---

  test "run drives a workflow to completion (json payload + folded journal)" do
    id = run_id()
    {code, out} = on_stdout(["run", demo_workflow(), "--run-id", id, "--provider", "mock", "--json"])

    assert code == 0
    payload = sole_payload(out)
    assert payload["command"] == "run"
    assert payload["runId"] == id
    assert payload["state"] == "completed"
    assert payload["result"] == "ok"

    # External truth: the run is completed and the single agent turn is journaled.
    assert Status.of(id).state == :completed
    committed = Enum.filter(Journal.fold(id), &(&1.type == :agent_committed))
    assert length(committed) == 1
  end

  test "run without --json renders human output and exits 0" do
    id = run_id()
    {code, out} = on_stdout(["run", demo_workflow(), "--run-id", id, "--provider", "mock"])

    assert code == 0
    assert out =~ id
    assert out =~ "completed"
  end

  test "test pins the mock provider even when --provider codex is passed" do
    id = run_id()
    # codex would shell out; the run staying offline and completing proves the pin.
    {code, out} = on_stdout(["test", demo_workflow(), "--run-id", id, "--provider", "codex", "--json"])

    assert code == 0
    payload = sole_payload(out)
    assert payload["command"] == "test"
    assert payload["state"] == "completed"
  end

  test "run of a fail-closed schema turn exits 8 with a malformed-output error" do
    id = run_id()
    {code, err} = on_stderr(["run", schema_fail_workflow(), "--run-id", id, "--provider", "mock", "--json"])

    assert code == 8
    error = last_error(err)
    assert error["code"] == "malformed-output"
    assert error["exitCode"] == 8

    # The terminal failure is journaled; the read model folds to :failed.
    assert Status.of(id).state == :failed
  end

  # --- error / exit-code contract ---

  test "an unknown provider is a provider-config error (exit 4)" do
    {code, err} = on_stderr(["run", demo_workflow(), "--provider", "bogus", "--json"])

    assert code == 4
    error = last_error(err)
    assert error["code"] == "provider-config"
    assert error["exitCode"] == 4
  end

  test "a non-positive budget is a usage error (exit 2)" do
    {code, err} = on_stderr(["run", demo_workflow(), "--provider", "mock", "--budget", "0", "--json"])

    assert code == 2
    assert last_error(err)["code"] == "usage"
  end

  test "an unknown command is a usage error (exit 2)" do
    {code, err} = on_stderr(["frobnicate", "--json"])

    assert code == 2
    assert last_error(err)["code"] == "usage"
  end

  test "a missing script path is a usage error (exit 2)" do
    {code, err} = on_stderr(["run", "--provider", "mock", "--json"])

    assert code == 2
    assert last_error(err)["code"] == "usage"
  end

  test "the removed --journal flag is rejected as a usage error (exit 2)" do
    {code, err} = on_stderr(["status", "--journal", "x", "--json"])

    assert code == 2
    error = last_error(err)
    assert error["code"] == "usage"
    assert error["message"] =~ "--journal was removed"
  end

  # --- read surfaces: pure folds over the journal ---

  test "status folds the journal for a selected run (json: one payload, exit 0)" do
    id = run_id()
    {0, _} = on_stdout(["run", demo_workflow(), "--run-id", id, "--provider", "mock", "--json"])

    {code, out} = on_stdout(["status", "--run-id", id, "--json"])

    assert code == 0
    payload = sole_payload(out)
    assert payload["command"] == "status"
    assert payload["runId"] == id
    assert payload["state"] == "completed"
    assert payload["usage"]["totalTokens"] == 0
    assert is_list(payload["recentEvents"])
  end

  test "status of an unknown run is a usage error (exit 2)" do
    {code, err} = on_stderr(["status", "--run-id", "run_does_not_exist", "--json"])

    assert code == 2
    assert last_error(err)["code"] == "usage"
  end

  test "status without --run-id selects a run from the index (exit 0)" do
    id = run_id()
    {0, _} = on_stdout(["run", demo_workflow(), "--run-id", id, "--provider", "mock", "--json"])

    {code, out} = on_stdout(["status", "--json"])

    assert code == 0
    payload = sole_payload(out)
    assert payload["command"] == "status"
    # The selected run is a real, indexed run (latest-selection is journal-derived).
    assert payload["runId"] in Journal.run_ids()
  end

  test "inspect returns the full folded event stream (exit 0)" do
    id = run_id()
    {0, _} = on_stdout(["run", demo_workflow(), "--run-id", id, "--provider", "mock", "--json"])

    {code, out} = on_stdout(["inspect", "--run-id", id, "--json"])

    assert code == 0
    payload = sole_payload(out)
    assert payload["command"] == "inspect"

    types = Enum.map(payload["events"], & &1["type"])
    assert types == ~w(run_started phase_entered log_emitted agent_committed run_completed)
  end

  test "list projects every run and includes the just-created one (exit 0)" do
    id = run_id()
    {0, _} = on_stdout(["run", demo_workflow(), "--run-id", id, "--provider", "mock", "--json"])

    {code, out} = on_stdout(["list", "--json"])

    assert code == 0
    payload = sole_payload(out)
    assert payload["command"] == "list"

    mine = Enum.find(payload["runs"], &(&1["runId"] == id))
    assert mine["state"] == "completed"
    assert mine["treeName"] == "cli-demo"
  end

  # --- resume ---

  test "resume of a completed run replays from the journal without re-running (exit 0)" do
    id = run_id()
    script = demo_workflow()
    {0, _} = on_stdout(["run", script, "--run-id", id, "--provider", "mock", "--json"])

    before = Enum.count(Journal.fold(id), &(&1.type == :agent_committed))
    assert before == 1

    # No script argument: the workflow is recovered from the run's journaled path.
    {code, out} = on_stdout(["resume", "--run-id", id, "--provider", "mock", "--json"])

    assert code == 0
    payload = sole_payload(out)
    assert payload["command"] == "resume"
    assert payload["state"] == "completed"

    # Exactly-once: resume did not re-commit the settled turn.
    assert Enum.count(Journal.fold(id), &(&1.type == :agent_committed)) == 1
  end
end
