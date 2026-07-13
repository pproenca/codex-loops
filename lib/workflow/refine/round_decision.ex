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
end
