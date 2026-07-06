defmodule Workflow.IdempotencyKey do
  @moduledoc """
  The exactly-once key for a paid effect: `(run_id, node_path, iteration)`.

  `iteration` is always `0` until loops exist (a later slice); the field is present
  now so the event log never needs a migration to gain it.
  """
  @enforce_keys [:run_id, :node_path, :iteration]
  defstruct [:run_id, :node_path, :iteration]

  @type t :: %__MODULE__{
          run_id: String.t(),
          node_path: Workflow.Node.address(),
          iteration: non_neg_integer()
        }
end
