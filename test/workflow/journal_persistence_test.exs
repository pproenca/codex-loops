defmodule Workflow.JournalPersistenceTest do
  use ExUnit.Case, async: false

  alias Exqlite.Sqlite3
  alias Workflow.Event
  alias Workflow.Event.Payload, as: P
  alias Workflow.IdempotencyKey
  alias Workflow.Journal
  alias Workflow.Node.Agent
  alias Workflow.Provider.Activity
  alias Workflow.Provider.Usage
  alias Workflow.Tree

  defp restart_journal do
    old = Process.whereis(Journal)
    ref = Process.monitor(old)
    Process.exit(old, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old, :killed}

    await_journal_restart(old)
  end

  defp await_journal_restart(old, tries \\ 100)
  defp await_journal_restart(_old, 0), do: flunk("Journal did not restart")

  defp await_journal_restart(old, tries) do
    case Process.whereis(Journal) do
      pid when is_pid(pid) and pid != old ->
        pid

      _other ->
        Process.sleep(10)
        await_journal_restart(old, tries - 1)
    end
  end

  defp await_restarted(names, previous, tries \\ 200)

  defp await_restarted(names, previous, tries) do
    current = Map.new(names, &{&1, Process.whereis(&1)})

    if Enum.all?(names, fn name -> is_pid(current[name]) and current[name] != previous[name] end) do
      current
    else
      if tries == 0, do: flunk("dependent children did not restart: #{inspect(current)}")
      Process.sleep(10)
      await_restarted(names, previous, tries - 1)
    end
  end

  defp run_in_fresh_beam(source, journal_path) do
    mix = System.find_executable("mix") || flunk("mix executable not found")

    System.cmd(mix, ["run", "-e", source],
      cd: File.cwd!(),
      env: [
        {"MIX_ENV", "test"},
        {"CODEX_LOOPS_JOURNAL_PATH", journal_path}
      ],
      stderr_to_stdout: true
    )
  end

  defp stored_event(run_id) do
    journal_path = :sys.get_state(Journal).path
    {:ok, db} = Sqlite3.open(journal_path, mode: :readonly)

    try do
      {:ok, statement} = Sqlite3.prepare(db, "SELECT event_blob FROM events WHERE run_id = ?")

      try do
        :ok = Sqlite3.bind(statement, [run_id])
        {:ok, [[blob]]} = Sqlite3.fetch_all(db, statement)
        :erlang.binary_to_term(blob, [:safe])
      after
        Sqlite3.release(db, statement)
      end
    after
      Sqlite3.close(db)
    end
  end

  test "events and run index survive a journal process restart" do
    run_id = "run_journal_persist_#{System.unique_integer([:positive])}"
    first = Event.run_started(%Tree{nodes: []}, 25, "/tmp/workflow.exs")
    second = Event.run_completed(:ok)

    assert :ok = Journal.register_run(run_id)
    assert {:ok, %{seq: 0}} = Journal.append_next(run_id, first)
    assert {:ok, %{seq: 1}} = Journal.append_next(run_id, second)

    assert Journal.last_seq(run_id) == 1
    assert run_id |> Journal.fold() |> Enum.map(& &1.type) == [:run_started, :run_completed]

    assert restart_journal()

    assert Journal.last_seq(run_id) == 1
    assert run_id |> Journal.fold() |> Enum.map(& &1.type) == [:run_started, :run_completed]
    assert run_id in Journal.run_ids()
    assert Journal.latest_run_id() == run_id
  end

  test "payload variants retain the version-one map shape on disk" do
    run_id = "run_journal_payload_shape_#{System.unique_integer([:positive])}"
    event = Event.run_completed(%{"answer" => "ok"})

    assert :ok = Journal.register_run(run_id)
    assert {:ok, %{seq: 0}} = Journal.append_next(run_id, event)

    assert %Event{payload: %{value: %{"answer" => "ok"}} = stored_payload} = stored_event(run_id)
    refute is_struct(stored_payload)

    assert [%Event{payload: %P.RunCompleted{value: %{"answer" => "ok"}}}] =
             Journal.fold(run_id)
  end

  test "legacy run-started maps hydrate a nil workspace root" do
    legacy = %Event{
      run_id: "legacy_workspace",
      seq: 0,
      type: :run_started,
      payload: %{
        tree_name: "legacy",
        tree_version: 1,
        node_count: 0,
        budget: nil,
        script_path: "/tmp/legacy.exs"
      }
    }

    assert %Event{
             payload: %P.RunStarted{
               script_path: "/tmp/legacy.exs",
               workspace_root: nil
             }
           } = Event.normalize(legacy)
  end

  test "additive payload keys survive persistence and typed hydration" do
    run_id = "run_journal_additive_payload_#{System.unique_integer([:positive])}"
    event = Event.run_completed(:ok)
    event = %{event | payload: Map.put(event.payload, :future_payload_key, "preserved")}

    assert :ok = Journal.register_run(run_id)
    assert {:ok, %{seq: 0}} = Journal.append_next(run_id, event)

    assert %Event{payload: stored_payload} = stored_event(run_id)
    refute is_struct(stored_payload)
    assert Map.fetch!(stored_payload, :future_payload_key) == "preserved"

    assert [%Event{payload: %P.RunCompleted{value: :ok} = payload}] = Journal.fold(run_id)
    assert Map.fetch!(payload, :future_payload_key) == "preserved"
  end

  test "restarting the journal rebuilds every later dependent child" do
    names = [
      Journal,
      Workflow.Run.Registry,
      Workflow.PubSub,
      Workflow.TaskSupervisor,
      Workflow.Run.Supervisor,
      Workflow.Web.Endpoint
    ]

    previous = Map.new(names, &{&1, Process.whereis(&1)})
    assert restart_journal()
    restarted = await_restarted(names, previous)

    assert Enum.all?(restarted, fn {_name, pid} -> Process.alive?(pid) end)
  end

  test "safe decoding rejects a blob that would mint an atom in a fresh BEAM" do
    run_id = "run_fresh_beam_#{System.unique_integer([:positive])}"
    value = :journal_atom_defined_only_in_persistence_test_7dd3
    event = Event.run_completed(value)

    assert :ok = Journal.register_run(run_id)
    assert {:ok, %{seq: 0}} = Journal.append_next(run_id, event)

    journal_path = :sys.get_state(Journal).path

    child = """
    try do
      Workflow.Journal.fold(#{inspect(run_id)})
      System.halt(23)
    rescue
      ArgumentError -> IO.write("unsafe atom rejected")
    end
    """

    {output, status} = run_in_fresh_beam(child, journal_path)

    assert status == 0, output
    assert String.ends_with?(output, "unsafe atom rejected")
  end

  test "a fresh BEAM decodes legitimate nested event structs and atom payload keys" do
    run_id = "run_fresh_beam_nested_#{System.unique_integer([:positive])}"

    event =
      Event.agent_committed(
        %Agent{address: [1], prompt: "inspect", label: "inspect:nested"},
        2,
        %IdempotencyKey{run_id: run_id, node_path: [1], iteration: 2, attempt: 1},
        %{"answer" => "ok"},
        %Usage{input_tokens: 3, output_tokens: 5, total_tokens: 8},
        [
          %Activity{
            kind: "command_execution",
            label: "Shell",
            summary: "mix test",
            status: :completed,
            activity_index: 0
          }
        ]
      )

    assert :ok = Journal.register_run(run_id)
    assert {:ok, %{seq: 0}} = Journal.append_next(run_id, event)
    assert restart_journal()

    journal_path = :sys.get_state(Journal).path

    child = """
    events = Workflow.Journal.fold(#{inspect(run_id)})
    IO.write("decoded-events:" <> Integer.to_string(length(events)))
    """

    {output, status} = run_in_fresh_beam(child, journal_path)

    assert status == 0, output
    assert String.ends_with?(output, "decoded-events:1")

    assert %Event{payload: %{activity: [stored_activity]}} = stored_event(run_id)
    refute is_struct(stored_activity)
    assert stored_activity.status == :completed

    assert [
             %Event{
               payload: %{
                 idempotency_key: %IdempotencyKey{attempt: 1},
                 usage: %Usage{total_tokens: 8},
                 activity: [%Activity{status: :completed, activity_index: 0}]
               }
             }
           ] = Journal.fold(run_id)
  end

  test "register_run is idempotent and preserves original creation order" do
    first = "run_order_first_#{System.unique_integer([:positive])}"
    second = "run_order_second_#{System.unique_integer([:positive])}"

    assert :ok = Journal.register_run(first)
    assert :ok = Journal.register_run(second)
    assert :ok = Journal.register_run(first)

    ids = Journal.run_ids()
    assert Enum.find_index(ids, &(&1 == first)) < Enum.find_index(ids, &(&1 == second))
  end
end
