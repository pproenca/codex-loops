defmodule Workflow.Event do
  @moduledoc """
  A single committed journal event: `agent-loops/journal@1`.

  The log is **versioned and additive**. `schema` pins the envelope version;
  `type` is an open discriminator (later slices add new types without breaking the
  fold); `payload` is a plain map. `run_id`/`seq` are stamped by the writer at
  commit time. Events carry no wall-clock — ordering is the monotonic `seq`, which
  keeps the fold deterministic.
  """

  @schema 1

  @enforce_keys [:type, :payload]
  defstruct [:run_id, :seq, :type, :payload, schema: @schema]

  @type t :: %__MODULE__{
          run_id: String.t() | nil,
          seq: non_neg_integer() | nil,
          type: atom(),
          payload: map(),
          schema: pos_integer()
        }

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema

  def run_started(%Workflow.Tree{} = tree) do
    %__MODULE__{
      type: :run_started,
      payload: %{
        tree_name: tree.name,
        tree_version: tree.version,
        node_count: length(tree.nodes)
      }
    }
  end

  def phase_entered(%Workflow.Node.Phase{} = node) do
    %__MODULE__{type: :phase_entered, payload: %{address: node.address, name: node.name}}
  end

  def log_emitted(%Workflow.Node.Log{} = node) do
    %__MODULE__{type: :log_emitted, payload: %{address: node.address, message: node.message}}
  end

  def agent_committed(%Workflow.Node.Agent{} = node, iteration, key, result, usage) do
    %__MODULE__{
      type: :agent_committed,
      payload: %{
        address: node.address,
        iteration: iteration,
        idempotency_key: key,
        prompt: node.prompt,
        result: result,
        usage: usage
      }
    }
  end

  def run_completed(value) do
    %__MODULE__{type: :run_completed, payload: %{value: value}}
  end
end
