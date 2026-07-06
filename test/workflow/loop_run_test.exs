defmodule Workflow.LoopRunTest do
  @moduledoc """
  Run semantics for the dynamic loop combinators, driven through the interpreter
  over inert trees with call-counting / deduping mock providers. Every assertion is
  on external behaviour: provider call counts, the committed journal (its
  journaled control-flow decisions and per-iteration accumulate events with stable
  addresses), the budget ledger, and the folded read model. Nothing inspects
  process internals.

  Covers the slice-#7 acceptance criteria: the loop-until-budget and loop-until-dry
  catalog workflows terminate; killing a run mid-loop and resuming rebuilds the
  accumulator exactly; and the predicate sub-vocabulary drives a real loop.
  """
  use ExUnit.Case, async: true

  alias Workflow.{Run, Journal, Status, Ledger, Accumulator, IdempotencyKey}
  alias Workflow.Catalog.{LoopUntilBudget, LoopUntilDry}
  alias Workflow.Test.{EchoProvider, ScriptedProvider, LoopProvider}

  defp run_id, do: "run_#{System.unique_integer([:positive])}"
  defp types(id), do: Journal.fold(id) |> Enum.map(& &1.type)
  defp events(id, type), do: Journal.fold(id) |> Enum.filter(&(&1.type == type))

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
    # then remaining is not > reserve, so the loop stops.
    assert {:ok, ^id} =
             Run.run(LoopUntilBudget,
               run_id: id,
               budget: 40,
               provider: {EchoProvider, sink: self()}
             )

    for _ <- 1..4, do: assert_received({:agent_called, "do one unit of work"})
    refute_received {:agent_called, _}

    # Every continue/stop decision is journaled: four continues + one terminal stop.
    decisions = events(id, :loop_decision) |> Enum.map(& &1.payload.decision)
    assert decisions == [:continue, :continue, :continue, :continue, :stop]
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
             Run.run(LoopUntilBudget,
               run_id: id,
               budget: 24,
               provider: {EchoProvider, sink: self()}
             )

    before = Journal.fold(id) |> length()

    # Re-invoking folds to :completed and reuses it verbatim — no decision recomputed,
    # no paid turn re-run, no new events appended.
    assert {:ok, ^id} =
             Run.run(LoopUntilBudget, run_id: id, provider: {Workflow.Test.ExplodingProvider, []})

    assert Journal.fold(id) |> length() == before
    assert Status.of(id).state == :completed
  end

  # --- loop-until-dry: termination on consecutive empty rounds, with dedup ---

  # Two rows, then two dry rounds surfacing only already-seen ids: added counts are
  # [2, 1, 0, 0], so with rounds: 2 the loop stops after the fourth iteration.
  defp dry_script,
    do: [
      [%{"id" => 1}, %{"id" => 2}],
      [%{"id" => 2}, %{"id" => 3}],
      [%{"id" => 3}],
      [%{"id" => 3}]
    ]

  test "loop-until-dry accumulates deduped items and terminates after K dry rounds" do
    id = run_id()
    {:ok, script} = ScriptedProvider.start(dry_script())

    assert {:ok, ^id} =
             Run.run(LoopUntilDry,
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
    added = events(id, :accumulate) |> Enum.map(&length(&1.payload.added))
    assert added == [2, 1, 0, 0]

    decisions = events(id, :loop_decision) |> Enum.map(& &1.payload.decision)
    assert decisions == [:continue, :continue, :continue, :continue, :stop]

    status = Status.of(id)
    assert status.state == :completed
    assert status.result == :done
  end

  @tag :capture_log
  test "killing a run mid-loop and resuming rebuilds the accumulator exactly" do
    id = run_id()
    {:ok, store} = LoopProvider.start(dry_script())

    # Crash in the return->commit window of iteration 1: iteration 0's items are
    # committed, iteration 1's paid effect happened server-side but never committed.
    assert {:error, {:run_crashed, :killed}} =
             Run.run(LoopUntilDry,
               run_id: id,
               provider: {LoopProvider, store: store, sink: self(), crash_at: 1}
             )

    assert_received {:agent_called, "find more items", 0}
    assert_received {:agent_called, "find more items", 1}

    # Only iteration 0 is durably accumulated so far.
    assert Accumulator.of(id) == %{items: [%{"id" => 1}, %{"id" => 2}]}
    await_lease_released(id)

    # Resume: iteration 0 replays from the journal (no re-collect); iteration 1's
    # deduped provider replays its recorded output and finally commits; the loop
    # drives to its dry stop.
    assert {:ok, ^id} =
             Run.run(LoopUntilDry,
               run_id: id,
               provider: {LoopProvider, store: store, sink: self()}
             )

    # Iteration 0 was NOT re-invoked; iteration 1 was (nothing was committed to replay).
    refute_received {:agent_called, "find more items", 0}
    assert_received {:agent_called, "find more items", 1}

    # The accumulator rebuilt exactly — no lost item (3 present), no duplicate (2 once).
    assert Accumulator.of(id) == %{items: [%{"id" => 1}, %{"id" => 2}, %{"id" => 3}]}

    # And iteration 1's paid effect was charged exactly once across the crash.
    key = %IdempotencyKey{run_id: id, node_path: [0, 0], iteration: 1, attempt: 0}
    assert LoopProvider.charges(store, key) == 1

    assert Status.of(id).state == :completed
  end

  # --- the predicate sub-vocabulary driving a real loop ---

  defmodule CountStop do
    use Workflow

    # No budget bound (remaining is :infinity, so `reserve: 0` never stops it); the
    # loop stops only when the predicate `count(:items) >= 2` holds.
    workflow "count-stop" do
      while_budget reserve: 0, until: count(:items) >= 2 do
        agent("emit", schema: %{"type" => "array"})
        collect(into: :items)
      end

      return(:ok)
    end
  end

  test "a while_budget `until` predicate stops the loop when count(:acc) is reached" do
    id = run_id()
    {:ok, script} = ScriptedProvider.start([[%{"id" => 1}], [%{"id" => 2}]])

    assert {:ok, ^id} =
             Run.run(CountStop,
               run_id: id,
               provider: {ScriptedProvider, script: script, sink: self()}
             )

    # Exactly two iterations: after the second collect, count(:items) == 2 stops it.
    for _ <- 1..2, do: assert_received({:agent_called, "emit"})
    refute_received {:agent_called, _}

    assert Accumulator.of(id) == %{items: [%{"id" => 1}, %{"id" => 2}]}

    decisions = events(id, :loop_decision) |> Enum.map(& &1.payload.decision)
    assert decisions == [:continue, :continue, :stop]

    assert Status.of(id).state == :completed
  end
end
