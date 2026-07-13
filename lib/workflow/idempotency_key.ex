defmodule Workflow.IdempotencyKey do
  @moduledoc """
  The stable identity of a paid effect: `(run_id, node_path, iteration)`, refined
  by `attempt` to identify one physical provider request.

  A logical effect — one node's output at one loop `iteration` — may require more
  than one *paid* provider call, because a fail-closed schema turn retries on
  invalid output. Those retries are distinct paid calls that must reach the backend
  under distinct keys. `attempt` (the zero-based retry index) therefore keeps
  retries independent. The writer durably records the key before invoking the
  provider and never reissues an attempt whose settlement is missing; that crash
  window terminates as `outcome_unknown`.

  `iteration` is `0` for every node outside a dynamic loop; inside `while_budget` /
  `until_dry` it carries the real per-iteration index, so the same body address keys
  a distinct paid effect each pass. The key format was fixed since the first slice —
  both `iteration` and `attempt` were reserved up front — so populating `iteration`
  now needs no migration.
  """
  @enforce_keys [:run_id, :node_path, :iteration]
  defstruct [:run_id, :node_path, :iteration, attempt: 0]

  @type t :: %__MODULE__{
          run_id: String.t(),
          node_path: Workflow.Node.address(),
          iteration: non_neg_integer(),
          attempt: non_neg_integer()
        }
end
