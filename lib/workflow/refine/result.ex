defmodule Workflow.Refine.Result do
  @moduledoc """
  Public structured projection for completed refine bindings.

  The writer uses this for `emit_result(:binding)`: it folds already-journaled
  refine events into the JSON-encodable shape promised by the DSL, never exposing
  atom-keyed internal payloads directly.
  """

  alias Workflow.Event
  alias Workflow.Event.Payload, as: P
  alias Workflow.Journal
  alias Workflow.JSONValue
  alias Workflow.Provider.Activity
  alias Workflow.Provider.Usage
  alias Workflow.Refine.ColdRead
  alias Workflow.Refine.OpenFinding
  alias Workflow.Refine.ReviewerDecision
  alias Workflow.Refine.RoleFailure
  alias Workflow.Refine.TerminalProjection

  @type result :: {:ok, map()} | {:error, {:unbound, Workflow.Node.binding_ref()}}

  @spec of(String.t(), Workflow.Node.address()) :: result()
  def of(run_id, address), do: run_id |> Journal.fold() |> fold(run_id, address)

  @spec fold([Event.t()], String.t(), Workflow.Node.address()) :: result()
  def fold(events, run_id, address) do
    case completed_event(events, address) do
      nil ->
        {:error, {:unbound, {:refine, address}}}

      completed ->
        {:ok, projection(events, run_id, address, completed)}
    end
  end

  @spec public(
          TerminalProjection.t() | P.RefineCompleted.t(),
          [Event.t()],
          String.t() | nil,
          Workflow.Node.address() | nil
        ) ::
          map()
  def public(attrs, events \\ [], run_id \\ nil, address \\ nil)

  def public(%TerminalProjection{} = attrs, events, run_id, address),
    do: public_projection(attrs, events, run_id, address)

  def public(%P.RefineCompleted{} = attrs, events, run_id, address), do: public_projection(attrs, events, run_id, address)

  defp public_projection(attrs, events, run_id, address) do
    %{
      "artifact" => attrs.artifact,
      "converged" => attrs.converged,
      "rounds" => attrs.rounds,
      "finalRound" => attrs.final_round,
      "openFindings" => Enum.map(attrs.open_findings, &open_finding_json/1),
      "finalOpenDefects" =>
        Enum.map(attrs.open_findings, &open_finding_json/1) ++
          role_failures_as_defects(attrs.role_failures),
      "roleFailures" => Enum.map(attrs.role_failures, &role_failure_json/1),
      "failedReviewers" => Enum.map(attrs.failed_reviewers, &JSONValue.stringify/1),
      "reviewerDecisions" => Enum.map(attrs.reviewer_decisions, &reviewer_decision_json/1),
      "coldRead" => cold_read_json(attrs.cold_read),
      "reportSnippets" => attrs.report_snippets,
      "rawRefs" => %{"journal" => raw_refs(events, run_id, address)}
    }
  end

  defp projection(events, run_id, address, completed), do: public(completed.payload, events, run_id, address)

  defp completed_event(events, address) do
    Enum.find(events, fn
      %Event{payload: %P.RefineCompleted{address: ^address}} -> true
      %Event{} -> false
    end)
  end

  defp open_finding_json(%OpenFinding{} = finding) do
    %{
      "reviewer" => JSONValue.stringify(finding.reviewer),
      "reviewerIndex" => finding.reviewer_index,
      "id" => finding.id,
      "issue" => finding.issue,
      "fix" => finding.fix
    }
  end

  defp reviewer_decision_json(%ReviewerDecision{} = decision) do
    %{
      "reviewer" => JSONValue.stringify(decision.reviewer),
      "reviewerIndex" => decision.reviewer_index,
      "approved" => ReviewerDecision.approved?(decision),
      "clear" => ReviewerDecision.clear?(decision),
      "adapter" => JSONValue.stringify(decision.adapter),
      "status" => JSONValue.stringify(ReviewerDecision.status(decision))
    }
  end

  defp role_failure_json(%RoleFailure{} = failure) do
    %{
      "role" => JSONValue.stringify(failure.role),
      "roleAddress" => failure.role_address,
      "round" => failure.round,
      "reviewer" => JSONValue.stringify(failure.reviewer),
      "reviewerIndex" => failure.reviewer_index,
      "attempts" => failure.attempts,
      "reason" => reason_json(failure.reason),
      "detail" => role_failure_detail_json(failure.detail),
      "usage" => usage_json(failure.usage),
      "activity" => Enum.map(failure.activity, &activity_entry_json/1)
    }
  end

  defp cold_read_json(nil), do: nil

  defp cold_read_json(%ColdRead{state: :completed} = cold_read) do
    %{
      "state" => "completed",
      "openFindings" => Enum.map(cold_read.open_findings, &open_finding_json/1),
      "reviewerDecision" => reviewer_decision_json(cold_read.reviewer_decision),
      "reportSnippets" => cold_read.report_snippets,
      "repaired" => ColdRead.repaired?(cold_read)
    }
  end

  defp cold_read_json(%ColdRead{state: :failed} = cold_read) do
    %{
      "state" => "failed",
      "roleFailure" => role_failure_json(cold_read.role_failure),
      "repaired" => ColdRead.repaired?(cold_read)
    }
  end

  defp role_failures_as_defects(role_failures) do
    role_failures
    |> Enum.map(&role_failure_json/1)
    |> Enum.map(fn failure ->
      %{
        "kind" => "role_failure",
        "role" => failure["role"],
        "roleAddress" => failure["roleAddress"],
        "reviewer" => failure["reviewer"],
        "reviewerIndex" => failure["reviewerIndex"],
        "id" => "role_failure:#{failure["role"]}:#{address_path(failure["roleAddress"])}",
        "issue" => "Refine role failed: #{failure["reason"]["code"]}",
        "fix" =>
          "Re-run or revise with the available successful findings; provider/runtime detail: " <>
            render_json_detail(failure["detail"]),
        "reason" => failure["reason"]
      }
    end)
  end

  defp reason_json(reason) do
    RoleFailure.reason_map(reason,
      provider_detail: &Function.identity/1,
      diagnostic_detail: &diagnostic_string/1
    )
  end

  defp role_failure_detail_json(nil), do: nil
  defp role_failure_detail_json(detail) when is_binary(detail), do: detail

  defp role_failure_detail_json(detail) do
    if JSONValue.durable_detail?(detail), do: detail, else: diagnostic_string(detail)
  end

  defp usage_json(nil), do: nil

  defp usage_json(%Usage{} = usage) do
    %{
      "inputTokens" => usage.input_tokens,
      "outputTokens" => usage.output_tokens,
      "totalTokens" => usage.total_tokens
    }
  end

  defp activity_entry_json(%Activity{} = entry), do: Activity.to_public_map(entry)

  defp raw_refs(events, run_id, address) do
    events
    |> Enum.filter(&refine_result_ref?(&1, address))
    |> Enum.sort_by(& &1.seq)
    |> Enum.map(fn event ->
      %{
        "runId" => event.run_id || run_id,
        "seq" => event.seq,
        "type" => Atom.to_string(event.type),
        "address" => event.payload.address
      }
    end)
  end

  defp refine_result_ref?(%Event{payload: %P.RefineCompleted{address: address}}, address), do: true
  defp refine_result_ref?(%Event{payload: %P.RefineNonConverged{address: address}}, address), do: true
  defp refine_result_ref?(%Event{payload: %P.RefineRoundDecision{address: address}}, address), do: true
  defp refine_result_ref?(%Event{payload: %P.RefineRoleFailed{address: address}}, address), do: true
  defp refine_result_ref?(%Event{payload: %P.RefineGateEvaluated{address: address}}, address), do: true

  defp refine_result_ref?(%Event{payload: %P.AgentActivity{address: role_address}}, address),
    do: gate_role_address?(role_address, address)

  defp refine_result_ref?(%Event{payload: %P.AgentCommitted{address: role_address}}, address),
    do: gate_role_address?(role_address, address)

  defp refine_result_ref?(%Event{payload: %P.AgentAttemptRejected{address: role_address}}, address),
    do: gate_role_address?(role_address, address)

  defp refine_result_ref?(%Event{payload: %P.AgentFailed{address: role_address}}, address),
    do: gate_role_address?(role_address, address)

  defp refine_result_ref?(%Event{}, _address), do: false

  defp gate_role_address?(role_address, address), do: role_address in [address ++ [3], address ++ [4]]

  defp address_path(address), do: "/" <> Enum.map_join(address, "/", &Integer.to_string/1)

  defp render_json_detail(nil), do: ""
  defp render_json_detail(detail) when is_binary(detail), do: detail
  defp render_json_detail(detail), do: JSONValue.deterministic_encode(detail)

  defp diagnostic_string(term), do: term |> diagnostic_value() |> JSONValue.deterministic_encode()

  defp diagnostic_value(value) when is_nil(value) or is_boolean(value) or is_integer(value) or is_binary(value), do: value

  defp diagnostic_value(value) when is_atom(value), do: %{"atom" => Atom.to_string(value)}
  defp diagnostic_value(value) when is_list(value), do: Enum.map(value, &diagnostic_value/1)

  defp diagnostic_value(value) when is_tuple(value),
    do: %{"tuple" => value |> Tuple.to_list() |> Enum.map(&diagnostic_value/1)}

  defp diagnostic_value(value) when is_map(value) do
    entries =
      value
      |> Enum.map(fn {key, nested} ->
        %{"key" => diagnostic_value(key), "value" => diagnostic_value(nested)}
      end)
      |> Enum.sort_by(fn entry -> JSONValue.deterministic_encode(entry["key"]) end)

    %{"map" => entries}
  end

  defp diagnostic_value(_value), do: %{"opaque" => "unsupported"}
end
