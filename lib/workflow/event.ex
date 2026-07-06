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

  @doc """
  The run's start marker. `budget` is the per-run token target the ledger folds
  against, or `nil` for an unbounded run. Recording it here (not in process state)
  keeps the ledger a pure fold and survives resume: the target is read back from
  this journaled event rather than re-supplied.
  """
  def run_started(%Workflow.Tree{} = tree, budget \\ nil) do
    %__MODULE__{
      type: :run_started,
      payload: %{
        tree_name: tree.name,
        tree_version: tree.version,
        node_count: length(tree.nodes),
        budget: budget
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

  @doc """
  A single fail-closed attempt whose output did not conform to the schema. Records
  the rejected output and the validator's reason so replay reconstructs every retry
  decision; the paid `usage` is still ledgered.
  """
  def agent_attempt_rejected(%Workflow.Node.Agent{} = node, iteration, attempt, output, reason, usage) do
    %__MODULE__{
      type: :agent_attempt_rejected,
      payload: %{
        address: node.address,
        iteration: iteration,
        attempt: attempt,
        prompt: node.prompt,
        output: output,
        reason: reason,
        usage: usage
      }
    }
  end

  @doc """
  Terminal node failure after the retry budget is exhausted (exit-8 / malformed
  structured output). This is the run's terminal event on the fail path — there is
  no `run_completed`.
  """
  def agent_failed(%Workflow.Node.Agent{} = node, iteration, attempts, reason) do
    %__MODULE__{
      type: :agent_failed,
      payload: %{
        address: node.address,
        iteration: iteration,
        attempts: attempts,
        reason: reason
      }
    }
  end

  def run_completed(value) do
    %__MODULE__{type: :run_completed, payload: %{value: value}}
  end
end
