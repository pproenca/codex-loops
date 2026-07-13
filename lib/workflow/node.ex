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
  @type fanout_scope :: :global | {:loop_local, address()}
  @type binding_ref ::
          {:node, address()}
          | {:map, address()}
          | {:refine, address()}
          | {:fanout, address(), fanout_scope()}
end

defmodule Workflow.Node.Emit do
  @moduledoc """
  Completes the run by rendering a `~P` template over journal-bound values.

  Rendering is pure and closure-free: `template` is inert data, `bindings` map
  compile-time names to stable journal references, and execution reuses
  `Workflow.RenderText` without introducing a paid effect or new event type.
  """
  @enforce_keys [:address, :template, :bindings]
  defstruct [:address, :template, :bindings]

  @type t :: %__MODULE__{
          address: Workflow.Node.address(),
          template: Workflow.Template.t(),
          bindings: %{atom() => Workflow.Node.binding_ref()}
        }
end

defmodule Workflow.Node.EmitResult do
  @moduledoc """
  Completes the run with a structured public result projection for a result-capable
  binding. This is intentionally distinct from `Emit`, which renders text.
  """
  @enforce_keys [:address, :binding, :ref]
  defstruct [:address, :binding, :ref]

  @type t :: %__MODULE__{
          address: Workflow.Node.address(),
          binding: atom(),
          ref: Workflow.Node.binding_ref()
        }
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
  An agent turn. The prompt is either a static literal or an inert `~P` template
  over earlier journal bindings; execution materializes any template to a string
  before the paid effect. The stable `(run_id, address, iteration, attempt)` key is
  journaled before dispatch so that attempt is never redelivered.

  `schema` is an inert typed JSON-schema variant (or `nil` for a schemaless turn),
  normalized from a literal map at the compiler boundary. When present the turn is
  **fail-closed**:
  the provider's output is validated against the schema, invalid output is retried
  on-thread up to `retries` times, and exhausting the budget fails the node.
  `schema`/`retries` are author-time constants, so the node stays inert and
  serializable — no closure is ever captured.
  """
  @enforce_keys [:address, :prompt]
  defstruct [:address, :prompt, :label, bindings: %{}, schema: nil, retries: 2]

  @type t :: %__MODULE__{
          address: Workflow.Node.address(),
          prompt: String.t() | Workflow.Template.t(),
          label: String.t() | nil,
          bindings: %{atom() => Workflow.Node.binding_ref()},
          schema: Workflow.Schema.t() | nil,
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
  so every branch's paid attempt is journaled and delivered at most once independently.

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

defmodule Workflow.Node.Loop do
  @moduledoc """
  The generic bounded loop core. It runs `body` repeatedly until a header predicate
  or body-local `%Workflow.Node.Until{}` stops it, or until `max_iterations` is
  exhausted under the declared `on_exhausted` policy.
  """
  @enforce_keys [:address, :body, :max_iterations]
  defstruct [:address, :body, :max_iterations, until: nil, on_exhausted: :stop]

  @type t :: %__MODULE__{
          address: Workflow.Node.address(),
          until: struct() | nil,
          body: [struct()],
          max_iterations: pos_integer(),
          on_exhausted: :stop | :fail | :accept_current
        }
end

defmodule Workflow.Node.Until do
  @moduledoc """
  Body-local loop stop. The predicate is evaluated at this node's source address;
  when true it stops the enclosing loop and skips later body nodes for that
  iteration.
  """
  @enforce_keys [:address, :predicate]
  defstruct [:address, :predicate]

  @type t :: %__MODULE__{address: Workflow.Node.address(), predicate: struct()}
end

defmodule Workflow.Node.Verify do
  @moduledoc """
  Higher-order verification: submit a `subject` (a literal finding) to a bounded
  panel of independent voters and let it **survive only when `threshold` of them
  confirm**. The panel comes in two flavours, both fixed at author time so the
  fan-out width is a compile-time constant:

    * `voters: N` — `N` identical votes (redundant, majority-style confirmation).
    * `lenses: [:correctness, :security, ...]` — one vote per perspective
      (adversarial / perspective-diverse verification).

  Each voter is pre-expanded into an inert, fail-closed `%Workflow.Node.Agent{}`
  with its own stable address `parent ++ [voter]`, schema-bound to a boolean
  `verdict`, so every vote is journaled and delivered at most once independently.
  Survival is a **pure fold** over the journaled verdicts against `threshold`
  (`:majority` | `:unanimous` | `:any` | a positive integer count) — never process
  state — so a resume replays the settled outcome.
  """
  @enforce_keys [:address, :subject, :mode, :voters, :threshold]
  defstruct [:address, :subject, :mode, :voters, :threshold]

  @type mode :: {:voters, pos_integer()} | {:lenses, [atom()]}

  @type t :: %__MODULE__{
          address: Workflow.Node.address(),
          subject: term(),
          mode: mode(),
          voters: [Workflow.Node.Agent.t()],
          threshold: :majority | :unanimous | :any | pos_integer()
        }
end

defmodule Workflow.Node.Refine.ColdReadGate do
  @moduledoc "A typed final cold-read gate for a refine node."

  @enforce_keys [:predicate, :reviewer]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          predicate: Workflow.Refine.Gate.predicate(),
          reviewer: Workflow.Refine.Reviewer.t()
        }
end

defmodule Workflow.Node.Refine.RepairGate do
  @moduledoc "A typed conditional repair gate for a refine node."

  @enforce_keys [:predicate, :agent]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          predicate: Workflow.Refine.Gate.predicate(),
          agent: Workflow.Node.Agent.t()
        }
end

defmodule Workflow.Node.Refine.HaltGate do
  @moduledoc "A typed terminal halt gate for a refine node."

  @enforce_keys [:predicate]
  defstruct @enforce_keys

  @type t :: %__MODULE__{predicate: Workflow.Refine.Gate.predicate()}
end

defmodule Workflow.Node.Refine.Gates do
  @moduledoc "The fixed collection of optional gates attached to a refine node."

  defstruct cold_read: nil, repair: nil, halt: nil

  @type t(cold_read, repair, halt) :: %__MODULE__{
          cold_read: cold_read | nil,
          repair: repair | nil,
          halt: halt | nil
        }

  @type t ::
          t(
            Workflow.Node.Refine.ColdReadGate.t(),
            Workflow.Node.Refine.RepairGate.t(),
            Workflow.Node.Refine.HaltGate.t()
          )
end

defmodule Workflow.Node.Refine do
  @moduledoc """
  Bounded adversarial refinement. V1 is intentionally narrow: an inline producer
  or a bound value supplies an artifact, a static reviewer panel checks it, a
  reviser handles blocking findings, and a terminal refine event commits or
  fails the result.
  """
  alias Workflow.Node.Refine.ColdReadGate
  alias Workflow.Node.Refine.Gates
  alias Workflow.Node.Refine.HaltGate
  alias Workflow.Node.Refine.RepairGate
  alias Workflow.Refine.Reviewer

  @enforce_keys [:address, :input, :reviewers, :reviser, :until, :max_rounds]
  defstruct [
    :address,
    :input,
    :reviewers,
    :reviser,
    :until,
    :max_rounds,
    on_non_convergence: :fail,
    max_concurrency: nil,
    reviewer_timeout_ms: nil,
    gates: %Gates{}
  ]

  @type t :: %__MODULE__{
          address: Workflow.Node.address(),
          input:
            {:producer, Workflow.Node.Agent.t()}
            | {:binding, atom(), Workflow.Node.binding_ref()},
          reviewers: [Reviewer.t()],
          reviser: Workflow.Node.Agent.t(),
          until: :unanimous,
          max_rounds: pos_integer(),
          on_non_convergence: :fail | :accept_current,
          max_concurrency: pos_integer() | nil,
          reviewer_timeout_ms: pos_integer() | nil,
          gates: Gates.t(ColdReadGate.t(), RepairGate.t(), HaltGate.t())
        }
end

defmodule Workflow.Node.Judge do
  @moduledoc """
  A judge panel: score each of a fixed list of `candidates` along the `by`
  criteria and `pick` a winner. The scoring grid is fully expanded at compile time
  into inert, pre-addressed agents — `scorers[c]` is candidate `c`'s ordered list
  of one fail-closed `%Workflow.Node.Agent{}` per criterion, each at the stable
  address `parent ++ [candidate, criterion]` and schema-bound to a numeric `score`.

  Fan-out width is `length(candidates) * length(by)`, both compile-time constants,
  so the panel stays bounded. The winner is derived by a **pure fold** over the
  journaled per-criterion scores (summed per candidate, then `pick`ed —
  `:max_score` / `:min_score`), so a resume replays the settled outcome rather than
  re-scoring.
  """
  @enforce_keys [:address, :candidates, :by, :pick, :scorers]
  defstruct [:address, :candidates, :by, :pick, :scorers]

  @type t :: %__MODULE__{
          address: Workflow.Node.address(),
          candidates: [term()],
          by: [atom()],
          pick: :max_score | :min_score,
          scorers: [[Workflow.Node.Agent.t()]]
        }
end

defmodule Workflow.Node.Synthesize do
  @moduledoc """
  Fold a set of `inputs` into a single result under a static `prompt`. Both are
  compile-time literals, so the node stays inert. At runtime it is one schemaless,
  at-most-once agent turn whose effective prompt deterministically embeds the
  `inputs` — reusing the same paid-effect machinery every other agent turn does, so
  its settled result replays from the journal with no special case.
  """
  @enforce_keys [:address, :inputs, :prompt]
  defstruct [:address, :inputs, :prompt]

  @type t :: %__MODULE__{
          address: Workflow.Node.address(),
          inputs: term(),
          prompt: String.t()
        }
end

defmodule Workflow.Node.BudgetSlices do
  @moduledoc """
  A **runtime-owned width helper**: `floor(remaining / per)` over the budget
  ledger. It is deliberately *not* author arithmetic — the only thing a workflow
  can say is `budget_slices(per: N)`, and the runtime, reading the journaled
  ledger, decides the concrete width. Because the width is derived from budget it
  is bounded, and because the decision is journaled it is deterministic across a
  resume.
  """
  @enforce_keys [:per]
  defstruct [:per, max: nil]

  @type t :: %__MODULE__{per: pos_integer(), max: pos_integer() | nil}
end

defmodule Workflow.Node.PathCount do
  @moduledoc """
  A runtime-owned fanout width helper over a lexically preceding binding.

  The compiler resolves `binding` to an explicit journal ref and records the JSON
  pointer plus a required structural cap. Runtime folds that ref from the journal,
  counts the pointed value, and journals the concrete width before any branch runs.
  """
  @enforce_keys [:binding, :ref, :pointer, :max]
  defstruct [:binding, :ref, :pointer, :max]

  @type t :: %__MODULE__{
          binding: atom(),
          ref: Workflow.Node.binding_ref(),
          pointer: String.t(),
          max: pos_integer()
        }
end

defmodule Workflow.Node.GenericFanout do
  @moduledoc """
  Generic core fanout over inert agent lanes. `{:repeat, lane}` stores one lane
  template and rebases it to `parent ++ [branch, stage]`; `{:explicit, lanes}`
  stores each heterogeneous lane at its final stable address.

  The DSL and journal surface are `fanout` and `fanout_*`; older `fan_out` syntax
  is compiled into this same node.
  """
  @enforce_keys [:address, :width, :lanes]
  defstruct [
    :address,
    :width,
    :lanes,
    bind: nil,
    max_concurrency: nil,
    on_zero: :complete
  ]

  @type t :: %__MODULE__{
          address: Workflow.Node.address(),
          width: non_neg_integer() | Workflow.Node.BudgetSlices.t() | Workflow.Node.PathCount.t(),
          lanes:
            {:repeat, [Workflow.Node.Agent.t()]}
            | {:explicit, [[Workflow.Node.Agent.t()]]},
          bind: atom() | nil,
          max_concurrency: pos_integer() | nil,
          on_zero: :complete | :fail
        }
end
