defmodule Workflow.Refine.Reviewer do
  @moduledoc """
  A compiled reviewer role in a refine node.

  The compiler constructs this value once. Runtime code may replace its embedded
  agent prompt for a particular round, but the reviewer identity, adapter, and
  stable agent address remain fixed.
  """

  alias Workflow.Node.Agent
  alias Workflow.Refine.ReviewerAdapter

  @enforce_keys [:index, :name, :prompt, :adapter, :agent]
  defstruct [:index, :name, :prompt, :adapter, :agent]

  @type t :: %__MODULE__{
          index: non_neg_integer() | nil,
          name: atom(),
          prompt: String.t(),
          adapter: ReviewerAdapter.t(),
          agent: Agent.t()
        }
end
