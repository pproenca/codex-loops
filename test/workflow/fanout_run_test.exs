defmodule Workflow.FanoutRunTest do
  @moduledoc """
  Run semantics for the static fan-out combinators, driven through the interpreter
  over an inert tree with call-counting / gating mock providers. Every assertion is
  on external behaviour: the number and concurrency of provider calls, the committed
  journal (with its stable per-branch/per-item node addresses), and the folded read
  model. Nothing inspects process internals.
  """
  use ExUnit.Case, async: true

  alias Workflow.{Run, Journal, Status, Idempotency, Event, IdempotencyKey}
  alias Workflow.Provider.Usage
  alias Workflow.Test.{EchoProvider, GateProvider, ExplodingProvider}

  defp run_id, do: "run_#{System.unique_integer([:positive])}"
  defp echo, do: {EchoProvider, sink: self()}
  defp gate(opts \\ []), do: {GateProvider, Keyword.merge([sink: self()], opts)}
  defp types(id), do: Journal.fold(id) |> Enum.map(& &1.type)

  defp committed_addresses(id) do
    Journal.fold(id)
    |> Enum.filter(&(&1.type == :agent_committed))
    |> Enum.map(& &1.payload.address)
  end

  # Collect `n` gated turns' pids (the pid each blocked turn reports itself as).
  defp gather_gated(0), do: []

  defp gather_gated(n) do
    assert_receive {:at_agent, pid}
    [pid | gather_gated(n - 1)]
  end

  # --- parallel: barrier fan-out ---

  defmodule Par do
    use Workflow

    workflow "par" do
      parallel([agent("a"), agent("b"), agent("c")])
      return(:ok)
    end
  end

  defmodule Capped do
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
    refute Enum.any?(types(id), &(&1 == :parallel_completed))

    # Release every branch; the barrier joins and the run finishes.
    for p <- pids, do: send(p, :proceed)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

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
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
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
    assert_receive {:agent_called, "s1"}
    assert_receive {:agent_called, "s1"}
    [lane_a_s1, lane_b_s1] = gather_gated(2)

    # No lane has started stage 2 yet — within a lane, stages are sequential.
    refute_receive {:agent_called, "s2"}, 50

    # Release ONE lane's stage 1. That lane advances to stage 2 while the other lane
    # is still blocked at stage 1: lanes are not stage-synchronized (no cross-item
    # barrier). A stage barrier would forbid stage 2 until every lane cleared stage 1.
    send(lane_a_s1, :proceed)
    assert_receive {:agent_called, "s2"}
    [lane_a_s2] = gather_gated(1)
    refute_receive {:agent_called, "s2"}, 50

    # Drain the rest to completion.
    send(lane_a_s2, :proceed)
    send(lane_b_s1, :proceed)
    assert_receive {:agent_called, "s2"}
    [lane_b_s2] = gather_gated(1)
    send(lane_b_s2, :proceed)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

    assert committed_addresses(id) == [[0, 0, 0], [0, 0, 1], [0, 1, 0], [0, 1, 1]]
    assert Status.of(id).state == :completed
  end

  # --- failure propagation through a fan-out ---

  defmodule ParFail do
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
end
