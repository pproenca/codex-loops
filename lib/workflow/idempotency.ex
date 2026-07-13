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

  alias Workflow.Event
  alias Workflow.Event.Payload
  alias Workflow.IdempotencyKey

  @type outcome ::
          {:committed, Workflow.Provider.result(), Workflow.Provider.Usage.t()}
          | {:failed, term()}
          | {:resume, pos_integer()}
          | :none

  @spec resolve([Event.t()], Workflow.Node.address(), non_neg_integer()) :: outcome()
  def resolve(events, node_path, iteration) do
    # Only agent events carry both `address` and `iteration`, so this keys the fold
    # to exactly this turn's paid effects — phases/logs/run markers are excluded.
    turn =
      Enum.filter(events, fn
        %Event{payload: %Payload.AgentStarted{address: ^node_path, iteration: ^iteration}} -> true
        %Event{payload: %Payload.AgentCommitted{address: ^node_path, iteration: ^iteration}} -> true
        %Event{payload: %Payload.AgentAttemptRejected{address: ^node_path, iteration: ^iteration}} -> true
        %Event{payload: %Payload.AgentFailed{address: ^node_path, iteration: ^iteration}} -> true
        %Event{} -> false
      end)

    cond do
      committed = Enum.find(turn, &match?(%Event{payload: %Payload.AgentCommitted{}}, &1)) ->
        {:committed, committed.payload.result, committed.payload.usage}

      failed = Enum.find(turn, &match?(%Event{payload: %Payload.AgentFailed{}}, &1)) ->
        {:failed, failed.payload.reason}

      (rejected = Enum.count(turn, &match?(%Event{payload: %Payload.AgentAttemptRejected{}}, &1))) > 0 ->
        {:resume, rejected}

      true ->
        :none
    end
  end

  @spec unsettled_attempt([Event.t()]) :: {:ok, IdempotencyKey.t()} | :none
  def unsettled_attempt(events) do
    Enum.find_value(events, :none, fn
      %Event{payload: %Payload.AgentStarted{idempotency_key: %IdempotencyKey{} = key} = payload} ->
        if settled_attempt?(events, payload), do: false, else: {:ok, key}

      %Event{} ->
        false
    end)
  end

  defp settled_attempt?(events, started) do
    Enum.any?(events, fn
      %Event{payload: %Payload.AgentCommitted{} = payload} ->
        same_turn?(payload, started) and payload.idempotency_key.attempt == started.attempt

      %Event{payload: %Payload.AgentAttemptRejected{} = payload} ->
        same_turn?(payload, started) and payload.attempt == started.attempt

      %Event{payload: %Payload.AgentFailed{} = payload} ->
        same_turn?(payload, started) and payload.attempts > started.attempt

      %Event{} ->
        false
    end)
  end

  defp same_turn?(left, right), do: left.address == right.address and left.iteration == right.iteration
end
