defmodule Workflow.Scheduler.Validation do
  @moduledoc "Successful workflow validation data returned by the scheduler context."

  alias Workflow.PlanIdentity
  alias Workflow.Schema

  @enforce_keys [
    :valid,
    :workflow_name,
    :node_count,
    :script,
    :input_schema,
    :tree_fingerprint,
    :arguments_validated
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          valid: true,
          workflow_name: String.t(),
          node_count: non_neg_integer(),
          script: %{path: String.t()},
          input_schema: map() | nil,
          tree_fingerprint: String.t(),
          arguments_validated: boolean()
        }

  @spec from_tree(Workflow.Tree.t(), String.t(), keyword()) :: t()
  def from_tree(%Workflow.Tree{} = tree, path, opts \\ []) do
    %__MODULE__{
      valid: true,
      workflow_name: tree.name,
      node_count: length(tree.nodes),
      script: %{path: path},
      input_schema: input_schema(tree.input_schema),
      tree_fingerprint: PlanIdentity.fingerprint(tree),
      arguments_validated: Keyword.get(opts, :arguments_validated, false)
    }
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = validation) do
    %{
      valid: validation.valid,
      workflow_name: validation.workflow_name,
      node_count: validation.node_count,
      script: validation.script,
      input_schema: validation.input_schema,
      tree_fingerprint: validation.tree_fingerprint,
      arguments_validated: validation.arguments_validated
    }
  end

  defp input_schema(nil), do: nil
  defp input_schema(schema), do: Schema.to_map(schema)
end
