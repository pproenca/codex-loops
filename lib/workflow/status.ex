defmodule Workflow.Status do
  @moduledoc """
  A read model reconstructed **purely by folding the journal** — no process state
  is consulted. `of/1` reads the events, `fold/2` is the pure reducer (unit-testable
  in isolation), so the same fold backs an in-process query today and a
  journal-subscribed LiveView tomorrow.
  """

  alias Workflow.{Journal, Event}
  alias Workflow.Provider.Usage

  defstruct run_id: nil,
            state: :pending,
            tree_name: nil,
            tree_version: nil,
            phase: nil,
            logs: [],
            agents: [],
            rejected: [],
            failure: nil,
            result: nil,
            usage: %Usage{},
            event_count: 0

  @type t :: %__MODULE__{}

  @spec of(String.t()) :: t()
  def of(run_id), do: run_id |> Journal.fold() |> fold(run_id)

  @spec fold([Event.t()], String.t()) :: t()
  def fold(events, run_id) do
    Enum.reduce(events, %__MODULE__{run_id: run_id}, &apply_event/2)
  end

  defp apply_event(%Event{type: :run_started, payload: p}, s) do
    %{s | state: :running, tree_name: p.tree_name, tree_version: p.tree_version} |> tick()
  end

  defp apply_event(%Event{type: :phase_entered, payload: p}, s) do
    %{s | phase: p.name} |> tick()
  end

  defp apply_event(%Event{type: :log_emitted, payload: p}, s) do
    %{s | logs: s.logs ++ [p.message]} |> tick()
  end

  defp apply_event(%Event{type: :agent_committed, payload: p}, s) do
    agent = %{
      address: p.address,
      prompt: p.prompt,
      result: p.result,
      usage: p.usage,
      idempotency_key: p.idempotency_key
    }

    %{s | agents: s.agents ++ [agent], usage: Usage.add(s.usage, p.usage)} |> tick()
  end

  defp apply_event(%Event{type: :agent_attempt_rejected, payload: p}, s) do
    rejection = %{address: p.address, attempt: p.attempt, reason: p.reason}
    %{s | rejected: s.rejected ++ [rejection], usage: Usage.add(s.usage, p.usage)} |> tick()
  end

  defp apply_event(%Event{type: :agent_failed, payload: p}, s) do
    failure = %{address: p.address, attempts: p.attempts, reason: p.reason}
    %{s | state: :failed, failure: failure} |> tick()
  end

  defp apply_event(%Event{type: :run_completed, payload: p}, s) do
    %{s | state: :completed, result: p.value} |> tick()
  end

  defp tick(%__MODULE__{} = s), do: %{s | event_count: s.event_count + 1}
end
