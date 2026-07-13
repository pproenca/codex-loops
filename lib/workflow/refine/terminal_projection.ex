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
end
