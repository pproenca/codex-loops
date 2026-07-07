defmodule Workflow.Scheduler.Validation do
  @moduledoc "Successful workflow validation data returned by the scheduler context."

  @enforce_keys [:valid, :workflow_name, :node_count, :script]
  defstruct [:valid, :workflow_name, :node_count, :script]

  @type t :: %__MODULE__{
          valid: true,
          workflow_name: String.t(),
          node_count: non_neg_integer(),
          script: %{path: String.t()}
        }

  @spec from_tree(Workflow.Tree.t(), String.t()) :: t()
  def from_tree(%Workflow.Tree{} = tree, path) do
    %__MODULE__{
      valid: true,
      workflow_name: tree.name,
      node_count: length(tree.nodes),
      script: %{path: path}
    }
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = validation) do
    %{
      valid: validation.valid,
      workflow_name: validation.workflow_name,
      node_count: validation.node_count,
      script: validation.script
    }
  end
end
