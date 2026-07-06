defmodule Workflow.ResumeTest do
  @moduledoc """
  Slice #5: the exactly-once effect boundary, resume, and the single-writer run
  lease — proven at the highest seam (`Workflow.Run` + a real crash + a resume),
  never by inspecting process internals. Each assertion is on external behaviour:
  a call-counting / charge-counting mock provider, the committed journal, the
  registry lease, and the folded read model.
  """
  use ExUnit.Case, async: true

  alias Workflow.{Run, Journal, Status, Ledger, IdempotencyKey}
  alias Workflow.Test.{EchoProvider, GateProvider, LedgeredProvider}

  # A run whose first turn commits and whose second turn can be held in flight.
  defmodule TwoAgents do
    use Workflow

    workflow "two-agents" do
      agent("first")
      agent("second")
      return(:ok)
    end
  end

  # A single paid turn, used for lease-takeover and the return→commit crash window.
  defmodule OneAgent do
    use Workflow

    workflow "one-agent" do
      agent("do it")
      return(:ok)
    end
  end

  defp run_id, do: "run_#{System.unique_integer([:positive])}"

  defp await_lease_released(run_id, tries \\ 200) do
    cond do
      Registry.lookup(Workflow.Run.Registry, run_id) == [] -> :ok
      tries == 0 -> flunk("lease for #{run_id} was never released")
      true -> Process.sleep(5); await_lease_released(run_id, tries - 1)
    end
  end

  defp kill_and_await(run_id, pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    await_lease_released(run_id)
  end

  @tag :capture_log
  test "killing a run mid-agent-turn then resuming does not re-invoke the committed turn" do
    id = run_id()

    # First run: agent "first" commits; the writer then blocks inside agent "second".
    {:ok, ^id, pid} =
      Run.start(TwoAgents, run_id: id, provider: {GateProvider, sink: self(), gate_on: "second"})

    assert_receive {:agent_called, "first"}
    assert_receive {:agent_called, "second"}
    assert_receive {:at_agent, ^pid}

    # The completed turn is durably journaled; the in-flight one is not.
    assert [%{payload: %{address: [0]}}] =
             Enum.filter(Journal.fold(id), &(&1.type == :agent_committed))

    kill_and_await(id, pid)

    # Resume with a fresh call-counting provider.
    assert {:ok, ^id} = Run.run(TwoAgents, run_id: id, provider: {EchoProvider, sink: self()})

    # The committed turn ("first") was replayed from the journal — never re-invoked.
    refute_received {:agent_called, "first"}
    # Only the uncommitted turn ("second") ran on resume.
    assert_received {:agent_called, "second"}
    refute_received {:agent_called, _}

    status = Status.of(id)
    assert status.state == :completed
    assert status.result == :ok

    # Exactly one committed turn per address: agent "first" was not re-committed.
    committed = Enum.filter(Journal.fold(id), &(&1.type == :agent_committed))
    assert Enum.map(committed, & &1.payload.address) == [[0], [1]]
  end

  @tag :capture_log
  test "one live writer holds the lease; a stale lease is taken over on resume" do
    id = run_id()

    {:ok, ^id, pid} = Run.start(OneAgent, run_id: id, provider: {GateProvider, sink: self()})
    assert_receive {:agent_called, "do it"}
    assert_receive {:at_agent, ^pid}

    # A second writer cannot hold the same run while the first is live.
    assert {:error, {:already_running, ^pid}} =
             Run.start(OneAgent, run_id: id, provider: {GateProvider, sink: self()})

    # The live writer dies; the registry releases the lease via its monitor — no
    # heartbeat, no pid-probe poll.
    kill_and_await(id, pid)

    # Resume takes over the freed lease and drives the run to completion.
    assert {:ok, ^id} = Run.run(OneAgent, run_id: id, provider: {EchoProvider, sink: self()})
    assert Status.of(id).state == :completed
  end

  @tag :capture_log
  test "a crash between provider-return and commit neither double-spends nor drops the effect" do
    id = run_id()
    {:ok, store} = LedgeredProvider.start()
    key = %IdempotencyKey{run_id: id, node_path: [0], iteration: 0}

    # First run: the provider records the paid effect, then hard-kills the writer
    # before it can commit — the exact return→commit window.
    assert {:error, {:run_crashed, :killed}} =
             Run.run(OneAgent,
               run_id: id,
               provider: {LedgeredProvider, store: store, sink: self(), crash_once: true}
             )

    assert_received {:agent_called, "do it"}

    # The effect was charged once server-side, but no commit landed — the journal
    # holds no agent result yet.
    assert LedgeredProvider.charges(store, key) == 1
    assert Enum.find(Journal.fold(id), &(&1.type == :agent_committed)) == nil

    await_lease_released(id)

    # Resume: the deduping provider replays the effect; the commit finally lands.
    assert {:ok, ^id} =
             Run.run(OneAgent, run_id: id, provider: {LedgeredProvider, store: store, sink: self()})

    # It was re-invoked (nothing was committed to replay from) ...
    assert_received {:agent_called, "do it"}
    # ... but the paid effect was NOT charged a second time: exactly-once.
    assert LedgeredProvider.charges(store, key) == 1

    # And the effect was not dropped: it is committed exactly once and accounted once.
    committed = Enum.filter(Journal.fold(id), &(&1.type == :agent_committed))
    assert [%{payload: %{result: %{"echo" => "do it"}}}] = committed

    status = Status.of(id)
    assert status.state == :completed
    assert status.result == :ok
    assert Ledger.of(id).spent == 2
  end
end
