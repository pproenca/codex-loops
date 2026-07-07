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
            current_phase_id: nil,
            phases: [],
            logs: [],
            agents: [],
            rejected: [],
            accumulators: %{},
            verifications: [],
            judgments: [],
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
    phase = %{id: "phase-#{length(s.phases)}", name: p.name, address: p.address, agents: []}
    %{s | phase: p.name, current_phase_id: phase.id, phases: s.phases ++ [phase]} |> tick()
  end

  defp apply_event(%Event{type: :log_emitted, payload: p}, s) do
    %{s | logs: s.logs ++ [p.message]} |> tick()
  end

  defp apply_event(%Event{type: :agent_committed, payload: p}, s) do
    s = ensure_phase(s)

    agent = %{
      address: p.address,
      iteration: p.iteration,
      prompt: p.prompt,
      result: p.result,
      usage: p.usage,
      idempotency_key: p.idempotency_key,
      activity: Map.get(p, :activity, []),
      phase_id: s.current_phase_id,
      phase_name: phase_name(s)
    }

    %{
      s
      | agents: s.agents ++ [agent],
        phases: append_agent_to_phase(s.phases, s.current_phase_id, agent),
        usage: Usage.add(s.usage, p.usage)
    }
    |> tick()
  end

  defp apply_event(%Event{type: :agent_attempt_rejected, payload: p}, s) do
    s = ensure_phase(s)

    rejection = %{
      address: p.address,
      iteration: p.iteration,
      attempt: p.attempt,
      prompt: p.prompt,
      output: p.output,
      reason: p.reason,
      activity: Map.get(p, :activity, []),
      phase_id: s.current_phase_id,
      phase_name: phase_name(s)
    }

    %{s | rejected: s.rejected ++ [rejection], usage: Usage.add(s.usage, p.usage)} |> tick()
  end

  defp apply_event(%Event{type: :agent_failed, payload: p}, s) do
    failure = %{
      address: p.address,
      iteration: p.iteration,
      attempts: p.attempts,
      reason: p.reason
    }

    %{s | state: :failed, failure: failure} |> tick()
  end

  # Fan-out markers are structural brackets; the branch/lane agent turns they enclose
  # already fold into `agents`/`usage` via `agent_committed`. They advance the event
  # count so the fold stays total over the versioned, additive log.
  defp apply_event(%Event{type: type}, s)
       when type in [
              :parallel_started,
              :parallel_completed,
              :pipeline_started,
              :pipeline_completed
            ],
       do: tick(s)

  # A declared reduction: append this iteration's already-deduped items to the named
  # accumulator. The read model is thus a pure fold — the same rebuild that resume
  # relies on — so LiveView renders only journaled accumulator state.
  defp apply_event(%Event{type: :accumulate, payload: p}, s) do
    accumulators = Map.update(s.accumulators, p.into, p.added, &(&1 ++ p.added))
    %{s | accumulators: accumulators} |> tick()
  end

  # Loop control-flow brackets/decisions carry no read-model state of their own; they
  # advance the count so the fold stays total over the versioned, additive log.
  defp apply_event(%Event{type: type}, s)
       when type in [:iteration_started, :loop_decision, :loop_completed],
       do: tick(s)

  # Quality-combinator brackets. The started/completed markers only bracket the
  # concurrent region — their votes/scores already fold into `agents`/`usage`. The
  # settled events carry the journal-folded panel outcome the read model surfaces,
  # so LiveView renders only journaled verification/judgment state.
  defp apply_event(%Event{type: type}, s)
       when type in [:verify_started, :judge_started, :fan_out_started, :fan_out_completed],
       do: tick(s)

  defp apply_event(%Event{type: :verify_settled, payload: p}, s) do
    verification = %{
      address: p.address,
      confirmations: p.confirmations,
      total: p.total,
      threshold: p.threshold,
      survived: p.survived
    }

    %{s | verifications: s.verifications ++ [verification]} |> tick()
  end

  defp apply_event(%Event{type: :judge_settled, payload: p}, s) do
    judgment = %{address: p.address, scores: p.scores, pick: p.pick, winner: p.winner}
    %{s | judgments: s.judgments ++ [judgment]} |> tick()
  end

  defp apply_event(%Event{type: :run_completed, payload: p}, s) do
    %{s | state: :completed, result: p.value} |> tick()
  end

  defp tick(%__MODULE__{} = s), do: %{s | event_count: s.event_count + 1}

  defp ensure_phase(%__MODULE__{current_phase_id: nil} = s) do
    phase = %{id: "phase-default", name: "Default phase", address: nil, agents: []}
    %{s | current_phase_id: phase.id, phases: s.phases ++ [phase]}
  end

  defp ensure_phase(%__MODULE__{} = s), do: s

  defp append_agent_to_phase(phases, phase_id, agent) do
    Enum.map(phases, fn
      %{id: ^phase_id, agents: agents} = phase -> %{phase | agents: agents ++ [agent]}
      phase -> phase
    end)
  end

  defp phase_name(%__MODULE__{phases: phases, current_phase_id: phase_id}) do
    case Enum.find(phases, &(&1.id == phase_id)) do
      nil -> nil
      phase -> phase.name
    end
  end
end
