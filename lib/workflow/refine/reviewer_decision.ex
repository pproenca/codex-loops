defmodule Workflow.Refine.ReviewerDecision do
  @moduledoc """
  The normalized outcome of one reviewer in a refine round.

  Journal compatibility is handled at the event boundary. By the time a
  decision reaches this module, its state is the single `outcome` tag.
  """

  alias Workflow.Refine.ReviewerAdapter

  @enforce_keys [:reviewer, :reviewer_index, :adapter, :outcome]
  defstruct @enforce_keys

  @type outcome :: :clear | :approved_with_findings | :rejected | :failed
  @type t :: %__MODULE__{
          reviewer: atom(),
          reviewer_index: non_neg_integer() | nil,
          adapter: ReviewerAdapter.t(),
          outcome: outcome()
        }

  @spec from_payload(map()) :: t()
  def from_payload(%{reviewer: reviewer, reviewer_index: reviewer_index, adapter: adapter, outcome: outcome})
      when outcome in [:clear, :approved_with_findings, :rejected, :failed] do
    %__MODULE__{
      reviewer: reviewer,
      reviewer_index: reviewer_index,
      adapter: adapter,
      outcome: outcome
    }
  end

  @spec to_payload(t()) :: map()
  def to_payload(%__MODULE__{} = decision) do
    %{
      reviewer: decision.reviewer,
      reviewer_index: decision.reviewer_index,
      adapter: decision.adapter,
      outcome: decision.outcome
    }
  end

  @spec approved?(t()) :: boolean()
  def approved?(%__MODULE__{outcome: outcome}), do: outcome in [:clear, :approved_with_findings]

  @spec clear?(t()) :: boolean()
  def clear?(%__MODULE__{outcome: :clear}), do: true
  def clear?(%__MODULE__{}), do: false

  @spec status(t()) :: :completed | :failed
  def status(%__MODULE__{outcome: :failed}), do: :failed
  def status(%__MODULE__{}), do: :completed
end
