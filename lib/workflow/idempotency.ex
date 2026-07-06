defmodule Workflow.Idempotency do
  @moduledoc """
  Exactly-once resolution for paid effects, decided **purely from the journal**.

  `resolve/3` folds the prior events for `(node_path, iteration)` into the node's
  settled outcome so a resume never re-runs a paid effect:

    * `{:committed, result, usage}` — a successful turn; its result is replayed.
    * `{:failed, reason}` — a turn that already exhausted its retry budget; the
      terminal failure is reconstructed, not re-attempted.
    * `{:resume, next_attempt}` — the turn is mid-flight: `next_attempt` paid
      attempts were already rejected and journaled, so the retry loop must resume
      at that attempt index rather than re-calling the provider from zero (which
      would double-pay for the already-journaled rejections).
    * `:none` — no prior outcome; the node must run for the first time.
  """

  @type outcome ::
          {:committed, Workflow.Provider.result(), Workflow.Provider.Usage.t()}
          | {:failed, term()}
          | {:resume, pos_integer()}
          | :none

  @spec resolve([Workflow.Event.t()], Workflow.Node.address(), non_neg_integer()) :: outcome()
  def resolve(events, node_path, iteration) do
    # Only agent events carry both `address` and `iteration`, so this keys the fold
    # to exactly this turn's paid effects — phases/logs/run markers are excluded.
    turn =
      Enum.filter(events, fn
        %{payload: %{address: ^node_path, iteration: ^iteration}} -> true
        _event -> false
      end)

    cond do
      committed = Enum.find(turn, &(&1.type == :agent_committed)) ->
        {:committed, committed.payload.result, committed.payload.usage}

      failed = Enum.find(turn, &(&1.type == :agent_failed)) ->
        {:failed, failed.payload.reason}

      (rejected = Enum.count(turn, &(&1.type == :agent_attempt_rejected))) > 0 ->
        {:resume, rejected}

      true ->
        :none
    end
  end
end
