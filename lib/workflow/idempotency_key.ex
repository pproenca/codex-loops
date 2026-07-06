defmodule Workflow.IdempotencyKey do
  @moduledoc """
  The exactly-once key for a paid effect: `(run_id, node_path, iteration)`, refined
  by `attempt` to identify a single physical provider request.

  A logical effect — one node's output at one loop `iteration` — may require more
  than one *paid* provider call, because a fail-closed schema turn retries on
  invalid output. Those retries are distinct paid calls that must reach the backend
  under distinct request-idempotency keys, or a deduping backend would replay the
  first (rejected) response for every retry and the turn could never succeed. So
  `attempt` (the zero-based retry index) is part of the key handed to the provider,
  keeping retries independent while still deduping the *same* attempt re-issued
  after a lost commit.

  `iteration` is always `0` until loops exist (a later slice); both `iteration` and
  `attempt` are present now so the event log never needs a migration to gain them.
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
