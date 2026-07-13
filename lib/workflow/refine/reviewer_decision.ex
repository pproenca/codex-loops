defmodule Workflow.Refine.ReviewerDecision do
  @moduledoc "The normalized outcome of one reviewer in a refine round."

  alias Workflow.Refine.ReviewerAdapter

  @enforce_keys [:reviewer, :reviewer_index, :approved, :clear, :adapter, :status]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          reviewer: atom(),
          reviewer_index: non_neg_integer() | nil,
          approved: boolean(),
          clear: boolean(),
          adapter: ReviewerAdapter.t(),
          status: :completed | :failed
        }

  @spec from_payload(t() | map()) :: t()
  def from_payload(%__MODULE__{} = decision), do: decision

  def from_payload(%{
        reviewer: reviewer,
        reviewer_index: reviewer_index,
        approved: approved,
        clear: clear,
        adapter: adapter,
        status: status
      }) do
    %__MODULE__{
      reviewer: reviewer,
      reviewer_index: reviewer_index,
      approved: approved,
      clear: clear,
      adapter: adapter,
      status: status
    }
  end

  @spec to_payload(t()) :: map()
  def to_payload(%__MODULE__{} = decision), do: Map.from_struct(decision)
end
