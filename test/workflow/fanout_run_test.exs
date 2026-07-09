defmodule Workflow.FanoutRunTest do
  @moduledoc """
  Run semantics for the static fan-out combinators, driven through the interpreter
  over an inert tree with call-counting / gating mock providers. Every assertion is
  on external behaviour: the number and concurrency of provider calls, the committed
  journal (with its stable per-branch/per-item node addresses), and the folded read
  model. Nothing inspects process internals.
  """
  use ExUnit.Case, async: true

  alias Workflow.Event
  alias Workflow.Idempotency
  alias Workflow.IdempotencyKey
  alias Workflow.Journal
  alias Workflow.Node.BudgetSlices
  alias Workflow.Provider.Usage
  alias Workflow.Run
  alias Workflow.Status
  alias Workflow.Test.EchoProvider
  alias Workflow.Test.ExplodingProvider
  alias Workflow.Test.GateProvider
  alias Workflow.Test.ScriptedProvider

  @receive_timeout 1_000

  defp run_id, do: "run_#{System.unique_integer([:positive])}"
  defp echo, do: {EchoProvider, sink: self()}
  defp gate(opts \\ []), do: {GateProvider, Keyword.merge([sink: self()], opts)}
  defp types(id), do: id |> Journal.fold() |> Enum.map(& &1.type)

  defp event(id, type), do: id |> Journal.fold() |> Enum.find(&(&1.type == type))

  defp committed_addresses(id) do
    id
    |> Journal.fold()
    |> Enum.filter(&(&1.type == :agent_committed))
    |> Enum.map(& &1.payload.address)
  end

  # Collect `n` gated turns' pids (the pid each blocked turn reports itself as).
  defp gather_gated(0), do: []

  defp gather_gated(n) do
    assert_receive {:at_agent, pid}, @receive_timeout
    [pid | gather_gated(n - 1)]
  end

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

  # --- parallel: barrier fan-out ---

  defmodule Par do
    @moduledoc false
    use Workflow

    workflow "par" do
      parallel([agent("a"), agent("b"), agent("c")])
      return(:ok)
    end
  end

  defmodule Capped do
    @moduledoc false
    use Workflow

    workflow "capped" do
      parallel([agent("a"), agent("b"), agent("c")], max_concurrency: 2)
      return(:ok)
    end
  end

  test "parallel runs every branch, journaling each at a distinct stable address, then barriers" do
    id = run_id()
    assert {:ok, ^id} = Run.run(Par, run_id: id, provider: echo())

    # Every branch's paid turn ran exactly once.
    for p <- ~w(a b c), do: assert_received({:agent_called, ^p})
    refute_received {:agent_called, _}

    # The concurrent region is bracketed by started/completed markers, with the three
    # branch turns committed between them at their own addresses.
    assert types(id) ==
             [
               :run_started,
               :parallel_started,
               :agent_committed,
               :agent_committed,
               :agent_committed,
               :parallel_completed,
               :run_completed
             ]

    assert committed_addresses(id) == [[0, 0], [0, 1], [0, 2]]

    status = Status.of(id)
    assert status.state == :completed
    assert status.result == :ok
    # Three branches, each billed 8 by EchoProvider.
    assert length(status.agents) == 3
    assert status.usage.total_tokens == 24
  end

  test "parallel runs branches concurrently and joins at the barrier" do
    id = run_id()
    {:ok, ^id, pid} = Run.start(Par, run_id: id, provider: gate())
    ref = Process.monitor(pid)

    # All three branches are in flight at the same time — proving concurrency, not
    # sequential execution (a sequential runner would surface only one gate at a time).
    pids = gather_gated(3)
    assert length(Enum.uniq(pids)) == 3

    # The barrier has not been crossed: the run is still running, no completion event.
    refute :parallel_completed in types(id)

    # Release every branch; the barrier joins and the run finishes.
    for p <- pids, do: send(p, :proceed)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, @receive_timeout

    assert :parallel_completed in types(id)
    assert Status.of(id).state == :completed
  end

  test "parallel bounds concurrency at the cap" do
    id = run_id()
    {:ok, ^id, pid} = Run.start(Capped, run_id: id, provider: gate())
    ref = Process.monitor(pid)

    # Only two branches start under a cap of two; the third waits for a free slot.
    [p1, p2] = gather_gated(2)
    refute_receive {:at_agent, _}, 50

    # Freeing one slot admits the third branch.
    send(p1, :proceed)
    [p3] = gather_gated(1)

    send(p2, :proceed)
    send(p3, :proceed)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, @receive_timeout
    assert Status.of(id).state == :completed
    assert committed_addresses(id) == [[0, 0], [0, 1], [0, 2]]
  end

  test "a completed parallel run resumes by replaying committed branches, never re-invoking" do
    id = run_id()
    assert {:ok, ^id} = Run.run(Par, run_id: id, provider: echo())
    for _ <- 1..3, do: assert_received({:agent_called, _})

    # Re-invoking the same run_id folds to :completed and reuses it verbatim — the
    # committed branch effects are replayed, so the provider must never run again.
    assert {:ok, ^id} = Run.run(Par, run_id: id, provider: {ExplodingProvider, []})
    refute_received {:agent_called, _}

    assert committed_addresses(id) == [[0, 0], [0, 1], [0, 2]]
    assert Status.of(id).state == :completed
  end

  test "a branch address participates in exactly-once resolution like any node" do
    # A committed branch turn at address [0, 1] resolves as settled, so a resume
    # replays it instead of re-running the paid effect.
    committed =
      Event.agent_committed(
        %Workflow.Node.Agent{address: [0, 1], prompt: "b"},
        0,
        %IdempotencyKey{run_id: "r", node_path: [0, 1], iteration: 0},
        %{"echo" => "b"},
        %Usage{total_tokens: 8}
      )

    assert {:committed, %{"echo" => "b"}, %Usage{total_tokens: 8}} =
             Idempotency.resolve([committed], [0, 1], 0)

    assert :none = Idempotency.resolve([committed], [0, 2], 0)
  end

  # --- pipeline: per-item lanes ---

  defmodule Pipe do
    @moduledoc false
    use Workflow

    workflow "pipe" do
      pipeline(["x", "y"], [agent("s1"), agent("s2")])
      return(:ok)
    end
  end

  test "pipeline runs each item through every stage at a distinct stable address" do
    id = run_id()
    assert {:ok, ^id} = Run.run(Pipe, run_id: id, provider: echo())

    # Two items × two stages = four paid turns: two of each stage prompt.
    for _ <- 1..2, do: assert_received({:agent_called, "s1"})
    for _ <- 1..2, do: assert_received({:agent_called, "s2"})
    refute_received {:agent_called, _}

    assert List.first(types(id)) == :run_started
    assert :pipeline_started in types(id)
    assert :pipeline_completed in types(id)

    # Each (item, stage) lands at its own [pipeline, item, stage] address, committed
    # deterministically in lane-then-stage order.
    assert committed_addresses(id) == [[0, 0, 0], [0, 0, 1], [0, 1, 0], [0, 1, 1]]

    started = Enum.find(Journal.fold(id), &(&1.type == :pipeline_started))
    assert started.payload.items == ["x", "y"]
    assert started.payload.stage_count == 2

    assert Status.of(id).state == :completed
  end

  test "pipeline lanes advance independently — no cross-item barrier" do
    id = run_id()
    {:ok, ^id, pid} = Run.start(Pipe, run_id: id, provider: gate())
    ref = Process.monitor(pid)

    # Both lanes reach stage 1 concurrently.
    assert_receive {:agent_called, "s1"}, @receive_timeout
    assert_receive {:agent_called, "s1"}, @receive_timeout
    [lane_a_s1, lane_b_s1] = gather_gated(2)

    # No lane has started stage 2 yet — within a lane, stages are sequential.
    refute_receive {:agent_called, "s2"}, 50

    # Release ONE lane's stage 1. That lane advances to stage 2 while the other lane
    # is still blocked at stage 1: lanes are not stage-synchronized (no cross-item
    # barrier). A stage barrier would forbid stage 2 until every lane cleared stage 1.
    send(lane_a_s1, :proceed)
    assert_receive {:agent_called, "s2"}, @receive_timeout
    [lane_a_s2] = gather_gated(1)
    refute_receive {:agent_called, "s2"}, 50

    # Drain the rest to completion.
    send(lane_a_s2, :proceed)
    send(lane_b_s1, :proceed)
    assert_receive {:agent_called, "s2"}, @receive_timeout
    [lane_b_s2] = gather_gated(1)
    send(lane_b_s2, :proceed)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, @receive_timeout

    assert committed_addresses(id) == [[0, 0, 0], [0, 0, 1], [0, 1, 0], [0, 1, 1]]
    assert Status.of(id).state == :completed
  end

  # --- failure propagation through a fan-out ---

  defmodule ParFail do
    @moduledoc false
    use Workflow

    # Every branch is schema-backed with no retries; EchoProvider's fixed
    # `%{"echo" => prompt}` output never satisfies the required "label", so each
    # branch fails closed deterministically.
    workflow "par-fail" do
      parallel([
        agent("a", schema: %{"type" => "object", "required" => ["label"]}, retries: 0),
        agent("b", schema: %{"type" => "object", "required" => ["label"]}, retries: 0)
      ])

      return(:ok)
    end
  end

  test "a failed branch fails the run, journals every concurrent branch, and skips the barrier" do
    id = run_id()

    assert {:error, {:malformed_output, address, {:missing_required, "label"}}} =
             Run.run(ParFail, run_id: id, provider: echo())

    assert address in [[0, 0], [0, 1]]

    # Both concurrent branches' paid attempts are journaled even though the run fails;
    # the barrier (`parallel_completed`) is never reached, and there is no completion.
    kinds = types(id)
    assert Enum.count(kinds, &(&1 == :agent_failed)) == 2
    refute :parallel_completed in kinds
    refute :run_completed in kinds

    assert Status.of(id).state == :failed
  end

  # --- fanout: fixed-width repeated agent lane ---

  defmodule GenericFanout do
    @moduledoc false
    use Workflow

    workflow "generic-fanout" do
      fanout width: 3 do
        agent("work")
        agent("check")
      end

      return(:ok)
    end
  end

  defmodule GenericFanoutZeroComplete do
    @moduledoc false
    use Workflow

    workflow "generic-fanout-zero-complete" do
      fanout width: 0, on_zero: :complete do
        agent("never")
      end

      return(:ok)
    end
  end

  defmodule GenericFanoutZeroFail do
    @moduledoc false
    use Workflow

    workflow "generic-fanout-zero-fail" do
      fanout width: 0, on_zero: :fail do
        agent("never")
      end

      return(:ok)
    end
  end

  defmodule GenericFanoutThenGate do
    @moduledoc false
    use Workflow

    workflow "generic-fanout-then-gate" do
      fanout width: 2 do
        agent("branch")
      end

      agent("gate")
      return(:ok)
    end
  end

  defmodule GenericFanoutBudgetMax do
    @moduledoc false
    use Workflow

    workflow "generic-fanout-budget-max" do
      fanout width: budget_slices(per: 10, max: 3) do
        agent("work")
      end

      return(:ok)
    end
  end

  defmodule GenericFanoutPathCountEmit do
    @moduledoc false
    use Workflow

    workflow "generic-fanout-path-count-emit" do
      let(:items = agent("items"))

      fanout width: path_count(:items, "/rows", max: 2), bind: :work do
        agent("work")
      end

      emit(~P"Rows: <%= count(@work) %>")
    end
  end

  defmodule GenericFanoutPredicateGate do
    @moduledoc false
    use Workflow

    workflow "generic-fanout-predicate-gate" do
      fanout width: 2, bind: :checks do
        agent("check")
      end

      while_budget reserve: 0,
                   until: agree(:checks, path: "/echo", equals: "check", threshold: :all),
                   max_iterations: 1 do
        agent("loop")
      end

      return(:ok)
    end
  end

  defmodule GenericFanoutBudgetThenGate do
    @moduledoc false
    use Workflow

    workflow "generic-fanout-budget-then-gate" do
      fanout width: budget_slices(per: 10, max: 2) do
        agent("branch")
      end

      agent("gate")
      return(:ok)
    end
  end

  defmodule GenericFanoutExplicitLanes do
    @moduledoc false
    use Workflow

    workflow "generic-fanout-explicit-lanes" do
      fanout width: 2 do
        lanes([
          [agent("research")],
          [agent("draft"), agent("review")]
        ])
      end

      return(:ok)
    end
  end

  test "fanout runs explicit heterogeneous lanes and commits stable addresses in lane order" do
    id = run_id()
    assert {:ok, ^id} = Run.run(GenericFanoutExplicitLanes, run_id: id, provider: echo())

    assert_received {:agent_called, "research"}
    assert_received {:agent_called, "draft"}
    assert_received {:agent_called, "review"}
    refute_received {:agent_called, _}

    assert committed_addresses(id) == [[0, 0, 0], [0, 1, 0], [0, 1, 1]]
    assert Status.of(id).state == :completed
  end

  test "fanout runs a fixed-width repeated lane and commits lane events in input order" do
    id = run_id()
    assert {:ok, ^id} = Run.run(GenericFanout, run_id: id, provider: echo())

    for _ <- 1..3 do
      assert_received {:agent_called, "work"}
      assert_received {:agent_called, "check"}
    end

    refute_received {:agent_called, _}

    assert types(id) ==
             [
               :run_started,
               :fanout_started,
               :agent_committed,
               :agent_committed,
               :agent_committed,
               :agent_committed,
               :agent_committed,
               :agent_committed,
               :fanout_completed,
               :run_completed
             ]

    assert event(id, :fanout_started).payload == %{
             address: [0],
             iteration: nil,
             width_expr: 3,
             width: 3,
             bind: nil
           }

    assert committed_addresses(id) == [
             [0, 0, 0],
             [0, 0, 1],
             [0, 1, 0],
             [0, 1, 1],
             [0, 2, 0],
             [0, 2, 1]
           ]

    assert Status.of(id).state == :completed
  end

  test "fanout on_zero complete journals generic markers without provider calls" do
    id = run_id()
    assert {:ok, ^id} = Run.run(GenericFanoutZeroComplete, run_id: id, provider: echo())

    refute_received {:agent_called, _}

    assert types(id) == [:run_started, :fanout_started, :fanout_completed, :run_completed]
    assert event(id, :fanout_started).payload.width == 0
    assert event(id, :fanout_completed).payload == %{address: [0], iteration: nil}
    assert committed_addresses(id) == []
    assert Status.of(id).state == :completed
  end

  test "fanout on_zero fail emits fanout_failed and returns the spec outcome" do
    id = run_id()

    assert {:error, {:fanout_failed, [0], nil, :zero_width}} =
             Run.run(GenericFanoutZeroFail, run_id: id, provider: echo())

    refute_received {:agent_called, _}

    assert types(id) == [:run_started, :fanout_started, :fanout_failed]

    assert event(id, :fanout_failed).payload == %{
             address: [0],
             iteration: nil,
             reason: :zero_width
           }

    status = Status.of(id)
    assert status.state == :failed

    assert status.failure == %{
             address: [0],
             iteration: nil,
             attempts: 0,
             reason: {:fanout_failed, [0], nil, :zero_width}
           }
  end

  test "fanout budget_slices width is capped, journaled, and committed in input order" do
    id = run_id()

    assert {:ok, ^id} =
             Run.run(GenericFanoutBudgetMax,
               run_id: id,
               budget: 50,
               provider: {EchoProvider, sink: self()}
             )

    for _ <- 1..3, do: assert_received({:agent_called, "work"})
    refute_received {:agent_called, _}

    assert event(id, :fanout_started).payload == %{
             address: [0],
             iteration: nil,
             width_expr: %BudgetSlices{per: 10, max: 3},
             width: 3,
             bind: nil
           }

    assert committed_addresses(id) == [[0, 0, 0], [0, 1, 0], [0, 2, 0]]
  end

  test "fanout path_count width reads a bound value with an explicit structural cap" do
    id = run_id()
    {:ok, script} = ScriptedProvider.start([%{"rows" => [1, 2, 3]}, %{}, %{}])

    assert {:ok, ^id} =
             Run.run(GenericFanoutPathCountEmit,
               run_id: id,
               provider: {ScriptedProvider, script: script, sink: self()}
             )

    assert_received {:agent_called, "items"}
    for _ <- 1..2, do: assert_received({:agent_called, "work"})
    refute_received {:agent_called, _}

    assert event(id, :fanout_started).payload.width == 2

    assert %Event{payload: %{value: "Rows: 2"}} =
             Enum.find(Journal.fold(id), &(&1.type == :run_completed))
  end

  test "fanout bindings feed supported predicates through explicit binding refs" do
    id = run_id()

    assert {:ok, ^id} =
             Run.run(GenericFanoutPredicateGate,
               run_id: id,
               provider: {EchoProvider, sink: self()}
             )

    for _ <- 1..2, do: assert_received({:agent_called, "check"})
    refute_received {:agent_called, "loop"}
    refute_received {:agent_called, _}

    assert Status.of(id).state == :completed
  end

  @tag :capture_log
  test "fanout resumes past completed lanes without re-emitting markers or re-invoking lanes" do
    id = run_id()

    {:ok, ^id, pid} =
      Run.start(GenericFanoutThenGate,
        run_id: id,
        provider: {GateProvider, sink: self(), gate_on: "gate"}
      )

    for _ <- 1..2, do: assert_receive({:agent_called, "branch"}, @receive_timeout)
    assert_receive {:agent_called, "gate"}, @receive_timeout
    assert_receive {:at_agent, ^pid}, @receive_timeout

    assert Enum.count(types(id), &(&1 == :fanout_started)) == 1
    assert Enum.count(types(id), &(&1 == :fanout_completed)) == 1

    kill_and_await(id, pid)

    assert {:ok, ^id} =
             Run.run(GenericFanoutThenGate, run_id: id, provider: {EchoProvider, sink: self()})

    refute_received {:agent_called, "branch"}
    assert_received {:agent_called, "gate"}
    refute_received {:agent_called, _}

    assert Enum.count(types(id), &(&1 == :fanout_started)) == 1
    assert Enum.count(types(id), &(&1 == :fanout_completed)) == 1
    assert committed_addresses(id) == [[0, 0, 0], [0, 1, 0], [1]]
    assert Status.of(id).state == :completed
  end

  @tag :capture_log
  test "dynamic fanout resumes exactly once after a journaled budget width decision" do
    id = run_id()

    {:ok, ^id, pid} =
      Run.start(GenericFanoutBudgetThenGate,
        run_id: id,
        budget: 20,
        provider: {GateProvider, sink: self(), gate_on: "gate"}
      )

    for _ <- 1..2, do: assert_receive({:agent_called, "branch"}, @receive_timeout)
    assert_receive {:agent_called, "gate"}, @receive_timeout
    assert_receive {:at_agent, ^pid}, @receive_timeout

    assert event(id, :fanout_started).payload.width == 2
    assert Enum.count(types(id), &(&1 == :fanout_started)) == 1
    assert Enum.count(types(id), &(&1 == :fanout_completed)) == 1

    kill_and_await(id, pid)

    assert {:ok, ^id} =
             Run.run(GenericFanoutBudgetThenGate,
               run_id: id,
               budget: 0,
               provider: {EchoProvider, sink: self()}
             )

    refute_received {:agent_called, "branch"}
    assert_received {:agent_called, "gate"}
    refute_received {:agent_called, _}

    assert Enum.count(types(id), &(&1 == :fanout_started)) == 1
    assert Enum.count(types(id), &(&1 == :fanout_completed)) == 1
    assert committed_addresses(id) == [[0, 0, 0], [0, 1, 0], [1]]
    assert Status.of(id).state == :completed
  end
end
