defmodule Workflow.LoopRunTest do
  @moduledoc """
  Run semantics for the dynamic loop combinators, driven through the interpreter
  over inert trees with call-counting / deduping mock providers. Every assertion is
  on external behaviour: provider call counts, the committed journal (its
  journaled control-flow decisions and per-iteration accumulate events with stable
  addresses), the budget ledger, and the folded read model. Nothing inspects
  process internals.

  Covers the slice-#7 acceptance criteria: the loop-until-budget and loop-until-dry
  catalog workflows terminate through the generic loop core; killing a run
  mid-loop and resuming rebuilds the accumulator exactly; and the predicate
  sub-vocabulary drives a real loop.
  """
  use ExUnit.Case, async: true

  alias Workflow.Accumulator
  alias Workflow.IdempotencyKey
  alias Workflow.Journal
  alias Workflow.Ledger
  alias Workflow.Run
  alias Workflow.Status
  alias Workflow.Status.Failure
  alias Workflow.Test.EchoProvider
  alias Workflow.Test.ExplodingProvider
  alias Workflow.Test.LoopProvider
  alias Workflow.Test.ScriptedProvider

  defmodule LoopUntilBudget do
    @moduledoc false

    def tree do
      Workflow.Test.tree!(
        "loop-until-budget",
        quote do
          loop max_iterations: 1000, until: budget_remaining() <= 8 do
            agent("do one unit of work")
          end

          return(:done)
        end,
        __ENV__
      )
    end
  end

  defmodule LoopUntilDry do
    @moduledoc false

    def tree do
      Workflow.Test.tree!(
        "loop-until-dry",
        quote do
          loop max_iterations: 1000, until: dry(rounds: 2, seen_by: [:id]) do
            agent("find more items", schema: %{"type" => "array"})
            collect(into: :items)
          end

          return(:done)
        end,
        __ENV__
      )
    end
  end

  defp run_id, do: "run_#{System.unique_integer([:positive])}"

  defp types(id) do
    id
    |> Journal.fold()
    |> Enum.reject(&(&1.type == :agent_started))
    |> Enum.map(& &1.type)
  end

  defp events(id, type), do: id |> Journal.fold() |> Enum.filter(&(&1.type == type))
  defp decisions(id), do: id |> events(:loop_decision) |> Enum.map(& &1.payload.decision)

  defp decision_shapes(id) do
    id
    |> events(:loop_decision)
    |> Enum.map(&Map.take(&1.payload, [:decision, :predicate_result, :exhausted, :source_address]))
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

  # --- loop-until-budget: provable termination on the ledger ---

  test "loop-until-budget runs until remaining drops to the reserve, then terminates" do
    id = run_id()

    # Budget 40, reserve 8, each turn bills 8: 40 -> 32 -> 24 -> 16 -> 8 (four turns),
    # then remaining is <= reserve, so the loop stops.
    assert {:ok, ^id} =
             Run.run(LoopUntilBudget.tree(),
               run_id: id,
               budget: 40,
               provider: {EchoProvider, sink: self()}
             )

    for _ <- 1..4, do: assert_received({:agent_called, "do one unit of work"})
    refute_received {:agent_called, _}

    # Every continue/stop decision is journaled: four continues + one terminal stop.
    assert decisions(id) == [:continue, :continue, :continue, :continue, {:stop, :until}]

    assert decision_shapes(id) == [
             %{
               decision: :continue,
               predicate_result: false,
               exhausted: false,
               source_address: nil
             },
             %{
               decision: :continue,
               predicate_result: false,
               exhausted: false,
               source_address: nil
             },
             %{
               decision: :continue,
               predicate_result: false,
               exhausted: false,
               source_address: nil
             },
             %{
               decision: :continue,
               predicate_result: false,
               exhausted: false,
               source_address: nil
             },
             %{
               decision: {:stop, :until},
               predicate_result: true,
               exhausted: false,
               source_address: nil
             }
           ]

    assert length(events(id, :iteration_started)) == 4
    assert :loop_completed in types(id)

    ledger = Ledger.of(id)
    assert ledger.spent == 32
    assert Ledger.remaining(ledger) == 8

    status = Status.of(id)
    assert status.state == :completed
    assert status.result == :done
  end

  test "a completed loop-until-budget resumes by replaying journaled decisions, never re-running" do
    id = run_id()

    assert {:ok, ^id} =
             Run.run(LoopUntilBudget.tree(),
               run_id: id,
               budget: 24,
               provider: {EchoProvider, sink: self()}
             )

    before = id |> Journal.fold() |> length()

    # Re-invoking folds to :completed and reuses it verbatim — no decision recomputed,
    # no paid turn re-run, no new events appended.
    assert {:ok, ^id} =
             Run.run(LoopUntilBudget.tree(), run_id: id, provider: {ExplodingProvider, []})

    assert id |> Journal.fold() |> length() == before
    assert Status.of(id).state == :completed
  end

  # --- loop-until-dry: termination on consecutive empty rounds, with dedup ---

  # Two rows, then two dry rounds surfacing only already-seen ids: added counts are
  # [2, 1, 0, 0], so with rounds: 2 the loop stops after the fourth iteration.
  defp dry_script, do: [[%{"id" => 1}, %{"id" => 2}], [%{"id" => 2}, %{"id" => 3}], [%{"id" => 3}], [%{"id" => 3}]]

  test "loop-until-dry accumulates deduped items and terminates after K dry rounds" do
    id = run_id()
    {:ok, script} = ScriptedProvider.start(dry_script())

    assert {:ok, ^id} =
             Run.run(LoopUntilDry.tree(),
               run_id: id,
               provider: {ScriptedProvider, script: script, sink: self()}
             )

    # Four rounds ran (the fourth is the second consecutive dry one), then it stopped.
    for _ <- 1..4, do: assert_received({:agent_called, "find more items"})
    refute_received {:agent_called, _}

    # The accumulator is a pure fold of the journal: deduped by :id, no duplicates.
    assert Accumulator.of(id) == %{items: [%{"id" => 1}, %{"id" => 2}, %{"id" => 3}]}
    assert Status.of(id).accumulators == %{items: [%{"id" => 1}, %{"id" => 2}, %{"id" => 3}]}

    # Per-iteration accumulate events record exactly what each round added.
    added = id |> events(:accumulate) |> Enum.map(&length(&1.payload.added))
    assert added == [2, 1, 0, 0]

    assert decisions(id) == [:continue, :continue, :continue, :continue, {:stop, :until}]

    status = Status.of(id)
    assert status.state == :completed
    assert status.result == :done
  end

  @tag :capture_log
  test "killing a run mid-loop preserves the accumulator and fails closed on an unknown turn" do
    id = run_id()
    {:ok, store} = LoopProvider.start(dry_script())

    # Crash in the return->commit window of iteration 1: iteration 0's items are
    # committed, iteration 1's paid effect happened server-side but never committed.
    assert {:error, {:run_crashed, :killed}} =
             Run.run(LoopUntilDry.tree(),
               run_id: id,
               provider: {LoopProvider, store: store, sink: self(), crash_at: 1}
             )

    assert_received {:agent_called, "find more items", 0}
    assert_received {:agent_called, "find more items", 1}

    # Only iteration 0 is durably accumulated so far.
    assert Accumulator.of(id) == %{items: [%{"id" => 1}, %{"id" => 2}]}
    await_lease_released(id)

    assert {:error, {:outcome_unknown, %{address: [0, 0], iteration: 1, attempt: 0}}} =
             Run.run(LoopUntilDry.tree(),
               run_id: id,
               provider: {LoopProvider, store: store, sink: self()}
             )

    # No settled or possibly-completed provider effect is repeated.
    refute_received {:agent_called, "find more items", 0}
    refute_received {:agent_called, "find more items", 1}

    assert Accumulator.of(id) == %{items: [%{"id" => 1}, %{"id" => 2}]}

    # The unknown iteration is never redelivered, so its recorded charge stays one.
    key = %IdempotencyKey{run_id: id, node_path: [0, 0], iteration: 1, attempt: 0}
    assert LoopProvider.charges(store, key) == 1

    assert Status.of(id).state == :failed
  end

  # --- the predicate sub-vocabulary driving a real loop ---

  defmodule CountStop do
    @moduledoc false

    # No budget bound (remaining is :infinity, so `reserve: 0` never stops it); the
    # loop stops only when the predicate `count(:items) >= 2` holds.
    def tree do
      Workflow.Test.tree!(
        "count-stop",
        quote do
          while_budget reserve: 0, until: count(:items) >= 2 do
            agent("emit", schema: %{"type" => "array"})
            collect(into: :items)
          end

          return(:ok)
        end,
        __ENV__
      )
    end
  end

  defmodule DryPredicateStop do
    @moduledoc false

    def tree do
      Workflow.Test.tree!(
        "dry-predicate-stop",
        quote do
          while_budget reserve: 0, until: dry(rounds: 1, seen_by: [:id]) do
            agent("emit", schema: %{"type" => "array"})
            collect(into: :items)
          end

          return(:ok)
        end,
        __ENV__
      )
    end
  end

  test "a while_budget `until` predicate stops the loop when count(:acc) is reached" do
    id = run_id()
    {:ok, script} = ScriptedProvider.start([[%{"id" => 1}], [%{"id" => 2}]])

    assert {:ok, ^id} =
             Run.run(CountStop.tree(),
               run_id: id,
               provider: {ScriptedProvider, script: script, sink: self()}
             )

    # Exactly two iterations: after the second collect, count(:items) == 2 stops it.
    for _ <- 1..2, do: assert_received({:agent_called, "emit"})
    refute_received {:agent_called, _}

    assert Accumulator.of(id) == %{items: [%{"id" => 1}, %{"id" => 2}]}

    assert decisions(id) == [:continue, :continue, {:stop, :until}]

    assert Status.of(id).state == :completed
  end

  test "a while_budget dry predicate stops after one dry round and drives collect seen_by" do
    id = run_id()

    {:ok, script} =
      ScriptedProvider.start([
        [%{"id" => 1, "value" => "first"}],
        [%{"id" => 1, "value" => "duplicate-by-id"}]
      ])

    assert {:ok, ^id} =
             Run.run(DryPredicateStop.tree(),
               run_id: id,
               provider: {ScriptedProvider, script: script, sink: self()}
             )

    # Iteration 0 adds one item; iteration 1 is dry after :id dedupe; iteration 2
    # sees a dry streak of 1 and stops before another provider call.
    for _ <- 1..2, do: assert_received({:agent_called, "emit"})
    refute_received {:agent_called, _}

    assert Accumulator.of(id) == %{items: [%{"id" => 1, "value" => "first"}]}

    accumulate_events = events(id, :accumulate)
    assert Enum.map(accumulate_events, & &1.payload.seen_by) == [[:id], [:id]]
    assert Enum.map(accumulate_events, &length(&1.payload.added)) == [1, 0]

    assert decisions(id) == [:continue, :continue, {:stop, :until}]

    assert Status.of(id).state == :completed
  end

  # --- generic loop core ---

  defmodule GenericMaxLoop do
    @moduledoc false

    def tree do
      Workflow.Test.tree!(
        "generic-max-loop",
        quote do
          loop max_iterations: 2 do
            agent("tick")
          end

          return(:ok)
        end,
        __ENV__
      )
    end
  end

  defmodule BodyUntilStop do
    @moduledoc false

    def tree do
      Workflow.Test.tree!(
        "body-until-stop",
        quote do
          loop max_iterations: 5 do
            agent("emit", schema: %{"type" => "array"})
            collect(into: :items)
            until(count(:items) >= 2)
            agent("after")
          end

          return(:ok)
        end,
        __ENV__
      )
    end
  end

  defmodule HeaderUntilStop do
    @moduledoc false

    def tree do
      Workflow.Test.tree!(
        "header-until-stop",
        quote do
          loop max_iterations: 5, until: count(:items) >= 2 do
            agent("emit", schema: %{"type" => "array"})
            collect(into: :items)
          end

          return(:ok)
        end,
        __ENV__
      )
    end
  end

  defmodule ExhaustFail do
    @moduledoc false

    def tree do
      Workflow.Test.tree!(
        "generic-loop-exhaust-fail",
        quote do
          loop max_iterations: 1, on_exhausted: :fail do
            agent("tick")
          end

          return(:ok)
        end,
        __ENV__
      )
    end
  end

  defmodule BodyUntilFanoutStop do
    @moduledoc false

    def tree do
      Workflow.Test.tree!(
        "body-until-fanout-stop",
        quote do
          loop max_iterations: 3 do
            fanout width: 2, bind: :checks do
              agent("check")
            end

            until(agree(:checks, path: "/echo", equals: "check", threshold: :all))
            agent("after")
          end

          return(:ok)
        end,
        __ENV__
      )
    end
  end

  test "generic loop runs until max_iterations and journals exhausted completion" do
    id = run_id()

    assert {:ok, ^id} =
             Run.run(GenericMaxLoop.tree(), run_id: id, provider: {EchoProvider, sink: self()})

    for _ <- 1..2, do: assert_received({:agent_called, "tick"})
    refute_received {:agent_called, _}

    assert decisions(id) == [:continue, :continue, {:exhausted, :stop}]

    assert decision_shapes(id) == [
             %{
               decision: :continue,
               predicate_result: false,
               exhausted: false,
               source_address: nil
             },
             %{
               decision: :continue,
               predicate_result: false,
               exhausted: false,
               source_address: nil
             },
             %{
               decision: {:exhausted, :stop},
               predicate_result: nil,
               exhausted: true,
               source_address: nil
             }
           ]

    assert [%{payload: completed}] = events(id, :loop_completed)

    assert %Workflow.Event.Payload.LoopCompleted{
             address: [0],
             iterations: 2,
             exhausted: true,
             reason: :max_iterations
           } = completed

    assert Status.of(id).state == :completed
  end

  test "generic loop header until stops from the journaled predicate decision" do
    id = run_id()
    {:ok, script} = ScriptedProvider.start([[%{"id" => 1}], [%{"id" => 2}]])

    assert {:ok, ^id} =
             Run.run(HeaderUntilStop.tree(),
               run_id: id,
               provider: {ScriptedProvider, script: script, sink: self()}
             )

    for _ <- 1..2, do: assert_received({:agent_called, "emit"})
    refute_received {:agent_called, _}

    assert Accumulator.of(id) == %{items: [%{"id" => 1}, %{"id" => 2}]}
    assert decisions(id) == [:continue, :continue, {:stop, :until}]

    assert decision_shapes(id) == [
             %{
               decision: :continue,
               predicate_result: false,
               exhausted: false,
               source_address: nil
             },
             %{
               decision: :continue,
               predicate_result: false,
               exhausted: false,
               source_address: nil
             },
             %{
               decision: {:stop, :until},
               predicate_result: true,
               exhausted: false,
               source_address: nil
             }
           ]

    assert [%{payload: %{iterations: 2, exhausted: false, reason: :until}}] =
             events(id, :loop_completed)

    assert Status.of(id).state == :completed
  end

  test "body-local until stops at its source position and skips later body nodes" do
    id = run_id()

    {:ok, script} =
      ScriptedProvider.start([
        [%{"id" => 1}],
        %{"after" => true},
        [%{"id" => 2}]
      ])

    assert {:ok, ^id} =
             Run.run(BodyUntilStop.tree(),
               run_id: id,
               provider: {ScriptedProvider, script: script, sink: self()}
             )

    assert_received {:agent_called, "emit"}
    assert_received {:agent_called, "after"}
    assert_received {:agent_called, "emit"}
    refute_received {:agent_called, "after"}
    refute_received {:agent_called, _}

    assert Accumulator.of(id) == %{items: [%{"id" => 1}, %{"id" => 2}]}

    assert decision_shapes(id) == [
             %{
               decision: :continue,
               predicate_result: false,
               exhausted: false,
               source_address: nil
             },
             %{
               decision: :continue,
               predicate_result: false,
               exhausted: false,
               source_address: [0, 2]
             },
             %{
               decision: :continue,
               predicate_result: false,
               exhausted: false,
               source_address: nil
             },
             %{
               decision: {:stop, :until},
               predicate_result: true,
               exhausted: false,
               source_address: [0, 2]
             }
           ]

    assert [%{payload: completed}] = events(id, :loop_completed)
    assert completed.iterations == 2
    assert completed.exhausted == false
    assert completed.reason == :until
  end

  test "on_exhausted fail emits loop_exhausted and folds to the spec failure outcome" do
    id = run_id()

    assert {:error, {:loop_exhausted, [0], 1}} =
             Run.run(ExhaustFail.tree(), run_id: id, provider: {EchoProvider, sink: self()})

    assert_received {:agent_called, "tick"}
    refute_received {:agent_called, _}

    assert types(id) == [
             :run_started,
             :loop_decision,
             :iteration_started,
             :agent_committed,
             :loop_decision,
             :loop_exhausted
           ]

    assert decisions(id) == [:continue, {:exhausted, :fail}]

    assert [%{payload: exhausted}] = events(id, :loop_exhausted)

    assert %Workflow.Event.Payload.LoopExhausted{
             address: [0],
             iterations: 1,
             reason: :max_iterations
           } = exhausted

    status = Status.of(id)
    assert status.state == :failed

    assert status.failure == %Failure{
             address: [0],
             iteration: 1,
             attempts: 0,
             reason: {:loop_exhausted, [0], 1}
           }

    event_count = id |> Journal.fold() |> length()

    assert {:error, {:loop_exhausted, [0], 1}} =
             Run.run(ExhaustFail.tree(), run_id: id, provider: {ExplodingProvider, []})

    assert id |> Journal.fold() |> length() == event_count
  end

  test "body-local until can stop from a loop-local fanout binding" do
    id = run_id()

    assert {:ok, ^id} =
             Run.run(BodyUntilFanoutStop.tree(), run_id: id, provider: {EchoProvider, sink: self()})

    for _ <- 1..2, do: assert_received({:agent_called, "check"})
    refute_received {:agent_called, "after"}
    refute_received {:agent_called, _}

    assert decision_shapes(id) == [
             %{
               decision: :continue,
               predicate_result: false,
               exhausted: false,
               source_address: nil
             },
             %{
               decision: {:stop, :until},
               predicate_result: true,
               exhausted: false,
               source_address: [0, 1]
             }
           ]

    assert [%{payload: %{iterations: 1, reason: :until, exhausted: false}}] =
             events(id, :loop_completed)
  end
end
