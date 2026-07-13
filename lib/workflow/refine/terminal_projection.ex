defmodule Workflow.Refine.TerminalProjection do
  @moduledoc "The in-memory terminal projection passed through refine gates."

  alias Workflow.Refine.ColdRead
  alias Workflow.Refine.OpenFinding
  alias Workflow.Refine.ReviewerDecision
  alias Workflow.Refine.RoleFailure
  alias Workflow.Refine.RoundDecision

  @enforce_keys [
    :converged,
    :final_round,
    :rounds,
    :artifact,
    :open_findings,
    :role_failures,
    :failed_reviewers,
    :reviewer_decisions,
    :report_snippets,
    :cold_read
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          converged: boolean(),
          final_round: non_neg_integer(),
          rounds: pos_integer(),
          artifact: String.t(),
          open_findings: [OpenFinding.t()],
          role_failures: [RoleFailure.t()],
          failed_reviewers: [atom()],
          reviewer_decisions: [ReviewerDecision.t()],
          report_snippets: [String.t()],
          cold_read: ColdRead.t() | nil
        }

  @spec new(boolean(), non_neg_integer(), String.t(), RoundDecision.t()) :: t()
  def new(converged, round, artifact, %RoundDecision{} = decision) when is_boolean(converged) do
    %__MODULE__{
      converged: converged,
      final_round: round,
      rounds: round + 1,
      artifact: artifact,
      open_findings: decision.open_findings,
      role_failures: decision.role_failures,
      failed_reviewers: decision.failed_reviewers,
      reviewer_decisions: decision.reviewer_decisions,
      report_snippets: decision.report_snippets,
      cold_read: nil
    }
  end

  @spec from_payload(t() | map()) :: t()
  def from_payload(%__MODULE__{} = projection), do: projection

  def from_payload(payload) when is_map(payload) do
    role_failures = Enum.map(Map.get(payload, :role_failures, []), &RoleFailure.from_payload/1)

    %__MODULE__{
      converged: Map.fetch!(payload, :converged),
      final_round: Map.fetch!(payload, :final_round),
      rounds: Map.fetch!(payload, :rounds),
      artifact: Map.fetch!(payload, :artifact),
      open_findings: payload |> Map.get(:open_findings, []) |> Enum.map(&OpenFinding.from_payload/1),
      role_failures: role_failures,
      failed_reviewers: Map.get(payload, :failed_reviewers, failed_reviewers(role_failures)),
      reviewer_decisions:
        payload
        |> Map.get(:reviewer_decisions, [])
        |> Enum.map(&ReviewerDecision.from_payload/1),
      report_snippets: Map.get(payload, :report_snippets, []),
      cold_read: normalize_cold_read(Map.get(payload, :cold_read))
    }
  end

  @spec to_payload(t()) :: map()
  def to_payload(%__MODULE__{} = projection) do
    %{
      converged: projection.converged,
      final_round: projection.final_round,
      rounds: projection.rounds,
      artifact: projection.artifact,
      open_findings: Enum.map(projection.open_findings, &OpenFinding.to_payload/1),
      role_failures: Enum.map(projection.role_failures, &RoleFailure.to_payload/1),
      failed_reviewers: projection.failed_reviewers,
      reviewer_decisions: Enum.map(projection.reviewer_decisions, &ReviewerDecision.to_payload/1),
      report_snippets: projection.report_snippets,
      cold_read: serialize_cold_read(projection.cold_read)
    }
  end

  defp normalize_cold_read(nil), do: nil
  defp normalize_cold_read(cold_read), do: ColdRead.from_payload(cold_read)

  defp serialize_cold_read(nil), do: nil
  defp serialize_cold_read(cold_read), do: ColdRead.to_payload(cold_read)

  defp failed_reviewers(role_failures) do
    role_failures
    |> Enum.map(& &1.reviewer)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end
end
