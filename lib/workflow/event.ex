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
  def agent_attempt_rejected(
        %Workflow.Node.Agent{} = node,
        iteration,
        attempt,
        output,
        reason,
        usage
      ) do
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

  @doc """
  Barrier fan-out markers. `parallel_started` records the branch count so a fold can
  see the fan-out width; `parallel_completed` marks the barrier join. Each branch's
  own paid turn is journaled as an ordinary `agent_*` event at its branch address,
  so these markers carry no results — they only bracket the concurrent region.
  """
  def parallel_started(%Workflow.Node.Parallel{} = node) do
    %__MODULE__{
      type: :parallel_started,
      payload: %{address: node.address, branch_count: length(node.branches)}
    }
  end

  def parallel_completed(%Workflow.Node.Parallel{} = node) do
    %__MODULE__{type: :parallel_completed, payload: %{address: node.address}}
  end

  @doc """
  Per-item fan-out markers. `pipeline_started` records the concrete `items` and the
  stage count; `pipeline_completed` marks the join. Each item lane's stage turns are
  journaled as ordinary `agent_*` events at their `[item, stage]` addresses.
  """
  def pipeline_started(%Workflow.Node.Pipeline{} = node) do
    stage_count = node.lanes |> List.first([]) |> length()

    %__MODULE__{
      type: :pipeline_started,
      payload: %{
        address: node.address,
        items: node.items,
        item_count: length(node.items),
        stage_count: stage_count
      }
    }
  end

  def pipeline_completed(%Workflow.Node.Pipeline{} = node) do
    %__MODULE__{type: :pipeline_completed, payload: %{address: node.address}}
  end

  @doc """
  Loop control-flow markers and the declared-reduction event. **Control-flow
  decisions are journaled**, so a resume replays them rather than recomputing them
  from a ledger/accumulator fold that reflects the whole run instead of the
  historical decision point.

    * `iteration_started` — enters loop iteration `n` at the loop's address.
    * `loop_decision` — the journaled `:continue`/`:stop` decision for iteration `n`.
    * `loop_completed` — the loop's terminal bracket, recording how many iterations ran.
    * `accumulate` — one `collect`'s reduction: the exact deduped items `added` to
      `into` this iteration, plus the resulting accumulator `size`. Folding these
      rebuilds every accumulator exactly on resume.
  """
  def iteration_started(loop, iteration) do
    %__MODULE__{type: :iteration_started, payload: %{address: loop.address, iteration: iteration}}
  end

  def loop_decision(loop, iteration, decision) when decision in [:continue, :stop] do
    %__MODULE__{
      type: :loop_decision,
      payload: %{address: loop.address, iteration: iteration, decision: decision}
    }
  end

  def loop_completed(loop, iterations) do
    %__MODULE__{type: :loop_completed, payload: %{address: loop.address, iterations: iterations}}
  end

  def accumulate(%Workflow.Node.Collect{} = node, iteration, seen_by, added, size) do
    %__MODULE__{
      type: :accumulate,
      payload: %{
        address: node.address,
        into: node.into,
        iteration: iteration,
        seen_by: seen_by,
        added: added,
        size: size
      }
    }
  end

  def run_completed(value) do
    %__MODULE__{type: :run_completed, payload: %{value: value}}
  end
end
