defmodule Workflow.ResumeTest do
  @moduledoc """
  Slice #5: the exactly-once effect boundary, resume, and the single-writer run
  lease — proven at the highest seam (`Workflow.Run` + a real crash + a resume),
  never by inspecting process internals. Each assertion is on external behaviour:
  a call-counting / charge-counting mock provider, the committed journal, the
  registry lease, and the folded read model.
  """
  use ExUnit.Case, async: true

  alias Workflow.{Run, Journal, Status, Ledger, Event, IdempotencyKey}
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

  # A fan-out region that precedes a gated agent, so a run can be held in flight
  # *after* the whole parallel bracket is journaled but before the gate settles.
  defmodule FanoutThenGate do
    use Workflow

    workflow "fanout-then-gate" do
      parallel([agent("a"), agent("b")])
      agent("gate")
      return(:ok)
    end
  end

  defmodule InjectedThenGate do
    use Workflow

    workflow "injected-then-gate" do
      let(:draft = agent("draft"))
      agent(~P"improve: <%= @draft %>")
      return(:ok)
    end
  end

  defmodule JournaledDynamicFanout do
    use Workflow

    workflow "journaled-dynamic-fanout" do
      fanout width: budget_slices(per: 10, max: 5) do
        agent("branch")
      end

      return(:ok)
    end
  end

  defp run_id, do: "run_#{System.unique_integer([:positive])}"

  defp await_lease_released(run_id, tries \\ 200) do
    cond do
      Registry.lookup(Workflow.Run.Registry, run_id) == [] ->
        :ok

      tries == 0 ->
        flunk("lease for #{run_id} was never released")

      true ->
        Process.sleep(5)
        await_lease_released(run_id, tries - 1)
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
  test "resuming past a completed fan-out region reuses its brackets, not re-emits them" do
    id = run_id()

    # First run: both branches commit and the parallel region is fully bracketed;
    # the writer then blocks inside the gate agent, mid-run.
    {:ok, ^id, pid} =
      Run.start(FanoutThenGate,
        run_id: id,
        provider: {GateProvider, sink: self(), gate_on: "gate"}
      )

    for p <- ~w(a b gate), do: assert_receive({:agent_called, ^p})
    assert_receive {:at_agent, ^pid}

    # The fan-out region is fully journaled before the crash: one started, both
    # branches, one completed.
    before = Journal.fold(id) |> Enum.map(& &1.type)
    assert Enum.count(before, &(&1 == :parallel_started)) == 1
    assert Enum.count(before, &(&1 == :parallel_completed)) == 1

    kill_and_await(id, pid)

    # Resume re-walks the tree from the top, re-entering the already-completed
    # fan-out node before reaching the still-open gate.
    assert {:ok, ^id} =
             Run.run(FanoutThenGate, run_id: id, provider: {EchoProvider, sink: self()})

    # Only the uncommitted gate turn ran on resume; the settled branches replayed.
    refute_received {:agent_called, "a"}
    refute_received {:agent_called, "b"}
    assert_received {:agent_called, "gate"}

    # The bracket is exactly-once: resume did not double-emit the started/completed
    # markers, so a fold that pairs them sees a single region.
    types = Journal.fold(id) |> Enum.map(& &1.type)
    assert Enum.count(types, &(&1 == :parallel_started)) == 1
    assert Enum.count(types, &(&1 == :parallel_completed)) == 1

    assert Status.of(id).state == :completed
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
             Run.run(OneAgent,
               run_id: id,
               provider: {LedgeredProvider, store: store, sink: self()}
             )

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

  @tag :capture_log
  test "resume re-renders a top-level injected prompt from journaled bindings without re-running the producer" do
    id = run_id()

    {:ok, ^id, pid} =
      Run.start(InjectedThenGate,
        run_id: id,
        provider: {GateProvider, sink: self(), gate_on: "improve: %{}"}
      )

    assert_receive {:agent_called, "draft"}
    assert_receive {:agent_called, "improve: %{}"}
    assert_receive {:at_agent, ^pid}

    assert [%{payload: %{address: [0], result: %{}}}] =
             Enum.filter(Journal.fold(id), &(&1.type == :agent_committed))

    kill_and_await(id, pid)

    assert {:ok, ^id} =
             Run.run(InjectedThenGate, run_id: id, provider: {EchoProvider, sink: self()})

    refute_received {:agent_called, "draft"}
    assert_received {:agent_called, "improve: %{}"}
    refute_received {:agent_called, _}

    committed =
      Enum.find(
        Journal.fold(id),
        &(&1.type == :agent_committed and &1.payload.address == [1])
      )

    assert committed.payload.prompt == "improve: %{}"
  end

  test "resume replays a journaled generic fanout width instead of recomputing budget_slices" do
    id = run_id()
    tree = JournaledDynamicFanout.__workflow__(:tree)
    [fanout, _return] = tree.nodes

    :ok = Journal.register_run(id)
    :ok = Journal.append(id, 0, Event.run_started(tree, 5))
    :ok = Journal.append(id, 1, Event.fanout_started(fanout, 3))

    assert {:ok, ^id} =
             Run.run(JournaledDynamicFanout,
               run_id: id,
               budget: 5,
               provider: {EchoProvider, sink: self()}
             )

    for _ <- 1..3, do: assert_received({:agent_called, "branch"})
    refute_received {:agent_called, _}

    events = Journal.fold(id)
    assert Enum.count(events, &(&1.type == :fanout_started)) == 1

    assert events
           |> Enum.filter(&(&1.type == :agent_committed))
           |> Enum.map(& &1.payload.address) == [[0, 0, 0], [0, 1, 0], [0, 2, 0]]
  end
end
