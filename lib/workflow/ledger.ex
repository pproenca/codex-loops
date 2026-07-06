defmodule Workflow.Ledger do
  @moduledoc """
  The budget ledger — the state `while_budget` and `budget_slices` read to make a
  loop's termination a **guarantee** rather than a hope.

  Like every other read surface it is a **pure fold over the journal**: it never
  consults process state. It accumulates paid provider usage into `spent` and
  combines it with the run's `total` target — both taken from journaled events — to
  derive `remaining`.

  Because every usage delta is non-negative, `spent` is monotonically
  non-decreasing, so `remaining/1` is monotonically **non-increasing** across a
  run. That is the invariant a bounded loop leans on to terminate.

  A run with no target folds to `total: nil`; `remaining/1` then reports
  `:infinity`. Since an atom sorts above every integer in Erlang term order,
  `remaining > 0` still answers correctly for an unbounded run, so callers need no
  special-casing.

  `total`/`spent` are folded fields and `remaining/1` derives from them, so all
  three are derivable purely from the journal.
  """

  alias Workflow.{Journal, Event}

  defstruct total: nil, spent: 0

  @type t :: %__MODULE__{total: non_neg_integer() | nil, spent: non_neg_integer()}

  @doc "Fold the whole journal of `run_id` into its ledger."
  @spec of(String.t()) :: t()
  def of(run_id), do: run_id |> Journal.fold() |> fold()

  @doc "The pure reducer over a journal event stream (unit-testable in isolation)."
  @spec fold([Event.t()]) :: t()
  def fold(events), do: Enum.reduce(events, %__MODULE__{}, &apply_event/2)

  @doc """
  Budget left against the target: `total - spent`, or `:infinity` for an unbounded
  run. Never increases as a run advances.
  """
  @spec remaining(t()) :: integer() | :infinity
  def remaining(%__MODULE__{total: nil}), do: :infinity
  def remaining(%__MODULE__{total: total, spent: spent}), do: total - spent

  # The run's target is declared once, at start; `nil` means unbounded.
  defp apply_event(%Event{type: :run_started, payload: %{budget: budget}}, ledger),
    do: %{ledger | total: budget}

  # Both a committed turn and a rejected fail-closed attempt are *paid* provider
  # usage, so each counts against the budget.
  defp apply_event(%Event{type: type, payload: %{usage: usage}}, ledger)
       when type in [:agent_committed, :agent_attempt_rejected],
       do: %{ledger | spent: ledger.spent + usage.total_tokens}

  # Structural markers, logs, terminal failure, completion: no budget movement.
  defp apply_event(%Event{}, ledger), do: ledger
end
