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
  before the paid effect, still keyed for exactly-once by
  `(run_id, address, iteration)`.

  `schema` is an inert, raw JSON-schema **map** (or `nil` for a schemaless turn),
  materialized from a literal map in the workflow source. When present the turn is
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
  `verdict`, so every vote is journaled and keyed for exactly-once independently.
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

defmodule Workflow.Node.Refine do
  @moduledoc """
  Bounded adversarial refinement. V1 is intentionally narrow: an inline producer
  or a bound value supplies an artifact, a static reviewer panel checks it, a
  reviser handles blocking findings, and a terminal refine event commits or
  fails the result.
  """
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
    gates: %{}
  ]

  @type gate_predicate :: Workflow.Refine.Gate.predicate()

  @type cold_read_gate :: %{
          predicate: gate_predicate(),
          reviewer: Reviewer.t()
        }

  @type repair_gate :: %{predicate: gate_predicate(), agent: Workflow.Node.Agent.t()}
  @type halt_gate :: %{predicate: gate_predicate()}

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
          gates: %{
            optional(:cold_read) => cold_read_gate(),
            optional(:repair) => repair_gate(),
            optional(:halt) => halt_gate()
          }
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
  exactly-once agent turn whose effective prompt deterministically embeds the
  `inputs` — reusing the same paid-effect machinery every other agent turn does, so
  it is journaled and resumable with no special case.
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
  Generic core fanout over inert agent lanes. A repeated fanout stores one lane and
  rebases it to `parent ++ [branch, stage]`; an explicit fanout stores each
  heterogeneous lane at its final stable address.

  The struct is named `GenericFanout` to coexist with the legacy `%FanOut{}` node
  on case-insensitive filesystems; the DSL and journal surface remain `fanout` and
  `fanout_*`.
  """
  @enforce_keys [:address, :width, :lanes]
  defstruct [
    :address,
    :width,
    :lanes,
    bind: nil,
    max_concurrency: nil,
    on_zero: :complete,
    repeated: true
  ]

  @type t :: %__MODULE__{
          address: Workflow.Node.address(),
          width: non_neg_integer() | Workflow.Node.BudgetSlices.t() | Workflow.Node.PathCount.t(),
          lanes: [[Workflow.Node.Agent.t()]],
          bind: atom() | nil,
          max_concurrency: pos_integer() | nil,
          on_zero: :complete | :fail,
          repeated: boolean()
        }
end

defmodule Workflow.Node.FanOut do
  @moduledoc """
  Budget-scaled fan-out: run `body` concurrently across a **dynamic** number of
  branches whose width is a runtime-owned `%Workflow.Node.BudgetSlices{}` decision
  (`floor(remaining / per)`), not a compile-time constant like `parallel`. The
  decided width is journaled (`fan_out_started`) so a resume replays it rather than
  recomputing against a ledger the branches have since spent down.

  `body` is an inert list of `%Workflow.Node.Agent{}` templates at placeholder
  addresses; at runtime branch `i` re-addresses them to `parent ++ [i, stage]` — a
  pure data rebase, no closure — so every branch turn is journaled and keyed for
  exactly-once independently. Width is bounded by the budget and further capped by
  `max_concurrency`.
  """
  @enforce_keys [:address, :width, :body]
  defstruct [:address, :width, :body, max_concurrency: nil]

  @type t :: %__MODULE__{
          address: Workflow.Node.address(),
          width: Workflow.Node.BudgetSlices.t(),
          body: [Workflow.Node.Agent.t()],
          max_concurrency: pos_integer() | nil
        }
end
