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
            refines: [],
            tool_activity: [],
            raw_refs: %{journal: []},
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

  defp apply_event(%Event{} = event, %__MODULE__{} = status) do
    status
    |> append_raw_ref(event)
    |> append_tool_activity(event)
    |> update_refines(event)
    |> then(&apply_known_event(event, &1))
  end

  defp apply_known_event(%Event{type: :run_started, payload: p}, s) do
    %{s | state: :running, tree_name: p.tree_name, tree_version: p.tree_version} |> tick()
  end

  defp apply_known_event(%Event{type: :phase_entered, payload: p}, s) do
    phase = %{id: "phase-#{length(s.phases)}", name: p.name, address: p.address, agents: []}
    %{s | phase: p.name, current_phase_id: phase.id, phases: s.phases ++ [phase]} |> tick()
  end

  defp apply_known_event(%Event{type: :log_emitted, payload: p}, s) do
    %{s | logs: s.logs ++ [p.message]} |> tick()
  end

  defp apply_known_event(%Event{type: :agent_committed, payload: p}, s) do
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

  defp apply_known_event(%Event{type: :agent_activity, payload: p}, s) do
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

  defp apply_known_event(%Event{type: :agent_attempt_rejected, payload: p}, s) do
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

  defp apply_known_event(%Event{type: :agent_failed, payload: p}, s) do
    s = ensure_phase(s)
    existing = find_agent_attempt(s.agents, p.address, p.iteration, p.attempts - 1)
    rejection = latest_rejection(s.rejected, p.address, p.iteration)
    failed_usage = Map.get(p, :usage)
    failed_activity = indexed_activity(Map.get(p, :activity, []))

    phase_id =
      (existing && existing.phase_id) || (rejection && rejection.phase_id) || s.current_phase_id

    phase_name =
      (existing && existing.phase_name) || (rejection && rejection.phase_name) || phase_name(s)

    agent =
      %{
        address: p.address,
        iteration: p.iteration,
        label:
          (existing && Map.get(existing, :label)) || (rejection && Map.get(rejection, :label)),
        prompt:
          (existing && Map.get(existing, :prompt)) || (rejection && Map.get(rejection, :prompt)),
        result: existing && Map.get(existing, :result),
        usage: failed_usage || (existing && Map.get(existing, :usage)) || %Usage{},
        idempotency_key: existing && Map.get(existing, :idempotency_key),
        status: :failed,
        activity:
          merge_activity(
            (existing && existing.activity) || (rejection && rejection.activity),
            failed_activity
          ),
        phase_id: phase_id,
        phase_name: phase_name
      }
      |> maybe_put_provider_failure(p.reason)

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
        phases: upsert_settled_agent_in_phase(s.phases, phase_id, agent),
        usage: add_failed_usage(s.usage, failed_usage)
    }
    |> tick()
  end

  defp apply_known_event(%Event{type: :refine_input_invalid, payload: p}, s) do
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

  defp apply_known_event(%Event{type: :refine_non_converged, payload: p}, s) do
    %{
      s
      | state: :failed,
        failure: %{
          address: p.address,
          iteration: 0,
          attempts: 0,
          reason: {:did_not_converge, p.address, Map.get(p, :reason, :max_rounds)}
        }
    }
    |> tick()
  end

  defp apply_known_event(%Event{type: :refine_role_failed, payload: p}, s) do
    %{s | usage: add_failed_usage(s.usage, Map.get(p, :usage))}
    |> tick()
  end

  # Fan-out markers are structural brackets; the branch/lane agent turns they enclose
  # already fold into `agents`/`usage` via `agent_committed`. They advance the event
  # count so the fold stays total over the versioned, additive log.
  defp apply_known_event(%Event{type: type}, s)
       when type in [
              :parallel_started,
              :parallel_completed,
              :pipeline_started,
              :pipeline_completed,
              :refine_started,
              :refine_round_started,
              :refine_round_decision,
              :refine_gate_evaluated,
              :refine_completed
            ],
       do: tick(s)

  # A declared reduction: append this iteration's already-deduped items to the named
  # accumulator. The read model is thus a pure fold — the same rebuild that resume
  # relies on — so LiveView renders only journaled accumulator state.
  defp apply_known_event(%Event{type: :accumulate, payload: p}, s) do
    accumulators = Map.update(s.accumulators, p.into, p.added, &(&1 ++ p.added))
    %{s | accumulators: accumulators} |> tick()
  end

  # Loop control-flow brackets/decisions carry no read-model state of their own; they
  # advance the count so the fold stays total over the versioned, additive log.
  defp apply_known_event(%Event{type: type}, s)
       when type in [:iteration_started, :loop_decision, :loop_completed],
       do: tick(s)

  # Quality-combinator brackets. The started/completed markers only bracket the
  # concurrent region — their votes/scores already fold into `agents`/`usage`. The
  # settled events carry the journal-folded panel outcome the read model surfaces,
  # so LiveView renders only journaled verification/judgment state.
  defp apply_known_event(%Event{type: type}, s)
       when type in [:verify_started, :judge_started, :fan_out_started, :fan_out_completed],
       do: tick(s)

  defp apply_known_event(%Event{type: :verify_settled, payload: p}, s) do
    verification = %{
      address: p.address,
      confirmations: p.confirmations,
      total: p.total,
      threshold: p.threshold,
      survived: p.survived
    }

    %{s | verifications: s.verifications ++ [verification]} |> tick()
  end

  defp apply_known_event(%Event{type: :judge_settled, payload: p}, s) do
    judgment = %{address: p.address, scores: p.scores, pick: p.pick, winner: p.winner}
    %{s | judgments: s.judgments ++ [judgment]} |> tick()
  end

  defp apply_known_event(%Event{type: :run_completed, payload: p}, s) do
    %{s | state: :completed, result: p.value} |> tick()
  end

  defp append_raw_ref(%__MODULE__{} = status, %Event{} = event) do
    update_in(status.raw_refs.journal, &(&1 ++ [raw_ref(status, event)]))
  end

  defp append_tool_activity(
         %__MODULE__{} = status,
         %Event{type: :agent_activity, payload: p} = event
       ) do
    entry = maybe_put_activity_index(p.entry, Map.get(p, :activity_index))
    append_tool_activity_entries(status, event, [entry])
  end

  defp append_tool_activity(%__MODULE__{} = status, %Event{type: type, payload: p} = event)
       when type in [
              :agent_committed,
              :agent_attempt_rejected,
              :agent_failed,
              :refine_role_failed
            ] do
    append_tool_activity_entries(status, event, Map.get(p, :activity, []))
  end

  defp append_tool_activity(%__MODULE__{} = status, %Event{}), do: status

  defp append_tool_activity_entries(status, _event, []), do: status

  defp append_tool_activity_entries(%__MODULE__{} = status, %Event{} = event, entries) do
    ref = raw_ref(status, event)

    additions =
      entries
      |> List.wrap()
      |> Enum.map(&%{entry: &1, raw_ref: ref})

    %{status | tool_activity: status.tool_activity ++ additions}
  end

  defp update_refines(%__MODULE__{} = status, %Event{type: :refine_started, payload: p} = event) do
    upsert_refine(status, p.address, fn refine ->
      refine
      |> Map.put(:state, :running)
      |> put_refine_ref(:started, raw_ref(status, event))
    end)
  end

  defp update_refines(
         %__MODULE__{} = status,
         %Event{type: :refine_round_started, payload: p} = event
       ) do
    upsert_refine(status, p.address, fn refine ->
      refine
      |> Map.put(:state, :running)
      |> Map.put(:artifact_preview, artifact_preview(p.artifact))
      |> put_refine_ref(:rounds, raw_ref(status, event))
    end)
  end

  defp update_refines(
         %__MODULE__{} = status,
         %Event{type: :refine_round_decision, payload: p} = event
       ) do
    upsert_refine(status, p.address, fn refine ->
      refine
      |> apply_refine_payload(p, :running, :replace)
      |> put_refine_ref(:decisions, raw_ref(status, event))
    end)
  end

  defp update_refines(
         %__MODULE__{} = status,
         %Event{type: :refine_role_failed, payload: p} = event
       ) do
    upsert_refine(status, p.address, fn refine ->
      role_failures = merge_role_failures(refine.role_failures, [p])

      refine
      |> Map.put(:role_failures, role_failures)
      |> Map.put(:failed_reviewers, failed_reviewers(role_failures))
      |> refresh_final_open_defects()
      |> put_refine_ref(:role_failures, raw_ref(status, event))
    end)
  end

  defp update_refines(
         %__MODULE__{} = status,
         %Event{type: :refine_gate_evaluated, payload: p} = event
       ) do
    upsert_refine(status, p.address, fn refine ->
      put_refine_ref(refine, :gates, raw_ref(status, event))
    end)
  end

  defp update_refines(%__MODULE__{} = status, %Event{type: type, payload: p} = event)
       when type in [:agent_activity, :agent_committed, :agent_attempt_rejected, :agent_failed] do
    ref = raw_ref(status, event)

    matching =
      status.refines
      |> Enum.filter(fn refine -> p.address in [refine.address ++ [3], refine.address ++ [4]] end)
      |> Enum.map(& &1.address)
      |> MapSet.new()

    if MapSet.size(matching) == 0 do
      status
    else
      %{status | refines: Enum.map(status.refines, &maybe_put_gate_role_ref(&1, matching, ref))}
    end
  end

  defp update_refines(%__MODULE__{} = status, %Event{type: :refine_completed, payload: p} = event) do
    upsert_refine(status, p.address, fn refine ->
      refine
      |> apply_refine_payload(p, :completed, :replace)
      |> put_refine_ref(:terminal, raw_ref(status, event))
    end)
  end

  defp update_refines(
         %__MODULE__{} = status,
         %Event{type: :refine_non_converged, payload: p} = event
       ) do
    upsert_refine(status, p.address, fn refine ->
      refine
      |> apply_refine_payload(Map.put_new(p, :converged, false), :failed, :replace)
      |> put_refine_ref(:terminal, raw_ref(status, event))
    end)
  end

  defp update_refines(
         %__MODULE__{} = status,
         %Event{type: :refine_input_invalid, payload: p} = event
       ) do
    upsert_refine(status, p.address, fn refine ->
      refine
      |> Map.put(:state, :failed)
      |> put_refine_ref(:terminal, raw_ref(status, event))
    end)
  end

  defp update_refines(%__MODULE__{} = status, %Event{}), do: status

  defp upsert_refine(%__MODULE__{} = status, address, fun) do
    {refines, found?} =
      Enum.map_reduce(status.refines, false, fn refine, found? ->
        if refine.address == address do
          {fun.(refine), true}
        else
          {refine, found?}
        end
      end)

    refines = if found?, do: refines, else: refines ++ [fun.(new_refine(address))]
    %{status | refines: refines}
  end

  defp new_refine(address) do
    %{
      address: address,
      state: :running,
      converged: nil,
      rounds: 0,
      final_round: nil,
      open_findings: [],
      final_open_defects: [],
      failed_reviewers: [],
      role_failures: [],
      artifact_preview: nil,
      reviewer_decisions: [],
      cold_read: nil,
      report_snippets: [],
      raw_refs: %{
        started: nil,
        rounds: [],
        decisions: [],
        role_failures: [],
        gates: [],
        gate_role_agents: [],
        terminal: nil,
        journal: []
      }
    }
  end

  defp apply_refine_payload(refine, payload, state, role_failure_mode) do
    role_failures =
      case role_failure_mode do
        :replace -> Map.get(payload, :role_failures, refine.role_failures)
        :merge -> merge_role_failures(refine.role_failures, Map.get(payload, :role_failures, []))
      end

    refine
    |> Map.put(:state, state)
    |> put_if_present(:converged, payload, :converged)
    |> put_if_present(:rounds, payload, :rounds)
    |> put_if_present(:final_round, payload, :final_round)
    |> put_if_present(:open_findings, payload, :open_findings)
    |> Map.put(:role_failures, role_failures)
    |> Map.put(
      :failed_reviewers,
      Map.get(payload, :failed_reviewers, failed_reviewers(role_failures))
    )
    |> put_if_present(:reviewer_decisions, payload, :reviewer_decisions)
    |> put_if_present(:cold_read, payload, :cold_read)
    |> put_if_present(:report_snippets, payload, :report_snippets)
    |> maybe_put_artifact_preview(payload)
    |> refresh_final_open_defects()
  end

  defp put_if_present(map, key, payload, payload_key) do
    if Map.has_key?(payload, payload_key),
      do: Map.put(map, key, Map.fetch!(payload, payload_key)),
      else: map
  end

  defp maybe_put_artifact_preview(refine, %{artifact: artifact}),
    do: %{refine | artifact_preview: artifact_preview(artifact)}

  defp maybe_put_artifact_preview(refine, _payload), do: refine

  defp put_refine_ref(refine, key, ref) when key in [:started, :terminal] do
    refine
    |> put_in([:raw_refs, key], ref)
    |> refresh_refine_journal_refs()
  end

  defp put_refine_ref(refine, key, ref) do
    refine
    |> update_in([:raw_refs, key], &(&1 ++ [ref]))
    |> refresh_refine_journal_refs()
  end

  defp maybe_put_gate_role_ref(refine, matching, ref) do
    if MapSet.member?(matching, refine.address) do
      put_refine_ref(refine, :gate_role_agents, ref)
    else
      refine
    end
  end

  defp refresh_refine_journal_refs(refine) do
    refs = refine.raw_refs

    journal =
      []
      |> maybe_append_ref(refs.started)
      |> Kernel.++(refs.rounds)
      |> Kernel.++(refs.decisions)
      |> Kernel.++(refs.role_failures)
      |> Kernel.++(refs.gates)
      |> Kernel.++(refs.gate_role_agents)
      |> maybe_append_ref(refs.terminal)
      |> Enum.sort_by(&(&1.seq || -1))

    put_in(refine.raw_refs.journal, journal)
  end

  defp maybe_append_ref(refs, nil), do: refs
  defp maybe_append_ref(refs, ref), do: refs ++ [ref]

  defp refresh_final_open_defects(refine) do
    %{
      refine
      | final_open_defects: refine.open_findings ++ role_failures_as_defects(refine.role_failures)
    }
  end

  defp role_failures_as_defects(role_failures) do
    Enum.map(role_failures, fn failure ->
      %{
        kind: :role_failure,
        role: failure.role,
        role_address: failure.role_address,
        reviewer: Map.get(failure, :reviewer),
        reviewer_index: Map.get(failure, :reviewer_index),
        id: "role_failure:#{failure.role}:#{address_path(failure.role_address)}",
        issue: "Refine role failed: #{role_failure_reason_code(failure.reason)}",
        fix:
          "Re-run or revise with the available successful findings; provider/runtime detail: #{inspect(Map.get(failure, :detail))}",
        reason: failure.reason
      }
    end)
  end

  defp role_failure_reason_code({:provider_failure, _kind, _detail}), do: "provider_failure"
  defp role_failure_reason_code({:malformed_output, _detail}), do: "malformed_output"
  defp role_failure_reason_code({:reviewer_timeout, _timeout}), do: "reviewer_timeout"
  defp role_failure_reason_code({:cold_read_timeout, _timeout}), do: "cold_read_timeout"
  defp role_failure_reason_code({:reviewer_crashed, _detail}), do: "reviewer_crashed"
  defp role_failure_reason_code({:cold_read_crashed, _detail}), do: "cold_read_crashed"
  defp role_failure_reason_code({:repair_failed, _detail}), do: "repair_failed"
  defp role_failure_reason_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp role_failure_reason_code(_reason), do: "unknown"

  defp merge_role_failures(left, right) do
    (left ++ right)
    |> Enum.uniq_by(&{&1.role, &1.role_address, &1.round, Map.get(&1, :reviewer_index)})
  end

  defp failed_reviewers(role_failures) do
    role_failures
    |> Enum.map(&Map.get(&1, :reviewer))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp artifact_preview(artifact) when is_binary(artifact) do
    binary_part(artifact, 0, min(byte_size(artifact), 4096))
  end

  defp artifact_preview(artifact), do: inspect(artifact)

  defp address_path(address), do: "/" <> Enum.map_join(address || [], "/", &Integer.to_string/1)

  defp raw_ref(%__MODULE__{} = status, %Event{} = event) do
    %{
      run_id: event.run_id || status.run_id,
      seq: event.seq,
      type: Atom.to_string(event.type)
    }
    |> put_present(:address, Map.get(event.payload, :address))
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

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

  defp maybe_put_provider_failure(agent, {:provider_failure, kind, detail}),
    do: Map.put(agent, :provider_failure, %{kind: kind, detail: detail})

  defp maybe_put_provider_failure(agent, _reason), do: agent

  defp add_failed_usage(%Usage{} = aggregate, %Usage{} = failed_usage),
    do: Usage.add(aggregate, failed_usage)

  defp add_failed_usage(%Usage{} = aggregate, _failed_usage), do: aggregate

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
