defmodule Workflow.ResumeTest do
  @moduledoc """
  The durable at-most-once effect boundary, resume, and the single-writer run
  lease — proven at the highest seam (`Workflow.Run` + a real crash + a resume),
  never by inspecting process internals. Each assertion is on external behaviour:
  a call-counting / charge-counting mock provider, the committed journal, the
  registry lease, and the folded read model.
  """
  use ExUnit.Case, async: true

  alias Workflow.Event
  alias Workflow.IdempotencyKey
  alias Workflow.Journal
  alias Workflow.Ledger
  alias Workflow.Run
  alias Workflow.Status
  alias Workflow.Test.EchoProvider
  alias Workflow.Test.GateProvider
  alias Workflow.Test.LedgeredProvider

  @receive_timeout 1_000

  # A run whose first turn commits and whose second turn can be held in flight.
  defmodule TwoAgents do
    @moduledoc false

    def tree do
      Workflow.Test.tree!(
        "two-agents",
        quote do
          agent("first")
          agent("second")
          return(:ok)
        end,
        __ENV__
      )
    end
  end

  # A single paid turn, used for lease-takeover and the return→commit crash window.
  defmodule OneAgent do
    @moduledoc false

    def tree do
      Workflow.Test.tree!(
        "one-agent",
        quote do
          agent("do it")
          return(:ok)
        end,
        __ENV__
      )
    end
  end

  # A fan-out region that precedes a gated agent, so a run can be held in flight
  # *after* the whole parallel bracket is journaled but before the gate settles.
  defmodule FanoutThenGate do
    @moduledoc false

    def tree do
      Workflow.Test.tree!(
        "fanout-then-gate",
        quote do
          parallel([agent("a"), agent("b")])
          agent("gate")
          return(:ok)
        end,
        __ENV__
      )
    end
  end

  defmodule InjectedThenGate do
    @moduledoc false

    def tree do
      Workflow.Test.tree!(
        "injected-then-gate",
        quote do
          let(:draft = agent("draft"))
          agent(~P"improve: <%= @draft %>")
          return(:ok)
        end,
        __ENV__
      )
    end
  end

  defmodule JournaledDynamicFanout do
    @moduledoc false

    def tree do
      Workflow.Test.tree!(
        "journaled-dynamic-fanout",
        quote do
          fanout width: budget_slices(per: 10, max: 5) do
            agent("branch")
          end

          return(:ok)
        end,
        __ENV__
      )
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
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, @receive_timeout
    await_lease_released(run_id)
  end

  @tag :capture_log
  test "resume fails closed when a durable start marker has no settlement" do
    id = run_id()

    # First run: agent "first" commits; the writer then blocks inside agent "second".
    {:ok, ^id, pid} =
      Run.start(TwoAgents.tree(), run_id: id, provider: {GateProvider, sink: self(), gate_on: "second"})

    assert_receive {:agent_called, "first"}, @receive_timeout
    assert_receive {:agent_called, "second"}, @receive_timeout
    assert_receive {:at_agent, ^pid}, @receive_timeout

    # The completed turn is durably journaled; the in-flight one is not.
    assert [%{payload: %{address: [0]}}] =
             Enum.filter(Journal.fold(id), &(&1.type == :agent_committed))

    kill_and_await(id, pid)

    assert {:error, {:outcome_unknown, %{address: [1], iteration: 0, attempt: 0}}} =
             Run.run(TwoAgents.tree(), run_id: id, provider: {EchoProvider, sink: self()})

    # Neither a settled turn nor a possibly-completed external effect is repeated.
    refute_received {:agent_called, "first"}
    refute_received {:agent_called, "second"}
    refute_received {:agent_called, _}

    status = Status.of(id)
    assert status.state == :failed
    assert status.failure.reason == {:outcome_unknown, %{address: [1], iteration: 0, attempt: 0}}

    # The already-settled first turn remains one committed journal result.
    committed = Enum.filter(Journal.fold(id), &(&1.type == :agent_committed))
    assert Enum.map(committed, & &1.payload.address) == [[0]]
  end

  @tag :capture_log
  test "resume preserves completed fan-out brackets before failing on an unknown gate outcome" do
    id = run_id()

    # First run: both branches commit and the parallel region is fully bracketed;
    # the writer then blocks inside the gate agent, mid-run.
    {:ok, ^id, pid} =
      Run.start(FanoutThenGate.tree(),
        run_id: id,
        provider: {GateProvider, sink: self(), gate_on: "gate"}
      )

    for p <- ~w(a b gate), do: assert_receive({:agent_called, ^p}, @receive_timeout)
    assert_receive {:at_agent, ^pid}, @receive_timeout

    # The fan-out region is fully journaled before the crash: one started, both
    # branches, one completed.
    before = id |> Journal.fold() |> Enum.map(& &1.type)
    assert Enum.count(before, &(&1 == :parallel_started)) == 1
    assert Enum.count(before, &(&1 == :parallel_completed)) == 1

    kill_and_await(id, pid)

    assert {:error, {:outcome_unknown, %{address: [1], iteration: 0, attempt: 0}}} =
             Run.run(FanoutThenGate.tree(), run_id: id, provider: {EchoProvider, sink: self()})

    # Settled branches replay from the journal and the possibly-completed gate is
    # never invoked again.
    refute_received {:agent_called, "a"}
    refute_received {:agent_called, "b"}
    refute_received {:agent_called, "gate"}

    # Resume does not duplicate the structural started/completed markers, so a
    # fold that pairs them sees a single region.
    types = id |> Journal.fold() |> Enum.map(& &1.type)
    assert Enum.count(types, &(&1 == :parallel_started)) == 1
    assert Enum.count(types, &(&1 == :parallel_completed)) == 1

    assert Status.of(id).state == :failed
  end

  @tag :capture_log
  test "one live writer holds the lease and a released lease still fails closed on unknown outcome" do
    id = run_id()

    {:ok, ^id, pid} = Run.start(OneAgent.tree(), run_id: id, provider: {GateProvider, sink: self()})
    assert_receive {:agent_called, "do it"}, @receive_timeout
    assert_receive {:at_agent, ^pid}, @receive_timeout

    # A second writer cannot hold the same run while the first is live.
    assert {:error, {:already_running, ^pid}} =
             Run.start(OneAgent.tree(), run_id: id, provider: {GateProvider, sink: self()})

    # The live writer dies; the registry releases the lease via its monitor — no
    # heartbeat, no pid-probe poll.
    kill_and_await(id, pid)

    assert {:error, {:outcome_unknown, %{address: [0], iteration: 0, attempt: 0}}} =
             Run.run(OneAgent.tree(), run_id: id, provider: {EchoProvider, sink: self()})

    refute_received {:agent_called, "do it"}
    assert Status.of(id).state == :failed
  end

  @tag :capture_log
  test "a crash between provider-return and commit is reported as outcome unknown" do
    id = run_id()
    {:ok, store} = LedgeredProvider.start()
    key = %IdempotencyKey{run_id: id, node_path: [0], iteration: 0}

    # First run: the provider records the paid effect, then hard-kills the writer
    # before it can commit — the exact return→commit window.
    assert {:error, {:run_crashed, :killed}} =
             Run.run(OneAgent.tree(),
               run_id: id,
               provider: {LedgeredProvider, store: store, sink: self(), crash_once: true}
             )

    assert_received {:agent_called, "do it"}

    # The effect was charged once server-side, but no commit landed — the journal
    # holds no agent result yet.
    assert LedgeredProvider.charges(store, key) == 1
    assert Enum.find(Journal.fold(id), &(&1.type == :agent_committed)) == nil

    await_lease_released(id)

    assert {:error, {:outcome_unknown, %{address: [0], iteration: 0, attempt: 0}}} =
             Run.run(OneAgent.tree(),
               run_id: id,
               provider: {LedgeredProvider, store: store, sink: self()}
             )

    refute_received {:agent_called, "do it"}
    assert LedgeredProvider.charges(store, key) == 1

    status = Status.of(id)
    assert status.state == :failed
    assert status.failure.reason == {:outcome_unknown, %{address: [0], iteration: 0, attempt: 0}}
    assert Ledger.of(id).spent == 0
  end

  @tag :capture_log
  test "journaled bindings do not bypass fail-closed handling for an unknown injected turn" do
    id = run_id()

    {:ok, ^id, pid} =
      Run.start(InjectedThenGate.tree(),
        run_id: id,
        provider: {GateProvider, sink: self(), gate_on: "improve: %{}"}
      )

    assert_receive {:agent_called, "draft"}, @receive_timeout
    assert_receive {:agent_called, "improve: %{}"}, @receive_timeout
    assert_receive {:at_agent, ^pid}, @receive_timeout

    assert [%{payload: %{address: [0], result: %{}}}] =
             Enum.filter(Journal.fold(id), &(&1.type == :agent_committed))

    kill_and_await(id, pid)

    assert {:error, {:outcome_unknown, %{address: [1], iteration: 0, attempt: 0}}} =
             Run.run(InjectedThenGate.tree(), run_id: id, provider: {EchoProvider, sink: self()})

    refute_received {:agent_called, "draft"}
    refute_received {:agent_called, "improve: %{}"}
    refute_received {:agent_called, _}
    assert Status.of(id).state == :failed
  end

  test "resume replays a journaled generic fanout width instead of recomputing budget_slices" do
    id = run_id()
    tree = JournaledDynamicFanout.tree()
    [fanout, _return] = tree.nodes

    :ok = Journal.register_run(id)
    assert {:ok, %{seq: 0}} = Journal.append_next(id, Event.run_started(tree, 5))
    assert {:ok, %{seq: 1}} = Journal.append_next(id, Event.fanout_started(fanout, 3))

    assert {:ok, ^id} =
             Run.run(JournaledDynamicFanout.tree(),
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
