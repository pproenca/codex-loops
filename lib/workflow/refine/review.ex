defmodule Workflow.Refine.ReviewFinding do
  @moduledoc "One normalized finding from a refine reviewer."

  @enforce_keys [:id, :blocking, :issue, :fix]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: String.t(),
          blocking: boolean(),
          issue: String.t(),
          fix: String.t()
        }

  @spec from_payload(t() | map()) :: t()
  def from_payload(%__MODULE__{} = finding), do: finding

  def from_payload(%{"id" => id, "blocking" => blocking, "issue" => issue, "fix" => fix}) do
    %__MODULE__{id: id, blocking: blocking, issue: issue, fix: fix}
  end

  @spec to_payload(t()) :: map()
  def to_payload(%__MODULE__{} = finding) do
    %{
      "id" => finding.id,
      "blocking" => finding.blocking,
      "issue" => finding.issue,
      "fix" => finding.fix
    }
  end
end

defmodule Workflow.Refine.Review do
  @moduledoc """
  One reviewer response after the provider boundary.

  Provider-specific raw maps become this type exactly once in
  `Workflow.Refine.ReviewerAdapter`. `from_payload/1` is only for canonical maps
  read back from the journal; `to_payload/1` preserves that durable map shape.
  """

  alias Workflow.Refine.ReviewFinding

  @enforce_keys [:approved, :findings, :report_snippets]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          approved: boolean(),
          findings: [ReviewFinding.t()],
          report_snippets: [String.t()]
        }

  @spec from_payload(t() | map()) :: t()
  def from_payload(%__MODULE__{} = review), do: review

  def from_payload(%{"approved" => approved, "findings" => findings} = payload) do
    %__MODULE__{
      approved: approved,
      findings: Enum.map(findings, &ReviewFinding.from_payload/1),
      report_snippets: Map.get(payload, "report_snippets", [])
    }
  end

  @spec to_payload(t()) :: map()
  def to_payload(%__MODULE__{} = review) do
    %{
      "approved" => review.approved,
      "findings" => Enum.map(review.findings, &ReviewFinding.to_payload/1),
      "report_snippets" => review.report_snippets
    }
  end
end
