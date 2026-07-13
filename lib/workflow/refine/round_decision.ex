defmodule Workflow.Refine.RoundDecision do
  @moduledoc "The normalized result of one complete refine reviewer round."

  alias Workflow.Refine.OpenFinding
  alias Workflow.Refine.ReviewerDecision
  alias Workflow.Refine.RoleFailure

  @enforce_keys [
    :consensus,
    :approval_count,
    :total,
    :reviewer_decisions,
    :artifact,
    :open_findings,
    :role_failures,
    :failed_reviewers,
    :report_snippets
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          consensus: boolean(),
          approval_count: non_neg_integer(),
          total: non_neg_integer(),
          reviewer_decisions: [ReviewerDecision.t()],
          artifact: String.t(),
          open_findings: [OpenFinding.t()],
          role_failures: [RoleFailure.t()],
          failed_reviewers: [atom()],
          report_snippets: [String.t()]
        }

  @spec from_payload(t() | map()) :: t()
  def from_payload(%__MODULE__{} = decision), do: decision

  def from_payload(payload) when is_map(payload) do
    role_failures = Enum.map(Map.get(payload, :role_failures, []), &RoleFailure.from_payload/1)

    %__MODULE__{
      consensus: Map.fetch!(payload, :consensus),
      approval_count: Map.fetch!(payload, :approval_count),
      total: Map.fetch!(payload, :total),
      reviewer_decisions:
        payload
        |> Map.get(:reviewer_decisions, [])
        |> Enum.map(&ReviewerDecision.from_payload/1),
      artifact: Map.fetch!(payload, :artifact),
      open_findings:
        payload
        |> Map.get(:open_findings, [])
        |> Enum.map(&OpenFinding.from_payload/1),
      role_failures: role_failures,
      failed_reviewers: Map.get(payload, :failed_reviewers, failed_reviewers(role_failures)),
      report_snippets: Map.get(payload, :report_snippets, [])
    }
  end

  @spec to_payload(t()) :: map()
  def to_payload(%__MODULE__{} = decision) do
    %{
      consensus: decision.consensus,
      approval_count: decision.approval_count,
      total: decision.total,
      reviewer_decisions: Enum.map(decision.reviewer_decisions, &ReviewerDecision.to_payload/1),
      artifact: decision.artifact,
      open_findings: Enum.map(decision.open_findings, &OpenFinding.to_payload/1),
      role_failures: Enum.map(decision.role_failures, &RoleFailure.to_payload/1),
      failed_reviewers: decision.failed_reviewers,
      report_snippets: decision.report_snippets
    }
  end

  defp failed_reviewers(role_failures) do
    role_failures
    |> Enum.map(& &1.reviewer)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end
end
