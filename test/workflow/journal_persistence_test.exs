defmodule Workflow.JournalPersistenceTest do
  use ExUnit.Case, async: false

  alias Workflow.Event
  alias Workflow.Journal
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

  test "restarting the journal rebuilds every later dependent child" do
    names = [
      Workflow.Journal,
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
    assert :ok = Journal.append(run_id, 0, %{event | run_id: run_id, seq: 0})

    journal_path = :sys.get_state(Journal).path

    child = """
    try do
      Workflow.Journal.fold(#{inspect(run_id)})
      System.halt(23)
    rescue
      ArgumentError -> IO.write("unsafe atom rejected")
    end
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
    assert String.ends_with?(output, "unsafe atom rejected")
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
