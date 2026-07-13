defmodule Workflow.Refine.OpenFinding do
  @moduledoc "A normalized blocking finding returned by a refine reviewer."

  @enforce_keys [:reviewer, :reviewer_index, :id, :issue, :fix]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          reviewer: atom(),
          reviewer_index: non_neg_integer() | nil,
          id: String.t(),
          issue: String.t(),
          fix: String.t()
        }

  @spec from_payload(map()) :: t()
  def from_payload(%{reviewer: reviewer, reviewer_index: reviewer_index, id: id, issue: issue, fix: fix}) do
    %__MODULE__{
      reviewer: reviewer,
      reviewer_index: reviewer_index,
      id: id,
      issue: issue,
      fix: fix
    }
  end

  @spec to_payload(t()) :: map()
  def to_payload(%__MODULE__{} = finding), do: Map.from_struct(finding)
end
