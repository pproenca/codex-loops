defmodule Workflow.Refine.Result do
  @moduledoc """
  Public structured projection for completed refine bindings.

  The writer uses this for `emit_result(:binding)`: it folds already-journaled
  refine events into the JSON-encodable shape promised by the DSL, never exposing
  atom-keyed internal payloads directly.
  """

  alias Workflow.{Event, Journal}
  alias Workflow.Provider.Usage

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

  @spec public(map(), [Event.t()], String.t() | nil, Workflow.Node.address() | nil) :: map()
  def public(attrs, events \\ [], run_id \\ nil, address \\ nil) do
    final_round = Map.get(attrs, :final_round)
    final_decision = final_decision(events, address, final_round)
    open_findings = Map.get(attrs, :open_findings, [])
    role_failures = Map.get(attrs, :role_failures, [])
    failed_reviewers = Map.get(attrs, :failed_reviewers, failed_reviewers(role_failures))

    report_snippets =
      Map.get(attrs, :report_snippets, decision_field(final_decision, :report_snippets, []))

    %{
      "artifact" => Map.fetch!(attrs, :artifact),
      "converged" => Map.fetch!(attrs, :converged),
      "rounds" => Map.fetch!(attrs, :rounds),
      "finalRound" => final_round,
      "openFindings" => Enum.map(open_findings, &open_finding_json/1),
      "finalOpenDefects" =>
        Enum.map(open_findings, &open_finding_json/1) ++
          role_failures_as_defects(role_failures),
      "roleFailures" => Enum.map(role_failures, &role_failure_json/1),
      "failedReviewers" => Enum.map(failed_reviewers, &atom_string/1),
      "reviewerDecisions" =>
        attrs
        |> Map.get(:reviewer_decisions, decision_field(final_decision, :reviewer_decisions, []))
        |> Enum.map(&reviewer_decision_json/1),
      "coldRead" => cold_read_json(Map.get(attrs, :cold_read)),
      "reportSnippets" => report_snippets,
      "rawRefs" => %{"journal" => raw_refs(events, run_id, address)}
    }
  end

  defp projection(events, run_id, address, completed),
    do: public(completed.payload, events, run_id, address)

  defp completed_event(events, address) do
    Enum.find(
      events,
      &(&1.type == :refine_completed and Map.get(&1.payload, :address) == address)
    )
  end

  defp final_decision(events, address, final_round) do
    events
    |> Enum.filter(
      &(&1.type == :refine_round_decision and Map.get(&1.payload, :address) == address)
    )
    |> Enum.find(&(Map.get(&1.payload, :round) == final_round))
  end

  defp decision_field(nil, _field, default), do: default

  defp decision_field(%Event{payload: payload}, field, default),
    do: Map.get(payload, field, default)

  defp open_finding_json(finding) do
    %{
      "reviewer" => atom_string(finding.reviewer),
      "reviewerIndex" => finding.reviewer_index,
      "id" => finding.id,
      "issue" => finding.issue,
      "fix" => finding.fix
    }
  end

  defp reviewer_decision_json(decision) do
    %{
      "reviewer" => atom_string(decision.reviewer),
      "reviewerIndex" => decision.reviewer_index,
      "approved" => decision.approved,
      "clear" => decision.clear,
      "adapter" => atom_string(decision.adapter),
      "status" => atom_string(decision.status)
    }
  end

  defp role_failure_json(failure) do
    %{
      "role" => atom_string(failure.role),
      "roleAddress" => failure.role_address,
      "round" => failure.round,
      "reviewer" => maybe_atom_string(failure.reviewer),
      "reviewerIndex" => failure.reviewer_index,
      "attempts" => failure.attempts,
      "reason" => reason_json(failure.reason),
      "detail" => role_failure_detail_json(failure.detail),
      "usage" => usage_json(failure.usage),
      "activity" => Enum.map(failure.activity, &activity_entry_json/1)
    }
  end

  defp cold_read_json(nil), do: nil

  defp cold_read_json(%{state: :completed} = cold_read) do
    %{
      "state" => "completed",
      "openFindings" => Enum.map(Map.get(cold_read, :open_findings, []), &open_finding_json/1),
      "reviewerDecision" => reviewer_decision_json(Map.fetch!(cold_read, :reviewer_decision)),
      "reportSnippets" => Map.get(cold_read, :report_snippets, []),
      "repaired" => Map.get(cold_read, :repaired, false)
    }
  end

  defp cold_read_json(%{state: :failed} = cold_read) do
    %{
      "state" => "failed",
      "roleFailure" => role_failure_json(Map.fetch!(cold_read, :role_failure)),
      "repaired" => Map.get(cold_read, :repaired, false)
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

  defp reason_json({:provider_failure, kind, detail}) do
    %{"code" => "provider_failure", "kind" => atom_string(kind), "detail" => detail}
  end

  defp reason_json({:malformed_output, detail}),
    do: %{"code" => "malformed_output", "detail" => diagnostic_string(detail)}

  defp reason_json({:reviewer_timeout, timeout_ms}),
    do: %{"code" => "reviewer_timeout", "timeoutMs" => timeout_ms}

  defp reason_json({:cold_read_timeout, timeout_ms}),
    do: %{"code" => "cold_read_timeout", "timeoutMs" => timeout_ms}

  defp reason_json({:reviewer_crashed, detail}),
    do: %{"code" => "reviewer_crashed", "detail" => diagnostic_string(detail)}

  defp reason_json({:cold_read_crashed, detail}),
    do: %{"code" => "cold_read_crashed", "detail" => diagnostic_string(detail)}

  defp reason_json({:repair_failed, detail}),
    do: %{"code" => "repair_failed", "detail" => diagnostic_string(detail)}

  defp role_failure_detail_json(nil), do: nil
  defp role_failure_detail_json(detail) when is_binary(detail), do: detail

  defp role_failure_detail_json(detail) do
    if json_value?(detail), do: detail, else: diagnostic_string(detail)
  end

  defp usage_json(nil), do: nil

  defp usage_json(%Usage{} = usage) do
    %{
      "inputTokens" => usage.input_tokens,
      "outputTokens" => usage.output_tokens,
      "totalTokens" => usage.total_tokens
    }
  end

  defp activity_entry_json(entry) when is_map(entry) do
    Map.new(entry, fn {key, value} -> {activity_key(key), activity_value(value)} end)
  end

  defp activity_key(key) when is_atom(key), do: Atom.to_string(key)
  defp activity_key(key) when is_binary(key), do: key
  defp activity_key(key), do: diagnostic_string(key)

  defp activity_value(value) when is_map(value), do: activity_entry_json(value)
  defp activity_value(value) when is_list(value), do: Enum.map(value, &activity_value/1)
  defp activity_value(value) when is_atom(value), do: Atom.to_string(value)
  defp activity_value(value), do: value

  defp raw_refs(events, run_id, address) do
    events
    |> Enum.filter(&refine_result_ref?(&1, address))
    |> Enum.sort_by(& &1.seq)
    |> Enum.map(fn event ->
      %{
        "runId" => event.run_id || run_id,
        "seq" => event.seq,
        "type" => Atom.to_string(event.type),
        "address" => Map.get(event.payload, :address)
      }
    end)
  end

  defp refine_result_ref?(%Event{payload: %{address: address}, type: type}, address)
       when type in [
              :refine_completed,
              :refine_non_converged,
              :refine_round_decision,
              :refine_role_failed,
              :refine_gate_evaluated
            ],
       do: true

  defp refine_result_ref?(%Event{payload: %{address: role_address}, type: type}, address)
       when type in [:agent_activity, :agent_committed, :agent_attempt_rejected, :agent_failed],
       do: role_address in [address ++ [3], address ++ [4]]

  defp refine_result_ref?(%Event{}, _address), do: false

  defp failed_reviewers(role_failures) do
    role_failures
    |> Enum.map(& &1.reviewer)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp address_path(address), do: "/" <> Enum.map_join(address, "/", &Integer.to_string/1)

  defp render_json_detail(nil), do: ""
  defp render_json_detail(detail) when is_binary(detail), do: detail
  defp render_json_detail(detail), do: deterministic_json_encode(detail)

  defp diagnostic_string(term), do: term |> diagnostic_value() |> deterministic_json_encode()

  defp diagnostic_value(value)
       when is_nil(value) or is_boolean(value) or is_integer(value) or is_binary(value),
       do: value

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
      |> Enum.sort_by(fn entry -> deterministic_json_encode(entry["key"]) end)

    %{"map" => entries}
  end

  defp diagnostic_value(_value), do: %{"opaque" => "unsupported"}

  defp deterministic_json_encode(nil), do: "null"
  defp deterministic_json_encode(true), do: "true"
  defp deterministic_json_encode(false), do: "false"
  defp deterministic_json_encode(value) when is_integer(value), do: Integer.to_string(value)
  defp deterministic_json_encode(value) when is_binary(value), do: Jason.encode!(value)

  defp deterministic_json_encode(value) when is_list(value) do
    "[" <> (value |> Enum.map(&deterministic_json_encode/1) |> Enum.join(",")) <> "]"
  end

  defp deterministic_json_encode(value) when is_map(value) do
    encoded =
      value
      |> Enum.sort_by(fn {key, _nested} -> key end)
      |> Enum.map(fn {key, nested} ->
        deterministic_json_encode(key) <> ":" <> deterministic_json_encode(nested)
      end)
      |> Enum.join(",")

    "{" <> encoded <> "}"
  end

  defp json_value?(value) when is_nil(value) or is_boolean(value), do: true
  defp json_value?(value) when is_integer(value) or is_binary(value), do: true
  defp json_value?(value) when is_list(value), do: Enum.all?(value, &json_value?/1)

  defp json_value?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested} -> is_binary(key) and json_value?(nested) end)
  end

  defp json_value?(_value), do: false

  defp atom_string(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_string(value) when is_binary(value), do: value

  defp maybe_atom_string(nil), do: nil
  defp maybe_atom_string(value), do: atom_string(value)
end
