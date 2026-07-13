defmodule Workflow.Idempotency do
  @moduledoc """
  Settlement resolution for paid effects, decided **purely from the journal**.

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

  Before invoking a provider, the writer journals `agent_started`. If a writer dies
  with such a marker and no matching settlement, the outcome is unknowable. Resume
  fails that run instead of redelivering a possibly-paid effect.
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

  @type unsettled_attempt :: %{
          address: Workflow.Node.address(),
          iteration: non_neg_integer(),
          attempt: non_neg_integer()
        }

  @spec unsettled_attempt([Workflow.Event.t()]) :: {:ok, unsettled_attempt()} | :none
  def unsettled_attempt(events) do
    Enum.find_value(events, :none, fn
      %{type: :agent_started, payload: payload} ->
        if settled_attempt?(events, payload), do: false, else: {:ok, Map.take(payload, [:address, :iteration, :attempt])}

      _event ->
        false
    end)
  end

  defp settled_attempt?(events, started) do
    Enum.any?(events, fn
      %{type: :agent_committed, payload: payload} ->
        same_turn?(payload, started) and payload.idempotency_key.attempt == started.attempt

      %{type: :agent_attempt_rejected, payload: payload} ->
        same_turn?(payload, started) and payload.attempt == started.attempt

      %{type: :agent_failed, payload: payload} ->
        same_turn?(payload, started) and payload.attempts > started.attempt

      _event ->
        false
    end)
  end

  defp same_turn?(left, right),
    do: left.address == right.address and left.iteration == right.iteration
end
