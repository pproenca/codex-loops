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
    attempt = idempotency_attempt(p.idempotency_key)
    existing = find_agent_attempt(s.agents, p.address, p.iteration, attempt)
    activity = indexed_activity(Map.get(p, :activity, []))

    agent = %{
      address: p.address,
      iteration: p.iteration,
      label: Map.get(p, :label),
      prompt: p.prompt,
      result: p.result,
      usage: p.usage,
      idempotency_key: p.idempotency_key,
      status: :completed,
      activity: merge_activity(existing && existing.activity, activity),
      phase_id: s.current_phase_id,
      phase_name: phase_name(s)
    }

    %{
      s
      | agents: upsert_settled_agent(s.agents, agent),
        phases: upsert_settled_agent_in_phase(s.phases, s.current_phase_id, agent),
        usage: Usage.add(s.usage, p.usage)
    }
    |> tick()
  end

  defp apply_event(%Event{type: :agent_activity, payload: p}, s) do
    s = ensure_phase(s)
    existing = find_agent_attempt(s.agents, p.address, p.iteration, p.attempt)
    entry = maybe_put_activity_index(p.entry, Map.get(p, :activity_index))

    agent = %{
      address: p.address,
      iteration: p.iteration,
      attempt: p.attempt,
      label: Map.get(p, :label) || (existing && Map.get(existing, :label)),
      prompt: p.prompt,
      result: existing && Map.get(existing, :result),
      usage: (existing && Map.get(existing, :usage)) || %Usage{},
      idempotency_key: existing && Map.get(existing, :idempotency_key),
      status: (existing && Map.get(existing, :status)) || :running,
      activity: merge_activity(existing && existing.activity, [entry]),
      phase_id: (existing && existing.phase_id) || s.current_phase_id,
      phase_name: (existing && existing.phase_name) || phase_name(s)
    }

    %{
      s
      | agents: upsert_in_flight_agent(s.agents, agent),
        phases: upsert_in_flight_agent_in_phase(s.phases, agent.phase_id, agent)
    }
    |> tick()
  end

  defp apply_event(%Event{type: :agent_attempt_rejected, payload: p}, s) do
    s = ensure_phase(s)
    existing = find_agent_attempt(s.agents, p.address, p.iteration, p.attempt)
    activity = indexed_activity(Map.get(p, :activity, []))
    phase_id = (existing && existing.phase_id) || s.current_phase_id
    phase_name = (existing && existing.phase_name) || phase_name(s)

    rejection = %{
      address: p.address,
      iteration: p.iteration,
      attempt: p.attempt,
      label: Map.get(p, :label) || (existing && Map.get(existing, :label)),
      prompt: p.prompt,
      output: p.output,
      reason: p.reason,
      activity: merge_activity(existing && existing.activity, activity),
      phase_id: phase_id,
      phase_name: phase_name
    }

    %{
      s
      | agents: remove_rejected_agent(s.agents, p.address, p.iteration, p.attempt),
        phases: remove_rejected_agent_from_phases(s.phases, p.address, p.iteration, p.attempt),
        rejected: s.rejected ++ [rejection],
        usage: Usage.add(s.usage, p.usage)
    }
    |> tick()
  end

  defp apply_event(%Event{type: :agent_failed, payload: p}, s) do
    s = ensure_phase(s)
    existing = find_agent_attempt(s.agents, p.address, p.iteration, p.attempts - 1)
    rejection = latest_rejection(s.rejected, p.address, p.iteration)

    phase_id =
      (existing && existing.phase_id) || (rejection && rejection.phase_id) || s.current_phase_id

    phase_name =
      (existing && existing.phase_name) || (rejection && rejection.phase_name) || phase_name(s)

    agent = %{
      address: p.address,
      iteration: p.iteration,
      label: (existing && Map.get(existing, :label)) || (rejection && Map.get(rejection, :label)),
      prompt:
        (existing && Map.get(existing, :prompt)) || (rejection && Map.get(rejection, :prompt)),
      result: existing && Map.get(existing, :result),
      usage: (existing && Map.get(existing, :usage)) || %Usage{},
      idempotency_key: existing && Map.get(existing, :idempotency_key),
      status: :failed,
      activity: (existing && existing.activity) || (rejection && rejection.activity) || [],
      phase_id: phase_id,
      phase_name: phase_name
    }

    failure = %{
      address: p.address,
      iteration: p.iteration,
      attempts: p.attempts,
      reason: p.reason
    }

    %{
      s
      | state: :failed,
        failure: failure,
        agents: upsert_settled_agent(s.agents, agent),
        phases: upsert_settled_agent_in_phase(s.phases, phase_id, agent)
    }
    |> tick()
  end

  defp apply_event(%Event{type: :refine_input_invalid, payload: p}, s) do
    %{
      s
      | state: :failed,
        failure: %{
          address: p.address,
          iteration: 0,
          attempts: 0,
          reason: {:invalid_refine_input, p.address, p.reason}
        }
    }
    |> tick()
  end

  defp apply_event(%Event{type: :refine_non_converged, payload: p}, s) do
    %{
      s
      | state: :failed,
        failure: %{
          address: p.address,
          iteration: 0,
          attempts: 0,
          reason: {:did_not_converge, p.address, :max_rounds}
        }
    }
    |> tick()
  end

  # Fan-out markers are structural brackets; the branch/lane agent turns they enclose
  # already fold into `agents`/`usage` via `agent_committed`. They advance the event
  # count so the fold stays total over the versioned, additive log.
  defp apply_event(%Event{type: type}, s)
       when type in [
              :parallel_started,
              :parallel_completed,
              :pipeline_started,
              :pipeline_completed,
              :refine_started,
              :refine_round_started,
              :refine_round_decision,
              :refine_completed
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

  defp find_agent_attempt(agents, address, iteration, attempt) do
    Enum.find(agents, &agent_attempt_match?(&1, address, iteration, attempt))
  end

  defp upsert_in_flight_agent(agents, agent) do
    if Enum.any?(agents, &agent_attempt_match?(&1, agent.address, agent.iteration, agent.attempt)) do
      Enum.map(agents, fn
        existing
        when existing.address == agent.address and existing.iteration == agent.iteration and
               existing.attempt == agent.attempt ->
          agent

        existing ->
          existing
      end)
    else
      agents ++ [agent]
    end
  end

  defp upsert_settled_agent(agents, agent) do
    {agents, inserted?} =
      Enum.reduce(agents, {[], false}, fn existing, {acc, inserted?} ->
        if agent_match?(existing, agent.address, agent.iteration) do
          if inserted?, do: {acc, inserted?}, else: {[agent | acc], true}
        else
          {[existing | acc], inserted?}
        end
      end)

    agents = Enum.reverse(agents)

    if inserted?, do: agents, else: agents ++ [agent]
  end

  defp remove_rejected_agent(agents, address, iteration, attempt) do
    Enum.reject(agents, &rejected_agent_match?(&1, address, iteration, attempt))
  end

  defp upsert_in_flight_agent_in_phase(phases, phase_id, agent) do
    Enum.map(phases, fn
      %{id: ^phase_id, agents: agents} = phase ->
        %{phase | agents: upsert_in_flight_agent(agents, agent)}

      phase ->
        phase
    end)
  end

  defp upsert_settled_agent_in_phase(phases, phase_id, agent) do
    Enum.map(phases, fn
      %{id: ^phase_id, agents: agents} = phase ->
        %{phase | agents: upsert_settled_agent(agents, agent)}

      phase ->
        phase
    end)
  end

  defp remove_rejected_agent_from_phases(phases, address, iteration, attempt) do
    Enum.map(phases, fn phase ->
      %{phase | agents: remove_rejected_agent(phase.agents, address, iteration, attempt)}
    end)
  end

  defp agent_match?(agent, address, iteration),
    do: agent.address == address and agent.iteration == iteration

  defp agent_attempt_match?(agent, address, iteration, attempt),
    do: agent_match?(agent, address, iteration) and Map.get(agent, :attempt) == attempt

  defp rejected_agent_match?(agent, address, iteration, attempt),
    do: agent_match?(agent, address, iteration) and Map.get(agent, :attempt) in [nil, attempt]

  defp idempotency_attempt(%{attempt: attempt}), do: attempt
  defp idempotency_attempt(_key), do: nil

  defp latest_rejection(rejections, address, iteration) do
    rejections
    |> Enum.filter(&(&1.address == address and &1.iteration == iteration))
    |> List.last()
  end

  defp indexed_activity(activity) do
    activity
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.map(fn {entry, index} -> maybe_put_activity_index(entry, index) end)
  end

  defp maybe_put_activity_index(entry, nil), do: entry

  defp maybe_put_activity_index(entry, index) when is_map(entry),
    do: Map.put_new(entry, :activity_index, index)

  defp merge_activity(left, right) do
    Enum.reduce(List.wrap(right), List.wrap(left), fn entry, acc ->
      if activity_index(entry) != nil and Enum.any?(acc, &same_activity?(&1, entry)) do
        acc
      else
        acc ++ [entry]
      end
    end)
  end

  defp activity_index(entry),
    do: Map.get(entry, :activity_index) || Map.get(entry, "activity_index")

  defp same_activity?(left, right) do
    activity_index(left) == activity_index(right) and
      strip_activity_index(left) == strip_activity_index(right)
  end

  defp strip_activity_index(entry) do
    entry
    |> Map.delete(:activity_index)
    |> Map.delete("activity_index")
  end

  defp phase_name(%__MODULE__{phases: phases, current_phase_id: phase_id}) do
    case Enum.find(phases, &(&1.id == phase_id)) do
      nil -> nil
      phase -> phase.name
    end
  end
end
