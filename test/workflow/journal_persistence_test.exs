defmodule Workflow.JournalPersistenceTest do
  use ExUnit.Case, async: false

  alias Workflow.{Event, Journal, Tree}

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

  test "events and run index survive a journal process restart" do
    run_id = "run_journal_persist_#{System.unique_integer([:positive])}"
    first = Event.run_started(%Tree{nodes: []}, 25, "/tmp/workflow.exs")
    second = Event.run_completed(:ok)

    assert :ok = Journal.register_run(run_id)
    assert :ok = Journal.append(run_id, 0, %{first | run_id: run_id, seq: 0})
    assert :ok = Journal.append(run_id, 1, %{second | run_id: run_id, seq: 1})

    assert Journal.last_seq(run_id) == 1
    assert Journal.fold(run_id) |> Enum.map(& &1.type) == [:run_started, :run_completed]

    assert restart_journal()

    assert Journal.last_seq(run_id) == 1
    assert Journal.fold(run_id) |> Enum.map(& &1.type) == [:run_started, :run_completed]
    assert run_id in Journal.run_ids()
    assert Journal.latest_run_id() == run_id
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
