defmodule Workflow.Node do
  @moduledoc """
  The closed combinator vocabulary of the workflow DSL, one inert struct per
  combinator. Every node carries a stable `:address` — a path (list of integers)
  from the tree root — that never changes across schema versions, so journal
  events and idempotency keys can reference nodes by address forever.

  Later slices extend this vocabulary additively; they must not renumber or
  reshape existing addresses.
  """

  @type address :: [non_neg_integer()]
end

defmodule Workflow.Node.Phase do
  @moduledoc "Marks entry into a named phase. Pure structural marker; no effects."
  @enforce_keys [:address, :name]
  defstruct [:address, :name]

  @type t :: %__MODULE__{address: Workflow.Node.address(), name: String.t()}
end

defmodule Workflow.Node.Log do
  @moduledoc "Emits a static log line into the journal. No wall-clock, no interpolation."
  @enforce_keys [:address, :message]
  defstruct [:address, :message]

  @type t :: %__MODULE__{address: Workflow.Node.address(), message: String.t()}
end

defmodule Workflow.Node.Agent do
  @moduledoc """
  An agent turn. The prompt is a static literal; execution is a paid effect keyed
  for exactly-once by `(run_id, address, iteration)`.

  `schema` is an inert, raw JSON-schema **map literal** (or `nil` for a schemaless
  turn). When present the turn is **fail-closed**: the provider's output is
  validated against the schema, invalid output is retried on-thread up to
  `retries` times, and exhausting the budget fails the node. `schema`/`retries`
  are compile-time constants materialized from literals, so the node stays inert
  and serializable — no closure is ever captured.
  """
  @enforce_keys [:address, :prompt]
  defstruct [:address, :prompt, schema: nil, retries: 2]

  @type t :: %__MODULE__{
          address: Workflow.Node.address(),
          prompt: String.t(),
          schema: map() | nil,
          retries: non_neg_integer()
        }
end

defmodule Workflow.Node.Return do
  @moduledoc "Completes the run with a literal value. Value is a compile-time constant."
  @enforce_keys [:address, :value]
  defstruct [:address, :value]

  @type t :: %__MODULE__{address: Workflow.Node.address(), value: term()}
end
