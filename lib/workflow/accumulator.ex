defmodule Workflow.Accumulator do
  @moduledoc """
  Declared loop accumulators, **rebuilt purely by folding the journal** — never
  author-managed mutable state and never process state.

  Each `collect` commits an `accumulate` event carrying the exact items it added
  that iteration (already deduped). `of/1` concatenates those `added` lists in
  commit order into `%{acc_name => items}`, so replaying the journal on resume
  reconstructs every accumulator exactly — no lost or duplicated items — without
  recomputing any dedup against non-deterministic agent output.

  `new_items/3` is the pure dedup a `collect` runs *once*, at harvest time, to
  decide which of an iteration's items are new. Its result is what gets journaled;
  the fold never dedups again.
  """

  alias Workflow.Event
  alias Workflow.Journal

  @doc "Fold the whole journal of `run_id` into `%{acc_name => items}`."
  @spec of(String.t()) :: %{atom() => list()}
  def of(run_id), do: run_id |> Journal.fold() |> fold()

  @doc "The pure reducer over a journal event stream (unit-testable in isolation)."
  @spec fold([Event.t()]) :: %{atom() => list()}
  def fold(events), do: Enum.reduce(events, %{}, &apply_event/2)

  defp apply_event(%Event{type: :accumulate, payload: p}, acc), do: Map.update(acc, p.into, p.added, &(&1 ++ p.added))

  defp apply_event(%Event{}, acc), do: acc

  @doc """
  The items in `harvest` that are new relative to `current`, deduping by the
  `seen_by` field list (and within `harvest` itself). An empty `seen_by` dedups by
  whole-item equality. Order is preserved.
  """
  @spec new_items(list(), list(), [atom()]) :: list()
  def new_items(current, harvest, seen_by) do
    seen = MapSet.new(current, &project(&1, seen_by))

    {new, _seen} =
      Enum.reduce(harvest, {[], seen}, fn item, {new, seen} ->
        key = project(item, seen_by)

        if MapSet.member?(seen, key),
          do: {new, seen},
          else: {[item | new], MapSet.put(seen, key)}
      end)

    Enum.reverse(new)
  end

  # An empty field list dedups by the whole item. Otherwise project the named
  # fields, tolerating both string (JSON) and atom keys.
  defp project(item, []), do: item
  defp project(item, seen_by) when is_map(item), do: Map.new(seen_by, &{&1, field(item, &1)})
  defp project(item, _seen_by), do: item

  defp field(item, field), do: Map.get(item, Atom.to_string(field), Map.get(item, field))
end
