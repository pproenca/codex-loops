defmodule Workflow.JournalPersistenceTest do
  use ExUnit.Case, async: false

  alias Workflow.Event
  alias Workflow.Journal
  alias Workflow.Node.Agent
  alias Workflow.Run.ActivityPersistenceSubscriber
  alias Workflow.Run.Stream, as: RunStream
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

  defp restart_activity_subscriber do
    old = Process.whereis(ActivityPersistenceSubscriber)
    ref = Process.monitor(old)
    Process.exit(old, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old, :killed}

    await_activity_subscriber_restart(old)
  end

  defp await_activity_subscriber_restart(old, tries \\ 100)
  defp await_activity_subscriber_restart(_old, 0), do: flunk("Activity subscriber did not restart")

  defp await_activity_subscriber_restart(old, tries) do
    case Process.whereis(ActivityPersistenceSubscriber) do
      pid when is_pid(pid) and pid != old ->
        pid

      _other ->
        Process.sleep(10)
        await_activity_subscriber_restart(old, tries - 1)
    end
  end

  defp wait_for_activity_count(run_id, count, tries \\ 100)

  defp wait_for_activity_count(run_id, count, 0) do
    flunk("expected #{count} persisted activity events, got: #{inspect(Journal.fold(run_id))}")
  end

  defp wait_for_activity_count(run_id, count, tries) do
    events = Enum.filter(Journal.fold(run_id), &(&1.type == :agent_activity))

    if length(events) == count do
      events
    else
      Process.sleep(10)
      wait_for_activity_count(run_id, count, tries - 1)
    end
  end

  defp restart_pubsub do
    old = Process.whereis(Workflow.PubSub)
    ref = Process.monitor(old)
    assert :ok = Supervisor.terminate_child(Workflow.Supervisor, Phoenix.PubSub.Supervisor)
    assert_receive {:DOWN, ^ref, :process, ^old, _reason}
    assert {:ok, _pid} = Supervisor.restart_child(Workflow.Supervisor, Phoenix.PubSub.Supervisor)

    await_pubsub_restart(old)
  end

  defp await_pubsub_restart(old, tries \\ 100)
  defp await_pubsub_restart(_old, 0), do: flunk("PubSub did not restart")

  defp await_pubsub_restart(old, tries) do
    case Process.whereis(Workflow.PubSub) do
      pid when is_pid(pid) and pid != old ->
        pid

      _other ->
        Process.sleep(10)
        await_pubsub_restart(old, tries - 1)
    end
  end

  defp await_activity_subscriber_pubsub(pubsub_pid, tries \\ 100)
  defp await_activity_subscriber_pubsub(_pubsub_pid, 0), do: flunk("Activity subscriber did not resubscribe")

  defp await_activity_subscriber_pubsub(pubsub_pid, tries) do
    case :sys.get_state(ActivityPersistenceSubscriber) do
      %{pubsub_pid: ^pubsub_pid, pubsub_ref: ref} when is_reference(ref) ->
        :ok

      _state ->
        Process.sleep(10)
        await_activity_subscriber_pubsub(pubsub_pid, tries - 1)
    end
  end

  test "events and run index survive a journal process restart" do
    run_id = "run_journal_persist_#{System.unique_integer([:positive])}"
    first = Event.run_started(%Tree{nodes: []}, 25, "/tmp/workflow.exs")
    second = Event.run_completed(:ok)

    assert :ok = Journal.register_run(run_id)
    assert :ok = Journal.append(run_id, 0, %{first | run_id: run_id, seq: 0})
    assert :ok = Journal.append(run_id, 1, %{second | run_id: run_id, seq: 1})

    assert Journal.last_seq(run_id) == 1
    assert run_id |> Journal.fold() |> Enum.map(& &1.type) == [:run_started, :run_completed]

    assert restart_journal()

    assert Journal.last_seq(run_id) == 1
    assert run_id |> Journal.fold() |> Enum.map(& &1.type) == [:run_started, :run_completed]
    assert run_id in Journal.run_ids()
    assert Journal.latest_run_id() == run_id
  end

  test "events containing workflow-authored atoms survive a fresh BEAM restart" do
    run_id = "run_fresh_beam_#{System.unique_integer([:positive])}"
    value = String.to_atom("workflow_value_#{System.unique_integer([:positive])}")
    event = Event.run_completed(value)

    assert :ok = Journal.register_run(run_id)
    assert :ok = Journal.append(run_id, 0, %{event | run_id: run_id, seq: 0})

    journal_path = :sys.get_state(Journal).path

    child = """
    [%Workflow.Event{payload: %{value: value}}] = Workflow.Journal.fold(#{inspect(run_id)})
    IO.write(inspect(value))
    """

    mix = System.find_executable("mix") || flunk("mix executable not found")

    {output, status} =
      System.cmd(mix, ["run", "-e", child],
        cd: File.cwd!(),
        env: [
          {"MIX_ENV", "test"},
          {"CODEX_LOOPS_JOURNAL_PATH", journal_path}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert String.ends_with?(output, inspect(value))
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

  test "activity persistence subscriber dedupes duplicate progress by stable attempt identity and index" do
    run_id = "run_activity_persist_#{System.unique_integer([:positive])}"
    node = %Agent{address: [2], prompt: "stream"}

    assert :ok = Journal.register_run(run_id)

    first =
      Event.agent_activity(node, 0, 0, 0, %{
        kind: "lifecycle",
        label: "Turn started",
        summary: "first",
        status: "running"
      })

    repeated =
      Event.agent_activity(node, 0, 0, 1, %{
        kind: "reasoning",
        label: "Reasoning",
        summary: "second",
        status: "completed"
      })

    assert :ok = RunStream.emit(run_id, first)
    assert :ok = RunStream.emit(run_id, first)
    assert :ok = RunStream.emit(run_id, repeated)

    persisted = wait_for_activity_count(run_id, 2)

    assert Enum.map(persisted, & &1.seq) == [0, 1]
    assert Enum.map(persisted, & &1.payload.activity_index) == [0, 1]
    assert Enum.map(persisted, & &1.payload.entry.summary) == ["first", "second"]
  end

  test "activity persistence subscriber resubscribes after restart" do
    run_id = "run_activity_resubscribe_#{System.unique_integer([:positive])}"
    node = %Agent{address: [3], prompt: "stream after restart"}

    assert :ok = Journal.register_run(run_id)
    assert restart_activity_subscriber()

    assert :ok =
             RunStream.emit(
               run_id,
               Event.agent_activity(node, 0, 0, 0, %{
                 kind: "tool",
                 label: "shell",
                 summary: "after restart",
                 status: "completed"
               })
             )

    assert [%{payload: %{entry: %{summary: "after restart"}}}] = wait_for_activity_count(run_id, 1)
  end

  test "activity persistence subscriber resubscribes after PubSub restart" do
    run_id = "run_activity_pubsub_resubscribe_#{System.unique_integer([:positive])}"
    node = %Agent{address: [4], prompt: "stream after pubsub restart"}

    assert :ok = Journal.register_run(run_id)
    new_pubsub = restart_pubsub()
    assert :ok = await_activity_subscriber_pubsub(new_pubsub)

    assert :ok =
             RunStream.emit(
               run_id,
               Event.agent_activity(node, 0, 0, 0, %{
                 kind: "tool",
                 label: "shell",
                 summary: "after pubsub restart",
                 status: "completed"
               })
             )

    assert [%{payload: %{entry: %{summary: "after pubsub restart"}}}] = wait_for_activity_count(run_id, 1)
  end
end
