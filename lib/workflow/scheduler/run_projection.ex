defmodule Workflow.Scheduler.RunProjection do
  @moduledoc """
  Scheduler-owned read projection for a run.

  The projection is derived from `Workflow.Status`, which folds the journal, plus
  scheduler-owned runtime lease facts used only for lifecycle availability. API
  reads and LiveView renders use the same scheduler snapshot.
  """

  alias Workflow.Provider.Usage
  alias Workflow.Status

  @enforce_keys [
    :run_id,
    :state,
    :workflow_name,
    :tree_name,
    :phase,
    :logs,
    :agent_count,
    :event_count,
    :usage,
    :result,
    :failure,
    :agents,
    :rejected,
    :verifications,
    :judgments,
    :refines,
    :tool_activity,
    :raw_refs,
    :lifecycle_action,
    :ui_path,
    :ui_url
  ]
  defstruct [
    :run_id,
    :state,
    :workflow_name,
    :tree_name,
    :phase,
    :logs,
    :agent_count,
    :event_count,
    :usage,
    :result,
    :failure,
    :agents,
    :rejected,
    :verifications,
    :judgments,
    :refines,
    :tool_activity,
    :raw_refs,
    :lifecycle_action,
    :ui_path,
    :ui_url
  ]

  @type t :: %__MODULE__{
          run_id: String.t(),
          state: atom(),
          workflow_name: String.t() | nil,
          tree_name: String.t() | nil,
          phase: String.t() | nil,
          logs: [String.t()],
          agent_count: non_neg_integer(),
          event_count: non_neg_integer(),
          usage: Usage.t(),
          result: term(),
          failure: map() | nil,
          agents: [map()],
          rejected: [map()],
          verifications: [map()],
          judgments: [map()],
          refines: [map()],
          tool_activity: [map()],
          raw_refs: map(),
          lifecycle_action: map(),
          ui_path: String.t(),
          ui_url: String.t()
        }

  @spec from_status(Status.t()) :: t()
  @spec from_status(Status.t(), keyword()) :: t()
  def from_status(%Status{} = status, opts \\ []) do
    ui_path = "/runs/#{status.run_id}"

    %__MODULE__{
      run_id: status.run_id,
      state: status.state,
      workflow_name: status.tree_name,
      tree_name: status.tree_name,
      phase: status.phase,
      logs: status.logs,
      agent_count: length(status.agents),
      event_count: status.event_count,
      usage: status.usage,
      result: status.result,
      failure: status.failure,
      agents: status.agents,
      rejected: status.rejected,
      verifications: status.verifications,
      judgments: status.judgments,
      refines: status.refines,
      tool_activity: status.tool_activity,
      raw_refs: status.raw_refs,
      lifecycle_action: lifecycle_action(status, opts),
      ui_path: ui_path,
      ui_url: ui_path
    }
  end

  @spec lifecycle_action(Status.t(), keyword()) :: map()
  def lifecycle_action(%Status{} = status, opts \\ []) do
    events = Keyword.get(opts, :events, [])
    running? = Keyword.get(opts, :running?, false)
    known? = known?(status, events, running?)

    cond do
      running? ->
        unavailable(:pause_unavailable, "Pause unavailable", "Pause is not implemented.")

      recoverable?(status, events, known?) ->
        %{
          action: :resume,
          label: "Resume",
          enabled: true,
          reason: "The writer is stopped before a terminal event.",
          method: "post",
          href: "/api/runs/#{status.run_id}/resume"
        }

      not known? ->
        unavailable(:run_unavailable, "Run unavailable", "No journaled run exists yet.")

      incomplete_without_script?(status, events) ->
        unavailable(
          :resume_unavailable,
          "Resume unavailable",
          "No journaled script path is available."
        )

      true ->
        unavailable(:none, "No lifecycle action", "Run is #{status.state}.")
    end
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = projection) do
    %{
      "runId" => projection.run_id,
      "state" => atom_string(projection.state),
      "treeName" => projection.tree_name,
      "phase" => projection.phase,
      "logs" => projection.logs,
      "agentCount" => projection.agent_count,
      "eventCount" => projection.event_count,
      "usage" => usage_map(projection.usage),
      "result" => jsonable(projection.result),
      "failure" => encode_failure(projection.failure),
      "agents" => Enum.map(projection.agents, &agent_map/1),
      "rejected" => Enum.map(projection.rejected, &rejected_map/1),
      "verifications" => Enum.map(projection.verifications, &verification_map/1),
      "judgments" => Enum.map(projection.judgments, &judgment_map/1),
      "refines" => Enum.map(projection.refines, &refine_map/1),
      "toolActivity" => Enum.map(projection.tool_activity, &tool_activity_map/1),
      "rawRefs" => raw_refs_map(projection.raw_refs),
      "workflowName" => projection.workflow_name,
      "lifecycleAction" => lifecycle_action_map(projection.lifecycle_action),
      "uiPath" => projection.ui_path,
      "uiUrl" => projection.ui_url
    }
  end

  defp known?(%Status{event_count: event_count}, events, running?),
    do: running? or events != [] or event_count > 0

  defp recoverable?(%Status{state: :running}, events, true), do: journaled_script_path?(events)
  defp recoverable?(_status, _events, _known?), do: false

  defp incomplete_without_script?(%Status{state: :running}, events),
    do: not journaled_script_path?(events)

  defp incomplete_without_script?(_status, _events), do: false

  defp journaled_script_path?(events) do
    Enum.any?(events, fn
      %{type: :run_started, payload: %{script_path: path}} when is_binary(path) and path != "" ->
        true

      _event ->
        false
    end)
  end

  defp unavailable(action, label, reason) do
    %{
      action: action,
      label: label,
      enabled: false,
      reason: reason,
      method: nil,
      href: nil
    }
  end

  defp lifecycle_action_map(action) do
    %{
      "action" => atom_string(action.action),
      "label" => action.label,
      "enabled" => action.enabled,
      "reason" => action.reason,
      "method" => action.method,
      "href" => action.href
    }
  end

  defp agent_map(agent) do
    %{
      "address" => agent.address,
      "iteration" => agent.iteration,
      "label" => Map.get(agent, :label),
      "prompt" => agent.prompt,
      "result" => jsonable(agent.result),
      "usage" => usage_map(agent.usage),
      "idempotencyKey" => idempotency_key_map(agent.idempotency_key),
      "status" => atom_string(agent.status),
      "activity" => json_value(agent.activity),
      "phaseId" => Map.get(agent, :phase_id),
      "phaseName" => Map.get(agent, :phase_name)
    }
    |> put_present("attempt", Map.get(agent, :attempt))
    |> put_present("providerFailure", provider_failure_map(Map.get(agent, :provider_failure)))
  end

  defp rejected_map(rejection) do
    %{
      "address" => rejection.address,
      "iteration" => rejection.iteration,
      "attempt" => rejection.attempt,
      "label" => Map.get(rejection, :label),
      "prompt" => rejection.prompt,
      "output" => jsonable(rejection.output),
      "reason" => inspect(rejection.reason),
      "activity" => json_value(rejection.activity),
      "phaseId" => Map.get(rejection, :phase_id),
      "phaseName" => Map.get(rejection, :phase_name)
    }
  end

  defp verification_map(verification) do
    %{
      "address" => verification.address,
      "confirmations" => verification.confirmations,
      "total" => verification.total,
      "threshold" => atom_string(verification.threshold),
      "survived" => verification.survived
    }
  end

  defp judgment_map(judgment) do
    %{
      "address" => judgment.address,
      "scores" => json_value(judgment.scores),
      "pick" => atom_string(judgment.pick),
      "winner" => json_value(judgment.winner)
    }
  end

  defp refine_map(refine) do
    %{
      "address" => refine.address,
      "state" => atom_string(refine.state),
      "converged" => refine.converged,
      "rounds" => refine.rounds,
      "finalRound" => refine.final_round,
      "openFindings" => Enum.map(refine.open_findings, &open_finding_map/1),
      "finalOpenDefects" => Enum.map(refine.final_open_defects, &final_open_defect_map/1),
      "failedReviewers" => Enum.map(refine.failed_reviewers, &atom_string/1),
      "roleFailures" => Enum.map(refine.role_failures, &role_failure_map/1),
      "artifactPreview" => refine.artifact_preview,
      "reviewerDecisions" => Enum.map(refine.reviewer_decisions, &reviewer_decision_map/1),
      "coldRead" => cold_read_map(refine.cold_read),
      "reportSnippets" => refine.report_snippets,
      "rawRefs" => refine_raw_refs_map(refine.raw_refs)
    }
  end

  defp open_finding_map(finding) do
    %{
      "reviewer" => atom_string(finding.reviewer),
      "reviewerIndex" => finding.reviewer_index,
      "id" => finding.id,
      "issue" => finding.issue,
      "fix" => finding.fix
    }
  end

  defp final_open_defect_map(%{kind: :role_failure} = defect) do
    %{
      "kind" => "role_failure",
      "role" => atom_string(defect.role),
      "roleAddress" => defect.role_address,
      "reviewer" => maybe_atom_string(defect.reviewer),
      "reviewerIndex" => defect.reviewer_index,
      "id" => defect.id,
      "issue" => defect.issue,
      "fix" => defect.fix,
      "reason" => reason_json(defect.reason)
    }
  end

  defp final_open_defect_map(finding), do: open_finding_map(finding)

  defp role_failure_map(failure) do
    %{
      "role" => atom_string(failure.role),
      "roleAddress" => failure.role_address,
      "round" => failure.round,
      "reviewer" => maybe_atom_string(Map.get(failure, :reviewer)),
      "reviewerIndex" => Map.get(failure, :reviewer_index),
      "attempts" => failure.attempts,
      "reason" => reason_json(failure.reason),
      "detail" => json_value(Map.get(failure, :detail)),
      "usage" => usage_map(Map.get(failure, :usage)),
      "activity" => json_value(Map.get(failure, :activity, []))
    }
  end

  defp reviewer_decision_map(decision) do
    %{
      "reviewer" => atom_string(decision.reviewer),
      "reviewerIndex" => decision.reviewer_index,
      "approved" => decision.approved,
      "clear" => decision.clear,
      "adapter" => atom_string(Map.get(decision, :adapter)),
      "status" => atom_string(decision.status)
    }
  end

  defp cold_read_map(nil), do: nil

  defp cold_read_map(%{state: :completed} = cold_read) do
    %{
      "state" => "completed",
      "openFindings" => Enum.map(Map.get(cold_read, :open_findings, []), &open_finding_map/1),
      "reviewerDecision" => reviewer_decision_map(Map.fetch!(cold_read, :reviewer_decision)),
      "reportSnippets" => Map.get(cold_read, :report_snippets, []),
      "repaired" => Map.get(cold_read, :repaired, false)
    }
  end

  defp cold_read_map(%{state: :failed} = cold_read) do
    %{
      "state" => "failed",
      "roleFailure" => role_failure_map(Map.fetch!(cold_read, :role_failure)),
      "repaired" => Map.get(cold_read, :repaired, false)
    }
  end

  defp tool_activity_map(activity) do
    %{
      "entry" => json_value(activity.entry),
      "rawRef" => raw_ref_map(activity.raw_ref)
    }
  end

  defp refine_raw_refs_map(raw_refs) do
    %{
      "started" => raw_ref_map(raw_refs.started),
      "rounds" => Enum.map(raw_refs.rounds, &raw_ref_map/1),
      "decisions" => Enum.map(raw_refs.decisions, &raw_ref_map/1),
      "roleFailures" => Enum.map(raw_refs.role_failures, &raw_ref_map/1),
      "gates" => Enum.map(raw_refs.gates, &raw_ref_map/1),
      "gateRoleAgents" => Enum.map(raw_refs.gate_role_agents, &raw_ref_map/1),
      "terminal" => raw_ref_map(raw_refs.terminal),
      "journal" => Enum.map(raw_refs.journal, &raw_ref_map/1)
    }
  end

  defp raw_refs_map(raw_refs) do
    %{"journal" => Enum.map(Map.get(raw_refs, :journal, []), &raw_ref_map/1)}
  end

  defp raw_ref_map(nil), do: nil

  defp raw_ref_map(ref) do
    %{
      "runId" => ref.run_id,
      "seq" => ref.seq,
      "type" => ref.type
    }
    |> put_present("address", Map.get(ref, :address))
  end

  defp usage_map(%Usage{} = usage) do
    %{
      "inputTokens" => usage.input_tokens,
      "outputTokens" => usage.output_tokens,
      "totalTokens" => usage.total_tokens
    }
  end

  defp usage_map(nil), do: nil

  defp encode_failure(nil), do: nil

  defp encode_failure(%{address: address, attempts: attempts, reason: reason}) do
    %{
      "address" => address,
      "attempts" => attempts,
      "reason" => inspect(reason)
    }
  end

  defp idempotency_key_map(nil), do: nil

  defp idempotency_key_map(key) do
    %{
      "runId" => key.run_id,
      "nodePath" => key.node_path,
      "iteration" => key.iteration,
      "attempt" => key.attempt
    }
  end

  defp provider_failure_map(nil), do: nil

  defp provider_failure_map(%{kind: kind, detail: detail}) do
    %{"kind" => atom_string(kind), "detail" => json_value(detail)}
  end

  defp reason_json({:provider_failure, kind, detail}),
    do: %{
      "code" => "provider_failure",
      "kind" => atom_string(kind),
      "detail" => json_value(detail)
    }

  defp reason_json({:malformed_output, detail}),
    do: %{"code" => "malformed_output", "detail" => inspect(detail)}

  defp reason_json({:reviewer_timeout, timeout}),
    do: %{"code" => "reviewer_timeout", "timeoutMs" => timeout}

  defp reason_json({:cold_read_timeout, timeout}),
    do: %{"code" => "cold_read_timeout", "timeoutMs" => timeout}

  defp reason_json({:reviewer_crashed, detail}),
    do: %{"code" => "reviewer_crashed", "detail" => inspect(detail)}

  defp reason_json({:cold_read_crashed, detail}),
    do: %{"code" => "cold_read_crashed", "detail" => inspect(detail)}

  defp reason_json({:repair_failed, detail}),
    do: %{"code" => "repair_failed", "detail" => inspect(detail)}

  defp reason_json(reason) when is_atom(reason), do: %{"code" => Atom.to_string(reason)}
  defp reason_json(reason), do: %{"code" => "unknown", "detail" => inspect(reason)}

  defp json_value(term) do
    case Jason.encode(term) do
      {:ok, _json} -> term
      {:error, _reason} -> inspect(term)
    end
  end

  defp jsonable(term) do
    case Jason.encode(term) do
      {:ok, _json} -> term
      {:error, _reason} -> inspect(term)
    end
  end

  defp atom_string(nil), do: nil
  defp atom_string(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_string(value) when is_binary(value), do: value
  defp atom_string(value), do: inspect(value)

  defp maybe_atom_string(nil), do: nil
  defp maybe_atom_string(value), do: atom_string(value)

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
