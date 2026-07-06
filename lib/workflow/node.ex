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

defmodule Workflow.Node.Parallel do
  @moduledoc """
  Static barrier fan-out: run every branch **concurrently** under a bounded
  concurrency cap, then join (barrier) before the run continues. Each branch is one
  inert `%Workflow.Node.Agent{}` with its own stable address `parent ++ [branch]`,
  so every branch's paid turn is journaled and keyed for exactly-once independently.

  Fan-out width is bounded by the branch list — a compile-time constant — so there
  is no unbounded or linked task explosion. `max_concurrency` may cap it further;
  `nil` means "all branches at once" (still bounded by the static width).
  """
  @enforce_keys [:address, :branches]
  defstruct [:address, :branches, max_concurrency: nil]

  @type t :: %__MODULE__{
          address: Workflow.Node.address(),
          branches: [Workflow.Node.Agent.t()],
          max_concurrency: pos_integer() | nil
        }
end

defmodule Workflow.Node.Pipeline do
  @moduledoc """
  Static per-item fan-out: run each `item` through the ordered `stages`
  independently. Item lanes run **concurrently** under the cap, and within a lane
  the stages run **sequentially** — there is no cross-item barrier, so stage `k` of
  one item never waits on stage `k` of another (the distinction from `parallel`).

  The lanes are fully expanded at compile time into inert, pre-addressed agents:
  `lanes[i]` is item `i`'s ordered `[%Agent{}]`, each stage at the stable address
  `parent ++ [item_index, stage_index]`. `items` is retained (a literal list) so the
  journal records which item each lane processed. Everything is serialisable data —
  no closure, no runtime expansion. Fan-out width is `length(items)`, a compile-time
  constant, so the fan-out stays bounded.
  """
  @enforce_keys [:address, :items, :lanes]
  defstruct [:address, :items, :lanes, max_concurrency: nil]

  @type t :: %__MODULE__{
          address: Workflow.Node.address(),
          items: [term()],
          lanes: [[Workflow.Node.Agent.t()]],
          max_concurrency: pos_integer() | nil
        }
end

defmodule Workflow.Node.Collect do
  @moduledoc """
  A **declared reduction**: fold the current loop iteration's most recent agent
  result into a named accumulator. `into` names the accumulator; the dedup field
  list (`seen_by`) comes from the enclosing loop, not the author — so the
  accumulator is owned and rebuilt by the runtime from the journal, never
  author-managed mutable state.

  `collect` is only meaningful inside a loop body (it needs an iteration and a
  harvest), so the compiler rejects it at top level. Each execution journals an
  `accumulate` event carrying the deduped items it added, so replaying the journal
  rebuilds the accumulator exactly.
  """
  @enforce_keys [:address, :into]
  defstruct [:address, :into]

  @type t :: %__MODULE__{address: Workflow.Node.address(), into: atom()}
end

defmodule Workflow.Node.WhileBudget do
  @moduledoc """
  A dynamic loop that runs its `body` once per iteration **while the budget
  ledger's `remaining` exceeds `reserve`** (and, optionally, while an `until`
  predicate stays false). Because every paid turn only lowers `remaining`
  (monotonically non-increasing), the loop **provably terminates**: it stops once
  `remaining <= reserve`. `max_iterations` is a structural safety bound that
  guarantees termination even for a body that spends nothing.

  The body is an inert list of nodes addressed `parent ++ [i]`; each iteration
  re-runs those addresses under a distinct `iteration`, which is the real
  per-iteration component of the exactly-once key. Every control-flow decision is
  journaled (`loop_decision`), so a resume **replays** the decision rather than
  recomputing it from a ledger fold that reflects the whole run instead of the
  historical decision point.
  """
  @enforce_keys [:address, :reserve, :body, :max_iterations]
  defstruct [:address, :reserve, :body, :max_iterations, until: nil]

  @type t :: %__MODULE__{
          address: Workflow.Node.address(),
          reserve: non_neg_integer(),
          until: struct() | nil,
          body: [struct()],
          max_iterations: pos_integer()
        }
end

defmodule Workflow.Node.UntilDry do
  @moduledoc """
  A dynamic loop that runs its `body` until **`rounds` consecutive iterations add
  nothing new** to their accumulators, deduping by the `seen_by` field list. A
  round is "dry" when its `collect`s added zero new items; `rounds` consecutive dry
  iterations stop the loop. `max_iterations` bounds it structurally so it
  terminates even if the body never goes dry.

  `seen_by` is a **field list, never a closure**, so the compiler sees it and the
  node stays inert and serializable. Dryness is derived by folding the journaled
  `accumulate` events — never from re-inspecting non-deterministic agent output —
  and each `loop_decision` is journaled so resume replays it.
  """
  @enforce_keys [:address, :rounds, :seen_by, :body, :max_iterations]
  defstruct [:address, :rounds, :seen_by, :body, :max_iterations]

  @type t :: %__MODULE__{
          address: Workflow.Node.address(),
          rounds: pos_integer(),
          seen_by: [atom()],
          body: [struct()],
          max_iterations: pos_integer()
        }
end
