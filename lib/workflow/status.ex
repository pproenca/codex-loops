defmodule Workflow.Status do
  @moduledoc """
  A read model reconstructed **purely by folding the journal** — no process state
  is consulted. `of/1` reads the events, `fold/2` is the pure reducer (unit-testable
  in isolation), so the same fold backs an in-process query today and a
  journal-subscribed LiveView tomorrow.
  """

  alias Workflow.Event
  alias Workflow.Event.Payload
  alias Workflow.IdempotencyKey
  alias Workflow.Journal
  alias Workflow.Provider.Activity
  alias Workflow.Provider.Usage
  alias Workflow.Refine.RoleFailure
  alias Workflow.Status.Agent
  alias Workflow.Status.Failure
  alias Workflow.Status.Judgment
  alias Workflow.Status.Phase
  alias Workflow.Status.ProviderFailure
  alias Workflow.Status.RawRef
  alias Workflow.Status.RawRefs
  alias Workflow.Status.Refine
  alias Workflow.Status.RefineRefs
  alias Workflow.Status.Rejection
  alias Workflow.Status.RoleFailureDefect
  alias Workflow.Status.ToolActivity
  alias Workflow.Status.Verification

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
            raw_refs: %RawRefs{journal: []},
            failure: nil,
            result: nil,
            usage: %Usage{},
            event_count: 0

  @type t :: %__MODULE__{
          run_id: String.t() | nil,
          state: :pending | :running | :completed | :failed,
          tree_name: String.t() | nil,
          tree_version: pos_integer() | nil,
          phase: String.t() | nil,
          current_phase_id: String.t() | nil,
          phases: [Phase.t()],
          logs: [String.t()],
          agents: [Agent.t()],
          rejected: [Rejection.t()],
          accumulators: %{optional(atom()) => list()},
          verifications: [Verification.t()],
          judgments: [Judgment.t()],
          refines: [Refine.t()],
          tool_activity: [ToolActivity.t()],
          raw_refs: RawRefs.t(),
          failure: Failure.t() | nil,
          result: term(),
          usage: Usage.t(),
          event_count: non_neg_integer()
        }

  @spec of(String.t()) :: t()
  def of(run_id), do: run_id |> Journal.fold() |> fold(run_id)

  @spec fold([Event.t()], String.t()) :: t()
  def fold(events, run_id) do
    Enum.reduce(events, %__MODULE__{run_id: run_id}, &apply_event/2)
  end

  @spec apply_event(Event.t(), t()) :: t()
  def apply_event(%Event{} = event, %__MODULE__{} = status) do
    status
    |> append_raw_ref(event)
    |> append_tool_activity(event)
    |> update_refines(event)
    |> then(&apply_known_event(event, &1))
  end

  defp apply_known_event(%Event{payload: %Payload.RunStarted{} = p}, s) do
    tick(%{s | state: :running, tree_name: p.tree_name, tree_version: p.tree_version})
  end

  defp apply_known_event(%Event{payload: %Payload.PhaseEntered{} = p}, s) do
    phase = %Phase{id: "phase-#{length(s.phases)}", name: p.name, address: p.address, agents: []}
    tick(%{s | phase: p.name, current_phase_id: phase.id, phases: s.phases ++ [phase]})
  end

  defp apply_known_event(%Event{payload: %Payload.LogEmitted{} = p}, s) do
    tick(%{s | logs: s.logs ++ [p.message]})
  end

  defp apply_known_event(%Event{payload: %Payload.AgentStarted{} = p}, s) do
    s = ensure_phase(s)

    agent = %Agent{
      address: p.address,
      iteration: p.iteration,
      label: p.label,
      prompt: p.prompt,
      result: nil,
      usage: %Usage{},
      attempt: p.attempt,
      idempotency_key: p.idempotency_key,
      status: :running,
      activity: [],
      phase_id: s.current_phase_id,
      phase_name: phase_name(s)
    }

    tick(%{
      s
      | agents: upsert_in_flight_agent(s.agents, agent),
        phases: upsert_in_flight_agent_in_phase(s.phases, s.current_phase_id, agent)
    })
  end

  defp apply_known_event(%Event{payload: %Payload.AgentCommitted{} = p}, s) do
    s = ensure_phase(s)
    attempt = idempotency_attempt(p.idempotency_key)
    existing = find_agent_attempt(s.agents, p.address, p.iteration, attempt)
    activity = indexed_activity(p.activity)

    agent = %Agent{
      address: p.address,
      iteration: p.iteration,
      label: p.label,
      prompt: p.prompt,
      result: p.result,
      usage: p.usage,
      attempt: attempt,
      idempotency_key: p.idempotency_key,
      status: :completed,
      activity: merge_activity(existing && existing.activity, activity),
      phase_id: s.current_phase_id,
      phase_name: phase_name(s)
    }

    tick(%{
      s
      | agents: upsert_settled_agent(s.agents, agent),
        phases: upsert_settled_agent_in_phase(s.phases, s.current_phase_id, agent),
        usage: Usage.add(s.usage, p.usage)
    })
  end

  defp apply_known_event(%Event{payload: %Payload.AgentActivity{}} = event, s) do
    event
    |> apply_agent_activity(s)
    |> tick()
  end

  defp apply_known_event(%Event{payload: %Payload.AgentAttemptRejected{} = p}, s) do
    s = ensure_phase(s)
    existing = find_agent_attempt(s.agents, p.address, p.iteration, p.attempt)
    activity = indexed_activity(p.activity)
    phase_id = (existing && existing.phase_id) || s.current_phase_id
    phase_name = (existing && existing.phase_name) || phase_name(s)

    rejection = %Rejection{
      address: p.address,
      iteration: p.iteration,
      attempt: p.attempt,
      label: p.label || (existing && existing.label),
      prompt: p.prompt,
      output: p.output,
      reason: p.reason,
      activity: merge_activity(existing && existing.activity, activity),
      phase_id: phase_id,
      phase_name: phase_name
    }

    tick(%{
      s
      | agents: remove_rejected_agent(s.agents, p.address, p.iteration, p.attempt),
        phases: remove_rejected_agent_from_phases(s.phases, p.address, p.iteration, p.attempt),
        rejected: s.rejected ++ [rejection],
        usage: Usage.add(s.usage, p.usage)
    })
  end

  defp apply_known_event(%Event{payload: %Payload.AgentFailed{} = p}, s) do
    s = ensure_phase(s)
    existing = find_agent_attempt(s.agents, p.address, p.iteration, p.attempts - 1)
    rejection = latest_rejection(s.rejected, p.address, p.iteration)
    failed_usage = p.usage
    failed_activity = indexed_activity(p.activity)

    phase_id =
      (existing && existing.phase_id) || (rejection && rejection.phase_id) || s.current_phase_id

    phase_name =
      (existing && existing.phase_name) || (rejection && rejection.phase_name) || phase_name(s)

    agent =
      maybe_put_provider_failure(
        %Agent{
          address: p.address,
          iteration: p.iteration,
          label: (existing && existing.label) || (rejection && rejection.label),
          prompt: (existing && existing.prompt) || (rejection && rejection.prompt),
          result: existing && existing.result,
          usage: failed_usage || (existing && existing.usage) || %Usage{},
          attempt: p.attempts - 1,
          idempotency_key: existing && existing.idempotency_key,
          status: :failed,
          activity:
            merge_activity(
              (existing && existing.activity) || (rejection && rejection.activity),
              failed_activity
            ),
          phase_id: phase_id,
          phase_name: phase_name
        },
        p.reason
      )

    failure = %Failure{
      address: p.address,
      iteration: p.iteration,
      attempts: p.attempts,
      reason: p.reason
    }

    tick(%{
      s
      | state: :failed,
        failure: failure,
        agents: upsert_settled_agent(s.agents, agent),
        phases: upsert_settled_agent_in_phase(s.phases, phase_id, agent),
        usage: add_failed_usage(s.usage, failed_usage)
    })
  end

  defp apply_known_event(%Event{payload: %Payload.RefineInputInvalid{} = p}, s) do
    tick(%{
      s
      | state: :failed,
        failure: %Failure{
          address: p.address,
          iteration: 0,
          attempts: 0,
          reason: {:invalid_refine_input, p.address, p.reason}
        }
    })
  end

  defp apply_known_event(%Event{payload: %Payload.RefineNonConverged{} = p}, s) do
    tick(%{
      s
      | state: :failed,
        failure: %Failure{
          address: p.address,
          iteration: 0,
          attempts: 0,
          reason: {:did_not_converge, p.address, p.reason}
        }
    })
  end

  defp apply_known_event(%Event{payload: %Payload.FanoutFailed{} = p}, s) do
    iteration = p.iteration

    tick(%{
      s
      | state: :failed,
        failure: %Failure{
          address: p.address,
          iteration: iteration,
          attempts: 0,
          reason: {:fanout_failed, p.address, iteration, p.reason}
        }
    })
  end

  defp apply_known_event(%Event{payload: %Payload.LoopExhausted{} = p}, s) do
    tick(%{
      s
      | state: :failed,
        failure: %Failure{
          address: p.address,
          iteration: p.iterations,
          attempts: 0,
          reason: {:loop_exhausted, p.address, p.iterations}
        }
    })
  end

  defp apply_known_event(%Event{payload: %Payload.RefineRoleFailed{} = p}, s) do
    tick(%{s | usage: add_failed_usage(s.usage, p.usage)})
  end

  # Fan-out markers are structural brackets; the branch/lane agent turns they enclose
  # already fold into `agents`/`usage` via `agent_committed`. They advance the event
  # count so the fold stays total over the versioned, additive log.
  defp apply_known_event(%Event{payload: %Payload.ParallelStarted{}}, s), do: tick(s)
  defp apply_known_event(%Event{payload: %Payload.ParallelCompleted{}}, s), do: tick(s)
  defp apply_known_event(%Event{payload: %Payload.PipelineStarted{}}, s), do: tick(s)
  defp apply_known_event(%Event{payload: %Payload.PipelineCompleted{}}, s), do: tick(s)
  defp apply_known_event(%Event{payload: %Payload.FanoutStarted{}}, s), do: tick(s)
  defp apply_known_event(%Event{payload: %Payload.FanoutCompleted{}}, s), do: tick(s)
  defp apply_known_event(%Event{payload: %Payload.RefineStarted{}}, s), do: tick(s)
  defp apply_known_event(%Event{payload: %Payload.RefineRoundStarted{}}, s), do: tick(s)
  defp apply_known_event(%Event{payload: %Payload.RefineRoundDecision{}}, s), do: tick(s)
  defp apply_known_event(%Event{payload: %Payload.RefineGateEvaluated{}}, s), do: tick(s)
  defp apply_known_event(%Event{payload: %Payload.RefineCompleted{}}, s), do: tick(s)

  # A declared reduction: append this iteration's already-deduped items to the named
  # accumulator. The read model is thus a pure fold — the same rebuild that resume
  # relies on — so LiveView renders only journaled accumulator state.
  defp apply_known_event(%Event{payload: %Payload.Accumulate{} = p}, s) do
    accumulators = Map.update(s.accumulators, p.into, p.added, &(&1 ++ p.added))
    tick(%{s | accumulators: accumulators})
  end

  # Loop control-flow brackets/decisions carry no read-model state of their own; they
  # advance the count so the fold stays total over the versioned, additive log.
  defp apply_known_event(%Event{payload: %Payload.IterationStarted{}}, s), do: tick(s)
  defp apply_known_event(%Event{payload: %Payload.LoopDecision{}}, s), do: tick(s)
  defp apply_known_event(%Event{payload: %Payload.LoopCompleted{}}, s), do: tick(s)

  # Quality-combinator brackets. The started/completed markers only bracket the
  # concurrent region — their votes/scores already fold into `agents`/`usage`. The
  # settled events carry the journal-folded panel outcome the read model surfaces,
  # so LiveView renders only journaled verification/judgment state.
  defp apply_known_event(%Event{payload: %Payload.VerifyStarted{}}, s), do: tick(s)
  defp apply_known_event(%Event{payload: %Payload.JudgeStarted{}}, s), do: tick(s)
  defp apply_known_event(%Event{payload: %Payload.LegacyFanOutStarted{}}, s), do: tick(s)
  defp apply_known_event(%Event{payload: %Payload.LegacyFanOutCompleted{}}, s), do: tick(s)

  defp apply_known_event(%Event{payload: %Payload.VerifySettled{} = p}, s) do
    verification = %Verification{
      address: p.address,
      confirmations: p.confirmations,
      total: p.total,
      threshold: p.threshold,
      survived: p.survived
    }

    tick(%{s | verifications: s.verifications ++ [verification]})
  end

  defp apply_known_event(%Event{payload: %Payload.JudgeSettled{} = p}, s) do
    judgment = %Judgment{address: p.address, scores: p.scores, pick: p.pick, winner: p.winner}
    tick(%{s | judgments: s.judgments ++ [judgment]})
  end

  defp apply_known_event(%Event{payload: %Payload.RunCompleted{} = p}, s) do
    tick(%{s | state: :completed, result: p.value})
  end

  defp apply_known_event(
         %Event{payload: %Payload.RunFailed{reason: {:outcome_unknown, %IdempotencyKey{} = key} = reason}},
         s
       ) do
    s = settle_outcome_unknown_agent(s, key)

    tick(%{
      s
      | state: :failed,
        failure: %Failure{
          address: key.node_path,
          iteration: key.iteration,
          attempts: key.attempt + 1,
          reason: reason
        }
    })
  end

  defp apply_known_event(%Event{payload: %Payload.RunFailed{} = p}, s) do
    tick(%{
      s
      | state: :failed,
        failure: %Failure{address: nil, iteration: 0, attempts: 0, reason: {:run_crashed, p.reason}}
    })
  end

  defp apply_agent_activity(%Event{payload: p}, s) do
    s = ensure_phase(s)
    existing = find_agent_attempt(s.agents, p.address, p.iteration, p.attempt)
    rejection = find_rejected_attempt(s.rejected, p.address, p.iteration, p.attempt)
    entry = maybe_put_activity_index(p.entry, p.activity_index)

    cond do
      existing ->
        agent = merge_agent_activity(existing, p, entry, s)

        %{
          s
          | agents: upsert_in_flight_agent(s.agents, agent),
            phases: upsert_in_flight_agent_in_phase(s.phases, agent.phase_id, agent)
        }

      rejection ->
        %{s | rejected: upsert_rejection(s.rejected, merge_rejection_activity(rejection, entry))}

      true ->
        agent = new_activity_agent(p, entry, s)

        %{
          s
          | agents: upsert_in_flight_agent(s.agents, agent),
            phases: upsert_in_flight_agent_in_phase(s.phases, agent.phase_id, agent)
        }
    end
  end

  defp append_raw_ref(%__MODULE__{} = status, %Event{} = event) do
    raw_refs = %{status.raw_refs | journal: status.raw_refs.journal ++ [raw_ref(status, event)]}
    %{status | raw_refs: raw_refs}
  end

  defp append_tool_activity(%__MODULE__{} = status, %Event{payload: %Payload.AgentActivity{} = p} = event) do
    entry = maybe_put_activity_index(p.entry, p.activity_index)
    append_tool_activity_entries(status, event, [entry])
  end

  defp append_tool_activity(%__MODULE__{} = status, %Event{payload: %Payload.AgentCommitted{} = p} = event) do
    append_payload_activity(status, event, p)
  end

  defp append_tool_activity(%__MODULE__{} = status, %Event{payload: %Payload.AgentAttemptRejected{} = p} = event) do
    append_payload_activity(status, event, p)
  end

  defp append_tool_activity(%__MODULE__{} = status, %Event{payload: %Payload.AgentFailed{} = p} = event) do
    append_payload_activity(status, event, p)
  end

  defp append_tool_activity(%__MODULE__{} = status, %Event{payload: %Payload.RefineRoleFailed{} = p} = event) do
    append_payload_activity(status, event, p)
  end

  defp append_tool_activity(%__MODULE__{} = status, %Event{}), do: status

  defp append_payload_activity(%__MODULE__{} = status, %Event{} = event, payload) do
    append_tool_activity_entries(status, event, payload.activity)
  end

  defp append_tool_activity_entries(status, _event, []), do: status

  defp append_tool_activity_entries(%__MODULE__{} = status, %Event{} = event, entries) do
    ref = raw_ref(status, event)

    additions = Enum.map(entries, &%ToolActivity{entry: &1, raw_ref: ref})

    %{status | tool_activity: status.tool_activity ++ additions}
  end

  defp update_refines(%__MODULE__{} = status, %Event{payload: %Payload.RefineStarted{} = p} = event) do
    upsert_refine(status, p.address, fn %Refine{} = refine ->
      put_refine_ref(%{refine | state: :running}, :started, raw_ref(status, event))
    end)
  end

  defp update_refines(%__MODULE__{} = status, %Event{payload: %Payload.RefineRoundStarted{} = p} = event) do
    upsert_refine(status, p.address, fn %Refine{} = refine ->
      refine = %{refine | state: :running, artifact_preview: artifact_preview(p.artifact)}
      put_refine_ref(refine, :rounds, raw_ref(status, event))
    end)
  end

  defp update_refines(%__MODULE__{} = status, %Event{payload: %Payload.RefineRoundDecision{} = p} = event) do
    upsert_refine(status, p.address, fn %Refine{} = refine ->
      refine
      |> apply_refine_payload(p, :running)
      |> put_refine_ref(:decisions, raw_ref(status, event))
    end)
  end

  defp update_refines(%__MODULE__{} = status, %Event{payload: %Payload.RefineRoleFailed{} = p} = event) do
    upsert_refine(status, p.address, fn %Refine{} = refine ->
      role_failures = merge_role_failures(refine.role_failures, [Payload.RefineRoleFailed.role_failure(p)])

      %{refine | role_failures: role_failures, failed_reviewers: failed_reviewers(role_failures)}
      |> refresh_final_open_defects()
      |> put_refine_ref(:role_failures, raw_ref(status, event))
    end)
  end

  defp update_refines(%__MODULE__{} = status, %Event{payload: %Payload.RefineGateEvaluated{} = p} = event) do
    upsert_refine(status, p.address, fn %Refine{} = refine ->
      put_refine_ref(refine, :gates, raw_ref(status, event))
    end)
  end

  defp update_refines(%__MODULE__{} = status, %Event{payload: %Payload.AgentActivity{} = p} = event),
    do: update_gate_role_ref(status, event, p)

  defp update_refines(%__MODULE__{} = status, %Event{payload: %Payload.AgentCommitted{} = p} = event),
    do: update_gate_role_ref(status, event, p)

  defp update_refines(%__MODULE__{} = status, %Event{payload: %Payload.AgentAttemptRejected{} = p} = event),
    do: update_gate_role_ref(status, event, p)

  defp update_refines(%__MODULE__{} = status, %Event{payload: %Payload.AgentFailed{} = p} = event),
    do: update_gate_role_ref(status, event, p)

  defp update_refines(%__MODULE__{} = status, %Event{payload: %Payload.RefineCompleted{} = p} = event) do
    upsert_refine(status, p.address, fn %Refine{} = refine ->
      refine
      |> apply_refine_payload(p, :completed)
      |> put_refine_ref(:terminal, raw_ref(status, event))
    end)
  end

  defp update_refines(%__MODULE__{} = status, %Event{payload: %Payload.RefineNonConverged{} = p} = event) do
    upsert_refine(status, p.address, fn %Refine{} = refine ->
      refine
      |> apply_refine_payload(p, :failed)
      |> put_refine_ref(:terminal, raw_ref(status, event))
    end)
  end

  defp update_refines(%__MODULE__{} = status, %Event{payload: %Payload.RefineInputInvalid{} = p} = event) do
    upsert_refine(status, p.address, fn %Refine{} = refine ->
      put_refine_ref(%{refine | state: :failed}, :terminal, raw_ref(status, event))
    end)
  end

  defp update_refines(%__MODULE__{} = status, %Event{}), do: status

  defp update_gate_role_ref(%__MODULE__{} = status, %Event{} = event, payload) do
    ref = raw_ref(status, event)

    matching =
      status.refines
      |> Enum.filter(fn refine -> payload.address in [refine.address ++ [3], refine.address ++ [4]] end)
      |> MapSet.new(& &1.address)

    if MapSet.size(matching) == 0 do
      status
    else
      %{status | refines: Enum.map(status.refines, &maybe_put_gate_role_ref(&1, matching, ref))}
    end
  end

  defp upsert_refine(%__MODULE__{} = status, address, fun) do
    {refines, found?} =
      Enum.map_reduce(status.refines, false, fn %Refine{} = refine, found? ->
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
    %Refine{
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
      raw_refs: %RefineRefs{
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

  defp apply_refine_payload(%Refine{} = refine, %Payload.RefineRoundDecision{} = payload, :running) do
    refresh_final_open_defects(%{
      refine
      | state: :running,
        open_findings: payload.open_findings,
        role_failures: payload.role_failures,
        failed_reviewers: payload.failed_reviewers,
        reviewer_decisions: payload.reviewer_decisions,
        report_snippets: payload.report_snippets,
        artifact_preview: artifact_preview(payload.artifact)
    })
  end

  defp apply_refine_payload(%Refine{} = refine, %Payload.RefineCompleted{} = payload, :completed),
    do: apply_terminal_refine_payload(refine, payload, :completed)

  defp apply_refine_payload(%Refine{} = refine, %Payload.RefineNonConverged{} = payload, :failed),
    do: apply_terminal_refine_payload(refine, payload, :failed)

  defp apply_terminal_refine_payload(%Refine{} = refine, payload, state) do
    refresh_final_open_defects(%{
      refine
      | state: state,
        converged: payload.converged,
        rounds: payload.rounds,
        final_round: payload.final_round,
        open_findings: payload.open_findings,
        role_failures: payload.role_failures,
        failed_reviewers: payload.failed_reviewers,
        reviewer_decisions: payload.reviewer_decisions,
        cold_read: payload.cold_read,
        report_snippets: payload.report_snippets,
        artifact_preview: artifact_preview(payload.artifact)
    })
  end

  defp put_refine_ref(%Refine{} = refine, key, %RawRef{} = ref) when key in [:started, :terminal] do
    raw_refs = Map.put(refine.raw_refs, key, ref)
    refresh_refine_journal_refs(%{refine | raw_refs: raw_refs})
  end

  defp put_refine_ref(%Refine{} = refine, key, %RawRef{} = ref) do
    raw_refs = Map.update!(refine.raw_refs, key, &(&1 ++ [ref]))
    refresh_refine_journal_refs(%{refine | raw_refs: raw_refs})
  end

  defp maybe_put_gate_role_ref(%Refine{} = refine, matching, %RawRef{} = ref) do
    if MapSet.member?(matching, refine.address) do
      put_refine_ref(refine, :gate_role_agents, ref)
    else
      refine
    end
  end

  defp refresh_refine_journal_refs(%Refine{} = refine) do
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

    %{refine | raw_refs: %{refs | journal: journal}}
  end

  defp maybe_append_ref(refs, nil), do: refs
  defp maybe_append_ref(refs, ref), do: refs ++ [ref]

  defp refresh_final_open_defects(%Refine{} = refine) do
    %{
      refine
      | final_open_defects: refine.open_findings ++ role_failures_as_defects(refine.role_failures)
    }
  end

  defp role_failures_as_defects(role_failures) do
    Enum.map(role_failures, fn %RoleFailure{} = failure ->
      %RoleFailureDefect{
        kind: :role_failure,
        role: failure.role,
        role_address: failure.role_address,
        reviewer: failure.reviewer,
        reviewer_index: failure.reviewer_index,
        id: "role_failure:#{failure.role}:#{address_path(failure.role_address)}",
        issue: "Refine role failed: #{RoleFailure.reason_code(failure.reason)}",
        fix:
          "Re-run or revise with the available successful findings; provider/runtime detail: #{inspect(failure.detail)}",
        reason: failure.reason
      }
    end)
  end

  defp merge_role_failures(left, right) do
    Enum.uniq_by(left ++ right, fn %RoleFailure{} = failure ->
      {failure.role, failure.role_address, failure.round, failure.reviewer_index}
    end)
  end

  defp failed_reviewers(role_failures) do
    role_failures
    |> Enum.map(fn %RoleFailure{reviewer: reviewer} -> reviewer end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp artifact_preview(artifact) when is_binary(artifact) do
    artifact
    |> binary_part(0, min(byte_size(artifact), 4096))
    |> :binary.copy()
  end

  defp artifact_preview(artifact), do: inspect(artifact)

  defp address_path(address), do: "/" <> Enum.map_join(address || [], "/", &Integer.to_string/1)

  defp raw_ref(%__MODULE__{} = status, %Event{} = event) do
    %RawRef{
      run_id: event.run_id || status.run_id,
      seq: event.seq,
      type: Atom.to_string(event.type),
      address: Map.get(event.payload, :address)
    }
  end

  defp tick(%__MODULE__{} = s), do: %{s | event_count: s.event_count + 1}

  defp ensure_phase(%__MODULE__{current_phase_id: nil} = s) do
    phase = %Phase{id: "phase-default", name: "Default phase", address: nil, agents: []}
    %{s | current_phase_id: phase.id, phases: s.phases ++ [phase]}
  end

  defp ensure_phase(%__MODULE__{} = s), do: s

  defp find_agent_attempt(agents, address, iteration, attempt) do
    Enum.find(agents, &agent_attempt_match?(&1, address, iteration, attempt))
  end

  defp settle_outcome_unknown_agent(%__MODULE__{} = status, %IdempotencyKey{
         node_path: address,
         iteration: iteration,
         attempt: attempt
       }) do
    settle = &settle_outcome_unknown_agent(&1, address, iteration, attempt)

    %{
      status
      | agents: Enum.map(status.agents, settle),
        phases: Enum.map(status.phases, fn phase -> %{phase | agents: Enum.map(phase.agents, settle)} end)
    }
  end

  defp settle_outcome_unknown_agent(%Agent{} = agent, address, iteration, attempt) do
    if agent_attempt_match?(agent, address, iteration, attempt) do
      %{agent | status: :failed}
    else
      agent
    end
  end

  defp find_rejected_attempt(rejections, address, iteration, attempt) do
    Enum.find(rejections, &rejected_agent_match?(&1, address, iteration, attempt))
  end

  defp new_activity_agent(%Payload.AgentActivity{} = payload, %Activity{} = entry, %__MODULE__{} = status) do
    %Agent{
      address: payload.address,
      iteration: payload.iteration,
      attempt: payload.attempt,
      label: payload.label,
      prompt: payload.prompt,
      result: nil,
      usage: %Usage{},
      idempotency_key: nil,
      status: :running,
      activity: merge_activity([], [entry]),
      phase_id: status.current_phase_id,
      phase_name: phase_name(status)
    }
  end

  defp merge_agent_activity(
         %Agent{} = agent,
         %Payload.AgentActivity{} = payload,
         %Activity{} = entry,
         %__MODULE__{} = status
       ) do
    %{
      agent
      | attempt: agent.attempt || payload.attempt,
        label: agent.label || payload.label,
        prompt: agent.prompt || payload.prompt,
        usage: agent.usage || %Usage{},
        status: agent.status || :running,
        activity: merge_activity(agent.activity, [entry]),
        phase_id: agent.phase_id || status.current_phase_id,
        phase_name: agent.phase_name || phase_name(status)
    }
  end

  defp merge_rejection_activity(%Rejection{} = rejection, entry) do
    %{rejection | activity: merge_activity(rejection.activity, [entry])}
  end

  defp upsert_rejection(rejections, %Rejection{} = rejection) do
    Enum.map(rejections, fn
      %Rejection{} = existing
      when existing.address == rejection.address and existing.iteration == rejection.iteration and
             existing.attempt == rejection.attempt ->
        rejection

      %Rejection{} = existing ->
        existing
    end)
  end

  defp upsert_in_flight_agent(agents, %Agent{} = agent) do
    agents =
      if Enum.any?(agents, &agent_attempt_match?(&1, agent.address, agent.iteration, agent.attempt)) do
        Enum.map(agents, fn
          %Agent{} = existing
          when existing.address == agent.address and existing.iteration == agent.iteration and
                 existing.attempt == agent.attempt ->
            agent

          %Agent{} = existing ->
            existing
        end)
      else
        [agent | agents]
      end

    sort_agents(agents)
  end

  defp upsert_settled_agent(agents, %Agent{} = agent) do
    sort_agents([agent | Enum.reject(agents, &agent_match?(&1, agent.address, agent.iteration))])
  end

  defp remove_rejected_agent(agents, address, iteration, attempt) do
    Enum.reject(agents, &rejected_agent_match?(&1, address, iteration, attempt))
  end

  defp upsert_in_flight_agent_in_phase(phases, phase_id, %Agent{} = agent) do
    Enum.map(phases, fn
      %Phase{id: ^phase_id, agents: agents} = phase ->
        %{phase | agents: upsert_in_flight_agent(agents, agent)}

      phase ->
        phase
    end)
  end

  defp upsert_settled_agent_in_phase(phases, phase_id, %Agent{} = agent) do
    Enum.map(phases, fn
      %Phase{id: ^phase_id, agents: agents} = phase ->
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

  defp agent_match?(%Agent{} = agent, address, iteration), do: agent.address == address and agent.iteration == iteration

  defp agent_match?(%Rejection{} = rejection, address, iteration),
    do: rejection.address == address and rejection.iteration == iteration

  defp agent_attempt_match?(%Agent{} = agent, address, iteration, attempt),
    do: agent_match?(agent, address, iteration) and agent_attempt(agent) == attempt

  defp rejected_agent_match?(%Agent{} = agent, address, iteration, attempt),
    do: agent_match?(agent, address, iteration) and agent.attempt in [nil, attempt]

  defp rejected_agent_match?(%Rejection{} = rejection, address, iteration, attempt),
    do: agent_match?(rejection, address, iteration) and rejection.attempt in [nil, attempt]

  defp agent_attempt(%Agent{} = agent), do: agent.attempt || idempotency_attempt(agent.idempotency_key)

  defp idempotency_attempt(%IdempotencyKey{attempt: attempt}), do: attempt
  defp idempotency_attempt(_key), do: nil

  defp latest_rejection(rejections, address, iteration) do
    rejections
    |> Enum.filter(&(&1.address == address and &1.iteration == iteration))
    |> List.last()
  end

  defp indexed_activity(activity) do
    activity
    |> Enum.with_index()
    |> Enum.map(fn {entry, index} -> maybe_put_activity_index(entry, index) end)
  end

  defp maybe_put_activity_index(%Activity{} = entry, nil), do: entry

  defp maybe_put_activity_index(%Activity{activity_index: nil} = entry, index), do: Activity.with_index(entry, index)

  defp maybe_put_activity_index(%Activity{} = entry, _index), do: entry

  defp maybe_put_provider_failure(%Agent{} = agent, {:provider_failure, kind, detail}),
    do: %{agent | provider_failure: %ProviderFailure{kind: kind, detail: detail}}

  defp maybe_put_provider_failure(%Agent{} = agent, _reason), do: agent

  defp add_failed_usage(%Usage{} = aggregate, %Usage{} = failed_usage), do: Usage.add(aggregate, failed_usage)

  defp add_failed_usage(%Usage{} = aggregate, _failed_usage), do: aggregate

  defp merge_activity(left, right) do
    Enum.reduce(right, left || [], &merge_activity_entry/2)
  end

  defp merge_activity_entry(entry, entries) do
    index = activity_index(entry)

    case Enum.find(entries, &(activity_index(&1) == index)) do
      nil ->
        entries ++ [entry]

      _existing when is_nil(index) ->
        entries ++ [entry]

      existing ->
        if same_activity?(existing, entry) do
          entries
        else
          raise ArgumentError, "conflicting activity entries share index #{index}"
        end
    end
  end

  defp sort_agents(agents), do: Enum.sort_by(agents, &{&1.address, &1.iteration, agent_attempt(&1) || 0})

  defp activity_index(%Activity{} = entry), do: entry.activity_index

  defp same_activity?(left, right) do
    activity_index(left) == activity_index(right) and
      strip_activity_index(left) == strip_activity_index(right)
  end

  defp strip_activity_index(%Activity{} = entry), do: %{entry | activity_index: nil}

  defp phase_name(%__MODULE__{phases: phases, current_phase_id: phase_id}) do
    case Enum.find(phases, &(&1.id == phase_id)) do
      nil -> nil
      phase -> phase.name
    end
  end
end
