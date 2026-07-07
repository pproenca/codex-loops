# Codex Loops Workflow DSL Specification

- **Status**: Draft
- **Version**: 0.1.0
- **Created**: 2026-07-06
- **Editors**: Codex Loops maintainers

This document specifies the **Codex Loops Workflow DSL**: an embedded Elixir
compile-time DSL for authoring deterministic, replayable agent workflows. It is written
to the completeness bar of an implementable language spec — a developer with no access to
the maintainers should be able to build a conforming implementation from this document
alone.

> Notation legend. A `::` production is **lexical** (source characters to tokens); a `:`
> production is **syntactic** (tokens to tree). `Symbol?` = optional, `Symbol+` = one or
> more, `Symbol*` = zero or more, `A but not B` = `A` excluding `B`. Algorithms are named
> functions with ordered steps (`Let`, `If … :`, `Return`, `Raise`). The full legend is
> in the [Notation Conventions](#appendix-a-notation-conventions) appendix.

---

## 1. Overview — Purpose & Design Principles

The Workflow DSL is a **declarative, closed-vocabulary language embedded in Elixir**. An
author writes a `workflow "name" do … end` block inside a module that does `use Workflow`.
At **compile time** (during `mix compile`) the block is parsed into an inert
`%Workflow.Tree{}` — an ordered list of plain `%Workflow.Node.*{}` structs that contain no
functions, no closures, and no captured runtime state. That tree is later executed by a
separate interpreter that records every decision and paid effect in an append-only
journal.

The DSL exists to describe **multi-agent orchestration** — sequencing agent turns,
fanning out work, running verification/judgement panels, and bounded iterative loops —
in a form that is **deterministic, serializable, and provably terminating**.

### 1.1 Shape

Declarative and imperative-sequenced: statements execute top to bottom, but every
statement is a static declaration, not an expression that computes a value. The DSL is a
*surface* over a plain compiler function; the macro layer is a thin shell that only
escapes the compiled tree into a compile-time constant.

### 1.2 Non-goals

The following are deliberately **out of scope** and MUST NOT be expressible:

- **General computation.** A workflow cannot compute values at runtime, bind variables,
  branch on agent output, or perform arithmetic. There is no value-binding construct.
  *(Dataflow §10 addendum: the implemented core narrows this bullet by reopening exactly one
  binding form — `let` over already-journaled `agent`/`synthesize` outputs — while keeping the
  arithmetic and branch-on-output bans intact; see §10.)*
- **Non-determinism.** No node reads a clock, a random source, the environment, the
  filesystem, or any external module. Wall-clock and randomness are *unrepresentable*.
- **Side effects outside the vocabulary.** No spawning shells, no I/O, no network calls,
  no module imports from inside a workflow body.
- **Runtime linting.** Determinism is not enforced by a runtime checker; it is a static
  property of the vocabulary (see principles below).

### 1.3 Design principles (the tie-breakers)

These principles resolve every ambiguity this document does not foresee. When two
readings are possible, the reading that upholds these principles is correct.

1. **Closed vocabulary.** The DSL has exactly **13** top-level combinators (§2.4). Any
   form outside the vocabulary is a compile error. New capability is added by adding a
   combinator to the closed set, never by allowing arbitrary Elixir. *Pre-resolves:* any
   unrecognized call, operator, literal, or closure is rejected, not interpreted.

2. **Determinism by absence.** Determinism is guaranteed by the *absence* of any
   vocabulary node that can read a clock or randomness, plus compiler rejection of
   external calls — never by a runtime linter. *Pre-resolves:* if a construct could
   introduce non-determinism, it is simply not in the vocabulary and cannot be written.

3. **The journal is the single source of truth.** Every observable decision (loop
   continue/stop, fan-out width, panel verdicts, agent results) is written to an
   append-only journal. All read surfaces (status, inspect, resume, live views) are
   **pure folds** over the journal, never independent state. *Pre-resolves:* resume never
   recomputes a past decision; it replays the journaled one.

4. **Fail closed.** A schema-backed agent whose output does not validate is retried
   on-thread up to its retry budget and then **fails the node and aborts the run**. There
   is no silent coercion, no default value, no partial acceptance of malformed structured
   output. *Pre-resolves:* invalid structured output is never treated as success.

5. **Bounded termination.** Every loop is provably terminating because a structural
   `max_iterations` cap (default `1000`) bounds **both** loop types unconditionally,
   regardless of body behavior. `while_budget`'s reserve condition and `until_dry`'s
   dryness condition are *early-stop* refinements layered on top of that cap — they may
   stop a loop sooner, but they are **not** what guarantees termination. In particular a
   `while_budget` body with no paid `agent` never decreases `remaining` (Rule 5.7.6 does
   not require an `agent`), so for such a loop only `max_iterations` bounds it.
   *Pre-resolves:* no workflow can loop forever, even one whose body spends nothing.

6. **No value binding.** No combinator binds a name to a runtime value. A `return` value,
   a `verify` subject, `judge` candidates, `pipeline` items, and every prompt MUST be a
   compile-time literal. *Pre-resolves:* a workflow cannot "capture" or "reference" a
   runtime result except through the fixed data-flow of accumulators and panel folds.
   *(Dataflow §10 addendum: Principle 6′ is presented there as the proposed reconciliation for
   the implemented `let`/`~P`/`emit` core — journaled-values-only, deterministic-render-only —
   while §1–§8 remain the frozen base body.)*

7. **Inert tree.** The compiled `%Tree{}` is pure, serializable data containing zero
   closures. It is `Macro.escape`-d into a compile-time constant and can be reconstructed
   losslessly from storage. *Pre-resolves:* nothing in a compiled workflow can hold a
   live function or process reference.

8. **Panels are observational.** `verify` and `judge` journal a verdict/winner but do
   **not** alter control flow. There is no conditional or branching combinator, and no
   `until:` predicate or `collect` accumulator can read a panel result (§6.8, §6.6): the
   only value a body node consumes is the immediately preceding agent's output via
   `collect`, never a panel outcome. Any reaction to a verdict happens **outside** the
   workflow, by folding the journal. *Pre-resolves:* a workflow never "branches on" a
   panel outcome — panels report, they do not gate.

---

## 2. Lexical Grammar

### 2.1 The DSL is embedded Elixir

The Workflow DSL **defines no lexer of its own**. A workflow's source text is ordinary
Elixir source. Elixir's own tokenizer and parser turn that text into a quoted abstract
syntax tree (`Macro.t()`), and the DSL compiler (`Workflow.Compiler.parse/2`) operates on
that AST — not on a character stream. Consequently:

- **Character set, encoding, whitespace, line terminators, and comments** are exactly
  Elixir's. Source is UTF-8 Elixir; whitespace is insignificant except as a token
  separator; `#` begins a line comment; comments do not nest. None of these are the
  DSL's to redefine.
- **Case sensitivity** is Elixir's: identifiers and atoms are case-sensitive.
- **The combinator names are not reserved words.** `agent`, `phase`, `verify`, etc. are
  recognized structurally — a local call form `name(args)` whose `name` atom is in the
  closed vocabulary. They are keywords *of the DSL grammar*, not of the Elixir lexer, and
  carry no meaning outside a `workflow` block.

An implementation MAY reuse a host language other than Elixir, but it MUST accept the same
*surface forms* (§3) and produce the same *tree* (§4); this document describes the Elixir
embedding, which is normative for the reference implementation.

### 2.2 Token kinds the DSL reads

Only a subset of Elixir tokens is meaningful to the DSL. The lexical productions below
describe that subset. They are Elixir's own productions, restated for completeness; an
implementation MUST accept exactly the values Elixir's tokenizer produces.

```
StringLiteral :: `"` StringCharacter* `"`
StringLiteral :: `"""` HeredocContent `"""`
StringCharacter :: SourceCharacter but not `"` or `\`
StringCharacter :: `\` EscapeSequence
IntegerLiteral :: `-`? Digit+
FloatLiteral :: `-`? Digit+ `.` Digit+ ExponentPart?
ExponentPart :: (`e` | `E`) (`+` | `-`)? Digit+
Digit :: one of `0` `1` `2` `3` `4` `5` `6` `7` `8` `9`
Atom :: `:` AtomName
AtomName :: Letter (Letter | Digit | `_`)*
BooleanLiteral :: `true`
BooleanLiteral :: `false`
NilLiteral :: `nil`
```

Note: numeric literals — both `IntegerLiteral` and `FloatLiteral` — inherit Elixir's
tokenization **exactly** (Elixir also admits `_` digit separators, e.g. `1_000`, and the
`0x`/`0o`/`0b` integer bases; these tokenize to the same integer/float values). A
`FloatLiteral` requires digits on both sides of the `.` (Elixir rejects `3.` and `.5`).
Floats are admissible data everywhere a scalar literal is (a `return`/`judge`
candidate/`pipeline` item/`verify` subject/`synthesize` input MAY be a float), and
`Schema.Validate`'s `"number"` type accepts them (§6.4.2); the productions above only
restate the DSL-relevant subset for completeness.

Note: a `StringLiteral` in the DSL MUST NOT contain runtime interpolation. Elixir string
interpolation (`"… #{expr} …"`) tokenizes to a call form, not a binary literal, so an
interpolated prompt fails the "must be a literal string" check (§5) — it is a compile
error, never a runtime concatenation.

### 2.3 Literal admissibility

Every value a combinator accepts as data (prompts, names, `return` values, `verify`
subjects, `judge` candidates, `pipeline` items, `synthesize` inputs, schema maps) MUST be
a **compile-time literal**. Formally, the AST MUST satisfy `Macro.quoted_literal?/1`: it is
built only from scalars (integers, floats, booleans, `nil`, atoms, binaries), lists,
tuples, and maps whose contents are themselves literals. A form that contains a variable
reference or a function call is **not** a literal and is rejected.

### 2.4 The closed combinator vocabulary

The DSL recognizes exactly these **13** combinator names as top-level statements:

```
agent  log  phase  parallel  pipeline  return  collect
while_budget  until_dry  verify  judge  synthesize  fan_out
```

> *(Dataflow §10 addendum: the implemented core recognizes `let` and `emit` alongside the base
> set and admits `~P` only in the checked positions described there. Proposed `gather` and `map`
> remain DEFER.)*

Two names are contextual, not standalone combinators:

- `collect` is in the 13 but is **body-only**: valid only inside a loop body (§3.7). A
  top-level `collect` is a compile error.
- `budget_slices(per: N)` is **not** one of the 13. It appears only as the value of
  `fan_out`'s `width:` option (§3.9).

Inside a loop body the vocabulary narrows to the **body vocabulary** — exactly
`agent`, `log`, `phase`, `collect`. Every other combinator is rejected in a body (§5.7).

---

## 3. Syntactic Grammar

The goal symbol is `WorkflowDefinition`. Productions below use single-colon (`:`)
syntactic notation over the token stream; ignored tokens (whitespace, comments) may appear
between terminals. Parentheses around call arguments are optional per Elixir (`phase "p"`
≡ `phase("p")`); the productions show the parenthesized form.

```
WorkflowDefinition : `workflow` StringLiteral `do` WorkflowBody `end`

WorkflowBody : Statement*

Statement :
  - PhaseStmt
  - LogStmt
  - AgentStmt
  - ReturnStmt
  - ParallelStmt
  - PipelineStmt
  - VerifyStmt
  - JudgeStmt
  - SynthesizeStmt
  - WhileBudgetStmt
  - UntilDryStmt
  - FanOutStmt
```

`collect` is not in `Statement`: it appears only in `BodyStatement` (§3.7). A top-level
`collect` parses syntactically as a call but is rejected by validation (§5.6).

### 3.1 Simple statements

```
PhaseStmt  : `phase` `(` StringLiteral `)`
LogStmt    : `log` `(` StringLiteral `)`
ReturnStmt : `return` `(` Literal `)`
```

- `phase` names a milestone. Its `StringLiteral` name MUST be unique within the workflow.
- `log` emits a static message. No interpolation.
- `return` sets the workflow's terminal value. `Literal` MUST satisfy §2.3. The workflow
  MUST contain at least one `return`.

### 3.2 Agent

```
AgentStmt : `agent` `(` StringLiteral AgentOpts? `)`
AgentOpts : `,` KeywordList
```

The optional `KeywordList` is a literal Elixir keyword list drawn only from the keys
`schema:`, `retries:`, and `label:`. `schema:` is either a
literal JSON-schema map or a **schema-module alias** — a module built with
`Workflow.Schema.DSL` (§4.5) that the compiler lifts to an inert map via
`module.__schema__(:json)`. `retries:` is a non-negative integer literal, default `2`
(total attempts = `retries + 1`), and requires `schema:` when present. `label:` is an
optional string literal used only as inert display metadata; it does not affect addressing,
idempotency, prompts, provider calls, validation, control flow, or results, and it may be
used with or without `schema:`.

**Inline schema maps MUST use string keys (normative).** `Schema.Validate` dispatches on
the **string** key `schema["type"]` (§6.4.2), so a literal schema map MUST be written with
string keys — `%{"type" => "object", "properties" => %{…}, "required" => […]}` — not the
idiomatic atom-keyed form `%{type: "object", …}`. An atom-keyed schema map still satisfies
Rule 5.3.4 (it is a literal map) and therefore **compiles and runs**, but `schema["type"]`
is then `nil`, which `Schema.Validate` treats as an unrecognized type and **accepts every
output permissively** (§6.4.2), silently defeating fail-closed validation (Principle 4).
The compiler does **not** reject an atom-keyed schema (Rule 5.3.4 checks only that the map
is a literal); a conforming implementation SHOULD emit a compile-time warning when a
literal schema map's top-level `"type"` string key is absent, and MAY reject it, but an
author MUST supply string keys to get fail-closed behavior (§11.3).

### 3.3 Parallel (barrier fan-out)

```
ParallelStmt : `parallel` `(` BranchList ConcurrencyOpt? `)`
BranchList   : `[` AgentStmt (`,` AgentStmt)* `]`
ConcurrencyOpt : `,` `[` `max_concurrency:` IntegerLiteral `]`
```

`BranchList` MUST be a non-empty literal list in which **every element is an `agent(…)`
call**. The only option is `max_concurrency: <positive integer>` (default: all branches
at once).

### 3.4 Pipeline (per-item fan-out, no barrier)

```
PipelineStmt : `pipeline` `(` ItemList `,` StageList ConcurrencyOpt? `)`
ItemList     : `[` Literal (`,` Literal)* `]`
StageList    : `[` AgentStmt (`,` AgentStmt)* `]`
```

`ItemList` MUST be a non-empty literal list of arbitrary literal values. `StageList` MUST
be a non-empty literal list of `agent(…)` calls. Same `max_concurrency:` option.

> Note (no per-item injection). A pipeline stage prompt does **not** receive its item.
> Each lane runs the **identical** literal stage prompts; the item is retained only as a
> journal label recording which item a lane ran (§4.4), never spliced into the prompt.
> This is the deliberate asymmetry with `synthesize`, `verify`, and `judge`, which *do*
> inject their data (`Inputs: …`, `<subject>`, `<candidate>`). An author who wants a lane
> to see its item MUST write that content into the stage prompt literally; there is no
> value binding (Principle 6).

### 3.5 Verify (verification panel)

```
VerifyStmt : `verify` `(` Literal `,` VerifyOpts `)`
VerifyOpts : KeywordList   ; keys drawn from voters:, lenses:, threshold:
```

The first argument (the *subject*) MUST be a literal (§2.3). Options MUST supply
**exactly one** of `voters: N` (positive integer) or `lenses: [:atom, …]` (non-empty list
of atoms), and MAY supply `threshold:` (default `:majority`).

### 3.6 Judge (scoring panel) and Synthesize

```
JudgeStmt      : `judge` `(` CandidateList `,` JudgeOpts `)`
CandidateList  : `[` Literal (`,` Literal)* `]`
JudgeOpts      : KeywordList   ; keys drawn from by:, pick:
SynthesizeStmt : `synthesize` `(` Literal `,` StringLiteral `)`
```

`judge` REQUIRES both `by: [:atom, …]` (non-empty list of criterion atoms) and
`pick: :max_score | :min_score`. `synthesize` takes a literal `inputs` value and a
literal string `prompt`.

### 3.7 Loops and loop bodies

```
WhileBudgetStmt : `while_budget` KeywordList `do` LoopBody `end`
UntilDryStmt    : `until_dry`    KeywordList `do` LoopBody `end`

LoopBody      : BodyStatement+
BodyStatement :
  - AgentStmt
  - LogStmt
  - PhaseStmt
  - CollectStmt

CollectStmt : `collect` `(` `[` `into:` Atom `]` `)`
```

The `do … end` block is Elixir block sugar: `while_budget reserve: 8 do … end` parses as
`while_budget([reserve: 8], [do: block])`. A `LoopBody` MUST contain at least one
`BodyStatement`, and MUST draw only from the body vocabulary (`agent`, `log`, `phase`,
`collect`). `while_budget` keys are drawn from `reserve:`, `until:`, `max_iterations:`
(with `reserve:` REQUIRED). `until_dry` keys are drawn from `rounds:`, `seen_by:`,
`max_iterations:` (with `rounds:` REQUIRED), and its body MUST contain at least one
`collect`. Because the body vocabulary is `[:agent, :log, :phase, :collect]`, **loops do
not nest** — a loop body cannot contain another `while_budget`/`until_dry` (Rule 5.7.6).

### 3.8 The `until:` predicate sub-grammar

`while_budget`'s optional `until:` value is drawn from a **closed predicate grammar**
(tokens to a `%Workflow.Predicate.*{}` struct):

```
Predicate :
  - Comparison
  - `all_of` `(` `[` Predicate (`,` Predicate)* `]` `)`
  - `any_of` `(` `[` Predicate (`,` Predicate)* `]` `)`

Comparison : Operand CompareOp IntegerLiteral
Operand :
  - `count` `(` Atom `)`
  - `budget_remaining` `(` `)`
CompareOp : one of `>` `<` `>=` `<=` `==`
```

The left operand MUST be `count(<accumulator-atom>)` or `budget_remaining()`; the right
operand MUST be a literal integer. Here `<accumulator-atom>` is a **metavariable** — any
atom — not a literal name: it names the accumulator the loop body writes to via
`collect(into: <accumulator-atom>)`. `count(:items)`, `count(:findings)`, etc. are all
legal; the accumulator need not be named `:acc`. `all_of`/`any_of` require at least one
nested predicate. Any other form is a compile error. No arithmetic, function call, or
closure is admissible.

> Note (accumulator name must match a `collect`). A `count(<atom>)` operand is meaningful
> only if the loop body `collect(into: <atom>)`s into that **exact same** atom. This is a
> name-resolution coupling the compiler does **not** enforce (there is no cross-check
> between the predicate and the body), so it is a silent footgun: a `count(:items)`
> predicate whose body forgets `collect(into: :items)` (or misspells the accumulator) still
> **compiles and runs**, but `count(:items)` resolves to an empty accumulator — size `0`
> — **forever** (§6.8, `ctx.accumulators[acc] or []`), so the predicate never fires and the
> loop runs to `max_iterations`/budget. An author using `until: count(:x) …` MUST write
> `collect(into: :x)` in the body with a matching atom. A conforming implementation MAY emit
> a SHOULD-level compile warning when an `until:` `count(<atom>)` has no matching
> `collect(into: <atom>)` in the same body.

### 3.9 Fan-out (budget-scaled dynamic fan-out)

```
FanOutStmt : `fan_out` KeywordList `do` AgentLane `end`
AgentLane  : AgentStmt+
WidthForm  : `budget_slices` `(` `[` `per:` IntegerLiteral `]` `)`
```

`fan_out` keys are drawn from `width:` (REQUIRED, MUST be exactly a `WidthForm` with a
positive integer `per`) and `max_concurrency:` (optional positive integer). The body MUST
be a non-empty lane of `agent(…)` calls. `budget_slices(per: N)` is admissible **only**
here.

> Note (no per-branch injection). Exactly like a `pipeline` stage (§3.4), a `fan_out` lane
> receives **no** per-branch content or index. Every branch runs the **byte-identical**
> literal lane prompt(s); the branch index `i` appears only in the branch **address**
> (`node.address ++ [i]`, §6.10), **never** in the prompt, and there is no value binding
> (Principle 6). A `fan_out` therefore launches N **undifferentiated replicas** of the same
> prompt — it does **not** hand each lane a distinct slice, shard, or index of the work.
> `budget_slices(per: N)` decides only **how many** replicas run (one per `N` remaining
> budget tokens), not what each does. An author who writes `fan_out … do agent("Investigate
> one slice of the search space") end` gets N lanes that all run that identical instruction
> with no way to tell which "slice" they are; the useful pattern is N **independent
> replicas** of the same task (e.g. diverse sampling), not a partition of work.

### 3.10 Operator precedence and associativity — N/A

The DSL introduces **no operators of its own**. The only operators that appear are the
five comparison operators inside `until:` predicates (§3.8); these are Elixir's
non-associative comparison operators, each used exactly once as `Operand Op Integer`, so
there is no chained-operator ambiguity to resolve (`a - b - c` and `a && b || c` cannot be
written — arithmetic and boolean operators are not in any DSL grammar). A precedence and
associativity table is therefore **not applicable** and is deliberately omitted; all host
tokenization and precedence is inherited from Elixir and never relied upon by DSL
semantics.

---

## 4. Semantic Model — the inert tree

Parsing a workflow yields a `%Workflow.Tree{}` whose `nodes` field is an ordered list of
`%Workflow.Node.*{}` structs. These structs are the semantic model: **inert, serializable
data with zero closures**. The macro escapes the tree into a compile-time constant exposed
by two reflection functions (introspection surface):

- `Module.__workflow__(:tree)` returns the `%Workflow.Tree{}`.
- `Module.__workflow__(:name)` returns the workflow's name string.

### 4.1 The tree container

`%Workflow.Tree{}`:

| Field | Type | Default | Notes |
|---|---|---|---|
| `name` | `String.t() \| nil` | `nil` | Set by the `workflow/2` macro from the string literal; the compiler leaves it `nil`. |
| `version` | `pos_integer()` | `1` | Structural version, independent of the journal schema version. |
| `nodes` | `[struct()]` | `[]` (enforced key) | Ordered list of node structs. |

### 4.2 Node addressing

An **address** is a path of non-negative integers from the tree root
(`@type address :: [non_neg_integer()]`). Every node struct carries an `:address` field of
this type — the sole exception is `%Workflow.Node.BudgetSlices{}`, which has none.

- Top-level statement `i` has address `[i]` (0-based position in the block).
- A child at position `k` under a parent at address `P` has address `P ++ [k]`.
- Grids and lanes append two indices: e.g. a `pipeline` item `i` stage `s` is at
  `P ++ [i, s]`.

Addresses are **stable across schema versions**: journal events and idempotency keys
reference nodes by address forever. A conforming implementation MUST NOT renumber or
reshape existing addresses when adding new node kinds.

### 4.3 Node struct catalog

Each node's enforced keys and defaults (from `lib/workflow/node.ex`). Every node except
`BudgetSlices` has `address :: address()`.

| Node | Enforced keys | Defaults / extra fields | Non-address field types |
|---|---|---|---|
| `Phase` | `[:address, :name]` | — | `name :: String.t()` |
| `Log` | `[:address, :message]` | — | `message :: String.t()` |
| `Agent` | `[:address, :prompt]` | `label: nil, schema: nil, retries: 2` | `prompt :: String.t()`; `label :: String.t() \| nil`; `schema :: map() \| nil`; `retries :: non_neg_integer()` |
| `Return` | `[:address, :value]` | — | `value :: term()` |
| `Parallel` | `[:address, :branches]` | `max_concurrency: nil` | `branches :: [Agent.t()]`; `max_concurrency :: pos_integer() \| nil` |
| `Pipeline` | `[:address, :items, :lanes]` | `max_concurrency: nil` | `items :: [term()]`; `lanes :: [[Agent.t()]]` |
| `Collect` | `[:address, :into]` | — | `into :: atom()` |
| `WhileBudget` | `[:address, :reserve, :body, :max_iterations]` | `until: nil` | `reserve :: non_neg_integer()`; `until :: struct() \| nil`; `body :: [struct()]`; `max_iterations :: pos_integer()` |
| `UntilDry` | `[:address, :rounds, :seen_by, :body, :max_iterations]` | — | `rounds :: pos_integer()`; `seen_by :: [atom()]`; `body :: [struct()]`; `max_iterations :: pos_integer()` |
| `Verify` | `[:address, :subject, :mode, :voters, :threshold]` | — | `subject :: term()`; `mode :: {:voters, pos_integer()} \| {:lenses, [atom()]}`; `voters :: [Agent.t()]`; `threshold :: :majority \| :unanimous \| :any \| pos_integer()` |
| `Judge` | `[:address, :candidates, :by, :pick, :scorers]` | — | `candidates :: [term()]`; `by :: [atom()]`; `pick :: :max_score \| :min_score`; `scorers :: [[Agent.t()]]` |
| `Synthesize` | `[:address, :inputs, :prompt]` | — | `inputs :: term()`; `prompt :: String.t()` |
| `BudgetSlices` | `[:per]` | — (no address) | `per :: pos_integer()` |
| `FanOut` | `[:address, :width, :body]` | `max_concurrency: nil` | `width :: BudgetSlices.t()`; `body :: [Agent.t()]` |

### 4.4 Compile-time template pre-expansion

Several combinators pre-expand into a grid or lane of inert `%Agent{}` templates **at
compile time**, so the tree already contains every paid turn (fully addressed) before the
run starts:

- **`parallel`**: branch `i` at `address ++ [i]`.
- **`pipeline`**: `lanes[i]` is item `i`'s ordered stages; stage `s` re-addressed to
  `address ++ [i, s]`. `items` is retained **only** so the journal records which item a
  lane ran — the item is **not** injected into any stage prompt. Every lane runs the same
  literal stage prompts; unlike `synthesize`/`verify`/`judge`, a pipeline stage receives
  no per-item content (§3.4).
- **`verify`**: one voter agent per vote at `address ++ [i]`, `schema` = the fixed verdict
  schema, `retries: 0`. In `{:voters, n}` mode there are `n` identical votes with prompt
  `"Confirm or refute this finding, answering with a boolean verdict: <subject>"`. In
  `{:lenses, lenses}` mode there is one vote per lens `i` with prompt
  `"From the <lens> perspective, confirm or refute this finding, answering with a boolean
  verdict: <subject>"`.
- **`judge`**: a scorer grid; candidate `c`, criterion `k` at `address ++ [c, k]`,
  `schema` = the fixed score schema, `retries: 0`, prompt `"Score this candidate on
  <criterion>, answering with a numeric score: <candidate>"`. The grid width is
  `length(candidates) * length(by)`.

**Placeholder rendering (normative, with a host-scoped clause for `inspect/1`).** The
`<subject>`, `<candidate>`, `<lens>`, and `<criterion>` placeholders above are substituted
into the fixed template **at compile time**, and the composed prompt is later journaled
verbatim in `agent_committed.prompt` (§7.2), so it is observable output. The substitution
rules are:

- `<subject>` (verify) and `<candidate>` (judge) are rendered by `RenderText`:

  ```
  RenderText(term):
    - If {term} is a binary (string): Return {term} unchanged.   ; no added quotes
    - Return inspect(term).                                       ; Elixir inspect/1
  ```

  So `verify("the bug", …)` renders `…verdict: the bug` (no surrounding quotes), while a
  non-string subject such as `verify(%{id: 1}, …)` renders `…verdict: %{id: 1}` (the
  `inspect/1` form). For a **binary** subject/candidate the rendering is fully pinned and
  cross-host normative: two conforming implementations MUST pass the string through
  **unchanged** and MUST NOT wrap it in quotes.

  For a **non-binary** subject/candidate the rendered text is `inspect(term)` — Elixir's
  `Kernel.inspect/1`. Because this document does not fix `inspect/1`'s exact byte grammar
  (map key ordering, the `:atom` colon, string escaping, list/tuple spacing), the
  `inspect/1`-based rendering is **normative only for the Elixir embedding** (where all
  conforming implementations invoke the same `inspect/1` and therefore journal identical
  bytes). For a non-Elixir host the exact rendering of a non-binary subject/candidate is
  **implementation-defined**; such a host MUST still journal the composed prompt verbatim
  and MUST still pass binaries through unquoted, but its representation of non-binary terms
  need not match the Elixir bytes. Authors who need a byte-stable journaled prompt across
  hosts MUST pass a **binary** subject/candidate.

- `<lens>` (verify) and `<criterion>` (judge) are atoms; each is rendered by `to_string/1`
  applied to the atom — i.e. its `String.Chars` form with **no leading colon**. So
  `lenses: [:correctness]` renders `From the correctness perspective, …` (not
  `:correctness`), and `by: [:impact]` renders `Score this candidate on impact, …`.

`synthesize`'s `Inputs: <inspect(inputs)>` splice (§6.3) is the one placeholder that always
uses `inspect/1` regardless of type, because its inputs are an arbitrary literal value, not
a subject/candidate; `RenderText` is not used there. Like the non-binary `RenderText` case,
this `inspect/1` splice is byte-normative **only for the Elixir embedding**; on a non-Elixir
host the rendering of `inputs` is implementation-defined (the prompt is still journaled
verbatim).

The verdict and score schemas are fixed constants:

```
verdict schema = %{"type" => "object",
                   "properties" => %{"verdict" => %{"type" => "boolean"}},
                   "required" => ["verdict"]}
score schema   = %{"type" => "object",
                   "properties" => %{"score" => %{"type" => "number"}},
                   "required" => ["score"]}
```

`fan_out` is the **only** combinator whose fan width is not a compile-time constant: its
body is stored with placeholder addresses and re-addressed per branch at runtime (§6.10),
because the width is a runtime budget decision. Like `pipeline` (and unlike
`synthesize`/`verify`/`judge`, which inject their data), a `fan_out` lane receives **no**
per-branch content or index — every branch runs the identical literal lane prompt; the branch
index appears only in the address, never in the prompt (§3.9).

Voter and scorer agents are always `retries: 0` and schema-bound, so a malformed vote or
score is a **hard panel failure**, never a re-roll.

### 4.5 Schema modules (the `schema:` module-alias form)

`agent`'s `schema:` option accepts a **literal JSON-schema map** (the primary form; the
maps validated by §6.4.2) or a **schema-module alias**: a module that exports
`__schema__(:json)` returning such a map. The two are interchangeable — `agent("…", schema:
Name)` behaves **identically** to passing `Name.__schema__(:json)`'s map literally. The
compiler resolves the alias at compile time (Rule 5.3.4) and stores only the resulting inert
map in the `%Agent{}` node; no module reference survives into the tree (Principle 7).

Schema modules are authored with a small **closed sub-DSL**, `Workflow.Schema.DSL`, which is
itself compile-time-only and produces an inert JSON-schema map. Its grammar and semantics:

```
SchemaDefinition : `schema` ModuleAlias `do` SchemaBody `end`
SchemaBody       : FieldStmt+
FieldStmt :
  - ScalarField
  - ArrayField
ScalarField : ScalarType `(` FieldName ReqOpt? `)`
ScalarType  : one of `string` `integer` `number` `boolean`
ArrayField  : `array` `(` FieldName `,` `[` `of:` ElemType `]` ReqOpt? `)`
            | `array` FieldName `,` `of:` `:object` `do` SchemaBody `end`
ElemType    : `:string` | `:integer` | `:number` | `:boolean`
FieldName   : Atom | StringLiteral
ReqOpt      : `,` `required:` BooleanLiteral
```

- `import Workflow.Schema.DSL` (or `use Workflow.Schema.DSL`) exposes `schema/2`.
- `schema Name do <body> end` defines a module `Name` exporting `Name.__schema__(:json)`
  (and a zero-arity `Name.__schema__/0`) that returns the inert map. A schema module MUST be
  compiled **before** the workflow that references it.
- **Every field is REQUIRED by default.** A field opts out with `required: false` (the value
  MUST be a boolean literal). Required fields populate the enclosing object's `"required"`
  list, in declaration order.
- The generated map is a JSON-Schema `"object"` whose `"properties"` are the declared
  fields in declaration order: a scalar field `string(:f)` → `%{"type" => "string"}`; an
  `array name, of: :string` → `%{"type" => "array", "items" => %{"type" => "string"}}`; an
  `array name, of: :object do … end` → an array whose `"items"` is the nested object built
  by the same rules.
- The vocabulary is **closed**: any form outside `string`/`integer`/`number`/`boolean`/
  `array` (or an `of:` element type outside the four scalars) raises a caller-located
  `Workflow.CompileError` at `mix compile`, exactly like the workflow DSL's forbidden-form
  catalog (§5.1).

Example — the module and its lifted map:

```elixir
import Workflow.Schema.DSL

schema BugReport do
  array :bugs, of: :object do
    string(:file)
    integer(:line)
  end
end

# BugReport.__schema__(:json) ==
#   %{"type" => "object",
#     "properties" => %{
#       "bugs" => %{"type" => "array",
#                   "items" => %{"type" => "object",
#                                "properties" => %{"file" => %{"type" => "string"},
#                                                  "line" => %{"type" => "integer"}},
#                                "required" => ["file", "line"]}}},
#     "required" => ["bugs"]}
```

**Placement (the "compiled before" rule, made concrete).** Because the compiler calls
`Name.__schema__(:json)` **at compile time** while parsing the referencing workflow
(Rule 5.3.4), the module `Name` MUST already be compiled at that point; a module Elixir has
not yet compiled is an "unknown/uncompiled module" and is **rejected**. Concretely:

- **RECOMMENDED:** define the schema module in its **own file** (or its own top-level
  `defmodule`), which Elixir compiles as an independent unit before the workflow module that
  references it. This always satisfies the rule.
- **Same-file definition works only if the schema module is compiled first.** A `schema Name
  do … end` written **below** the `defmodule …WorkflowModule` that references it (or in any
  arrangement Elixir does not compile first) fails Rule 5.3.4 at `mix compile` with a
  caller-located error. The literal-map form (`schema: %{…}`) has no ordering constraint and
  is the fallback when placement is awkward.

Example — schema module in its own file, referenced by a workflow in another:

```elixir
# file: lib/schemas/bug_report.ex  (compiles as its own unit, before the workflow)
import Workflow.Schema.DSL

schema BugReport do
  string(:file)
  integer(:line)
end

# file: lib/flows/triage.ex
defmodule Triage do
  use Workflow

  workflow "triage" do
    agent("Report one bug as {file, line}.", schema: BugReport)   # BugReport already compiled
    return(:done)
  end
end
```

An implementation MAY treat the module-alias form as syntactic sugar; what is normative is
that `schema: Name` and `schema: Name.__schema__(:json)`'s map yield the **same** `%Agent{}`
node and therefore the same run behavior.

---

## 5. Validation (static semantics)

All validation runs at **compile time** in the plain function `Workflow.Compiler.parse/2`
(the `workflow/2` macro is a thin shell that only escapes the compiled tree or raises the
finding). No validation is deferred to runtime.

### 5.0 The two error channels and finding shape

`parse/2` surfaces validation through two channels; both end as a **caller-located**
`mix compile` failure:

1. **Recoverable finding** — `{:error, %Workflow.Compiler.Finding{}}`. Used for
   wrong-argument-shape errors, per-option errors, and whole-DSL invariants. The macro
   converts it to a raised, formatted `Workflow.CompileError`.
2. **Raised `Workflow.CompileError`** — raised directly for the *forbidden-form catalog*
   (§5.1).

A `%Finding{}` carries `message`, optional `form` (the offending AST), `file`, `line`, and
optional `hint`. `file`/`line` come from the caller's `%Macro.Env{}` and the offending
form's line metadata, so an error names the exact line in the author's file. When `form`
is `nil` (whole-DSL invariants) the render shows location only; otherwise it renders a
rustc-style snippet with a caret underline.

An implementation MUST report every validation failure as a compile-time error located at
the offending declaration. It MUST NOT accept an invalid workflow and defer the error to
run time.

### 5.1 Forbidden-form catalog (raises)

Any form that is not a recognized combinator call is rejected. These **raise**
`Workflow.CompileError`.

**Rule 5.1.1 — No closures.** A `fn … end` form is rejected.
*Why:* a workflow is inert data and cannot capture a closure.

```counter-example
workflow "x" do
  agent(fn -> :nope end)     # anonymous functions are not part of the vocabulary
  return(:ok)
end
```

**Rule 5.1.2 — No external module calls.** Any `Module.fun(…)` or `:erlang_mod.fun(…)`
call is rejected (e.g. `Enum.map/2`, `:rand.uniform/0`, `System.monotonic_time/0`).
*Why:* a workflow must be deterministic and self-contained.

```counter-example
workflow "x" do
  agent(:rand.uniform())     # calls to external modules are not part of the vocabulary
  return(:ok)
end
```

**Rule 5.1.3 — No unknown bare calls.** A local call `name(args)` whose `name` is not in
the vocabulary is rejected, with a Jaro-distance "did you mean" hint when the closest
combinator scores `>= 0.7`.
*Why:* the vocabulary is closed.

```counter-example
workflow "x" do
  frobnicate("boom")         # unknown combinator `frobnicate`
  return(:ok)
end
```

**Rule 5.1.4 — No stray forms.** Any other form (a bare literal, a variable reference, an
operator expression) that is not a combinator call is rejected.
*Why:* only combinator statements are meaningful.

```counter-example
workflow "x" do
  42                         # unknown workflow form outside the combinator vocabulary
  return(:ok)
end
```

### 5.2 Known combinator, wrong argument shape (finding)

A form whose name **is** in the vocabulary but whose arguments do not match any accepted
shape is a recoverable finding: `` `<combinator>` was called with invalid arguments ``.

```counter-example
agent(:not_a_string)         # `agent` was called with invalid arguments
```

Per-combinator argument and option rules follow. Each rule is a decidable predicate over
the AST; each carries the smallest violating input.

### 5.3 `agent`, `return`, `synthesize`

**Rule 5.3.1 — Agent prompt is a literal string.** `agent(prompt)` and
`agent(prompt, opts)` require `is_binary(prompt)`.

```counter-example
agent(some_var)              # `agent` was called with invalid arguments
```

**Rule 5.3.2 — Agent options are a `schema:`/`retries:`/`label:` keyword literal.** A
two-argument `agent` requires a literal keyword list whose keys are all in
`[:schema, :retries, :label]`.

```counter-example
agent("go", schema: %{"type" => "object"}, bogus: 1)   # invalid arguments
```

**Rule 5.3.3 — Retries require a schema.** A two-argument `agent` MAY supply only
`label:`. If it supplies `retries:`, it MUST also supply `schema:`.

```counter-example
agent("go", retries: 2)      # `agent` with options requires a `schema:`
```

**Rule 5.3.4 — Schema is a literal map or a schema module.** `schema:` MUST be either a
literal JSON-schema map (satisfying `Macro.quoted_literal?`) or a **schema-module alias**
(§4.5) — a module that exports `__schema__(:json)`, which the compiler calls at compile
time to obtain the inert JSON-schema map. A non-map, a non-literal map, a module that does
not export `__schema__(:json)`, or an unknown/uncompiled module is rejected. A schema module
MUST be compiled before the workflow that references it.

```counter-example
agent("go", schema: "not a map")   # `agent` schema must be a literal map
```

**Rule 5.3.5 — Retries is a non-negative integer.** `retries:` MUST be an integer `>= 0`
(default `2`).

```counter-example
agent("go", schema: %{"type" => "object"}, retries: -1)   # must be a non-negative integer
```

**Rule 5.3.6 — Label is inert display metadata.** `label:` MUST be a string literal when
present. It is copied to the `%Agent{label: …}` field and to prompt-bearing agent event
payloads (§7.2), and has no semantic effect.

```counter-example
agent("go", label: :read_docs)   # `agent` label must be a string literal
```

**Rule 5.3.7 — Return value is a literal.** `return(value)` requires
`Macro.quoted_literal?(value)`.

```counter-example
return(compute())            # `return` expects a literal value
```

**Rule 5.3.8 — Synthesize inputs/prompt are literals.** `synthesize(inputs, prompt)`
requires `Macro.quoted_literal?(inputs)` and `is_binary(prompt)`.

```counter-example
synthesize(["a"], some_var)  # `synthesize` prompt must be a literal string
```

### 5.4 `parallel`, `pipeline`

**Rule 5.4.1 — Parallel needs at least one agent branch.** `branches` MUST be a non-empty
literal list; every element MUST resolve to an `%Agent{}`.

```counter-example
parallel([])                 # `parallel` requires at least one branch
```

```counter-example
parallel([log("x")])         # `parallel` branches must be `agent` turns
```

**Rule 5.4.2 — Pipeline needs items and agent stages.** `items` MUST be a non-empty
literal list; `stages` MUST be a non-empty literal list of `agent(…)` turns.

```counter-example
pipeline([], [agent("s")])   # `pipeline` requires at least one item
```

**Rule 5.4.3 — `max_concurrency` is a positive integer.** The only fan-out option is
`max_concurrency: <positive integer>`.

```counter-example
parallel([agent("a")], max_concurrency: 0)   # `max_concurrency` must be a positive integer
```

### 5.5 `verify`, `judge`

**Rule 5.5.1 — Verify subject is a literal.** The subject MUST satisfy
`Macro.quoted_literal?`.

```counter-example
verify(finding, voters: 3)   # `verify` subject must be a literal
```

**Rule 5.5.2 — Exactly one of `voters:`/`lenses:`.** Supply `voters: N` (positive integer)
XOR `lenses: [atoms…]` (non-empty list of atoms). Both or neither is rejected.

```counter-example
verify("f", voters: 3, lenses: [:a])   # takes either `voters:` or `lenses:`, not both
```

```counter-example
verify("f", threshold: :any)           # `verify` requires `voters: N` or `lenses: [...]`
```

**Rule 5.5.3 — Threshold in range.** `threshold:` (default `:majority`) MUST be one of
`:majority | :unanimous | :any`, or an integer `n` with `0 < n <= total`, where `total`
is the voter count (`n` for `{:voters, n}`; `length(lenses)` for `{:lenses, lenses}`).

```counter-example
verify("f", voters: 2, threshold: 5)   # `verify` threshold is out of range
```

**Rule 5.5.4 — Judge needs candidates, criteria, and a pick.** `candidates` MUST be a
non-empty literal list; `by:` MUST be a non-empty list of criterion atoms; `pick:` MUST be
`:max_score` or `:min_score`.

```counter-example
judge([], by: [:q], pick: :max_score)              # `judge` requires at least one candidate
```

```counter-example
judge(["a"], by: [:q], pick: :best)                # `judge` `pick:` is out of vocabulary
```

### 5.6 `collect` placement

**Rule 5.6.1 — `collect` is loop-body-only.** A top-level `collect` is rejected.

```counter-example
workflow "x" do
  collect(into: :items)      # `collect` must appear inside a loop body
  return(:ok)
end
```

**Rule 5.6.2 — `collect` takes exactly `into: :atom`.** Inside a body, `collect` MUST have
exactly the single option `into:` whose value is an atom.

```counter-example
until_dry rounds: 1 do
  agent("go", schema: %{"type" => "array"})
  collect(into: "items")     # `collect` `into:` must be an accumulator name (an atom)
end
```

### 5.7 Loops (`while_budget`, `until_dry`) and body vocabulary

**Rule 5.7.1 — A loop needs options and a `do` block.** The call MUST parse as
`[opts, [do: block]]` or `[[do: block]]`.

```counter-example
while_budget reserve: 8      # a loop requires options and a `do` block
```

**Rule 5.7.2 — Loop options are the allowed keys only.** `while_budget` keys ⊆
`[:reserve, :until, :max_iterations]`; `until_dry` keys ⊆
`[:rounds, :seen_by, :max_iterations]`.

```counter-example
while_budget reserve: 8, foo: 1 do
  agent("go")
end                          # invalid loop options
```

**Rule 5.7.3 — `reserve:` required (`>= 0`); `rounds:` required (`>= 1`).**

```counter-example
while_budget max_iterations: 10 do
  agent("go")
end                          # a loop requires `reserve:`
```

**Rule 5.7.4 — `max_iterations:` is a positive integer.** Optional; default `1000`.

```counter-example
until_dry rounds: 1, max_iterations: 0 do
  agent("go", schema: %{"type" => "array"})
  collect(into: :i)
end                          # `max_iterations` must be a positive integer
```

**Rule 5.7.5 — `seen_by:` is a list of atoms.** Optional; default `[]`. Never a function.

```counter-example
until_dry rounds: 1, seen_by: [1] do
  agent("go", schema: %{"type" => "array"})
  collect(into: :i)
end                          # `seen_by` must be a list of field names (atoms)
```

**Rule 5.7.6 — A loop body is non-empty and body-vocabulary only.** A body MUST contain at
least one node, drawn only from `[:agent, :log, :phase, :collect]`. `while_budget`,
`until_dry`, `parallel`, `pipeline`, `return`, `verify`, `judge`, `synthesize`, and
`fan_out` are rejected inside a body. **Loops therefore do not nest:** because the body
vocabulary excludes `while_budget` and `until_dry`, no loop body can contain another loop,
and there is no such thing as a nested loop body. Every loop is a top-level sibling
(relevant to phase-scope in Rule 5.10.1).

```counter-example
while_budget reserve: 8 do
  return(:ok)                # `return` is not allowed inside a loop body
end
```

**Rule 5.7.7 — `until_dry` body must `collect`.** An `until_dry` body MUST contain at least
one `collect`, because dryness is measured over what the body accumulates.

```counter-example
until_dry rounds: 2 do
  agent("go", schema: %{"type" => "array"})
end                          # `until_dry` body must `collect` into an accumulator
```

### 5.8 `fan_out`

**Rule 5.8.1 — `width:` is exactly `budget_slices(per: N)`.** REQUIRED; `N` a positive
integer. Any other form (arbitrary arithmetic, a bare integer) is rejected.

```counter-example
fan_out width: 4 do
  agent("go")
end                          # `fan_out` width must be `budget_slices(per: N)`
```

**Rule 5.8.2 — `fan_out` body is a non-empty agent lane.** Each body step MUST be an
`agent(…)` turn.

```counter-example
fan_out width: budget_slices(per: 10) do
  log("x")
end                          # `fan_out` body steps must be `agent` turns
```

### 5.9 `until:` predicate sub-vocabulary

**Rule 5.9.1 — Predicate operands and thresholds.** The left operand of a comparison MUST
be `count(<accumulator-atom>)` (where `<accumulator-atom>` is **any** atom, naming the
accumulator the body collects into — not a literal named `acc`) or `budget_remaining()`;
the right MUST be a literal integer; the operator MUST be one of `> < >= <= ==`.
`all_of`/`any_of` require at least one nested predicate. Anything else is rejected. (The
compiler does not require the accumulator atom to match a `collect(into:)` in the body; an
unmatched name resolves to an empty accumulator forever — see the note in §3.8.)

```counter-example
while_budget reserve: 0, until: count(:items) >= size() do
  agent("go", schema: %{"type" => "array"})
  collect(into: :items)
end                          # a predicate threshold must be a literal integer
```

### 5.10 Whole-DSL invariants (findings)

**Rule 5.10.1 — Phase names unique *per lexical scope*.** Phase-name uniqueness is
enforced **independently within each lexical scope**, not globally across the workflow. A
scope is either the **top-level statement list** or the body of **one individual loop**
(`while_budget` / `until_dry`). The compiler carries a **separate** seen-set per scope: the
top-level `build` starts a fresh set, and each loop body's `build_body` starts its own
fresh set. Because loops do **not** nest (Rule 5.7.6 — a loop body's vocabulary excludes
`while_budget`/`until_dry`), these scopes are always **siblings**: the single top-level
statement list plus each individual loop body, never one loop body inside another.
Consequently two `phase("p")` in the
**same** scope collide (rejected, located at the second declaration), but the **same** name
reused across scope boundaries — a top-level `phase("p")` and a loop-body `phase("p")`, or
two sibling loop bodies each with `phase("p")` — does **not** collide and is accepted.

```counter-example
workflow "x" do
  phase("p")
  phase("p")                 # duplicate phase name "p" — same (top-level) scope: REJECTED
  return(:ok)
end
```

```example
workflow "x" do
  phase("p")                 # top-level scope
  while_budget reserve: 8 do
    phase("p")               # loop-body scope — a DIFFERENT scope, so NOT a duplicate: ACCEPTED
    agent("go")
  end
  return(:ok)
end
```

**Rule 5.10.2 — A workflow MUST contain a `return`.** The top-level node list MUST contain
at least one `%Return{}`; otherwise a finding located at the workflow declaration line.
*(Dataflow §10 addendum: the implemented core widens this terminal rule so a final top-level
`emit` also satisfies it; see §10.7.)*

```counter-example
workflow "x" do
  phase("p")
  log("hi")                  # workflow must contain a `return`
end
```

**Rule 5.10.3 — The workflow name is a string literal.** `workflow name do … end` requires
`name` to be a string literal; a non-literal name raises directly.

```counter-example
workflow @name do            # workflow name must be a string literal
  return(:ok)
end
```

**Rule 5.10.4 — Duplicate keyword-option keys: first-occurrence wins, except where an exact
key-set is required.** An Elixir keyword list admits a **repeated** key, and a duplicated-key
list still satisfies `Macro.quoted_literal?` (§2.3) and every `keys ⊆ allowed-set` predicate
(Rules 5.3.2, 5.5.2, 5.7.2, 5.8.1, and the schema field-option Rule 5.11.3, which test only
membership, not uniqueness). The reference does **not** reject a repeated key at those
subset checks; it reads each option with Elixir's `Keyword.fetch/2`, which returns the
**first** occurrence. Therefore a repeated option key is **accepted** and the **first**
occurrence **wins**; later occurrences are silently ignored. This is pinned, observable
behavior — it fixes the resulting node's fields and thus the run and every read projection.
Examples (all compile):

- `agent("x", schema: A, schema: B)` → `%Agent{}` with schema `A`; `B` is ignored.
- `agent("x", schema: %{…}, retries: 1, retries: 2)` → `retries: 1`.
- `agent("x", label: "first", label: "second")` → `label: "first"`.
- `verify("f", voters: 1, voters: 3)` → `{:voters, 1}`.
- `judge(["a"], by: [:x], by: [:y], pick: :max_score)` → `by: [:x]`.
- `while_budget reserve: 4, reserve: 8 do agent("go") end` → `reserve: 4`.
- A schema field option `string(:f, required: false, required: true)` → `required: false`
  (§5.11.3).

**Exception — an option checked by exact key-set equality rejects a duplicate.** Two options
are validated with `Keyword.keys(opts) == [<key>]` rather than a subset predicate, so a
repeated key makes the key list unequal to the singleton and the option is **rejected**, not
first-won:

- `collect(into: :a, into: :b)` — `Keyword.keys` is `[:into, :into] != [:into]` → the finding
  `` `collect` takes exactly one option, `into: :name` `` (Rule 5.6.2).
- A `parallel`/`pipeline` options list with a repeated `max_concurrency:` — keys
  `!= [:max_concurrency]` → the finding `invalid fan-out options` (Rule 5.4.3).

A conforming implementation MUST reproduce **both**: first-occurrence-wins for the
subset-checked options, and rejection for the two exact-key-set options above.

```counter-example
collect(into: :a, into: :b)   # exact-key-set option: a repeated `into:` is rejected
```

### 5.11 Schema sub-DSL (`Workflow.Schema.DSL`) validation

The schema sub-DSL (§4.5) is its own closed vocabulary parsed by the plain function
`Workflow.Schema.Compiler.parse_object/2`. Like the workflow DSL's forbidden-form catalog
(§5.1), every out-of-vocabulary form **raises** a caller-located `Workflow.CompileError` at
`mix compile`; the rules below are decidable predicates over the schema-body AST, each with
the smallest violating (or, where noted, accepted) input. The builder vocabulary is exactly
`string`, `integer`, `number`, `boolean`, and `array` (scalar element types
`:string | :integer | :number | :boolean`, plus `of: :object` with a nested body).

**Rule 5.11.1 — Only the closed builder vocabulary.** A field form whose head is not one of
`string`/`integer`/`number`/`boolean`/`array` (in any accepted arity) raises `unknown schema
builder outside the field vocabulary`.

```counter-example
schema Bad do
  frobnicate(:x)             # unknown schema builder outside the field vocabulary
end
```

**Rule 5.11.2 — A field name is a literal atom or string.** A `ScalarField`/`ArrayField`
name that is not a literal atom or binary raises `a schema field name must be a literal atom
or string`.

```counter-example
schema Bad do
  string(some_var)           # a schema field name must be a literal atom or string
end
```

**Rule 5.11.3 — Field options are a keyword literal from the allowed keys.** A scalar
field's options MUST be a literal keyword list drawn from `[:required]`; an `array`'s from
`[:of, :required]`. Any other key or a non-keyword raises `invalid schema field options`
(or `schema field options must be a keyword list`). A **repeated** allowed key is accepted
and resolved **first-occurrence-wins** (the compiler reads each with `Keyword.fetch/2`), per
Rule 5.10.4 — e.g. `array(:xs, of: :string, of: :integer)` uses `of: :string`.

```counter-example
schema Bad do
  string(:f, bogus: 1)       # invalid schema field options
end
```

**Rule 5.11.4 — `required:` is a boolean literal.** When present, `required:` MUST be a
boolean literal; any non-boolean raises `` `required:` must be a boolean `` (a field is
required by default; opt out with `required: false`).

```counter-example
schema Bad do
  string(:f, required: 1)    # `required:` must be a boolean
end
```

**Rule 5.11.5 — `array` requires an `of:` item type.** An `array` field MUST supply `of:`.

```counter-example
schema Bad do
  array(:xs, [])             # `array xs` requires an `of:` item type
end
```

**Rule 5.11.6 — `of: :object` REQUIRES a `do` block; a scalar `of:` FORBIDS one.**
`array name, of: :object` MUST be paired with a `do … end` body (raising `` `array <name>,
of: :object` requires a `do` block `` otherwise), and a scalar `of:` (e.g. `of: :string`)
MUST NOT carry a `do` block (raising `` … does not take a `do` block ``). An `of:` value
outside `:object` and the four scalars raises `` `array <name>` has an unknown item type … ``.

```counter-example
schema Bad do
  array(:xs, of: :object)    # `array xs, of: :object` requires a `do` block
end
```

**Rule 5.11.7 — An empty nested-object body is valid (accepts to an empty object).** A
`schema` body (top-level or a nested `of: :object` body) MAY be empty; `parse_object`
of an empty body yields `%{"type" => "object", "properties" => %{}, "required" => []}`
(no fields, no required keys). This is accepted, not rejected.

```example
schema Empty do
end
# Empty.__schema__(:json) == %{"type" => "object", "properties" => %{}, "required" => []}
```

**Duplicate field names (pinned output — accepted, collapsed).** The sub-DSL does **not**
enforce field-name uniqueness. Declaring the same field twice is **valid** and produces a
pinned, observable map: `"properties"` is built with `Map.new`, so a repeated key collapses
to a **single** property whose value is the **last** declaration's type; but `"required"` is
built by a comprehension that does **not** dedup, so a repeated required field **appears
twice** in the `"required"` list, in declaration order.

```example
schema Dup do
  string(:f)
  string(:f)
end
# Dup.__schema__(:json) ==
#   %{"type" => "object",
#     "properties" => %{"f" => %{"type" => "string"}},   # one key (last wins)
#     "required" => ["f", "f"]}                            # NOT deduped
```

**String vs. atom field names produce the same property key (pinned).** A field name is
rendered to a property key by `Atom.to_string/1` for an atom and passed through unchanged
for a binary, so `string(:f)` and `string("f")` produce the **identical** property key
`"f"` (and would collapse per the duplicate-field rule above if both appear). Authors MUST
treat an atom field name and the equivalent string field name as the same field.

---

## 6. Execution (dynamic semantics)

A valid `%Tree{}` is executed by a single **live writer** process. Execution is a walk over
the tree that commits journal events; **resume is a pure fold** over the journal, carrying
no runtime state across process death. Algorithms below are function-style; every path
returns a result tuple or raises a defined error.

### 6.1 The error model (pinned)

The execution error model is **abort-on-fail-closed at the run boundary, with journaled
partial progress**:

- **Success** yields `{:ok, run_id}` and a terminal `run_completed` event carrying the
  `return` value (or `nil` if no `return` executed — though §5.10.2 guarantees one exists).
- **A fail-closed node** (a schema-backed agent whose output never validates within its
  retry budget) commits an `agent_failed` event, halts the entire run, and yields
  `{:error, {:malformed_output, address, reason}}`. There is **no** `run_completed` on the
  fail path. The run **aborts**; it does not skip the node or continue. For a **top-level**
  fail-closed node the `agent_failed` is genuinely terminal — the last event in the journal.
- **Concurrent regions are partial-commit then abort.** In `parallel`, `pipeline`,
  `verify`, `judge`, and `fan_out`, every lane's events are committed in input order —
  **including the events of a failed lane** — and the **first** failure reason (in input
  order) becomes the run's halt reason. A failed voter or scorer fails its whole panel.
  Inside such a region `agent_failed` is **not** necessarily the last event in `seq` order:
  a later lane (committed after the first failing one, still in input order) may contribute
  its own `agent_committed` or `agent_failed` **after** the first `agent_failed`. Two
  distinct projections of the failure exist, and **they deliberately differ** when 2+ lanes
  in one region fail:

  - The **fresh run's returned halt reason** — the tuple the *initial* `run` call returns
    (the writer's `{:halt, reason}`, §6.2 `RunTree`) — is the **first** failing lane's
    reason in input order, because `CommitLanes`/`CommitLanesWithResults` keep
    `failure || reason` (§6.9).
  - The **Status fold's `failure`** (§7.3) is the **last** `agent_failed` in `seq` order,
    because the fold overwrites `failure`/`state` on **every** `agent_failed` with **no**
    state guard (last-wins). Every read surface derived from the fold — `status`, `inspect`,
    and the `:failed` short-circuit branch of a **resume** (§6.2 `ExecuteRun`, which returns
    `status.failure`) — therefore reports the **last** failure.

  The two coincide when exactly one lane fails (last equals first). When 2+ lanes in the
  same region fail they diverge: the initial `run` returns the **first** reason, while any
  later resume/status projection returns the **last** — so a resume of an already-`:failed`
  multi-failure run does **not** reproduce the exact tuple the initial `run` returned. This
  is a deliberate, pinned consequence of the last-wins Status fold; it is the one place the
  returned run-result tuple is **not** a faithful replay of the initial outcome, and it
  narrows C4's "resume replays journaled decisions" for the multi-failure case (§7.3, §8
  C4). Still, **no** `run_completed` is ever written on the fail path, and both projections
  name a genuine failing lane in the same region, so the run's terminal disposition
  (`:failed` at a real address, exit 8) is identical across all reads.
- **An off-thread provider crash inside a concurrent region is a run crash, not a lane
  failure.** In `parallel`/`pipeline`/`verify`/`judge`/`fan_out` the provider call runs
  off-thread inside `BuildAgent`/`RunLane`/`ScoreLane`, whose result contract is only
  `{:ok, …}` or the schema-`{:failed, …}` lane result (§6.9). A **provider-level** crash —
  `CallProvider` returning a non-`{:ok, output, usage}` shape or raising (§6.4.1) — is
  **not** a schema `{:failed, …}`: it is not caught and converted, it **propagates** off the
  lane task and **crashes the live writer**, exactly as a top-level provider crash does.
  Because the region commits nothing until every lane result is gathered and `CommitLanes`
  runs (§6.9), **no** events of that region are committed when a lane crashes — the region's
  `*_started` marker may already be in the journal, but **none** of the region's lane
  `agent_committed`/`agent_attempt_rejected`/`agent_failed` events and **no** `*_settled` /
  `*_completed` marker are written. The caller observes `{:error, {:run_crashed, reason}}`
  (no `run_completed`). This is distinct from a schema `{:failed, …}` lane, which **is**
  committed (its events land, first-in-input-order reason becomes the halt) and yields
  `{:malformed_output, address, reason}` (exit 8) — a provider crash yields `run_crashed`
  (exit 1, or 130 when `reason` is `:killed`).
- **A crash** (writer process death) surfaces to the caller as
  `{:error, {:run_crashed, reason}}` via a process monitor; `:killed` maps to a distinct
  exit (§7).
- **A held lease** (another live writer owns the run's single-writer lease, §6.2.1) yields
  `{:error, {:already_running, pid}}`.

Errors never propagate as partial *success*: there is no data-plus-errors result. A run is
either completed (with a value) or halted (at a specific node address).

### 6.2 Entry and resume

```
ExecuteRun(run_id, tree, provider, budget, script_path):
  - Let {prior} be Journal.Fold(run_id).
  - Let {status} be Status.of(prior, run_id).       ; = Workflow.Status.of, §7.3
  - If {status.state} is `:completed`:
    - Return {:ok, run_id}.            ; no fresh run_started, no re-run
  - If {status.state} is `:failed`:
    - Return {:error, {:malformed_output, status.failure.address, status.failure.reason}}.
      ; status.failure is the LAST agent_failed (last-wins fold, §7.3); for a single-failure
      ; run this equals the first, but for a 2+-lane failure it is the LAST failing lane —
      ; a resume therefore returns a DIFFERENT tuple than the initial run did (§6.1, §7.3).
  - Return {RunTree(run_id, tree, provider, budget, script_path, prior)}.
```

```
RunTree(run_id, tree, provider, budget, script_path, prior):
  - Let {seq} be Journal.LastSeq(run_id) + 1.
  - If {prior} is empty:
    - Commit Event.run_started(tree, budget, script_path); advance {seq}.
  - Let {ctx} be {seq: seq, return: nil, last_result: nil, iteration: 0, seen_by: []}.
  - Let {outcome} be RunNodes(tree.nodes, run_id, provider, prior, ctx).
  - If {outcome} is {:cont, ctx'}:
    - Commit Event.run_completed(ctx'.return).
    - Return {:ok, run_id}.
  - If {outcome} is {:halt, _ctx, reason}:
    - Return {:error, reason}.         ; terminal agent_failed already journaled
```

`Journal.Fold(run_id)` returns every event for `run_id` in `seq` ascending (commit) order —
**the** ordering; there is no wall-clock. `Journal.LastSeq(run_id)` returns the greatest
committed `seq` for `run_id`, or **`-1`** when the journal is empty; so `Journal.LastSeq(run_id)
+ 1` yields the next `seq` to assign — `0` on a fresh run, which is why the canonical minimal
run occupies contiguous `seq` `0..4` (§7.2). `Status.of` is the pure read-model reducer
(the `Workflow.Status.of` defined in §7.3). A fresh `run_started` is committed only when
`prior` is empty; a resume appends no new `run_started`.

**The `Commit` primitive, traversal cursor, and serialized append boundary (normative).**
`Journal.LastSeq(run_id) + 1` is consulted in `RunTree` to seed the writer's `ctx.seq`
cursor. That cursor is the writer's semantic traversal cursor: it is threaded through the
walk, preserves source-order decisions, and lets positional/idempotent helpers know where the
next writer-owned commit is expected to land if no progress telemetry interleaves.

The journal append boundary is the authoritative physical `seq` allocator. Every event that
is actually committed during a live run — simple commits (`run_started`, `run_completed`,
`phase_entered`, `log_emitted`, `agent_committed`, `agent_attempt_rejected`, `agent_failed`,
`accumulate`, `iteration_started`, `loop_decision`, `loop_completed`), region marker/lane
commits (via `CommitMarker` §6.3, `CommitAll` §6.9), and `agent_activity` progress telemetry
— is appended through the serialized journal allocator. The allocator stamps the event with
the next available `seq` at append time, so progress telemetry emitted while the writer is
blocked inside a provider turn or waiting for concurrent lanes can interleave without
colliding with later settled events:

```
Commit(event, ctx):
  - Append {event} through Journal.AppendNext(run_id, event), which stamps run_id and the
    next available seq inside the serialized journal process.
  - Return {ctx with seq = max(ctx.seq, stamped_event.seq + 1)}.
```

Wherever a §6 algorithm says "Commit `Event.…`", the operation is `Commit`, and the returned
advanced cursor MUST be threaded into the `ctx` that algorithm returns. `CommitMarker` and
`CommitAll` are the same discipline expressed with an explicit lower-bound cursor
argument/return instead of the whole `ctx`: a caller holding the cursor as `ctx.seq` passes
`ctx.seq` in and writes the returned cursor back into `ctx.seq`. Consequently the produced
physical `seq` values are **contiguous** across the whole run (§7.2), even when progress
telemetry lands between a provider call starting and its eventual settled event.

This allocation rule does not change workflow decisions: `agent_activity` is progress-only
read-model data, while the writer still controls semantic traversal/order and positional
marker/idempotency. To make crash/replay safe, `agent_activity` is idempotent by
`(address, iteration, attempt, activity_index)`; appending the same key again returns the
already-journaled event instead of writing a duplicate. Distinct repeated activity entries
MUST use distinct `activity_index` values and therefore remain visible even if their
`kind`/`label`/`summary`/`status` fields are byte-identical.

**Resume recompiles the tree (no identity check).** The inert `%Tree{}` is **not** carried
across process death; a resume is handed a tree **recompiled from the (mutable) workflow
script** — from the journaled `run_started.script_path`, or an explicitly passed path (§7.6).
The reference performs **no** structural comparison between that recompiled tree and the tree
the journaled, address-keyed events were written against: `ExecuteRun` folds the journal,
short-circuits on a terminal `:completed`/`:failed` fold (above), and otherwise runs the
recompiled tree directly through `RunTree`. Journaled **decisions** (committed agent turns,
`loop_decision`, `fan_out_started.width`, panel settlements) are still replayed by address
rather than recomputed (Principle 3). But resume is address-safe **only to the extent the
script file is unchanged**: if the script was edited between the original run and the resume (a
single inserted top-level statement shifts every subsequent `[i]` address, §4.2), the
recompiled tree may not line up with the journaled events, and the reference does **not**
detect this. Operators MUST resume against the same script the run was started with. (A
structural tree-identity check that rejects a divergent script — journaling a fingerprint in
`run_started` and comparing it on resume — is a plausible future hardening; it is **not**
implemented and is **not** required for conformance.)

**Resume with no resolvable script path.** Because `:script_path` is OPTIONAL (§7.6), a run
started programmatically from a `%Tree{}` may journal `run_started.script_path == nil`.
A resume that must recompile from a script — i.e. one handed only a `run_id`, not a
`%Tree{}`/module — resolves its source as **the explicitly passed path, else the journaled
`run_started.script_path`**. If **neither** is available (no explicit path and a `nil`
journaled `script_path`), there is nothing to recompile: resume MUST NOT start a writer and
returns `{:error, {:no_script_path, run_id}}` ⇒ exit 2 (`:usage`, §7.5). (Such a run remains
resumable by re-invoking the run API with the original `%Tree{}`/module and the same
`:run_id`, §7.6 — that path carries the tree directly and needs no script to recompile.)

`RunNodes` reduces over the node list, threading `ctx`, short-circuiting on the first
`{:halt, ctx, reason}`; otherwise returning `{:cont, ctx}`.

### 6.2.1 The single-writer lease

`ExecuteRun`/`RunTree` run only while the caller holds a **single-writer lease** for
`run_id`. The lease is a **process registration**, not a stored record: the live writer
registers under a unique name `Lease(run_id)` in a process registry keyed by `run_id`, and
the registry **monitors** the writer and releases the name the instant the writer process
exits (normally or by crash).

```
AcquireLease(run_id):
  - Attempt to start the writer process registered under the name Lease(run_id).
  - If the name is already registered by a live process {pid}:
    - Return {:error, {:already_running, pid}}.       ; a second live writer is refused
  - Otherwise the writer starts holding the lease; Return {:ok, writer}.
```

Consequences a conforming implementation MUST preserve:

- **At most one live writer per run.** Acquisition is atomic in the registry: two concurrent
  attempts for the same `run_id` — the exact `{:already_running, pid}` counter-case — resolve
  to exactly one winner; the loser gets `{:error, {:already_running, pid}}` (§6.1, §7.4),
  which maps to exit 1 (§7.5). The winner runs `ExecuteRun`; the loser does nothing.
- **The lease is held for the whole run and released on exit.** It is acquired **before**
  the first effect (the writer idles until told to begin, so the caller's crash monitor is
  in place before any `CallProvider`), and released automatically when the writer process
  dies — there is **no** explicit unlock, **no** heartbeat, and **no** stored lock row.
- **Resume needs no stale-lease takeover.** Because the registry releases the lease the
  moment the previous writer dies, a crashed or completed run leaves the lease **free**. A
  `resume` therefore just calls `AcquireLease` again: if no live writer holds `run_id` it
  acquires cleanly and folds the journal (§6.2); if a writer *is* still alive it correctly
  gets `{:already_running, pid}`. There is no timeout-based staleness rule to tune — liveness
  is the OS-level liveness of the writer process, observed by the registry monitor. (An
  implementation on a substrate without process monitors MAY instead use a stored lease with
  a liveness probe, provided the **observable** outcomes are identical: at most one live
  writer, `{:already_running, pid}` when one exists, and a free lease once it exits.)

### 6.3 Per-node dispatch

`RunNode(node, run_id, provider, prior, ctx)` returns `{:cont, ctx}` or
`{:halt, ctx, reason}`, by node kind:

- **`Phase`** — `Let {seq} be CommitMarker(phase_entered, node, prior, ctx.seq)` (payload
  `%{address, name}`); return `{:cont, ctx with seq = seq}`.
- **`Log`** — `Let {seq} be CommitMarker(log_emitted, node, prior, ctx.seq)` (payload
  `%{address, message}`); no wall-clock, no interpolation; return `{:cont, ctx with seq = seq}`.
- **`Return`** — set `ctx.return = node.value`; commit **no** event; return `{:cont, ctx}`
  (the `seq` cursor is unchanged — `return` writes nothing).
  `return` does **NOT** halt execution: it returns `{:cont, …}` like every other simple
  statement, so **every top-level statement after a `return` still runs**. With multiple
  `return`s, each overwrites `ctx.return`, so the **last executed** `return` supplies the
  terminal `run_completed.value` (§6.2). There is no early-termination or conditional
  combinator in the vocabulary, so early/conditional termination is **not expressible** — a
  workflow that must end with a given value MUST place that `return` **last**. Example:
  `agent("a"); return(:early); agent("b"); return(:late)` runs both agents and completes
  with value `:late`, not `:early`.
  *(Dataflow §10 addendum: the current compiler enforces terminal-final placement for top-level
  `return` and `emit`; a top-level node after either terminal is rejected. The base last-wins
  model remains historical context for §1–§8; see §10.7.)*
- **`Agent`** — see RunAgent (§6.4).
- **`Collect`** — see RunCollect (§6.6).
- **`WhileBudget`** / **`UntilDry`** — Loop (§6.7), entered at `iteration = 0`:
  `WhileBudget → Loop(node, [], run_id, provider, prior, ctx, 0)` and
  `UntilDry → Loop(node, node.seen_by, run_id, provider, prior, ctx, 0)`.
- **`Parallel`** / **`Pipeline`** / **`Verify`** / **`Judge`** / **`FanOut`** — the
  concurrent-region algorithms (§6.8–6.10).
- **`Synthesize`** — construct an ephemeral `%Agent{address: node.address, prompt:
  "<prompt>\n\nInputs: <inspect(inputs)>", schema: nil, retries: 0}` and delegate to
  RunAgent, reusing the ordinary journaled/keyed/resumable agent path.

Structural markers are **positional** — reused verbatim on resume if already journaled,
otherwise committed. They key on one of two tuples:

- **Positional markers** (`phase_entered`, `log_emitted`, and every region/boundary marker:
  `parallel_started`/`parallel_completed`, `pipeline_started`/`pipeline_completed`,
  `verify_started`/`verify_settled`, `judge_started`/`judge_settled`,
  `fan_out_started`/`fan_out_completed`, `loop_completed`) are keyed by `(type, address)` and
  are committed **at most once per address**. On resume, if a marker with that
  `(type, address)` is already journaled it is reused verbatim and not re-committed.
- **The iteration marker** (`iteration_started`) is the **only** body marker keyed by
  `(type, address, iteration)`: it sits at the loop body's boundary and commits a distinct
  event each pass (one per iteration `0, 1, 2, …`), via `IterationMarker` (§6.7).

Every positional marker in §6.9–§6.10 — including the region **start** markers
(`parallel_started`, `pipeline_started`, `verify_started`, `judge_started`,
`fan_out_started`) and the region **settle/complete** markers (`parallel_completed`,
`pipeline_completed`, `verify_settled`, `judge_settled`, `fan_out_completed`,
`loop_completed`) — is committed through `CommitMarker`, which enforces the at-most-once
`(type, address)` idempotency on resume:

```
CommitMarker(type, node, prior, seq):
  - If an event of {type} with payload.address == node.address is in {prior}:
    - Return {seq}.                          ; already journaled — reuse verbatim, commit nothing
  - Commit the {type} event for {node} through the serialized append boundary;
    Return max(seq, stamped_event.seq + 1).
```

This is why a region resumed after a mid-region crash (§6.9) reproduces **exactly** the
crash-free journal: the `*_settled` / `*_completed` marker is written **at most once per
address**, so a resumed run never appends a duplicate settle event and the Status fold
(§7.3), which appends a fresh `verifications`/`judgments` entry on each such event, stays
identical to the crash-free fold (C4, §8). Wherever §6.9–§6.10 say "commit
Event.`verify_settled`(…)" (or any other start/settle/complete marker) the operation is
`CommitMarker` — an implementation MUST NOT unconditionally re-commit a region marker on
resume.

A consequence of keying `phase_entered`/`log_emitted` by `(type, address)`: a `phase`/`log`
**inside a loop body** has one fixed address, so it commits **exactly once for the whole
loop** — on the first iteration that reaches it — and is skipped on every later iteration
(its `(type, address)` is already journaled). This is intentional and observable: `Status`
sees one such marker per body address regardless of iteration count, and a resumed journal
reproduces it identically because the key does not depend on iteration. An implementation
MUST NOT re-emit a body `phase`/`log` per iteration, and MUST NOT key `iteration_started` by
`(type, address)` alone (doing so would collapse all iterations to one and drop the
per-pass boundary the loop fold relies on).

Each agent turn is **independent**: no shared conversation, thread, or prior-result context
flows from one node to the next. `CallProvider` (§6.4.1) receives only this node's literal
`prompt`, `schema`, and idempotency `key` — never earlier agents' outputs. "On-thread
retry" (§1.3, §6.4) means only that a **single** node's fail-closed retries reuse the same
node/iteration identity (Principle 4, §1.3); it does **not** mean turns share a
conversation. Authors MUST make every prompt self-contained.

### 6.4 Agent turn and exactly-once resolution

```
RunAgent(node, run_id, provider, prior, ctx):
  - Let {iteration} be ctx.iteration.
  - Let {outcome} be ResolveIdempotency(prior, node.address, iteration).
  - If {outcome} is {:committed, result, _usage}:
    - Return {:cont, ctx with last_result = result}.        ; replay, never re-run
  - If {outcome} is {:failed, reason}:
    - Return {:halt, ctx, {:malformed_output, node.address, reason}}.
  - If {outcome} is {:resume, next}:
    - Return CommitAttempt(node, run_id, provider, iteration, next, ctx).
  - If {outcome} is `:none`:
    - Return CommitAttempt(node, run_id, provider, iteration, 0, ctx).
```

```
ResolveIdempotency(events, node_path, iteration):
  - Let {ours} be the events whose payload has address == node_path and iteration == iteration.
  - If an `agent_committed` is in {ours}: Return {:committed, its result, its usage}.
  - If an `agent_failed` is in {ours}: Return {:failed, its reason}.
  - Let {r} be the count of `agent_attempt_rejected` in {ours}.
  - If {r} > 0: Return {:resume, r}.
  - Return `:none`.
```

```
CommitAttempt(node, run_id, provider, iteration, attempt, ctx):
  - Let {key} be IdempotencyKey(run_id, node.address, iteration, attempt).
  - Let {output, usage, activity} be CallProvider(provider, node.prompt, node.schema, key).  ; §6.4.1
  - If {node.schema} is nil:                                 ; schemaless
    - Let {ctx} be Commit(Event.agent_committed(node, iteration, key, output, usage, activity), ctx).
    - Return {:cont, ctx with last_result = output}.
  - Let {v} be Schema.Validate(node.schema, output).         ; schema-bound
  - If {v} is {:ok, validated}:
    - Let {ctx} be Commit(Event.agent_committed(node, iteration, key, validated, usage, activity), ctx).
    - Return {:cont, ctx with last_result = validated}.
  - Let {ctx} be Commit(Event.agent_attempt_rejected(node, iteration, attempt, output, reason, usage, activity), ctx).
  - If {attempt} < node.retries:
    - Return CommitAttempt(node, run_id, provider, iteration, attempt + 1, ctx).  ; recurse with the advanced cursor
  - Let {ctx} be Commit(Event.agent_failed(node, iteration, attempt + 1, reason), ctx).
  - Return {:halt, ctx, {:malformed_output, node.address, reason}}.
```

Each paid attempt is committed **incrementally** — a rejection lands in the journal before
the next paid provider call — so a crash mid-retry resumes at the first un-journaled
attempt. The provider is called as `provider.run_agent(prompt, schema, key, opts)` with the
idempotency `key`; a conforming backend MUST use `key` as its request-idempotency key so a
re-issued request after a lost commit returns the already-produced result **without
charging again** (money spent at most once, result never dropped).

### 6.4.1 CallProvider (the provider port)

A provider is a pair `{module, opts}`. `CallProvider` is the single seam between the
deterministic runner and a non-deterministic backend:

```
CallProvider({module, opts}, prompt, schema, key):
  - Return module.run_agent(prompt, schema, key, opts).
```

- **Inputs.** `prompt :: String.t()` (this node's literal prompt — never a splice of any
  other node's output), `schema :: map() | nil` (the node's JSON-schema map, or `nil` for a
  schemaless turn), `key :: IdempotencyKey` (§6.5), and the backend-specific `opts`.
- **Success return.** A conforming backend MUST return either `{:ok, result, usage}` or
  `{:ok, result, usage, activity}`. `result` is the decoded provider output (`term()`; for a
  schema-bound turn a decoded JSON value — a map, list, or scalar), `usage` is a
  `%Usage{input_tokens, output_tokens, total_tokens}` of non-negative integers, and
  `activity` is an ordered list of maps describing provider progress (§7.2). The three-tuple
  form is normalized to the four-tuple form with `activity == []`. The runner
  **hard-matches** one of these success shapes: `CallProvider` returning any other shape (an
  `{:error, …}` tuple, a network failure, a raised exception) is **not** a
  schema-validation failure and is **not** retried. It crashes the live writer, which the
  caller observes via its monitor as `{:error, {:run_crashed, reason}}` (§6.1, §7.4) —
  mapped to exit 1 (or exit 130 when `reason` is `:killed`) per §7.5. Fail-closed retry
  (§6.4) applies **only** to a successful call whose `output` fails `Schema.Validate`; a
  provider-level failure is a crash, not a retry.
- **Activity sink.** The runner MAY add `activity_sink: (map() -> :ok)` to `opts`. A
  backend that receives it MAY call it for non-terminal progress while the turn is running.
  The runner journals each sink call as `agent_activity` with the next local
  `activity_index`; the backend's terminal `activity` list is reconciled to those indices
  before `agent_committed` / `agent_attempt_rejected` is written. The activity sink is
  progress telemetry only: it does not change validation, retry, idempotency keys, or
  workflow results.
- **Codex `--output-schema` strictness.** The Codex provider passes a schema-backed turn's
  schema to the CLI with `--output-schema`. Before writing that temporary schema file, it
  normalizes every object schema recursively to force `"additionalProperties" => false`,
  overriding any author-supplied value. This provider-port normalization is for Codex/OpenAI
  structured-output strictness; it does not mutate `%Agent{schema}` in the inert tree, and
  the writer still validates the returned value against the original schema map.
- **Turn independence.** Because `CallProvider` receives only `(prompt, schema, key,
  opts)`, no conversation state, thread, or prior result is carried between turns. Every
  agent turn is independent; all context an agent needs MUST be present in its own literal
  prompt (Principle 6). A backend MUST use `key` as its request-idempotency key so a
  re-issued request after a lost commit returns the already-produced `result` without
  charging again.
  *(Proposed §10 — dataflow: a proposed extension would widen the `prompt` input and this Turn-independence clause to §6.4.1′, admitting a deterministically-rendered template materialized to a `String.t()` by a pure journal fold before the call; `CallProvider`'s `(prompt, schema, key, opts)` signature is unchanged; see §10.)*

**Provider-port callbacks.** A provider module has two callbacks:

| callback | signature | required? | when called |
|---|---|---|---|
| `c:run_agent/4` | `run_agent(prompt, schema, key, opts) -> {:ok, result, usage} \| {:ok, result, usage, activity}` | **REQUIRED** | once per paid attempt (§6.4) |
| `c:validate_config/1` | `validate_config(opts) -> :ok \| {:error, reason}` | OPTIONAL | once, **pre-run**, during `ResolveProvider` |

**Provider resolution (pre-run gate, exit 4).** Before the run starts — before
`AcquireLease` and the first `run_started` commit — the invocation entry point (§7.6)
resolves the `{module, opts}` pair exactly once:

```
ResolveProvider({module, opts}):
  - If {module} does not export run_agent/4:
    - Return {:error, {:provider_config, {:not_a_provider, module}}}.
  - If {module} exports validate_config/1:
    - Let {r} be module.validate_config(opts).
    - If {r} is {:error, reason}: Return {:error, {:provider_config, reason}}.
  - Return {:ok, {module, opts}}.        ; a resolved provider proceeds to RunTree
```

The two failure classes are **disjoint and pinned**:

- **Pre-run (`{:error, {:provider_config, reason}}` ⇒ exit 4, §7.5).** `ResolveProvider`
  fails: the module is not loaded / does not export `run_agent/4` (`{:not_a_provider,
  module}`), **or** an implemented `validate_config/1` returns `{:error, reason}` (required
  configuration — an API key, endpoint, model id — is absent or invalid). No `run_started`
  is committed; no lease is taken. A provider with **no** `validate_config/1` is treated as
  `:ok` at this gate (it can only fail later, at call time).
- **Call-time (`{:error, {:run_crashed, reason}}` ⇒ exit 1, or 130 when `reason` is
  `:killed`).** A provider that **resolved** but whose `run_agent/4` later returns a non-
  `{:ok, result, usage}` shape or raises (§6.4.1, "Success return"). This crashes the live
  writer mid-run and is **never** an exit-4 `provider-config` failure.

An **absent or `nil`** `:provider` option is neither of the above: it is a caller misuse of
the run API (a missing REQUIRED option, §7.6), reported as `{:error, {:usage, :provider}}`
⇒ exit 2 (`:usage`, §7.5), **before** `ResolveProvider` is reached.

### 6.4.2 Schema.Validate (the fail-closed gate)

`Schema.Validate(schema, value)` is the pure predicate that decides whether a schema-bound
agent's decoded output may proceed. It returns `{:ok, value}` (accept — the value is passed
through unchanged) or `{:error, reason}` (reject — journaled in
`agent_attempt_rejected.reason` and, on exhaustion, `agent_failed.reason`). It reads no
clock and no external state; it operates on already-decoded terms (the provider adapter
owns JSON decoding).

It supports exactly the JSON-Schema subset structured outputs use. `Validate` dispatches on
the schema's `"type"` string; the supported keywords, their accept predicates, and their
rejection reasons are:

| `schema["type"]` | Accept when | Reject reason on mismatch |
|---|---|---|
| `"object"` | `value` is a map that passes the `required`/`properties` checks below | see below |
| `"string"` | `value` is a UTF-8 binary | `{:expected_string, value}` |
| `"integer"` | `value` is an integer | `{:expected_integer, value}` |
| `"number"` | `value` is a number **and not a boolean** | `{:expected_number, value}` |
| `"boolean"` | `value` is `true` or `false` | `{:expected_boolean, value}` |
| `"array"` | `value` is a list; if `"items"` is present, every element validates against it | `{:expected_array, value}` or `{:item, <element reason>}` |
| any other / absent `"type"` | **always accept** (`{:ok, value}`) | — |

Two non-obvious rules a conforming implementation MUST honor:

1. **Unrecognized type ⇒ accept.** A schema whose `"type"` is not one of the six above (or
   has no `"type"` key) validates **permissively** — `Validate` returns `{:ok, value}`
   without inspecting `value`. This keeps forward-compatible schemas from rejecting.
   **Dispatch is on the *string* key `schema["type"]`.** A schema map written with atom keys
   (`%{type: "object", …}`) therefore has `schema["type"] == nil` and falls into this
   accept-all branch, so **all** output is accepted and fail-closed validation silently
   no-ops. Inline schema maps MUST use string keys (§3.2); a conforming implementation
   SHOULD warn at compile time when a literal schema map's top-level `"type"` string key is
   absent.
2. **A boolean is not a number.** `"number"` (and `"integer"`) MUST reject `true`/`false`
   even though some languages treat booleans as numeric. `"number"` accepts any integer or
   float; `"integer"` accepts integers only.

```
Schema.Validate(schema, value):
  - If schema["type"] is "object":
    - If value is not a map: Return {:error, {:expected_object, value}}.
    - Let {required} be schema["required"] (default []).
    - Let {missing} be the first key in {required} not present in value (in list order).
    - If {missing} exists: Return {:error, {:missing_required, missing}}.
    - For each {key, sub} in schema["properties"] (default {}), in the map's iteration order:
      - If value has {key}:
        - Let {r} be Schema.Validate(sub, value[key]).
        - If {r} is {:error, reason}: Return {:error, {:property, key, reason}}.
      - Else: continue.                 ; an absent optional property is `required`'s concern, not a type error
    - Return {:ok, value}.
  - If schema["type"] is "string":  If value is a binary, Return {:ok, value}; else {:error, {:expected_string, value}}.
  - If schema["type"] is "integer": If value is an integer, Return {:ok, value}; else {:error, {:expected_integer, value}}.
  - If schema["type"] is "number":  If value is a number and not a boolean, Return {:ok, value}; else {:error, {:expected_number, value}}.
  - If schema["type"] is "boolean": If value is true or false, Return {:ok, value}; else {:error, {:expected_boolean, value}}.
  - If schema["type"] is "array":
    - If value is not a list: Return {:error, {:expected_array, value}}.
    - If schema has no "items": Return {:ok, value}.
    - For each {element} in value, in order:
      - Let {r} be Schema.Validate(schema["items"], element).
      - If {r} is {:error, reason}: Return {:error, {:item, reason}}.
    - Return {:ok, value}.
  - Return {:ok, value}.               ; unrecognized/absent type ⇒ permissive accept
```

**Reason terms.** The `reason` journaled in `agent_attempt_rejected.reason` /
`agent_failed.reason` is exactly one of: `{:missing_required, key}`, `{:property, key,
reason}` (nested), `{:expected_object, value}`, `{:expected_string, value}`,
`{:expected_integer, value}`, `{:expected_number, value}`, `{:expected_boolean, value}`,
`{:expected_array, value}`, or `{:item, reason}` (nested). Object and array reasons nest, so
a rejection points at the exact offending field or element (e.g. `{:property, "verdict",
{:expected_boolean, 1}}`). Validation stops at the **first** failing `required` key (in the
`"required"` list's order), then the **first** failing property **in the `"properties"`
map's iteration order** (the order the algorithm's `For each {key, sub} in
schema["properties"]` step visits — see the host-scoped clause below), then the first
failing array element (in list order) — a `reason` names a single defect, not a list.

**Property-check order (host-scoped, like `inspect/1` in §4.4).** `"properties"` is a
literal map, which does **not** preserve declaration order; the reference iterates it with
`Enum.reduce_while/3`, i.e. in the Elixir map's **iteration order** (for the Elixir
embedding, Erlang term order of the keys). When **two or more** properties both fail, which
one's `reason` is journaled is therefore fixed by this map-iteration order — **not** by the
schema's as-written declaration order. Because `reason` is observable output
(`agent_attempt_rejected.reason` / `agent_failed.reason`, §7.2), the property-check order is
**byte-normative only for the Elixir embedding** (all conforming Elixir implementations
iterate the same map identically and journal the same `reason`). For a non-Elixir host the
exact property-check order is **implementation-defined but MUST be stable** for a given
schema map (deterministic across runs and across resume). Authors who need a specific
which-field-fails-first guarantee MUST make at most one property fail per output.

### 6.5 The exactly-once key

```
IdempotencyKey = %{run_id, node_path :: address, iteration :: non_neg_integer, attempt :: non_neg_integer}
```

- The **logical** exactly-once identity of a paid effect is `(run_id, node_path,
  iteration)`.
- `iteration` is `0` for any node outside a dynamic loop; inside `while_budget`/`until_dry`
  it is the real per-iteration index, so the same body address keys a **distinct** paid
  effect each pass.
- `attempt` (zero-based) refines the logical identity into a single **physical** provider
  request, so each fail-closed retry reaches the backend under a distinct request key.

### 6.6 Collect (declared reduction, loop-body only)

```
RunCollect(node, run_id, prior, ctx):
  - If an `accumulate` for (node.address, ctx.iteration) is in {prior}:
    - Return {:cont, ctx}.                                   ; replay / never double-count
  - Let {harvest} be Wrap(ctx.last_result).
  - Let {current} be the current items of accumulator {node.into}.
  - Let {added} be Accumulator.NewItems(current, harvest, ctx.seen_by).   ; dedup by seen_by
  - Let {ctx} be Commit(Event.accumulate(node, ctx.iteration, ctx.seen_by, added,
                            length(current) + length(added)), ctx).
  - Return {:cont, ctx}.

Wrap(last_result):
  - If {last_result} is nil:  Return the empty list [].       ; no preceding agent this pass
  - If {last_result} is a list: Return {last_result}.         ; each element becomes one item
  - Return the one-element list [{last_result}].              ; a scalar/map becomes a single item
```

`Wrap` is the harvest-shaping rule (the reference implements it with Elixir's `List.wrap/1`,
but its three cases are pinned here so a non-Elixir host reproduces them exactly). It is
**load-bearing**: whether a single agent result becomes one item or is spread element by
element decides accumulation, dedup, dryness, and every `count(:acc)` predicate. Worked
cases:

- **Array-schema agent** (`schema: %{"type" => "array"}`) whose validated result is
  `[%{"id" => 1}, %{"id" => 2}]` → `Wrap` returns that list, harvesting **two** items.
- **Object-schema agent** whose validated result is `%{"id" => 1}` → `Wrap` returns
  `[%{"id" => 1}]`, harvesting **one** item (the whole map).
- **No preceding agent this pass** (e.g. `ctx.last_result` is `nil` because the body's only
  prior node was a `phase`/`log`) → `Wrap` returns `[]`, harvesting **nothing** — the round
  contributes zero items and counts as dry for `DryStreak` (§6.7).

`collect` harvests the current iteration's most recent agent result into the named
accumulator, deduplicating against fields named by the enclosing loop's `seen_by`. Dedup
runs **once** at harvest; the fold that rebuilds accumulators never re-dedups.

### 6.6.1 Accumulator folds (`NewItems`, `Of`)

`Accumulator.Of(run_id)` rebuilds every accumulator purely by folding the journal, and
`Accumulator.NewItems` is the dedup a `collect` runs once, at harvest:

```
Accumulator.Of(run_id):
  - Let {acc} be an empty Map (accumulator name -> ordered list).
  - For each event in Journal.Fold(run_id), in seq order:
    - If it is an `accumulate` with payload p:
      - Set acc[p.into] to (acc[p.into] or []) ++ p.added.     ; append already-deduped items
    - Else: no-op.
  - Return {acc}.
```

```
Accumulator.NewItems(current, harvest, seen_by):
  - Let {seen} be the Set { Project(item, seen_by) : item in current }.
  - Let {added} be an empty List.
  - For each {item} in harvest, in input order:
    - Let {key} be Project(item, seen_by).
    - If {key} is in {seen}: continue.                         ; already present — drop
    - Add {item} to {added}; add {key} to {seen}.              ; dedup within harvest too
  - Return {added}.                                            ; input order preserved

Project(item, []):        Return {item}.                        ; empty seen_by ⇒ whole-item identity
Project(item, seen_by) when item is a map:
  - Return the Map { f => Field(item, f) : f in seen_by }.
Project(item, seen_by):   Return {item}.                        ; non-map item ⇒ whole-item identity

Field(item, f):
  - If item has the string key `to_string(f)`: Return item[to_string(f)].
  - Return item[f].                                             ; else fall back to the atom key
```

Rules a conforming implementation MUST honor:

- **An accumulator is identified by NAME globally across the whole run.** `Accumulator.Of`
  folds **every** `accumulate` event by its `into` name with **no** address filter, so all
  `collect(into: :x)` anywhere in the run — including in an **earlier sibling loop** —
  contribute to the single accumulator `:x` that `count(:x)` (§6.8) reads. Since loops cannot
  nest (Rule 5.7.6), two **sequential** top-level loops that reuse the name `:x` share one
  global accumulator for every `until: count(:x) …` predicate. This is the **opposite** of
  `DryStreak`'s per-loop isolation (§6.7), which filters `accumulate` events by an
  **address prefix** so a sibling loop's rounds never affect *this* loop's dryness. The two
  folds deliberately differ: **`count()` is global-by-name; dryness is per-loop-by-address.**
  Concretely, if loop 1 collects 5 items into `:items`, then a later loop 2 with
  `until: count(:items) >= 5` sees `count(:items) == 5` at iteration `0` and stops
  immediately — its body never runs — even though loop 2 itself collected nothing. A
  conforming implementation MUST reproduce both folds exactly. Authors SHOULD use a
  **distinct accumulator name per loop** unless cross-loop accumulation is deliberately
  intended; reusing a name means `count(:x)` in one loop sees items any `collect(into: :x)`
  added **anywhere earlier in the run**.
- **Empty `seen_by` (the default for `while_budget` and for `until_dry`) dedups by
  whole-item equality** — two harvested items collapse only if they are equal terms.
- **`seen_by` field resolution tolerates both key shapes.** `seen_by` entries are atoms
  (`:id`), but a schema-backed agent result is a **string-keyed** JSON map (`"id"`).
  `Field` resolves `:id` by trying the **string** key `"id"` first, then the atom key
  `:id`, so `seen_by: [:id]` deduplicates a `%{"id" => …}` item correctly. An author using
  `seen_by` MUST therefore make the agent emit objects carrying those fields — **whether
  enforced by an object-typed element schema (`items` of `"type" => "object"` with the named
  `properties`, RECOMMENDED) or only by prompt contract** (the prompt instructing the agent
  to include them). The coupling is unchecked at compile time, so this is a footgun: if the
  agent returns items **missing** a `seen_by` field, `Project(item, [:id])` yields
  `%{id: nil}` for **every** such item, they all collapse to one, and each round adds at most
  one item — so an `until_dry` loop can go dry (and stop) after `rounds` even though the
  agent found real, distinct work. An object-typed element schema turns that silent collapse
  into a fail-closed rejection (a missing required field is `agent_failed`), which is why it
  is the safer of the two.
- **Dedup runs against `current` AND against earlier items in the same `harvest`.** A
  duplicate within one harvest is dropped once; `added` never contains two items with the
  same projected key.
- **Order is preserved.** `added` lists items in harvest input order; `Of` concatenates
  `added` lists in seq order — so an accumulator's order is the deterministic order items
  were first seen.

### 6.7 Dynamic loops

```
Loop(node, seen_by, run_id, provider, prior, ctx, iteration):
  - Let {decision, ctx} be Decide(node, run_id, prior, ctx, iteration).
  - If {decision} is `:stop`:
    - Commit Event.loop_completed(node, iteration).          ; iterations = iteration
    - Return {:cont, ctx}.
  - Let {seq} be IterationMarker(run_id, node, iteration, ctx.seq).
      ; commits iteration_started(node, iteration) unless already journaled for (address, iteration)
  - Let {body_ctx} be ctx with {seq: seq, iteration: iteration, seen_by: seen_by, last_result: nil}.
  - Let {r} be RunNodes(node.body, run_id, provider, prior, body_ctx).
  - If {r} is {:cont, body_ctx'}:
    - Return Loop(node, seen_by, run_id, provider, prior, ctx with seq = body_ctx'.seq, iteration + 1).
  - If {r} is {:halt, body_ctx', reason}:
    - Return {:halt, ctx with seq = body_ctx'.seq, reason}.
```

Both loop kinds **enter `Loop` with `iteration = 0`** (§6.3 dispatch): `WhileBudget` calls
`Loop(node, [], run_id, provider, prior, ctx, 0)` (empty `seen_by`); `UntilDry` calls
`Loop(node, node.seen_by, run_id, provider, prior, ctx, 0)`. `iteration` then strictly
increases by one on each recursive pass (§6.7 `Loop`), so it seeds the exactly-once key
(§6.5), the `iteration_started`/`loop_decision`/`accumulate` payloads, and `DryStreak`'s
backward walk.

```
Decide(node, run_id, prior, ctx, iteration):
  - If a `loop_decision` for (node.address, iteration) is in {prior}:
    - Return {its decision, ctx}.                            ; replay verbatim
  - Let {decision} be FreshDecision(node, run_id, iteration).
  - Commit Event.loop_decision(node, iteration, decision).   ; decision in [:continue, :stop]
  - Return {decision, ctx}.
```

```
FreshDecision(WhileBudget, run_id, iteration):        ; first match wins
  - If {iteration} >= node.max_iterations: Return `:stop`.
  - If node.until is set and Predicate.Evaluate(node.until, PredicateContext(run_id)): Return `:stop`.
  - If Ledger.Remaining(run_id) > node.reserve: Return `:continue`.
  - Return `:stop`.

FreshDecision(UntilDry, run_id, iteration):
  - If {iteration} >= node.max_iterations: Return `:stop`.
  - If DryStreak(run_id, node.address, iteration) >= node.rounds: Return `:stop`.
  - Return `:continue`.
```

`PredicateContext(run_id) = %{accumulators: Accumulator.Of(run_id), remaining:
Ledger.Remaining(run_id)}`.

`DryStreak` counts how many consecutive most-recent rounds added **nothing** to any
accumulator, walking backward from the round just completed. A round is identified by its
`iteration` index, and a body MAY `collect` more than once per iteration, so a round's
contribution is the **sum** of `length(added)` over **all** of that round's `accumulate`
events. The per-round isolation filter is **both** an iteration match and an address-prefix
match:

```
DryStreak(run_id, loop_address, iteration):
  - Let {events} be Journal.Fold(run_id).
  - Let {streak} be 0.
  - For {r} from {iteration} - 1 down to 0, inclusive:
    - Let {round_events} be the `accumulate` events in {events} whose
      payload.iteration == {r} AND whose payload.address is prefixed by {loop_address}.
    - Let {sum} be the total of length(payload.added) over {round_events}.
    - If {sum} == 0: Set {streak} to {streak} + 1.
    - Else: Return {streak}.                  ; first non-dry round stops the walk
  - Return {streak}.
```

Both filters are load-bearing: `payload.iteration == r` isolates the round, and "address
prefixed by `loop_address`" restricts the count to `collect` nodes belonging to *this* loop
(so a sibling loop's accumulates never leak into *this* loop's dryness). **This
address-prefix isolation applies to dryness ONLY.** `count(:x)` predicates (§6.8) read the
**global**, name-keyed accumulator via `Accumulator.Of` (§6.6.1), which has **no** address
filter, so a `count(:x)` is **not** isolated from a sibling loop that also collected into
`:x` — see the global-by-name rule in §6.6.1. `UntilDry` stops (§6.7 `FreshDecision`)
once `DryStreak(...) >= node.rounds`.

**Termination guarantee.** Termination is delivered **unconditionally** by the
`max_iterations` cap: `FreshDecision` returns `:stop` the moment `iteration >=
node.max_iterations` for **both** loop types, and `iteration` strictly increases by one per
pass, so every loop halts after at most `max_iterations` iterations regardless of body
behavior. The budget/reserve and dryness conditions are **early-stop refinements**, not the
termination proof: they may return `:stop` sooner, but they are not required to. In
particular, because `remaining` is monotonically non-increasing (every paid usage delta is
non-negative; §6.7.1) but is **not** guaranteed to *decrease* — a `while_budget` body with
no paid `agent` spends nothing, so `remaining > reserve` can stay true forever — the reserve
condition alone does **not** guarantee termination. A conforming implementation MUST enforce
`max_iterations` as the structural bound; it MUST NOT rely on the reserve/dryness condition
to terminate a loop.

### 6.7.1 The ledger fold (budget accounting)

`Ledger.Remaining(run_id)` is the budget quantity that `while_budget` (§6.7) and `fan_out`
(§6.10) consult. It is a pure fold over committed usage:

```
Ledger.Of(run_id):
  - Let {total} be nil and {spent} be 0.
  - For each event in Journal.Fold(run_id), in seq order:
    - If it is `run_started`:                 Set {total} to its payload.budget.
    - If it is `agent_committed`:              Set {spent} to spent + its payload.usage.total_tokens.
    - If it is `agent_attempt_rejected`:       Set {spent} to spent + its payload.usage.total_tokens.
    - Else: no-op.
  - Return {total: total, spent: spent}.

Ledger.Remaining(run_id):
  - Let {l} be Ledger.Of(run_id).
  - If {l.total} is nil: Return :infinity.    ; no budget target ⇒ unbounded
  - Return {l.total} - {l.spent}.
```

Pinned rules a conforming implementation MUST honor:

- **Unit = total tokens.** `spent` sums `usage.total_tokens` (not `input_tokens`,
  `output_tokens`, or a whole `%Usage{}`). Therefore `1` budget unit = `1` total token, and
  `reserve:` (§3.7) and `budget_slices(per:)` (§3.9) are compared in total tokens.
- **`total` comes from `run_started.budget`.** `budget :: non_neg_integer() | nil`. A
  `nil` (absent) budget is the **unbounded** case: `Remaining` returns the atom `:infinity`,
  which sorts above every integer (§6.8), so `budget_remaining() > n` is always `true` and
  `fan_out` raises (§6.10). A `non_neg_integer()` budget makes `Remaining` an integer.
- **Rejected attempts still pay.** Both `agent_committed` and `agent_attempt_rejected` add
  to `spent` — a fail-closed retry is charged. No other event type affects the ledger.
- **Monotonicity.** Because every `usage.total_tokens` is `>= 0`, `spent` is monotonically
  non-decreasing and `remaining` monotonically non-increasing across a run (see §6.7's
  termination note for why non-increasing does not by itself imply termination).

### 6.8 `until:` predicate evaluation

```
Predicate.Evaluate(pred, ctx):
  - If {pred} is Compare{op, left, right}:
    - Return ApplyCompare(op, Resolve(left, ctx), right).
  - If {pred} is AllOf{ps}: Return true iff Evaluate holds for every p in ps.
  - If {pred} is AnyOf{ps}: Return true iff Evaluate holds for some p in ps.

Resolve(Count{acc}, ctx)  = length(ctx.accumulators[acc] or []).
Resolve(BudgetRemaining{}, ctx) = ctx.remaining.

ApplyCompare(op, a, b):
  - Return the truth value of the comparison `a op b`, where {op} is one of
    `>` `<` `>=` `<=` `==` applied with Elixir's term-comparison semantics.
    When {a} is the atom `:infinity` (an unbounded ledger, §6.7.1) it sorts above every
    integer, so `budget_remaining() > n` and `>= n` are true and `< n`, `<= n` are false.
```

`ApplyCompare` is the operator-application helper (named to avoid colliding with the
`Compare{op, left, right}` predicate struct it is called from). `Resolve` maps an operand
node to an integer (or `:infinity` for `budget_remaining()` under an unbounded run); the
right operand is always the comparison's literal integer.

`ctx.remaining` may be the atom `:infinity` (no budget target); it sorts above every
integer, so `budget_remaining() > n` is `true` under an unbounded run.

### 6.9 Barrier and per-item fan-out — `parallel`, `pipeline`

`Parallel`:

```
RunParallel(node, run_id, provider, prior, ctx):
  - Let {seq} be CommitMarker(parallel_started, node, prior, ctx.seq).   ; payload %{address, branch_count}
  - Let {cap} be node.max_concurrency or max(length(node.branches), 1).
  - Let {results} be RunConcurrently(node.branches, cap, fn branch ->
      BuildAgent(branch, run_id, provider, prior) end).       ; off-thread, no journal writes
  - Let {r} be CommitLanes(results, run_id, seq).             ; commit each branch's events in branch order
  - If {r} is {:ok, seq'}:
    - Return {:cont, ctx with seq = CommitMarker(parallel_completed, node, prior, seq')}.
  - If {r} is {:halt, seq', reason}: Return {:halt, ctx with seq = seq', reason}.
```

`Pipeline` is identical except: it commits `pipeline_started` (payload `%{address, items,
item_count, stage_count}`), fans out over `node.lanes` (each lane runs its stages
**sequentially** via `RunLane`), joins with no barrier, and commits `pipeline_completed`.

`RunConcurrently(inputs, cap, fun)` runs `fun` over `inputs` with at most `cap` in flight,
**ordered** (results in input order), with no timeout. Because results are gathered in
input order, **scheduling is unobservable** in the journal: any concurrency strategy that
preserves input-order commit is conforming. `fun` may return only a lane result
(`{:ok, …}` or `{:failed, …}`); if the provider crashes off-thread inside a lane (§6.4.1),
that crash **propagates** through `RunConcurrently` and crashes the writer before
`CommitLanes` runs, so the region commits **no** lane events (§6.1) — it is a
`{:run_crashed, reason}`, never a lane `{:failed, …}`.

`CommitLanes` and its result-threading variant `CommitLanesWithResults` are the two lane
commit algorithms. Both fold the gathered lane results **in input order**, commit **every**
lane's events (a failed lane still commits every event it produced up to and including its
failing stage), thread the `seq` cursor through, and adopt the **first** failing lane's
reason (in input order) as the halt reason. They differ only in whether successful lanes'
`result` values are threaded out.

```
CommitLanes(results, run_id, seq):
  - Let {seq'} be {seq} and {failure} be nil.
  - For each {lane} in {results}, in input order:
    - If {lane} is {:ok, events} or {:ok, events, _result}:
      - Set {seq'} to CommitAll(run_id, seq', events).   ; commit this lane's events from seq'
    - If {lane} is {:failed, events, reason}:
      - Set {seq'} to CommitAll(run_id, seq', events).    ; failed lane's events STILL commit
      - Set {failure} to ({failure} or {reason}).         ; keep the FIRST failing reason
  - If {failure} is nil: Return {:ok, seq'}.
  - Return {:halt, seq', failure}.
```

```
CommitLanesWithResults(results, run_id, seq):
  - Let {seq'} be {seq}, {failure} be nil, and {out} be an empty List.
  - For each {lane} in {results}, in input order:
    - If {lane} is {:ok, events, result}:
      - Set {seq'} to CommitAll(run_id, seq', events).
      - Append {result} to {out}.                         ; successful-lane results, in input order
    - If {lane} is {:failed, events, reason}:
      - Set {seq'} to CommitAll(run_id, seq', events).    ; failed lane's events STILL commit
      - Set {failure} to ({failure} or {reason}).         ; keep the FIRST failing reason
  - If {failure} is nil: Return {:ok, seq', out}.
  - Return {:halt, seq', failure}.

CommitAll(run_id, seq, events):
  - Fold {events} in order, committing each through the serialized append boundary and
    advancing the lower-bound cursor to max(seq, stamped_event.seq + 1);
    Return the resulting next lower-bound {seq}.
```

Return contracts a conforming implementation MUST honor:

- **`CommitLanes`** (used by `RunParallel`, `RunPipeline`, `RunFanOut`) returns
  `{:ok, seq'}` when no lane failed, else `{:halt, seq', reason}` where `reason` is the
  **first** failing lane's reason in input order. Successful-lane results are **not**
  threaded out (these regions consume no per-lane result).
- **`CommitLanesWithResults`** (used by `RunVerify`, `RunJudge`) returns
  `{:ok, seq', results}` — where `results` are the **successful** lanes' `result` values in
  **input order** (a voter's `%{"verdict" => …}` map, a candidate lane's numeric `total`) —
  else `{:halt, seq', reason}` with the same first-failure semantics. On the `:halt` branch
  the panel **never** computes confirmations/scores or a `*_settled` marker: the halt
  short-circuits before `Survives`/`PickWinner`, so a failed lane fails the whole panel and
  `out` is discarded. On the `:ok` branch the panel folds `results` in input order (counting
  confirmations for verify, zipping totals with candidates for judge, §6.10).
- Both commit failed lanes' events, so the journal after a partial-failure region is
  identical whether or not a later lane also failed; only the **returned** halt reason (the
  first failure) and the Status fold's `failure` (the last `agent_failed`, §7.3) may differ
  when 2+ lanes fail (§6.1, §7.3).

`BuildAgent` mirrors RunAgent/CommitAttempt but returns events for `CommitLanes` to commit
instead of committing them itself (off-thread), so branches never touch the journal
directly. Crucially, it is **resume-aware**: like RunAgent (§6.4) it MUST first consult
`ResolveIdempotency(prior, address, iteration)` so a partially-committed region resumes
without re-committing already-journaled branch events:

```
BuildAgent(node, run_id, provider, prior):
  - Let {iteration} be the agent's iteration (0 outside a loop).
  - Let {outcome} be ResolveIdempotency(prior, node.address, iteration).
  - If {outcome} is {:committed, result, _usage}:
    - Return {:ok, [], result}.               ; already journaled — NO events to re-commit
  - If {outcome} is {:failed, reason}:
    - Return {:failed, [], reason}.            ; already journaled failure — no events
  - If {outcome} is {:resume, n}:
    - Build attempts starting at attempt {n}; Return the un-journaled events
      ({:ok, new_events, result} or {:failed, new_events, reason}).
  - If {outcome} is `:none`:
    - Build attempts starting at attempt 0; Return all produced events
      ({:ok, events, result} or {:failed, events, reason}).
```

Because `BuildAgent` returns only **un-journaled** events for each branch, `CommitLanes`
never re-commits an `agent_committed` or `agent_attempt_rejected` that a prior (crashed)
attempt already wrote. Consequently a region resumed after a crash mid-region reproduces
**exactly** the crash-free journal: committed branches contribute no new events, and the run
continues at the first un-journaled attempt of the first incomplete branch (C4, §8).

`RunLane` is the sequential runner for a `pipeline` lane and a `fan_out` branch. Like
`BuildAgent` it runs **off-thread and writes no journal events** — it returns accumulated
events for `CommitLanes` to commit in input order, so lanes never touch the journal
directly:

```
RunLane(stages, run_id, provider, prior):
  - Let {events} be an empty List and {result} be nil.
  - For each {stage} in stages, in order:
    - Let {r} be BuildAgent(stage, run_id, provider, prior).   ; each stage re-addressed at compile time (§4.4)
    - If {r} is {:ok, stage_events, stage_result}:
      - Append {stage_events} to {events}; set {result} to {stage_result}.
    - If {r} is {:failed, stage_events, reason}:
      - Append {stage_events} to {events}.
      - Return {:failed, events, reason}.                      ; first failure halts the lane; earlier stages' events are kept
  - Return {:ok, events, result}.
```

- **Return contract.** `{:ok, events, result}` (all stages committed, `result` = the last
  stage's result) or `{:failed, events, reason}` (the first failing stage's reason,
  `events` carrying every event produced up to and including that stage). `CommitLanes`
  commits `events` in input order and adopts the first lane's `reason` as the halt reason
  (§6.1). A lane thus fails closed at its first failing stage; later stages of that lane do
  not run.
- **Sequential within a lane.** A lane's stages run strictly in order (each stage's paid
  effect is keyed by its own compile-time address); only the lanes themselves run
  concurrently up to `cap` (§6.11).

### 6.10 Verify, Judge, Fan-out

`Verify`:

```
RunVerify(node, run_id, provider, prior, ctx):
  - Let {seq} be CommitMarker(verify_started, node, prior, ctx.seq).    ; %{address, mode, voter_count, threshold}
      ; `mode` is the atom TAG :voters or :lenses (ModeTag(node.mode)), NOT the node's mode tuple.
      ; voter_count and threshold carry the arity, so the tuple's payload is fully recoverable.
  - Let {results} be RunConcurrently(node.voters, max(length(node.voters),1),
      fn voter -> BuildAgent(voter, run_id, provider, prior) end).
  - Let {r} be CommitLanesWithResults(results, run_id, seq).   ; §6.9, voter (input) order
  - If {r} is {:halt, seq', reason}: Return {:halt, ctx with seq = seq', reason}.
      ; a failed vote fails the panel — no verify_settled is committed
  - Otherwise {r} is {:ok, seq', votes}; let {votes} be that result list and {seq} be {seq'}.
  - Let {confirmations} be the count of votes v where v["verdict"] == true.
  - Let {total} be length(votes).
  - Let {survived} be Survives(confirmations, total, node.threshold).
  - Let {seq} be CommitMarker(verify_settled, node, prior, seq).  ; %{address, confirmations, total, threshold, survived}
  - Set ctx.last_result = %{survived, confirmations, total}; Return {:cont, ctx with seq}.
```

```
Survives(confirmations, total, threshold):
  - If threshold is :majority:  Return confirmations * 2 > total.
  - If threshold is :unanimous: Return confirmations == total.
  - If threshold is :any:       Return confirmations >= 1.
  - If threshold is integer n:  Return confirmations >= n.

ModeTag({:voters, _}):  Return :voters.
ModeTag({:lenses, _}):  Return :lenses.
```

`Judge` mirrors `Verify`: `node.scorers :: [[Agent.t()]]` is the pre-expanded **scorer
grid** in **candidate-major** order — `scorers[c]` is candidate `c`'s ordered list of
criterion scorer agents, criterion `k` addressed `node.address ++ [c, k]` (§4.4). Candidate
lanes run through `RunConcurrently` + `CommitLanesWithResults` (§6.9) in **candidate order**, and
each lane's criteria run **sequentially** through resume-aware `BuildAgent` (§6.9). `judge`
has **no** `max_concurrency` option; its cap is fixed at "all candidate lanes at once".

```
RunJudge(node, run_id, provider, prior, ctx):
  - Let {seq} be CommitMarker(judge_started, node, prior, ctx.seq).   ; %{address, candidates, criteria}
  - Let {cap} be max(length(node.scorers), 1).                        ; all candidate lanes at once
  - Let {results} be RunConcurrently(node.scorers, cap, fn lane ->
      ScoreLane(lane, run_id, provider, prior) end).                  ; off-thread, candidate order
  - Let {r} be CommitLanesWithResults(results, run_id, seq).          ; §6.9, candidate (input) order
  - If {r} is {:halt, seq', reason}:
    - Return {:halt, ctx with seq = seq', reason}.  ; a failed score fails the panel — no judge_settled
  - Otherwise {r} is {:ok, seq', totals}; let {totals} be that result list (per-candidate
    totals, candidate order) and {seq} be {seq'}.
  - Let {scores} be the Map built from `node.candidates` zipped with {totals}, in
    candidate order (Map insertion; see the duplicate-candidate pin below).
  - Let {winner} be PickWinner(node.pick, scores).
  - Let {seq} be CommitMarker(judge_settled, node, prior, seq).       ; %{address, scores, pick, winner}
  - Set ctx.last_result = %{winner, scores}; Return {:cont, ctx with seq}.
```

```
ScoreLane(criteria, run_id, provider, prior):                  ; one candidate's criterion scorers
  - Let {events} be an empty List and {total} be 0.
  - For each {scorer} in {criteria}, in criterion order:
    - Let {r} be BuildAgent(scorer, run_id, provider, prior).   ; resume-aware (§6.9), addr node.address ++ [c,k]
    - If {r} is {:ok, scorer_events, result}:
      - Append {scorer_events} to {events}.
      - Set {total} to {total} + Number(result, "score").      ; Number(map, "score") = the value if a number, else 0
    - If {r} is {:failed, scorer_events, reason}:
      - Append {scorer_events} to {events}.
      - Return {:failed, events, reason}.                       ; first failed score halts the lane
  - Return {:ok, events, total}.
```

`ScoreLane` is the judge counterpart of `RunLane` (§6.9): it runs one candidate's criterion
scorers **sequentially** via resume-aware `BuildAgent` (so a resumed judge never re-runs a
committed scorer or double-charges it), sums each scorer's `"score"` field
(`Number(result, "score")` = the field's value when it is a number, else `0` — the reference
computes this as `Map.get(result, "score", 0)`), and fails the whole lane (hence the panel)
at the first failed score. Because scorers are `retries: 0` and schema-bound (§4.4), a
malformed score is a hard panel failure. The grid's committed order is therefore
candidate-major `[c0k0, c0k1, …, c1k0, …]`, matching the `address ++ [c, k]` layout, so two
implementations journal the same scorer `seq` ordering.

```
PickWinner(pick, scores):                                      ; scores is the candidate→total Map
  - If {pick} is :max_score: Return the key of the first entry, in {scores}'s enumeration
    order, whose value equals the maximum value in {scores}.
  - If {pick} is :min_score: Return the key of the first entry, in {scores}'s enumeration
    order, whose value equals the minimum value in {scores}.
```

**Tie-break (pinned, map-enumeration order).** `PickWinner` receives only the candidate→total
**Map** (not the ordered candidate list); the reference computes the winner as
`scores |> Enum.max_by(&elem(&1, 1)) |> elem(0)` (and `Enum.min_by` for `:min_score`), which
returns the **first** maximal (resp. minimal) entry in the map's **enumeration order** — for
an Elixir map that is **Erlang term order of the candidate keys**. Therefore on equal totals
the winner is the candidate that is **smallest in term order** among those tied, **not** the
earliest in `node.candidates` declaration order. Because `judge_settled.winner` is journaled
output, this rule is normative: two conforming implementations MUST journal the same `winner`
for the same `scores` Map by breaking ties in the map's key-enumeration (term) order. For
example, `judge(["b", "a"], …)` with both candidates tied and `pick: :max_score` journals
winner `"a"` (`"a" < "b"` in term order, enumerated first), **not** `"b"`.

**Duplicate candidates (pinned collapse).** Rule 5.5.4 requires only a non-empty candidate
list, so duplicate candidate literals (e.g. `judge(["a", "a"], …)`) are **valid** — the
compiler does not enforce candidate uniqueness (only phase names are unique, Rule 5.10.1).
`scores` is built by zipping `node.candidates` with the per-candidate totals and folding into
a Map, so a duplicate candidate literal is **a single map key** whose value is the total of
the **last** occurrence in candidate order (Map insertion is last-write-wins on a repeated
key). Consequently `judge_settled.scores` has **fewer entries than candidates** when
candidates repeat, and `PickWinner` sees only the collapsed key. This is the pinned,
observable behavior; an author who needs one score per position MUST make candidate literals
distinct.

`FanOut` — the only runtime-decided width:

```
RunFanOut(node, run_id, provider, prior, ctx):
  - Let {width, seq} be DecideWidth(node, run_id, prior, ctx.seq):
    - If a `fan_out_started` for node.address is in {prior}: replay its payload.width.
    - Else width = ComputeWidth(node.width, run_id); commit Event.fan_out_started(node, width).  ; %{address, per, width}
  - ComputeWidth(BudgetSlices{per}, run_id):
    - If Ledger.Remaining(run_id) is :infinity: Raise ArgumentError
        ("budget_slices requires a bounded run (no budget target set)").
    - Return div(max(remaining, 0), per).
  - Let {branches} be, for each {i} from 0 to {width} - 1 inclusive,
      RebaseBody(node.body, node.address ++ [i]); if {width} is 0, {branches} is [].
      ; RebaseBody re-addresses stage s to branch_address ++ [s]
  - Let {cap} be node.max_concurrency or max(width, 1).
  - RunConcurrently(branches, cap, RunLane…); CommitLanes.
  - On {:ok, seq'}: Return {:cont, ctx with seq = CommitMarker(fan_out_completed, node, prior, seq')}.
```

**Zero-width fan-out (pinned).** `ComputeWidth` = `div(max(remaining, 0), per)` can
legitimately be **0** — e.g. `budget_slices(per: 100)` with `remaining` 50. A width of 0
means the region has **no branches**: `RunFanOut` commits `fan_out_started` with `width: 0`,
runs **zero** lanes (`RunConcurrently([], …)` returns immediately), commits
`fan_out_completed`, and leaves `ctx` — including `ctx.last_result` — **unchanged**. The
loop "for each `i` from 0 to `width` - 1 inclusive" produces the empty branch list when
`width` is 0; an implementation MUST NOT interpret it as a descending range (which would
fabricate a branch at a negative index).

An unbounded run raises when it reaches a `fan_out` (there is no budget to slice) — this is
the one execution-time raise that is not a validation failure; it surfaces as a run crash.

**Panels are observational (no gating).** `RunVerify` and `RunJudge` set `ctx.last_result`
to `%{survived, …}` / `%{winner, …}` and journal `verify_settled` / `judge_settled`, but a
panel verdict has **zero** control-flow effect (Principle 8). At top level nothing consumes
`ctx.last_result`: `collect` is the only consumer and is body-only (§6.6), panels are
forbidden inside loop bodies (Rule 5.7.6), and the `until:` predicate grammar (§3.8) can
reference only `count(:acc)` and `budget_remaining()` — never a verdict. **The language has
no conditional or branching combinator.** A verdict or winner therefore cannot alter what
runs next; it is journaled output only. Any reaction to a panel outcome (e.g. "stop if the
verification failed") happens **outside** the workflow, by folding the journal
(`Status.verifications` / `Status.judgments`, §7.3) after the run. Authors MUST NOT attempt
to gate a workflow on a panel result — a review-gated pipeline is not expressible in this
vocabulary.

### 6.11 Concurrency: what is parallel vs serial

- `parallel` branches, `pipeline` lanes, `verify` voters, `judge` **candidate lanes**, and
  `fan_out` branches MAY run concurrently up to their `cap`. The `cap` sources are:
  `parallel`/`pipeline`/`fan_out` take `node.max_concurrency` (default = all at once);
  `verify` and `judge` have **no** `max_concurrency` option, so their cap is fixed at "all at
  once" (`max(length(node.voters), 1)` and `max(length(node.scorers), 1)` respectively).
  Because every region gathers results in input order and commits in input order, **the
  observable journal is independent of scheduling**. A conforming implementation MAY use any
  scheduling strategy (including fully sequential) as long as commit order matches input
  order.
- Within a `pipeline` lane, a `fan_out` branch, or a `judge` candidate lane, the constituent
  agents (stages / criterion scorers) run **sequentially**.
- Top-level statements run **sequentially** in source order.

---

## 7. Output & Error Format

### 7.1 The journal (single source of truth)

Events are stored append-only in SQLite (default path
`~/.codex/workflows/runs_1.sqlite`, overridable by `CODEX_LOOPS_JOURNAL_PATH` or app
config). The envelope is `%Workflow.Event{}` with identity string
`agent-loops/journal@1` (`@schema 1`):

```
Event = %{run_id :: String.t() | nil, seq :: non_neg_integer() | nil,
          type :: atom(), payload :: map(), schema :: pos_integer() (default 1)}
```

`run_id`/`seq` are stamped by the writer at commit. `type` is an open atom discriminator;
`payload` is a plain map; there is **no wall-clock** — ordering is the monotonic `seq`
alone. Events are keyed by `(run_id, seq)`. Folds MUST stay total over unknown/new event
types (the log is versioned and additive).

### 7.2 Event constructors and payload keys

| `type` | Payload keys |
|---|---|
| `:run_started` | `tree_name, tree_version, node_count, budget, script_path` (no address) |
| `:phase_entered` | `address, name` |
| `:log_emitted` | `address, message` |
| `:agent_committed` | `address, iteration, idempotency_key, label, prompt, result, usage, activity` |
| `:agent_activity` | `address, iteration, attempt, activity_index, label, prompt, entry` |
| `:agent_attempt_rejected` | `address, iteration, attempt, label, prompt, output, reason, usage, activity` |
| `:agent_failed` | `address, iteration, attempts, reason` (last event for a top-level fail; inside a concurrent region later lane events may follow it in seq order — the run's halt reason is the **first** `agent_failed` (§6.1), while the Status fold's `failure` is the **last** `agent_failed` in seq order (§7.3)) |
| `:parallel_started` / `:parallel_completed` | `address, branch_count` / `address` |
| `:pipeline_started` / `:pipeline_completed` | `address, items, item_count, stage_count` / `address` |
| `:iteration_started` | `address, iteration` |
| `:loop_decision` | `address, iteration, decision` (`:continue` \| `:stop`) |
| `:loop_completed` | `address, iterations` |
| `:accumulate` | `address, into, iteration, seen_by, added, size` |
| `:verify_started` / `:verify_settled` | `address, mode, voter_count, threshold` / `address, confirmations, total, threshold, survived` |
| `:judge_started` / `:judge_settled` | `address, candidates, criteria` / `address, scores, pick, winner` |
| `:fan_out_started` / `:fan_out_completed` | `address, per, width` / `address` |
| `:run_completed` | `value` (terminal on success path; no address) |

> *(Proposed §10 — dataflow: a proposed extension pins `agent_committed.prompt` and
> `agent_attempt_rejected.prompt` to the materialized `EffectivePrompt` string for template-prompt
> agents, never the inert `%Template{}`; see §10.)*

Payload-value pins (each is observable output, so it is normative):

- **`run_started.node_count`** is exactly `length(tree.nodes)` — the number of **top-level**
  statement nodes in the tree, counted **before** any pre-expansion. It does **not** recurse
  into branches, lanes, voters, scorers, loop bodies, or fan-out lanes, and it does **not**
  count the pre-expanded grid/lane `%Agent{}` templates of §4.4. For the canonical minimal
  run (`phase; log; agent; return`) `node_count` is `4`.
- **`run_started` carries no `tree_fingerprint`.** The journaled `run_started` payload is
  exactly `tree_name, tree_version, node_count, budget, script_path` (the table above). The
  reference computes **no** structural fingerprint of the tree, and resume performs no
  tree-identity comparison (§6.2, "Resume recompiles the tree"). `tree_name`/`tree_version`
  are the tree's `name`/`version`; `script_path` is the file a resume recompiles from
  (mutable, and trusted as-is).
- **`run_started.budget`** is `non_neg_integer() | nil`, in **total tokens** (§6.7.1). `nil`
  means an unbounded run (`Ledger.Remaining` = `:infinity`).
- **`phase_entered` / `log_emitted` carry no `iteration` key.** Both are positional markers
  keyed by `(type, address)` (§6.3): payloads are exactly `%{address, name}` and
  `%{address, message}`. A body `phase`/`log` therefore commits at most once per address for
  the whole loop, and a resumed journal reproduces it identically.
- **`verify_started.mode`** is the atom **tag** `:voters` or `:lenses` (`ModeTag(node.mode)`,
  §6.10), **not** the node's `mode` tuple. The companion `voter_count` and `threshold` keys
  carry the arity, so the tuple is fully recoverable without embedding it.
- **`agent_committed.idempotency_key`** is the §6.5 `IdempotencyKey` map **verbatim** — the
  4-key map `%{run_id, node_path, iteration, attempt}` (`node_path` is the node's address
  list, §4.2; `iteration` and `attempt` are the same non-negative integers §6.5 pins). It is
  **not** flattened, hashed, or rendered to a canonical string; the journaled payload and the
  §7.3 `agents` projection both carry this map as-is. Because it is observable output, two
  conforming implementations journal byte-identical `idempotency_key` maps for the same
  effect.
- **`agent_committed.label` / `agent_activity.label` / `agent_attempt_rejected.label`** are
  the `%Agent{label}` string or `nil`. A label is display metadata only (§3.2, Rule 5.3.6):
  it MUST NOT affect prompts, schemas, keys, validation, retry, control flow, or results.
- **`agent_activity.activity_index`** is a non-negative integer local to
  `(address, iteration, attempt)` when emitted by the runner's activity sink. The tuple
  `(address, iteration, attempt, activity_index)` is replay-idempotent: a duplicate append
  returns the original event and MUST NOT create a second event. Distinct repeated entries
  use distinct indices and are preserved even when `entry.kind`, `entry.label`,
  `entry.summary`, and `entry.status` are identical.
- **`agent_committed.activity` / `agent_attempt_rejected.activity`** are ordered lists of
  activity entry maps for the completed attempt. Entries MAY carry `activity_index` when the
  runner reconciles them with streamed `agent_activity` events; read-model folds use that
  index to avoid counting the same streamed/final activity twice, never value-only dedupe.

`run_completed` is the terminal success event; on failure the terminal event is
`agent_failed` and **no** `run_completed` is written. Control-flow outcomes
(`loop_decision`, `fan_out_started` width, `verify_settled`, `judge_settled`) are journaled
so that resume replays rather than recomputes them. A canonical minimal run journals, in
order: `run_started, phase_entered, log_emitted, agent_committed, run_completed` with
contiguous `seq` `0..4`.

### 7.3 Status fold (read model)

`Workflow.Status.of(run_id) = Journal.fold(run_id) |> fold(run_id)` is a **pure** reducer
over the journal (it consults no process state). `state` transitions:

```
:pending --run_started--> :running --run_completed--> :completed
                                    --agent_failed---> :failed
```

The fold accumulates `logs`, `agents`, `rejected`, `accumulators`, `verifications`,
`judgments`, `usage` (summed only from `agent_committed` and `agent_attempt_rejected` —
rejections still pay), and sets `result = value` on `run_completed`. Every clause increments
`event_count`, so the fold is total.

**List-projection shapes (pinned).** These projections live in the `Workflow.Status` struct
returned by `Workflow.Status.of/1` (§7.6). Of them, **only `logs` (verbatim) and
`agentCount = length(agents)`** surface in the §7.5 run-projection envelope; the `agents`,
`rejected`, `verifications`, and `judgments` lists are **not** envelope fields — they are
reachable only through the `Workflow.Status` struct (§7.5). Each is an **ordered list
appended in `seq` order** (one entry per matching event, in the order the fold visits them):

- **`logs`** is an ordered list of **bare `message` strings** — exactly the `log_emitted`
  payload's `message` binary (§7.2), **not** a map. On each `log_emitted` the fold appends
  `payload.message`. (Because a body `log` commits at most once per address, §6.3, a loop
  emits one entry, not one per iteration.)
- **`agents`** is an ordered list of agent projections. `agent_activity` upserts a
  `:running` projection so long-running turns are visible before they commit. On
  `agent_committed`, the fold upserts the same `(address, iteration)` projection with
  `status: :completed` and the projected payload
  `%{address, iteration, label, prompt, result, usage, idempotency_key, activity}`. On
  `agent_failed`, the fold upserts a `status: :failed` projection using the latest matching
  rejection for `label`, `prompt`, `activity`, and phase placement, so an exhausted
  rejected-only agent remains selectable in read surfaces. `agentCount` in the envelope
  (§7.5) is exactly `length(agents)`.
  *(Proposed §10 — dataflow: a proposed extension pins the projected `prompt` — and the `agent_committed.prompt` / `agent_attempt_rejected.prompt` payload keys (§7.2) — to the rendered `String.t()`, never an inert `%Template{}`; see §10.)*
- **`rejected`** is an ordered list appending, on each `agent_attempt_rejected`, the map
  `%{address, iteration, attempt, label, prompt, output, reason, activity}`.
- **`verifications`** / **`judgments`** append, on each `verify_settled` / `judge_settled`,
  the map `%{address, confirmations, total, threshold, survived}` /
  `%{address, scores, pick, winner}` respectively.

Two conforming implementations therefore emit **byte-identical** `logs` (and the other list
projections) for the same journal.

**Failure projection (last-wins, pinned).** On **every** `agent_failed` the fold sets
`failure = %{address, attempts, reason}` and `state = :failed` **unconditionally** — there
is **no** state guard, so a later `agent_failed` **overwrites** an earlier one. The folded
`failure` is therefore the **last** `agent_failed` in `seq` order. In the common case — a
single `agent_failed` (a top-level fail-closed node, or a concurrent region with exactly one
failing lane) — last equals first, so the folded `failure` matches the halt reason `run`
returned (§6.2) and what `status`/`inspect`/`resume` report.

**Note (multi-failure divergence, and its C4 consequence).** In a concurrent region where
**2+ lanes** commit `agent_failed` (§6.1), the two projections differ deliberately: the
**initial** run's returned halt reason is the **first** failing lane in input order
(`CommitLanes`/`CommitLanesWithResults` keep `failure || reason`, §6.9), whereas the Status
fold's `failure` is the **last** `agent_failed` in `seq` order (last-wins, no guard). A
conforming implementation MUST reproduce **both** exactly: the fold overwrites `failure`/
`state` on each `agent_failed` with no guard, and the initial `run` returns the
first-in-input-order failure. Because a **resume** of an already-`:failed` run returns the
Status projection (§6.2, the `:failed` branch of `ExecuteRun` returns `status.failure`),
resume yields the **last** failing lane's tuple — **not** the first that the initial `run`
returned. This is the single deliberate exception to C4's "resume replays journaled
decisions": for a multi-failure region the resume/status result tuple (last) differs from
the initial-run result (first). It is intentional and pinned here; every other decision
resume reproduces byte-for-byte. Single-failure runs (the overwhelmingly common case) have
last == first and no divergence.

The fold also tracks `phase`: on each `phase_entered` it sets `phase = payload.name`, so
`phase` is the `name` of the **most recent** `phase_entered` event, or `nil` when no phase
has been entered. This is the value surfaced as the envelope's `phase` field (§7.5); it is
a projection, computable from the journal alone.

### 7.4 Result shape

The final value of a completed run is the `run_completed` payload's `value` — the
workflow's `%Return{}` value (a compile-time literal). A provider's per-turn `result` is
opaque (`term()`), accompanied by `%Usage{input_tokens, output_tokens, total_tokens}`
(all `non_neg_integer()`, summed field-wise).

Run API return values:

- `{:ok, run_id}` on completion.
- `{:error, {:malformed_output, address, reason}}` on fail-closed abort.
- `{:error, {:already_running, pid}}` when a live writer holds the lease.
- `{:error, {:run_crashed, reason}}` on writer crash.

### 7.5 CLI envelope, error object, exit codes

Under `--json`, stdout carries **exactly one** final JSON object, which always has a
`"command"` field; progress/warnings go to stderr; on failure the last stderr line is a
single-line JSON error object. The error object is:

```
{"code": <json code>, "exitCode": <int>, "message": <string>, "hint"?: <string>}
```

The single mapping below is the source of truth for both the process exit code and the
JSON `code`:

| internal code | JSON `code` | exit code |
|---|---|---|
| `:usage` | `usage` | 2 |
| `:provider_config` | `provider-config` | 4 |
| `:validation` | `validation` | 6 |
| `:malformed_output` | `malformed-output` | 8 |
| `:killed` | `killed` | 130 |
| `:runtime` | `runtime` | 1 |

Success exits `0`. Run-outcome mapping: `{:error, {:provider_config, reason}}` — raised
**before** the run starts by `ResolveProvider` (§6.4.1) when the selected provider cannot be
configured or resolved (a module that does not export `run_agent/4`, or a `validate_config/1`
that returns `{:error, reason}` because required configuration is absent) → exit 4;
`{:malformed_output, …}` → exit 8; `{:run_crashed, :killed}` → exit 130; `{:run_crashed, _}`
and `{:already_running, _}` → exit 1; a compile/validation failure of the workflow script →
exit 6; a missing script file, a bad option, an **absent/`nil` `:provider`** option
(`{:usage, :provider}`, §6.4.1), or a resume with no resolvable script path
(`{:no_script_path, run_id}`, §6.2) → exit 2. The `provider-config` code (exit 4) is the
pre-run provider-resolution failure; it is distinct from a provider that resolves but then
fails a call at run time, which is `{:run_crashed, reason}` (exit 1, §6.4.1).

The run projection envelope (for `run`/`test`/`resume`/`status`/`inspect`) carries
**exactly** these fields: `runId, state, treeName, phase, logs, agentCount, eventCount,
usage, result, failure`, plus a `command` field added by the caller. Here `logs` is the §7.3
`logs` projection verbatim — an ordered (seq-order) JSON array of the `log_emitted`
**message strings** — and `agentCount` is `length(agents)` (the §7.3 `agents` list); `usage`
is `%{"inputTokens", "outputTokens", "totalTokens"}`; `failure` is `nil` or
`%{"address", "attempts", "reason" => inspect(reason)}`. The §7.3 `agents`, `rejected`,
`verifications`, and `judgments` list projections are **not** envelope fields: the envelope
exposes the agent stream solely as the `agentCount` integer, and the rejection/verification/
judgment lists are reachable only through the `Workflow.Status` struct (`Workflow.Status.of/1`,
§7.3, §7.6). A value that is not JSON-encodable is rendered
via `inspect/1` so the envelope always encodes; as in §4.4, this `inspect/1` fallback is
byte-normative **only for the Elixir embedding** — a non-Elixir host MUST still produce an
encodable envelope, but its string rendering of a non-JSON-encodable value is
implementation-defined.

**Scope of this section: envelope and exit codes only; the CLI *input* surface is
non-normative.** What §7.5 pins is the **output** contract of a `--json` invocation — the
single final envelope object above, the error object, the JSON `code`↔exit-code mapping, and
the run-outcome mapping. The **input** surface of the `run`/`test`/`resume`/`status`/`inspect`
commands — their flags and positional arguments, how a `{module, opts}` provider is written
as a command-line string and resolved to a module (and thereby into the exit-4
`provider-config` path of §6.4.1), how `:budget`/`:run_id`/`:script_path` are passed, and any
behavioral difference between `run` and `test` (e.g. a default mock provider) — is
**implementation-defined and NOT normative**. Conformance for invocation is defined solely
against the §7.6 programmatic run API (`Workflow.Run.run/2`, `Workflow.Run.start/2`) and the
§7.3 read model (`Workflow.Status.of/1`); a CLI is one OPTIONAL front end over that API, and
two conforming implementations MAY expose entirely different command-line grammars provided
each still emits the §7.5 envelope and exit codes and drives the §7.6 API underneath. Any
provider-string→`{module, opts}` resolution a CLI performs MUST, on failure, surface as the
same `{:usage, …}` (exit 2) or `{:provider_config, …}` (exit 4) outcomes §6.4.1 pins for the
programmatic path.

### 7.6 Running a workflow (the invocation entry point)

A workflow is invoked through the public run API. This is the only place a **budget** — the
quantity `while_budget` (§6.7), `budget_remaining()` (§6.8), and `fan_out` (§6.10) consult —
enters the system: the budget is **not** part of the workflow source; it is supplied here.

- **`Workflow.Run.run(workflow, opts)` → `{:ok, run_id} | {:error, reason}`** blocks until
  the run finishes and returns the run-outcome tuple (§7.4).
- **`Workflow.Run.start(workflow, opts)` → `{:ok, run_id, pid} | {:error, {:already_running,
  pid}}`** starts the writer and returns immediately (asynchronous).
- **`workflow`** is a compiled `%Workflow.Tree{}` **or** a module that `use`s `Workflow`
  (resolved via `module.__workflow__(:tree)`).
- **`opts`** is a keyword list:
  - `:provider` — **REQUIRED**, a `{module, opts}` pair (§6.4.1); the run cannot start
    without it. An **absent or `nil`** `:provider` is a caller misuse reported as
    `{:error, {:usage, :provider}}` ⇒ exit 2 (`:usage`), raised before `ResolveProvider`.
    A **supplied** provider that cannot be resolved/configured (`ResolveProvider` fails,
    §6.4.1) is a distinct pre-run `provider-config` failure (exit 4, §7.5).
  - `:budget` — OPTIONAL, `non_neg_integer()`, the run's total-token budget (§6.7.1).
    **Omitted / `nil` ⇒ unbounded** (`Ledger.Remaining` = `:infinity`): `while_budget` still
    runs (bounded by `max_iterations`), but `fan_out` **raises at run time** (a run crash,
    exit 1) because there is no budget to slice (§6.10). `1` budget unit = `1` total token.
  - `:run_id` — OPTIONAL, `String.t()`; a fresh id is generated when omitted. Reusing an id
    resumes/attaches to that run (§6.2); a second live writer for the same `run_id` is
    refused with `{:error, {:already_running, pid}}` (§6.2.1).
  - `:script_path` — OPTIONAL, `String.t()`; recorded in `run_started.script_path` so
    `resume` can **recompile** the tree from that file (or from a path passed explicitly to
    `resume`). That file is **mutable** and the recompiled tree is trusted **as-is**: the
    reference performs **no** structural identity check between the recompiled tree and the
    journaled events (§6.2, "Resume recompiles the tree"). Journaled **decisions** are still
    replayed by address rather than recomputed (Principle 3), but resume is address-safe only
    if the script is unchanged since the run started; editing the script (which shifts `[i]`
    addresses, §4.2) can desynchronize the recompiled tree from the journal, undetected.
    Operators MUST resume against the same script the run was started with.

**Precondition — `fan_out` REQUIRES a budget.** A workflow containing a `fan_out` MUST be run
with a `:budget`; run unbounded it crashes when it reaches the `fan_out` (§6.10). Read state
back with `Workflow.Status.of(run_id)` (§7.3) or the raw journal via
`Workflow.Journal.fold(run_id)`.

---

## 8. Conformance

The key words **MUST**, **MUST NOT**, **REQUIRED**, **SHALL**, **SHALL NOT**, **SHOULD**,
**SHOULD NOT**, **RECOMMENDED**, **MAY**, and **OPTIONAL** in this document are to be
interpreted as described in [RFC 2119](https://tools.ietf.org/html/rfc2119) and
[RFC 8174](https://tools.ietf.org/html/rfc8174): they are normative **only when in
uppercase**. All content is normative except clearly marked examples, counter-examples,
and notes, which are non-normative.

**Observably-equivalent clause.** The algorithms in this document describe required
*observable* behavior — the sequence of committed journal events, the run result, and the
exit code. A conforming implementation MAY use any internal strategy (any concurrency
schedule, any storage engine, any host language) provided the observable result is
identical to what these algorithms produce. In particular, because every concurrent region
commits in input order (§6.11), a conforming implementation MAY execute lanes sequentially
or in parallel — the journal MUST be the same either way.

Normative requirements a conforming implementation MUST satisfy:

- **C1 (closed vocabulary).** It MUST reject, at compile time, any form outside the 13-way
  vocabulary (and the body vocabulary inside loops), per §5.
  *(Dataflow §10 addendum: the implemented core recognizes `let` and `emit`; `gather`/`map`
  remain DEFER and `reduce`/`select` remain REJECT.)*
- **C2 (determinism by absence).** It MUST NOT provide any workflow-body construct that
  reads a clock, randomness, environment, filesystem, or external module. Determinism
  MUST be a property of the vocabulary, not a runtime linter.
- **C3 (inert tree).** The compiled tree MUST be closure-free, serializable data.
- **C4 (journal as truth).** All read surfaces (status/inspect/resume/live views) MUST be
  pure folds over the journal. Resume MUST replay journaled decisions, not recompute them.
  Resume recompiles the tree from the (mutable) journaled `script_path` and trusts it as-is;
  the reference does **not** journal a tree fingerprint or verify tree identity on resume
  (§6.2, §7.6). (A structural tree-identity check is a possible future hardening, not a
  conformance requirement.)
  - **C4b (multi-failure result exception).** For a concurrent region in which 2+ lanes
    commit `agent_failed`, the initial `run` returns the **first** failing lane's reason
    while resume/status return the **last** (last-wins Status fold). A conforming
    implementation MUST reproduce **both** projections exactly; this is the single,
    pinned exception to "resume replays journaled decisions" (§6.1, §7.3).
- **C5 (exactly-once).** A paid effect MUST be identified by `(run_id, node_path,
  iteration)` and refined by `attempt`; a backend MUST use the idempotency key so an
  effect is paid at most once and its result is never dropped.
- **C6 (fail closed).** A schema-backed agent whose output fails validation MUST retry
  on-thread up to its retry budget and then fail the node and abort the run with exit 8;
  it MUST NOT coerce, default, or accept malformed structured output.
- **C7 (bounded termination).** Every loop MUST terminate. Termination MUST be guaranteed
  by the structural `max_iterations` cap alone (§6.7), which bounds both loop types
  unconditionally; an implementation MUST NOT rely on the `while_budget` reserve or
  `until_dry` dryness condition to terminate a loop — those are early-stop refinements that
  MAY halt a loop sooner.
- **C8 (located errors).** Every validation failure MUST be reported as a compile-time
  error located at the offending declaration in the author's source.
- **C9 (no value binding).** It MUST require compile-time literals for prompts, names,
  `return` values, `verify` subjects, `judge` candidates, `pipeline` items, `synthesize`
  inputs, and schema maps.
  *(Dataflow §10 addendum: C9′ is the proposed reconciliation for the implemented core — a
  flowed value must be journaled by a lexically-preceding node and rendered by deterministic,
  closure-free `RenderText`; see §10.)*

An implementation MAY add new node kinds and new event types (the log is additive), but it
MUST preserve existing addresses (§4.2) and MUST keep folds total over unknown types. It
MUST NOT weaken C1–C9.

---

## 9. Proposed extensions — `refine` (NOT YET IMPLEMENTED)

> **Status: Proposed / design-stage.** The `refine` combinator described here is **not**
> part of the closed vocabulary; it is **not** in `@combinators`, the compiler does not
> parse it, and no conforming implementation of §1–§8 includes it. This section is a design
> for a future combinator and is **non-normative** with respect to the implemented
> language. When implemented, it would become the 14th combinator and the rules below would
> move into §3–§7.

### 9.1 Purpose

Iterative adversarial refinement: a **producer** agent's work is checked by a parallel
**panel of reviewers** that return structured findings; a **fixer** revises the work using
those findings; repeat until the panel reaches consensus or a round bound is hit.

### 9.2 Proposed surface grammar

`verify`/`judge`-style positional subject plus keyword options:

```
RefineStmt : `refine` `(` AgentStmt `,` RefineOpts `)`
RefineOpts : KeywordList   ; reviewers:, revise_with:, until:, max_rounds:, on_stall:?
```

```
refine <producer :: agent(literal)>,
       reviewers: [<lens atoms>+] | <pos-int>,
       revise_with: <fixer :: agent(literal)>,
       until: :unanimous | :majority,
       max_rounds: <pos-int literal>
       [, on_stall: :fail | :accept]
```

### 9.3 Proposed validation rules (each with the smallest counter-example)

**V1 — producer MUST be an `agent()` form.**

```counter-example
refine "a claim", reviewers: [:a], revise_with: agent("fix"), until: :unanimous, max_rounds: 3
# a bare literal subject is `verify`, not `refine`
```

**V2 — `revise_with:` REQUIRED and an `agent()` form.**

```counter-example
refine agent("draft"), reviewers: [:a], until: :unanimous, max_rounds: 3
# a refine with no fixer is just verify
```

**V3 — `reviewers:` is a non-empty lens list or a positive integer.**

```counter-example
refine agent("draft"), reviewers: [], revise_with: agent("fix"), until: :unanimous, max_rounds: 3
```

**V4 — `until:` in `{:unanimous, :majority}`.**

```counter-example
refine agent("draft"), reviewers: [:a], revise_with: agent("fix"), until: :vibes, max_rounds: 3
```

**V5 — `:majority` requires `>= 3` reviewers.**

```counter-example
refine agent("draft"), reviewers: [:a, :b], revise_with: agent("fix"), until: :majority, max_rounds: 3
# majority of 2 collapses to unanimous; require >= 3
```

**V6 — `max_rounds:` is a positive-integer literal `<=` the iteration cap.**

```counter-example
refine agent("draft"), reviewers: [:a], revise_with: agent("fix"), until: :unanimous, max_rounds: 0
```

**V7 — prompts are literal strings, no interpolation.**

```counter-example
refine agent("fix #{x}"), reviewers: [:a], revise_with: agent("fix"), until: :unanimous, max_rounds: 3
```

### 9.4 Proposed semantic model

```
%Refine{producer :: Agent.t(),
        reviewers :: [Agent.t()],      # pre-expanded, one template per lens
        fixer     :: Agent.t(),
        threshold :: :unanimous | :majority,
        max_rounds :: pos_integer(),
        on_stall  :: :fail | :accept}  # default :fail
```

Reviewer schema (fixed): `{verdict: boolean, findings: [{id, issue, fix}]}`.

**Addressing:** `refine_addr ++ [round, role, voter_i]` — the reserved idempotency
`iteration` slot finally carries a nonzero value, set to `round`.

### 9.5 Proposed execution

```
ExecuteRefine(node, run_id, provider, prior, ctx):
  - Let {artifact} be RunProducer(node.producer, run_id, provider, round 0).
  - For {r} in 0 .. node.max_rounds - 1:
    - Let {verdicts} be RunReviewers(node.reviewers, artifact, r) — PARALLEL, schema-bound, journaled.
    - If Consensus(verdicts, node.threshold): Return {:converged, artifact}.
    - If {r} == node.max_rounds - 1:                          ; STALL
      - If node.on_stall is :fail:  Raise RefineStalled.       ; default
      - If node.on_stall is :accept: Return {:stalled, artifact}.  ; journaled converged: false
    - Else:
      - Let {findings} be OpenFindings(verdicts).
      - Let {artifact} be RunFixer(node.fixer, artifact, findings, r + 1).

Consensus(verdicts, :unanimous) = all verdicts are true.
Consensus(verdicts, :majority)  = count(true) > n / 2   (strict; majority of 2 = 2).

OpenFindings(verdicts):
  - Take the findings from THIS round's FAILING reviewers only.
  - Flatten, dedup by finding.id, and order by (reviewer_index, finding.id).
  - This total order makes the fixer prompt a deterministic function of journaled data (replay-safe).
```

> **Sub-algorithm status (non-normative sketch).** `RunProducer`, `RunReviewers`, and
> `RunFixer` are **not** defined as standalone algorithms because `refine` is design-stage;
> they are shorthand for reuse of the already-specified agent path, and would be pinned when
> §9 is promoted into §3–§7:
> - `RunProducer(producer, …, round r)` and `RunFixer(fixer, artifact, findings, round r)`
>   are ordinary `RunAgent` (§6.4) turns whose `iteration` slot carries `r` (§9.4) — the
>   producer and fixer are `%Agent{}` templates with the normal retry-then-fail path.
> - `RunReviewers(reviewers, artifact, round r)` is a `verify`-style parallel panel
>   (`RunConcurrently` + `CommitLanes`, §6.9) over the pre-expanded reviewer `%Agent{}`
>   templates (each `retries: 0`, schema-bound to the fixed reviewer schema in §9.4), one
>   lane per lens, keyed at `refine_addr ++ [r, role, voter_i]`.
> Until §9 is promoted, these three names are intentionally-unspecified placeholders; no
> conforming implementation of §1–§8 executes `refine`.

**Error model.** A **reviewer** malformed output is a **hard fail-closed** (no retry —
reviewers are `retries: 0`). A **producer/fixer** malformed output follows the existing
agent retry-then-fail path.

### 9.6 Proposed output

Events: `refine_round_started{r}`, `refine_produced` / `refine_revised{r}`,
`refine_verdict{voter, verdict, findings}`, and a terminal `refine_converged{r}` or
`refine_stalled{rounds}`. A stalled `:fail` surfaces a **distinct** `:did_not_converge`
error — RECOMMENDED a new exit code distinct from `malformed-output` (exit 8), e.g. exit 9
— so a non-convergence is never confused with a validation failure.

### 9.7 Proposed conformance

Reviewers MAY run in any order or in parallel, since `Consensus` and `OpenFindings` are
order-independent (the fixer prompt is composed from a total order over journaled
findings). Scheduling MUST NOT affect the verdict or the fixer's composed prompt.

---

## 10. Dataflow core and proposed extensions

> **Status: dataflow core implemented; remaining surface proposed/deferred.** The reference
> implementation has shipped the zero-new-event dataflow core: `let :name = agent(...)`,
> `let :name = synthesize(...)`, top-level `agent(~P"...")` prompt injection over previous
> `let` bindings, and terminal `emit(~P"...")`. This section is the normative home for that
> dataflow addendum going forward while §1–§8 remain the frozen base specification, carrying
> only forward-reference notes to this section. `SPEC-DATAFLOW-PROPOSAL.md` remains design
> provenance, not the primary spec.
>
> **Clearly delimited PROPOSED surface.** `gather` and `map` remain **DEFER**; their detailed
> rules are specified below as proposed future work and are not implemented by the current
> reference compiler. `reduce` and `select`/`when` remain **REJECT**. The §10.3 Principle 6 →
> 6′ reconciliation and its amendments are presented as **PROPOSED** amendments to the base
> normative body; they explain how §1–§8 should be folded when the dataflow addendum is next
> promoted into the main grammar.
>
> Notation is identical to the rest of this document (Appendix A): a `::` production is
> **lexical**, a `:` production is **syntactic**. RFC 2119 keywords in the implemented core
> describe shipped requirements; RFC 2119 keywords under sections explicitly marked DEFER,
> PROPOSED, or REJECT fix future or excluded behavior precisely.

### 10.1 Purpose & the governing rule (design principles)

**The base problem: outputs flow nowhere.** The §1–§8 DSL produces values it cannot reuse. An
`agent`, a `verify`/`judge` panel, and a `synthesize` each commit a result to the journal
(`agent_committed.result`, `verify_settled`, `judge_settled` — §7.2), but **no later node can
read any of them**. Principle 6 (*No value binding*) forbids naming a runtime value; §2.2
forbids prompt interpolation; §6.4.1 fixes the provider port so the prompt is "this node's
literal prompt — never a splice of any other node's output". The one in-vocabulary value edge —
`agent → collect → accumulator` (§6.6) — carries only a **count** into a loop's early-stop
predicate; the item **content** never reaches another prompt. The worked "outputs flow nowhere"
cases (§11.4 C/F/G) enshrine this: `judge`'s winner is never passed to `synthesize`; a
`pipeline` stage never sees its item; a `fan_out` lane is a byte-identical replica.
The implemented dataflow core opens one narrow edge for `agent`/`synthesize` outputs: bind the
producer with `let`, render it through `~P`, and consume it from a later top-level `agent` or
`emit`.

**The thesis: add DATA FLOW, not CONTROL FLOW.** This extension would add the ability to **flow
a journaled value into a later prompt or the terminal result** — and deliberately **not** add
control flow: no general `if`, no value-dependent choice of which subtree runs, no unbounded
iteration, no arbitrary computation. It changes only *what data a node's prompt is rendered
from*, never which nodes run or how many times. The deferred `map` proposal is the one
possible exception: it would add bounded, capped fan-out over a journaled collection and remains
outside the implemented core.

**The governing rule (the spine).** Three clauses apply to every idiom in §10:

1. **Flow only journaled values, and only through deterministic renders.** A value MAY flow from
   node *P* into node *Q*'s prompt (or the terminal result) **iff** *P*'s output is already a
   committed journal event **before** *Q* executes, and the flow happens through the
   deterministic, total, closure-free `RenderText` of §4.4 — widened here (§10.4) to accept
   journaled values as input. No interpolation (`"… #{expr} …"`), no computed value, no closure
   ever enters a prompt.
2. **Transform collections with nodes only — never lambdas.** The implemented core has no
   collection transform beyond existing `synthesize`. The deferred future forms keep the same
   rule: per-element work uses a **node** (`map`, one agent per element) and folding a collection
   into one value uses a **node** (`gather`, one agent over the whole collection). No
   `Enum.map(fn … end)`, no anonymous function, ever (Rule 5.1.1 still holds; §10.4's struct
   stays closure-free).
3. **Bound every fan-out.** If the deferred `map` ships, its runtime width MUST carry a
   **compile-time structural cap** (`max: <pos-int literal>`), exactly as every loop carries
   `max_iterations` (Principle 5). Width `= min(observed_length, max)`; the region has at most
   `max` lanes and provably terminates.

### 10.2 Verdict summary — per-idiom decisions

| Idiom | Verdict | One-line reason |
|---|---|---|
| **Template layer** (§10.4) | **ADOPT / IMPLEMENTED** — foundation | Nothing flows without it; inert struct + compile-time binary scanner + the render §4.4 already defines. Closure-free by construction. |
| **`let`** (§10.5) | **ADOPT / IMPLEMENTED CORE** | The keystone; currently binds `agent(...)` and `synthesize(...)`. No new effect/event/key — a bound value is a fold over the producer's existing `agent_committed`. |
| **prompt injection** (§10.6) | **ADOPT / IMPLEMENTED CORE** | The edge authors want ("improve this draft"); top-level `agent(~P"...")` renders previous `let` bindings and rides the existing `agent_committed.prompt`. |
| **`emit`** (§10.7) | **ADOPT / IMPLEMENTED CORE** | Pure render, no paid effect; makes "flow N results into one document" a first-class terminal. |
| **pipeline-with-dataflow** (§10.8) | **ADOPT / IMPLEMENTED by composition** | Falls out of `let` + injection + sequencing — no new combinator. |
| **`gather`** (§10.9) | **DEFER** | `synthesize` over journaled inputs; ship when folding several bound outputs recurs. |
| **`map`** (§10.9) | **DEFER** | Heaviest: runtime-decided width, per-lane re-addressing, structural `max:` cap, a new region + two new events. Single-agent lanes in Tier 1. |
| **`reduce`** (§10.10) | **REJECT** (Tier 1) | Drifts toward in-language computation; `gather` + accumulators cover real needs. |
| **`select` / `when`** (§10.10) | **REJECT** | It is **control** flow, not data flow — violates Principle 8 and the thesis. |

**Build order.** (1) **Complete:** dataflow core = Template + `let` over `agent`/`synthesize` +
top-level injection + `emit`, one coherent slice (unlocks pipeline-with-dataflow for free, adds
**zero** new events). (2) **DEFER:** `gather`. (3) **DEFER:** `map`. (4) **Never, absent a hard
wall:** `reduce`, `select`/`when`. §9 `refine` remains an independent proposed extension.

### 10.3 Reconciliation — Principle 6 → 6′ and the proposed amendments

This section is a principled **strengthening** of "no value binding", not a loosening. The
render §4.4 *already* splices data into prompts (`verify` splices `<subject>`, `judge` splices
`<candidate>`, `synthesize` splices `Inputs: <inspect(inputs)>`); the implemented language is
"only **compile-time-literal** data in prompts, through `RenderText`." This extension changes
exactly one thing: it widens the *source* of `RenderText`'s input from "a compile-time literal"
to "a value already committed to the journal." The render itself is unchanged.

When promoted, §10 would amend the following shipped clauses. Each amendment is a strengthening.
These are presented as **proposed amendments**; the shipped clauses in §1–§8 are unchanged and
carry only the one-line forward-reference notes that point here.

- **Principle 6 → Principle 6′ (journaled-values-only, deterministic-render-only).** A name MAY
  be bound (via `let`, §10.5) only to a value **already committed to the journal** by a
  lexically-preceding node. A bound value MAY flow into a later node **only** through
  `RenderText` (§10.4) over an **inert `%Template{}`** whose only dynamic parts are
  assigns-referencing-bindings. It MUST NOT flow through interpolation, a closure, arithmetic, a
  general conditional, or any computed value. Every prompt and terminal value remains a
  deterministic function of journaled data (Principle 3). This forbids strictly more than
  "arbitrary interpolation would" and permits only the narrow, checked case.
- **§1.2 General-computation Non-goal → §1.2′ (surgically narrowed).** The bullet bundles four
  bans; the amendment reopens **exactly one** (value binding, via `let`) and keeps the arithmetic
  and branch-on-output bans, and every other Non-goal, intact: "The **only** value-binding
  construct is `let`, which binds a name to an already-journaled output for deterministic render
  under Principle 6′; it cannot capture, compute, or branch on a runtime value."
- **§6.4.1 provider port → §6.4.1′.** `prompt :: String.t()` is EITHER this node's literal prompt
  OR the deterministic `RenderTemplate` (§10.4) of an inert `%Template{}` over already-journaled
  bindings; never arbitrary interpolation/closure/computed/live splice. Turn independence is
  **preserved**: the injected prompt is materialized to a `String.t()` by a pure journal fold
  **before** the call, journaled verbatim at commit, never re-rendered on replay. `CallProvider`
  still receives only `(prompt, schema, key, opts)`.
- **Rule 5.3.1 → Rule 5.3.1′ (agent prompt admits an inert `%Template{}`).** The frozen gate
  requires `is_binary(prompt)`; a `~P` template lowers to the AST tuple `{:sigil_P, meta, …}`, for
  which `is_binary/1` is false, so the frozen rule categorically rejects it. The amendment: the
  agent-prompt AST is admissible iff **either** `is_binary(prompt)` **or** it is a `{:sigil_P, _, _}`
  node lowered by `parse/2` to an inert closure-free `%Template{}` in an admissible position
  (Rule P.1). This is a strengthening: it admits only the checked, closure-free `%Template{}` and
  still rejects every variable, call form, interpolation, and computed prompt the frozen rule rejects.
- **§2.3 Literal admissibility → §2.3′ (a `~P` template is a `Macro.quoted_literal?` exemption).**
  The frozen rule requires every prompt/data value to satisfy `Macro.quoted_literal?/1`; a sigil is a
  call-form AST (`{:sigil_P, …}`), not a quoted literal, so the frozen rule rejects it. The amendment:
  a prompt / `emit` / `gather` template MAY be a `~P` sigil that lowers to an inert, closure-free
  `%Template{}`, exempt from the `Macro.quoted_literal?` requirement **precisely because** it lowers
  to escapable inert data (a `Macro.escape`-able struct, §10.4.2). Interpolation, closures, and
  computed prompts remain non-literal and rejected; only the checked `%Template{}` is exempt.
- **§6.4 commit path + §7.2 / §7.3 payload semantics → §6.4-commit′ / §7.2′ / §7.2-rejected′ /
  §7.3′.** For a template-prompt agent the commit path MUST store the materialized
  `EffectivePrompt(node, run_id, lane) :: String.t()` (§10.6) in the `prompt` payload of **every**
  prompt-bearing agent event it writes — **both** `agent_committed.prompt` **and**
  `agent_attempt_rejected.prompt` — in place of `node.prompt` (which holds the inert `%Template{}`
  struct). `agent_failed` has no `prompt` key and is untouched. `EffectivePrompt` renders from
  the **same** journaled producer terms on every attempt (producers commit before the consumer
  runs, §10.4 Rule T.5); for a **binary** binding — or any binding rendered on the same host
  `inspect/1` — the rejected attempt and the eventual commit therefore journal a byte-identical
  string, and for a **non-binary** binding under a cross-version resume they are identical only up
  to the §10.4.5 `inspect/1` host/version caveat (map-key order is not canonical across Elixir
  versions). Either way the §7.3 `agents` projection surfaces a rendered `String.t()`, never a
  struct. (Authors needing byte-identity across hosts bind **binary** values, per §10.4.5.)
- **§8 C9 → C9′.** An implementation MUST require that every value flowed into a prompt or
  terminal result is (a) committed to the journal by a lexically-preceding node and resolved by a
  pure fold, and (b) rendered by the deterministic, closure-free `RenderText`. Interpolation,
  closures, arithmetic-in-prompts, and computed values remain rejected.
- **The closed-vocabulary cluster → 17-way.** Five shipped clauses that fix the top-level
  combinator *count* widen in lockstep: **Principle 1 → 1′** ("exactly **17** top-level
  combinators — the shipped 13 (or **14** if §9's `refine` is also promoted, making the vocabulary
  **18-way**) plus `let`, `map`, `gather`, `emit`"); **§2.4 → §2.4′** (recognized names 13 → 17,
  or 14 → 18 with `refine`); **§8 C1 → C1′** (reject any form outside this widened vocabulary — the
  17-way set, or the 18-way set that counts `refine` in when §9 also promotes); **Rule 5.1.3**'s
  vocabulary set widened (so the four names are not "unknown bare calls" — each gets its own
  `parse/2` clause); **§11.2** at-a-glance table gains four rows. `collect` remains **body-only**.
  This count amendment is stated **relative to the live baseline**: §9 (`refine`) and §10 are
  independent proposals, so an implementation promoting both MUST count `refine` inside the closed
  vocabulary (18-way) rather than reject it under a literal "17-way" reading of Principle 1′/C1′.
- **Separately (terminal-value amendment): §5.10.2** ("a workflow MUST contain a `return`") is
  widened by `emit` to "a `return` **or** an `emit`" (§10.7 / DF-E2).

Every amendment is a strengthening. C2–C8 (except C1 → C1′) are untouched; `map` extends C7 with
one more structural cap (`map.max`) and loses nothing.

### 10.4 The template layer — Verdict: ADOPT (foundation)

Prompt injection (§10.6) and `emit` (§10.7) both render bound values into text through a
**logic-less, inert template**. The `~P` template reuses **only the ideas** of EEx/HEEx — the
`<%= @assign %>` hole surface and compile-time assigns-dependency tracking — and reuses **none of
EEx's code**: no `EEx.tokenize`, no `EEx.Engine`, no embedded Elixir, no compile-to-closure. A
`~P` template is lowered by a **hand-rolled binary scanner**, a plain function called from
`Workflow.Compiler.parse/2` — the same single validation locus every other combinator uses —
never by a self-expanding sigil macro.

> **Note — no `sigil_P` macro exists.** `~P` is surface syntax only. No `defmacro sigil_P` is
> defined or imported; `parse/2` recognizes the raw AST term
> `{:sigil_P, meta, [{:<<>>, _, [raw]}, mods]}` in an admissible prompt position and lowers it
> with the plain function `Workflow.Template.parse/2`, keeping all template validation inside
> `parse/2`.

**10.4.1 Surface (lexical) grammar.** A template is written with the `~P` sigil (**P** for
*prompt*), an **uppercase** sigil so its content is a **single raw literal binary** with **no
interpolation and no escape processing** (like `~S`). The grammar below defines the language of
the `raw` binary the sigil delivers, written as a **maximal-munch lexical grammar with
lookahead**: at each position the lexer begins a `Tag` (whenever `<%` appears) or consumes one
`TextChar`. Only `AssignHole` is admissible; every other tag shape is grammar-**recognized** and
**rejected** with a caller-located diagnostic (§10.4.4).

```
Template :: Segment*          ; the lexical grammar of the `raw` binary the `~P` sigil delivers
Segment ::
  - Tag
  - TextRun
TextRun :: TextChar+
TextChar :: SourceCharacter [lookahead != EExTagOpen and != InterpolationOpen]
EExTagOpen :: `<` `%`
InterpolationOpen :: `#` `{`          ; rejected by Rule T.9
Tag ::
  - AssignHole                 ; the ONLY admissible tag (renders); all others rejected in 10.4.4
  - StatementTag               ; `<% … %>` (no `=`) — rejected (Rule T.2)
  - CommentTag                 ; `<%# … %>` — rejected (Rule T.7)
  - LiteralEscapeTag           ; `<%%` — rejected (Rule T.8)
AssignHole :: `<%=` TemplateWS* `@` AssignName TemplateWS* `%>`
StatementTag :: `<%` [lookahead != `=` and != `#` and != `%`] TagBody `%>`
CommentTag :: `<%#` TagBody `%>`
LiteralEscapeTag :: `<%%` TagBody `%>`
TagBody :: (SourceCharacter but not the sequence `%>`)*
AssignName :: (Letter | `_`) (Letter | Digit | `_`)*   ; recognizer ~r/\A@([A-Za-z_][A-Za-z0-9_]*)\z/
TemplateWS :: ' ' | '\t' | '\n' | '\r'          ; space, tab, line terminators (literal characters)
```

The sigil **delimiter** (`~P"…"`, `~P"""…"""`, `~P[…]`, `~P/…/`, …) is Elixir's own concern and
out of scope: `Template` constrains only `raw`, which keeps the grammar and the reference scanner
in exact agreement by construction. Because `~P` is uppercase, an inline `~P"a\nb"` carries the
two **literal** characters `\` and `n`, not a line terminator; to put a real newline in a
template use a heredoc `~P"""…"""` or a literal line break. **Disambiguation (normative):**
wherever `<%` (`EExTagOpen`) begins it MUST be lexed as the start of a `Tag`, never as text
(maximal munch), so no `<%…` sequence is ever derivable as template text; an `EExTagOpen` not
closed by `%>` before end-of-template is a compile error (Rule T.6), not a fallback to text.
The implemented core also rejects any raw `#{` sequence before tag scanning (Rule T.9); even
though uppercase sigils would otherwise treat it as literal text, the prompt-template surface keeps
all dynamic holes in the single `<%= @name %>` vocabulary.

**10.4.2 The inert `%Template{}` struct (semantic model).**

```
%Workflow.Template{
  segments :: [String.t()],   ; alternating literal text runs; length(assigns) + 1
  assigns  :: [String.t()]    ; referenced assign names, in source order
}
```

- Every `segments` entry is a **binary** (a slice of `raw`), never a charlist. For `n` holes,
  `segments` contains `n + 1` entries: the literal text before the first hole, the text between
  holes, and the final tail. Empty text runs are retained. `assigns` stores the scanned assign
  names as strings in the same order as the holes.
- An `@name` inside a template is **template syntax, not Elixir** — a scanned run of characters,
  never a variable or module-attribute AST node; macro hygiene does not apply. The struct holds
  **zero closures** and is `Macro.escape`-able into a compile-time constant (Principle 7).
- **Addressing.** A `%Template{}` has **no address** — inert data embedded in a consuming node's
  field, exactly like `%Workflow.Node.BudgetSlices{}` (§4.2). It is rendered *within* the
  execution of the node that holds it (an `agent`, §10.6, or `emit`, §10.7), under that node's key.

**10.4.3 Compile-time lowering (a hand-rolled binary scanner).** `Workflow.Template.parse/2` is a plain
compiler function — a direct binary scanner over `raw` — called by `parse/2` the moment it
matches a `{:sigil_P, meta, [{:<<>>, _, [raw]}, mods]}` node in an admissible prompt position; it
does not assign semantics to `mods`; current modifiers are accepted as a no-op and MUST NOT affect
the lowered template. It calls **no** `EEx.tokenize`, **no** `EEx.Engine`, and **never**
`Code.string_to_quoted` on a hole body.

```
Template.parse(raw, env):              ; a plain function CALLED FROM parse/2 — no macro expansion
  - If raw contains the two-byte sequence `#{`: Return {:error, Finding at the sigil} (Rule T.9).
  - Return Scan(raw, empty List, empty List, env).

Scan(source, segments, assigns, env):
  - If source contains no `<%`:
    - Return {:ok, %Template{segments: reverse([source | segments]), assigns: reverse(assigns)}}.
  - Let literal be the bytes before the first `<%`.
  - Let rest be the bytes after that opener.
  - Return ScanTag(literal, rest, segments, assigns, env).

ScanTag(literal, rest, segments, assigns, env):    ; rest is the suffix after `<%`
  - If rest begins with `=`:
    - If the suffix after `=` contains no `%>`: Return {:error, Finding: missing `%>`} (Rule T.6).
    - Let body be the bytes strictly between `=` and the first `%>`.
    - Let trimmed be body with leading/trailing TemplateWS removed.
    - If trimmed matches ~r/\A@([A-Za-z_][A-Za-z0-9_]*)\z/ capturing name:
      - Let remaining be the bytes after the first `%>`.
      - Return Scan(remaining, [literal | segments], [name | assigns], env).
    - Otherwise: Return {:error, Finding: only `<%= @name %>` holes are allowed} (Rules T.1, T.3).
  - Otherwise:
    - Return {:error, Finding: only `<%= @name %>` holes are allowed} (Rules T.2, T.7, T.8).
```

Every branch recurses on a strictly shorter suffix, returns, or raises — there is no
fall-through. "No embedded Elixir" is a **structural** guarantee of the recognizer, not a
validation applied after admitting a superset. Assign names are stored as strings; binding
resolution compares them to `Atom.to_string(binding_name)`, so no template assign atom is created.

**10.4.4 Validation rules (each with the smallest counter-example).** Template-*shape* rules are
enforced by the scanner as `parse/2` lowers the node; forbidden **expression** forms take the
forbidden-form `raise` path, a rejected **tag shape** with no embedded expression yields a
`Finding`, both anchored at the sigil's `meta`. Name-resolution rules are checked by the
**consuming** combinator's `parse/2` walk under the threaded `BindingEnv`.

- **Rule T.1 — a hole is a bare assign.** `~P"Improve <%= @draft + 1 %>"` (arithmetic) and
  `~P"Improve <%= String.upcase(@draft) %>"` (a call) are rejected.
- **Rule T.2 — no control statements.** `~P"<% if @ok do %>yes<% end %>"` is rejected.
- **Rule T.3 — no block expressions.** `~P"<%= for x <- @xs do %>...<% end %>"` is rejected.
- **Rule T.4 — every referenced assign resolves to an in-scope binding.**
  `agent(~P"Improve <%= @ghost %>")` with no preceding `let :ghost` is rejected at the consuming
  statement.
- **Rule T.5 — define-before-use.** An assign MUST resolve to a binding whose producer
  **lexically precedes** the consumer; a forward or self reference is rejected. (This guarantees
  the producer is journaled before the consumer renders.)
- **Rule T.6 — an `EExTagOpen` must be closed by `%>`.** `~P"literal <%= tag"` is a `Finding`, not
  silently literal text.
- **Rule T.7 — no comment tags.** `~P"keep <%# a note %> this"` is rejected (not text, not
  silently dropped).
- **Rule T.8 — no literal-escape tags.** `~P"escaped <%% not-a-tag %>"` is rejected; a literal
  `<%` is intentionally inexpressible.
- **Rule T.9 — no raw interpolation marker.** `~P"literal #{x}"` is rejected by the implemented
  scanner even though uppercase sigils do not interpolate it; write literal braces as text that
  does not form the `#{` sequence, or use `<%= @x %>` for a real dataflow hole.

**10.4.5 Render.** Rendering reuses §4.4's `RenderText` unchanged.

```
RenderTemplate(template, run_id, bindings, lane):
  - Let parts be TemplateParts(template, bindings, lane).
  - Return RenderText.of(run_id, parts).

TemplateParts(template, bindings, lane):
  - Let parts be the List [{:text, first(template.segments)}].
  - For each pair {name, text} from zip(template.assigns, tail(template.segments)), in order:
    - Let ref be the binding whose atom key string equals name.
    - Append ResolvePart(ref, lane) to parts.
    - Append {:text, text} to parts.
  - Return parts.

ResolvePart(ref, lane):
  - If ref is {:node, address}: Return {:bound_value, ref}.
  - If ref is {:map, address}: Return {:bound_list, ref}.      ; deferred map/gather support
  - If ref is {:element, over}: Resolve per the deferred map lane rules in §10.11.

RenderText(term):                       ; §4.4 VERBATIM (the shipped Workflow.Compiler.to_text/1)
  - If term is a binary: Return term unchanged.
  - Otherwise: Return inspect(term).
```

> **Note — the one place determinism is weaker.** `Kernel.inspect/1` has no canonical map-key
> order across Elixir versions, so a runtime string-keyed provider map is byte-stable only for a
> fixed host `inspect/1`. Authors needing cross-host byte stability MUST bind **binary** values
> (or pre-render via `map`). Binary bindings render byte-identically everywhere.

> **Note — structured bindings render as Elixir `inspect/1`, not JSON.** `RenderText`'s non-binary
> branch renders a term via `inspect/1`, so a **schema-bound** producer's value — a decoded JSON
> term (a map/list, §6.4.1), not a binary — splices **Elixir-literal** syntax into a downstream
> `~P` prompt. Injecting `let :bugs = agent(…, schema: %{"type" => "array", …})` as `<%= @bugs %>`
> yields text like `[%{"file" => "a.ex", "line" => 3}]` (Elixir map/atom syntax), **not** JSON — a
> compiling but misleading prompt. An author feeding structured data to a downstream model SHOULD
> therefore bind or produce a **binary** (prose) value, or pre-render it, and reserve structured
> (non-binary) bindings for cases where Elixir-inspect text is acceptable to the consuming agent.
> The same caveat applies to `emit` (§10.7) and `gather` (§10.9.1) prompts. This is a teaching note;
> the behavior is exactly the `RenderText` above.

**10.4.6 Conformance (template layer).**

- **DF-T1.** A `~P` template MUST be lowered by `parse/2` (via `Workflow.Template.parse/2`) at compile time
  to an inert `%Template{}` whose `segments` entries are all binaries; it MUST NOT compile to a
  closure or quoted expression, and the scanner MUST NOT call `EEx.tokenize`, `EEx.Engine`, or
  `Code.string_to_quoted` on a hole body. The implemented core rejects raw `#{` (Rule T.9) and
  treats sigil modifiers as no-op surface metadata.
- **DF-T2.** The scanner MUST admit only `<%= @name %>` holes and literal text and MUST accept and
  reject **exactly** the §10.4.1 language — every other `<%…` opener and every raw `#{` opener is
  a caller-located compile error at the sigil's `meta`.
- **DF-T3.** `RenderTemplate` MUST render assign values through §4.4's `RenderText` unchanged, so a
  template and the corresponding `verify`/`judge` splice render an identical binary identically.
- **DF-T4.** `template.assigns` MUST list referenced assign names in source order as strings,
  usable for name-resolution and binding resolution without re-scanning `segments`.

### 10.5 `let` — name a journaled output — Verdict: ADOPT

`let` binds a compile-time **name to an address**; the value is always fetched by folding the
journal (`BoundValue`). It creates no new value, no new paid effect, no new event, and no key —
the producer's own `agent_committed` is the binding's sole record.

**10.5.1 Surface (syntactic) grammar.**

```
LetStmt : `let` BindingRefAtom `=` Producer
BindingRefAtom :: `:` AtomName   ; LEXICAL — one atom-literal token `:name`, no whitespace
AtomName :: (`a`–`z` | `_`) (Letter | Digit | `_`)*   ; implemented binding-name recognizer; NO trailing ?/!
Producer :
  - AgentStmt                 ; binds the agent's journaled result ({:node, addr})
  - SynthesizeStmt            ; synthesize's output is an ordinary agent output
  - GatherStmt                ; DEFER, §10.9 (when adopted) — binds one agent_committed
  - `(` MapStmt `)`           ; DEFER, §10.9 — binds the ORDERED LIST of the map's lane results ({:map, addr})
```

The implemented core accepts only `AgentStmt` and `SynthesizeStmt`. `GatherStmt` and `MapStmt`
are listed here to keep the future extension closed and explicit, but both remain **DEFER** and
MUST be rejected by the current compiler. `AgentStmt`/`SynthesizeStmt`/future `GatherStmt` are
paren-call forms that need no extra parentheses. Future `MapStmt` is the **only** block-bearing
producer and MUST be parenthesized — `let :xs = (map … do … end)` — because without parens the
`do…end` attaches to `let` (the outermost paren-less call), leaving `map` bodyless.
`parse/2` matches the uniform one-arg shape
`{:let, meta, [{:=, _, [name_ast, producer_ast]}]}`, requires `name_ast` to be an atom literal,
and dispatches `producer_ast` back through the ordinary per-form entry under the in-scope
`binding_env`, so every producer kind lowers unchanged. It MUST reject the two-arg
`{:let, _, [_, [do: _]]}` shape (an un-parenthesized `map`) with a caller-located hint (Rule L.5),
never repair it by reattaching the block.

**10.5.2 Inert representation + addressing + idempotency.**

The implemented core has **no `%Workflow.Node.Let{}` struct**. `let` is compile-time binding
syntax: the producer node is inserted into the top-level node list at address `[i]`, exactly where
an unbound producer would have appeared, and `BindingEnv` records `name → {:node, [i]}`. `let`
therefore introduces **no key** of its own; the producer keys exactly as any agent/synthesize
turn. The bound value is **not** part of any key (keys stay value-free, Principle 2). Future
deferred `map` binding would record `name → {:map, [i]}`.

**10.5.3 Validation rules (smallest counter-examples).**

- **Rule L.1 — binding name is a literal atom matching `AtomName`.** `let x = agent("go")` (not an
  atom) and `let :ok? = agent("go")` (trailing `?` — not an `AtomName`, so no `~P` template could
  ever reference it) are rejected.
- **Rule L.2 — producer is a bindable node.** `let :v = verify("claim", voters: 3)` (a panel is
  not bindable — its outcome is a fold) and `let :v = log("hi")` (`log` commits no result) are
  rejected.
- **Duplicate binding names — accepted, latest binding wins for subsequent consumers.** The
  implemented core does **not** reject a second `let :d`; `BindingEnv` is updated with the later
  address. A consumer between the two bindings resolves `@d` to the first producer; a consumer
  after the second resolves `@d` to the second. A conforming implementation MAY warn, but MUST NOT
  make duplicate binding names a runtime ambiguity.
- **Rule L.4 — `let` is top-level-only (Tier-1 restriction).** A `let` inside a loop body or a
  `map` body is rejected; bindings resolve at `iteration = 0`.
- **Rule L.5 — a block-bearing producer MUST be parenthesized** (the two-arg `{:let, _, [_, [do:
  _]]}` shape), rejected with a caller-located hint to add parentheses.

**10.5.4 Execution algorithm.**

```
RunLet(producer, run_id, provider, prior, ctx):
  - Let r be RunNode(producer, run_id, provider, prior, ctx).   ; the producer's OWN path (§6.4)
  - Return r.                                                   ; the binding is compile-time; nothing extra committed
```

`RunLet` is conceptual only in the implemented core: execution runs the producer's ordinary path.
Determinism, exactly-once, and replay-safety are inherited verbatim. For an `agent`/`synthesize`
producer the producer commits one `agent_committed` at `[i]`, keyed and resumable exactly as any
agent; on resume the binding is re-derived by `ResolveRef` (`{:node} → BoundValue` folding that
same event). For a future `gather`, the same one-`agent_committed` rule would apply. For a future
`map` producer the producer commits its own `map_started`/`map_completed` (§10.9.2) and its lanes' per-lane
`agent_committed`s; the binding is re-derived by `ResolveRef` (`{:map} → BoundList`, DF-M4) — `let`
itself still commits nothing. `let` adds no effect and no non-determinism, and runs exactly one node
(it does not iterate).

**10.5.5 Journal events. None new** — the producer's `agent_committed` is the binding's sole
record (a `let_bound{…}` marker would be pure redundancy; omitted per Principle 3).

**10.5.6 Conformance.**

- **DF-L1.** A `let` MUST bind a literal-atom name to a single producer node and MUST introduce
  **no** journal event or key of its own. In the implemented core, `agent` and `synthesize` are the
  only bindable producers, and the binding is the producer's own `agent_committed` (no new event).
  Future `gather` would follow the same rule; future `map` would bind the ordered lane list
  resolved via `BoundList` per DF-M4, and the `map`'s `map_started`/`map_completed` would be the
  **producer's** events, not `let`'s. `let` is the sole value-binding construct admitted by the
  narrowed Non-goal §1.2′.
- **DF-L2.** A bound value MUST be resolvable **only** by a pure fold over the journal via
  `ResolveRef` (`{:node} → BoundValue`, `{:map} → BoundList`); an implementation MUST NOT cache the
  value in process state.
- **DF-L3.** Binding names are top-level only in Tier 1; a bound reference MUST resolve at
  `iteration = 0`. If a name is rebound, subsequent consumers MUST resolve to the latest
  lexically-preceding binding, while earlier consumers keep the address captured when they were
  parsed.
- **DF-L4.** `parse/2` MUST recognize `let` as the uniform one-arg `{:let, _, [{:=, _, [name,
  producer]}]}` shape, MUST require `name` to be an atom literal, MUST dispatch `producer` through
  the ordinary node path, and MUST reject the two-arg block-bearing shape (Rule L.5) rather than
  repair it.

### 10.6 Prompt injection — the core dataflow edge — Verdict: ADOPT

Let an `agent`'s prompt be a `%Template{}` (§10.4) that renders in-scope bindings, so a downstream
agent acts on an upstream journaled result.

**10.6.1 Surface grammar.** Extend `AgentStmt` (§3.2) so the prompt may be a template:

```
AgentStmt : `agent` `(` Prompt AgentOpts? `)`
Prompt :
  - StringLiteral            ; the existing literal form (§3.2) — unchanged
  - TemplateLiteral          ; a ~P template (§10.4) — implemented only for top-level agents; future map-lane position is DEFER (Rule P.1)
```

`TemplateLiteral` is a **syntactic** symbol (single colon) denoting a `~P` sigil token whose raw
content is the §10.4.1 `Template` language (the **lexical** production `Template :: Segment*`); the
two names are kept distinct so `Template` always means the raw-content grammar and never the sigil
token. The grammar admits `TemplateLiteral` in every `AgentStmt`; **validation (Rule P.1) narrows** it.

**10.6.2 Inert node struct (widens `%Node.Agent{}`).**

```
%Workflow.Node.Agent{
  address, prompt :: String.t() | %Template{},        ; widened
  bindings :: %{atom() => BindingRef} | %{},           ; NEW; %{} for a literal prompt
  schema :: map() | nil, retries :: non_neg_integer()  ; default 2
}
```

`bindings` is materialized at construction by folding `template.assigns` against `binding_env`
(raising Rules T.4/T.5). The struct is escapable (addresses only). The key is unchanged and
value-free: `(run_id, address, iteration, attempt)`; the **rendered** prompt is journaled in
`agent_committed.prompt`, never in the key.

**10.6.3 Validation rules.** Assigns resolve (Rules T.4/T.5); interpolation is still rejected (a
literal `"…#{}…"` is a call form, not a binary). **Rule P.1 — closed whitelist:** in the
implemented core, a `%Template{}` prompt is admissible on a **top-level `agent`** and a
top-level `emit` template. "Top-level" includes a `let`-bound producer, because implemented
`let` lowers to the producer at the same top-level address (§10.5.2), so `let :x =
agent(~P…)` is admissible exactly as the unbound top-level agent form is. The deferred future
whitelist would add `map`-lane `agent` and top-level `gather` positions when those idioms are
promoted. A `%Template{}` prompt is rejected in two families, each by an **active guard**
matching `{:sigil_P, meta, _}`: (1) observational/literal-only positions (`verify`/`judge`
subject/candidate, `return`, `phase`/`log`, and a `synthesize` prompt or inputs — a `let`-bound
`synthesize` stays literal-only) — panels stay literal-only (Principle 8); (2) nested
agent positions (`parallel` branch, `pipeline` stage, `fan_out` body, loop body). The guard emits
a precise diagnostic ("templates are not admissible in a `parallel` branch"; for a `synthesize`,
"templates are not admissible in a `synthesize` prompt — use `gather` (§10.9.1) to fold journaled
inputs") rather than a misleading "unbound assign". So although §10.5.1 lists `synthesize` among
the `let`-bindable Producers, its prompt admits no `%Template{}`: a fold of journaled values into a
prompt is expressed by `gather` (§10.9.1), not `synthesize`.

```counter-example
let :x = agent("draft")
verify(~P"Is <%= @x %> sound?", voters: 3)   # family 1 — template subject on a panel — REJECTED
```

```counter-example
let :x = agent("draft")
parallel([agent(~P"Improve <%= @x %>")])     # family 2 — template prompt in a `parallel` branch — REJECTED
```

**10.6.4 Execution algorithm.** In the implemented core, `RunAgent`/`CommitAttempt` (§6.4) keep
their base arity. Before the provider call, the runner materializes any template prompt to a
binary; the prompt handed to `CallProvider` is therefore always a `String.t()`:

```
EffectivePrompt(node, run_id):
  - If node.prompt is a binary: Return node.prompt.                  ; literal — unchanged
  - Return RenderTemplate(node.prompt, run_id, node.bindings, nil).  ; §10.4.5; implemented core has no map lane
```

A top-level agent evaluates `CallProvider(provider, EffectivePrompt(node, run_id), node.schema,
key)`. The deferred `map` proposal (§10.9.2) is the only place that would require a lane index; when
promoted, it would widen `EffectivePrompt`/`BuildAgent` with a trailing `lane` argument so a
`{:element, over}` binding can resolve against `%{index: e}` (§10.11). Until `map` is promoted,
there is no `lane` value in the implemented runtime.
The materialized string is journaled verbatim **at commit** (never re-rendered on replay, DF-P3).
Because producers commit before the consumer runs (Rule T.5), every attempt renders from the same
journaled terms, so a rejected attempt and the eventual commit journal a byte-identical prompt for
**binary** bindings (and for **non-binary** bindings only up to the §10.4.5 `inspect/1`
host/version caveat under a cross-version resume). This is admitted by the amended provider port
§6.4.1′ (§10.3): `CallProvider` still receives only `(prompt, schema, key, opts)`.

**10.6.5 Journal events. None new** — the rendered prompt rides the existing
`agent_committed.prompt` (and `agent_attempt_rejected.prompt`), per §6.4-commit′ / §7.2′ / §7.3′.

**10.6.6 Conformance.**

- **DF-P1.** An `agent` prompt MUST be either a literal string or an inert `%Template{}` over
  in-scope bindings, rendered per §6.4.1′; interpolation and computed prompts remain rejected. A
  `%Template{}` prompt is admissible **only** on a top-level agent in the implemented core; the
  `map`-lane position is reserved for the deferred `map` proposal (Rule P.1).
- **DF-P2.** The rendered prompt MUST be a deterministic `RenderTemplate` fold over the journal,
  materialized before the call and journaled verbatim at commit in the `prompt` payload of **every**
  prompt-bearing agent event (`agent_committed.prompt` **and** `agent_attempt_rejected.prompt`),
  **not** the inert `%Template{}` held in `node.prompt`; it MUST NOT enter the idempotency key.
- **DF-P3.** A resumed, already-committed agent MUST replay its journaled prompt and MUST NOT
  re-render.

### 10.7 `emit` — render the terminal result from bound values — Verdict: ADOPT

Produce the run's terminal value by **rendering a template over bound values**, rather than by
returning a compile-time literal (`return`).

**10.7.1 Surface grammar.** `EmitStmt : `emit` `(` TemplateLiteral `)`` — **template-only** (unlike
`gather`), where `TemplateLiteral` is the §10.6.1 syntactic symbol for a `~P` sigil token (its raw
content the §10.4.1 lexical `Template` language).

```elixir
emit(~P"""
# Review Report

## Findings
<%= @findings %>

## Recommended patch set
<%= @report %>
""")
```

**10.7.2 Inert node struct + addressing + idempotency.**

```
%Workflow.Node.Emit{ address :: address(), template :: %Template{}, bindings :: %{atom() => BindingRef} }
```

Address `[i]`. **No idempotency key** — `emit` performs no paid effect (pure render). Its rendered
value flows into the terminal `run_completed` event.

**10.7.3 Validation rules.**

- **Rule E.1 — assigns resolve** (Rules T.4/T.5). `emit(~P"Result: <%= @answer %>")` with no
  preceding `let :answer` is rejected.
- **Rule E.2 — final terminal from `return` OR `emit`.** §5.10.2 is widened: a workflow MUST end
  with a final top-level `return` **or** `emit`; both set the terminal value. A workflow with a
  `let` but no final `return`/`emit` is rejected (no terminal value), and any top-level node after
  a `return`/`emit` is rejected.
- **Rule E.3 — `emit` is top-level-only** (Tier-1 restriction), mirroring `let`/`map`/`gather`.
- **Rule E.4 — `emit`'s argument MUST be a `~P` Template** (active guard). `parse/2`'s `emit`
  clause MUST match `{:emit, meta, [{:sigil_P, _, _}]}` and reject any other argument. The real
  hazard is an accept-vs-reject divergence on a **binary** argument: a literal `emit("done")` hands
  `to_text/1` a binary it would cleanly wrap as one `{:text, "done"}` segment and accept, so
  without the guard one implementer rejects it (Template-only grammar) while another accepts it as
  a literal terminal. `emit` of a pure literal is exactly `return`, so it is rejected with a hint.

```counter-example
emit("done")     # a literal-string emit — REJECTED (that is `return`); write `return("done")` or `emit(~P"done")`
```

**10.7.4 Execution algorithm.**

```
RunEmit(node, run_id, ctx):
  - Let value be RenderTemplate(node.template, run_id, node.bindings, nil).   ; §10.4.5; emit is top-level, lane nil
  - Return {:cont, ctx with return = value}.         ; sets the terminal value (bare, exactly as §6.3 `Return`); commits no event
```

`emit` mirrors `return` (§6.3): it sets `ctx.return` and commits no event of its own. The compiler
requires `emit`/`return` to be the final top-level node, so no later top-level node can overwrite
that terminal value. The rendered string is a pure journal fold (§10.4.5) and flows into
`run_completed.value`, so the terminal value is a deterministic function of journaled data. `emit`
runs once.

**10.7.5 Journal events. None new** — the rendered value is captured in the existing terminal
`run_completed.value`, exactly as a `return` value is. (An optional `emit_rendered{address, value}`
marker is RECOMMENDED-not-required for observability.)

**10.7.6 Conformance.**

- **DF-E1.** `emit` MUST set the terminal value to a deterministic `RenderTemplate` fold over the
  journal; the value MUST be journaled in `run_completed.value`.
- **DF-E2.** A workflow MUST end with a final top-level `return` or `emit`; that final terminal
  node supplies the terminal value.
- **DF-E3.** `emit` MUST commit no paid effect and MUST NOT allow later top-level nodes; the
  compiler enforces terminal-final placement.
- **DF-E4.** `emit`'s argument MUST be a `~P` `Template`; `parse/2` MUST match `{:emit, meta,
  [{:sigil_P, _, _}]}` and actively reject any non-template argument with a caller-located `Finding`
  — never stringify it via `to_text/1`.

### 10.8 pipeline-with-dataflow — Verdict: ADOPT (by composition)

**No new combinator.** Sequential threading falls out of `let` + prompt injection + top-level
sequencing (§6.11) + define-before-use. Each `let` binds a stage's journaled output; the next
stage injects it:

```elixir
let :draft   = agent("Write a draft.")
let :review  = agent(~P"""
Review this draft:

<%= @draft %>
""")
let :final   = agent(~P"""
Revise the draft to address the review.

Draft:
<%= @draft %>

Review:
<%= @review %>
""")
emit(~P"<%= @final %>")
```

This is exactly the data-flow the current `pipeline` combinator refuses to provide (§11.4 G).
Extending the `pipeline` *combinator* (threading across item lanes) is **DEFERRED** — the
`let`-chain covers sequential threading at top level with zero new mechanism.

- **DF-C1 (conformance).** An implementation that ships `let` + prompt injection MUST make the
  `let`-chain above work with no additional feature; sequential threading is a consequence, not a
  combinator.

### 10.9 Deferred idioms — `gather` and `map` (specified, marked DEFER)

Both are specified to the same bar so they are ready when the wall appears, but neither ships in
the core dataflow slice.

**10.9.1 `gather` — fold a bound collection into one value with a NODE (DEFER).** `synthesize`
generalized from **literal** to **journaled** inputs.

- **Grammar.** `GatherStmt : `gather` `(` Prompt `)`` — reuses `AgentStmt`'s
  `Prompt : StringLiteral | TemplateLiteral` (§10.6.1) (a literal `gather` is grammatical but
  pointless — it is `synthesize` with no inputs).
- **Struct + addressing.** `gather` is dispatched as a **schemaless agent turn** — an ephemeral
  `%Agent{schema: nil, retries: 0}` built at **runtime** over its rendered template — analogous to
  how the implemented `synthesize` is dispatched: at **compile time** `synthesize` keeps its own
  distinct `%Node.Synthesize{}` struct (it is *not* rewritten to `%Agent{}`), and only at **runtime**
  dispatch does §6.3 construct an ephemeral `%Agent{… schema: nil, retries: 0}` and delegate to
  `RunAgent`. By the same choice `gather` needs no schema/retries and reduces to one schemaless agent
  turn at runtime; an implementation MAY carry a thin distinct `%Gather{}` producer struct through
  compilation (as `synthesize` carries `%Node.Synthesize{}`), which is why §10.5.2 lists `%Gather{}`
  among the producer structs. When carried, its fields mirror `%Emit{}` (§10.7.2) — a rendered
  template over bound values:

```
%Workflow.Node.Gather{ address :: address(), template :: %Template{}, bindings :: %{atom() => BindingRef} }
```

  It is escapable (addresses + inert `%Template{}` only, zero closures); `bindings` is materialized
  from `template.assigns` against `binding_env` exactly as `%Agent{}`/`%Emit{}` (§10.6.2/§10.7.2).
  Addressing and idempotency are an ordinary agent's.
- **Validation.** Assigns resolve (Rules T.4/T.5); no schema/retries options in Tier 1;
  top-level-only (mirroring `let` Rule L.4). `gather(~P"Summarize <%= @missing %>")` with no
  binding is rejected.
- **Execution.** Identical to a schemaless agent (§6.4) with a rendered prompt (§10.6.4); one turn,
  trivially terminating.
- **Events. None new** — one ordinary `agent_committed`.
- **Conformance. DF-G1:** `gather` MUST reduce to one schemaless agent turn over a rendered
  template; its result MUST be an ordinary `agent_committed`, bindable by `let`. **DF-G2:** every
  fold of a collection into one value in Tier 1 MUST be a node (`gather`) or the existing
  accumulator machinery — never a lambda or an in-language reducer.

**10.9.2 `map` — node-per-element over a bounded collection (DEFER).** The heaviest idiom:
runtime-decided width, per-lane re-addressing, a structural `max:` cap, a new concurrent region,
and the **only** two new journal events in the whole extension. Single-agent lanes in Tier 1
(multi-stage lanes → Tier 2).

- **Grammar.**

```
MapStmt : `map` ElementName `,` MapOpts `do` MapLane `end`
ElementName : BindingRefAtom
MapOpts : MapOpt (`,` MapOpt)*     ; unordered keyword list
MapOpt : `over:` BindingRefAtom (REQUIRED) | `max:` IntegerLiteral (REQUIRED) | `max_concurrency:` IntegerLiteral (OPTIONAL)
MapLane : AgentStmt                ; EXACTLY ONE agent per map lane (Tier-1); distinct from §3.9's `AgentLane : AgentStmt+`
```

- **Struct.**

```
%Workflow.Node.Map{
  address, element_name :: atom(),
  over :: BindingRef,               ; {:node, addr} (a list-valued producer) OR {:map, addr} (another map's ordered list)
  max :: pos_integer(), body :: [Agent.t()],   ; one-element lane
  max_concurrency :: pos_integer() | nil
}
```

  Lane `e`'s agent is addressed `address ++ [e, 0]`, keyed `(run_id, address ++ [e, 0], iteration
  = 0, attempt)` — the element value is **not** in the key. The lane agent is parsed under the
  element-extended env `Map.put(binding_env, element_name, {:element, over})` (a disjoint extension,
  Rule M.5).
- **Validation** (each rule with the smallest invalid counter-example, in the T./L./E. style).
  - **Rule M.1 — `over:` names an in-scope list-valued binding** (a REQUIRED key). A value that is
    not a list fails closed at runtime (`MapOverNotAList`, §10.11), never coerced.
    Counter-example: `map :x, max: 3 do agent(~P"do <%= @x %>") end` — no `over:` — REJECTED.
  - **Rule M.2 — `max:` is a REQUIRED positive-integer literal.** An unbounded map is
    unexpressible; `max:` is a structural termination cap resolved at compile time, never a binding
    or a computed expression. Counter-example: `map :x, over: :xs, max: budget do agent(~P"<%= @x %>") end`
    — non-literal `max:` — REJECTED.
  - **Rule M.3 — the lane body is exactly one agent** (`MapLane`, Tier-1; multi-stage lanes are
    Tier-2). Counter-example: `map :x, over: :xs, max: 3 do agent(~P"a <%= @x %>"); agent(~P"b <%= @x %>") end`
    — two lane stages — REJECTED.
  - **Rule M.4 — `map` is top-level-only** (mirroring `let` Rule L.4; bindings resolve at
    iteration 0). Counter-example: a `map` nested inside a `while_budget` or `parallel` body —
    REJECTED.
  - **Rule M.5 — `ElementName` must not shadow an in-scope binding.** The lane env is the
    **disjoint** extension `Map.put(binding_env, element_name, {:element, over})`; if
    `element_name` already names an in-scope binding the extension is not disjoint.
    Counter-example: `map :xs, over: :xs, max: 3 do agent(~P"<%= @xs %>") end` — the element name
    `:xs` shadows the `over:` binding `:xs` — REJECTED.
  - **Rule M.6 — the lane MUST use its element** (its `assigns` include `ElementName`); otherwise
    every lane renders a byte-identical prompt and the fan-out is pointless.
    Counter-example: `map :x, over: :xs, max: 3 do agent("go") end` — the lane ignores `@x` —
    REJECTED.
  - **Rule M.7 — `max_concurrency:` is OPTIONAL and, when present, MUST be a positive-integer
    literal** (reusing the Rule M.2 literal check: a binding or a computed expression is rejected,
    and so is any value `< 1` — `0` or a negative is not a `pos_integer()`). It caps the number of
    in-flight lanes (`cap` in `RunMap`); when absent the cap defaults to the full `width` — all
    lanes at once, mirroring §6.9 `parallel`.
    Counter-example: `map :x, over: :xs, max: 3, max_concurrency: budget do agent(~P"<%= @x %>") end`
    — non-literal `max_concurrency:` — REJECTED (and `max_concurrency: 0` is likewise REJECTED).
- **Execution.** `RunMap` resolves `over` via `ResolveRef` (`{:node} → BoundValue`, `{:map} →
  BoundList`; **never** `BoundValue` directly — DF-M5), computes `width = min(observed_length,
  max)`, builds the ordered lane list as `width` pairs `{lane_agent, %{index: e}}`, and drives the
  base `RunConcurrently` (§6.9 — its `(inputs, cap, fun)` signature is genuinely unchanged) over a
  **lane runner** that threads each lane's 0-based index into its agent:

```
RunMap(node, run_id, provider, prior, ctx):
  - Let {width, seq} be DecideMapWidth(node, run_id, prior, ctx.seq).   ; replay-verbatim on resume; resolves+journals `over` only on the fresh path
  - Let {cap} be node.max_concurrency or max(width, 1).    ; OPTIONAL max_concurrency (Rule M.7); nil ⇒ all lanes at once, mirroring §6.9 RunParallel
  - Let {lanes} be the List [ {the lane agent re-addressed node.address ++ [e, 0], %{index: e}} for e in 0..(width - 1) ].
  - Let {results} be RunConcurrently(lanes, cap, fn {lane_agent, lane} ->
      BuildAgent(lane_agent, run_id, provider, prior, lane) end).   ; lane threaded into §10.6.4 EffectivePrompt
  - Let {r} be CommitLanes(results, run_id, seq).          ; commit each lane's events in lane order
  - If {r} is {:ok, seq'}:
    - Return {:cont, ctx with seq = CommitMarker(map_completed, node, prior, seq')}.   ; payload %{address}, idempotent on resume (§6.3)
  - If {r} is {:halt, seq', reason}: Return {:halt, ctx with seq = seq', reason}.       ; a failed lane aborts the run — its consumer never runs (§6.1, §10.11)

DecideMapWidth(node, run_id, prior, seq):
  - If a map_started for node.address is in {prior}:            ; RESUME — replay the journaled decision verbatim
    - Return {that event's payload.width, seq}.                ; width AND observed_length are read from the journal, never re-derived from `over` (DF-M2)
  - Let {list} be ResolveRef(node.over, run_id, nil).          ; FRESH path only — {:node} list-valued OR {:map} ordered list — DF-M5
  - If list is not a list: Raise MapOverNotAList (§10.11) — abort the run (exit 1), never coerce.
  - Let {width} be min(length(list), node.max).
  - Let {seq'} be CommitMarker(map_started, node, prior, seq).  ; payload %{address, over, observed_length: length(list), width, max: node.max}; keyed (type, address), idempotent on resume (§6.3)
  - Return {width, seq'}.
```

  So `RunConcurrently` itself is unchanged (its `fun` closes over the per-lane `%{index: e}`), but
  `BuildAgent` (§6.9) **is extended** with a trailing `lane` argument — base callers pass
  `lane = nil`; only this map lane runner passes `%{index: e}` (§10.6.4). A lane agent whose `~P`
  prompt references the element therefore resolves `{:element, over}` against `lane.index` (§10.11).
  The earlier "§6.9 unchanged" claim is thus made precise: the concurrency primitive is reused
  as-is, the per-agent builder gains the lane. Bounded termination: at most `max` lanes, each one agent.
- **Events — the only two new in §10.**

| type | payload keys |
|---|---|
| `:map_started` | `address, over, observed_length, width, max` |
| `:map_completed` | `address` |

  `map_started.over` stores the whole `BindingRef` tuple verbatim; `observed_length` is replayed
  verbatim (never recomputed). A `let`-bound map's value is `BoundList` over the lanes'
  `agent_committed.result` plus `map_started.width` — no third event.
- **Conformance. DF-M1:** `max:` MUST be a positive-integer literal (an unbounded map rejected);
  `max_concurrency:`, when present, MUST likewise be a positive-integer literal (Rule M.7), and
  when absent the lane cap defaults to the full width.
  **DF-M2:** the width decision MUST be journaled in `map_started.width` and replayed verbatim.
  **DF-M3:** each lane MUST be a single agent keyed on `(run_id, address ++ [e, 0], iteration,
  attempt)`. **DF-M4:** a `let`-bound `map` MUST resolve to the ordered List of its lanes' terminal
  results via `BoundList` (a resolution rule, no new event). **DF-M5:** `over:` MAY name any
  list-valued binding — a `{:node}` producer whose journaled result is a list **or** a `{:map}`
  (its ordered lane-result List), resolved via `ResolveRef`, never `BoundValue` directly.

### 10.10 Rejected idioms — documented as out-of-Tier-1

Two candidate idioms cross the Tier-1/Tier-2 line. They are specified precisely enough to be
**implementable as excluded**: a conforming implementation must reject them.

**10.10.1 `select` / `when` (REJECT).** Choosing among literal branches by a predicate over a bound
value (`select @verdict do; true -> agent("ship"); false -> agent("revise"); end`) is **control
flow**, and the thesis is *data flow, not control flow* (§10.1). It violates Principle 8 and §6.10
("no conditional or branching combinator"): it chooses **which subtree runs** on a runtime value.
This is categorically distinct from the existing value→control edges (`while_budget until:`,
`until_dry` dryness), which are **size-only** folds that affect only **loop stop**, never which
node runs. The Tier-1 alternative: render the value into **one** agent's prompt and let the
**agent** branch internally — semantic branching belongs in the model's reasoning, not the
workflow graph.

```counter-example
let :v = verify("claim", voters: 3)     # (already rejected: panels aren't bindable, Rule L.2)
select @v do                            # a branching combinator — NOT in the vocabulary — REJECTED
  true  -> agent("ship it")
  false -> agent("revise it")
end
```

- **DF-X1 (conformance).** An implementation MUST NOT provide any combinator that selects which
  node/subtree runs based on a runtime value. Value-dependent control flow remains unexpressible
  (C2, Principle 8).

**10.10.2 `reduce` with a closed in-language reducer (REJECT for Tier 1).** Folding a bound
collection into one value with a **closed operator** rather than a node (`reduce(:n, over: :items,
with: :count)`) is deterministic and closure-free, so it does not break the hard invariants — but
it drifts toward **in-language computation** (`:count` → `:sum` → general arithmetic is the exact
§1.2 boundary). `gather` (a node fold) and the existing accumulator `count()` (§6.8) already cover
real needs, so Tier 1 has no unmet need a closed reducer uniquely serves. **REJECT** until a
concrete corpus wall shows `gather` + accumulators are insufficient; then admit the smallest set
(likely just `:concat` of binaries), never arithmetic.

```counter-example
reduce(:n, over: :items, with: :count)   # an in-language reducer — REJECTED (use gather or count() in a predicate)
```

- **DF-X2 (conformance).** An implementation MUST NOT provide an in-language collection reducer in
  Tier 1; collection folds are nodes (`gather`) or accumulators only.

### 10.11 Shared machinery, output & error format

**Binding resolution (shared by every idiom).** `BindingRef` is `{:node, address}` | `{:map,
address}` | `{:element, over_ref}`. `BindingEnv` is a compile-time ordered map `name(atom) →
BindingRef` threaded through parsing so only lexically-preceding bindings are in scope (Rule T.5);
there is **no** runtime name→value map. The implemented core emits only `{:node, address}` refs;
`{:map, address}` is support for the deferred `map` producer's ordered result list, and
`{:element, over_ref}` belongs only to the deferred `map` lane scope. At runtime a reference is
resolved by the pure journal fold `ResolveAssign → ResolveRef`, defined for **all three**
`BindingRef` shapes:

```
ResolveAssign(name, bindings, run_id, lane):   ; bindings :: %{atom() => BindingRef} (the node's field)
  - Let ref be bindings[name].                 ; name resolved at compile time (Rules T.4/T.5); always present
  - Return ResolveRef(ref, run_id, lane).

ResolveRef(ref, run_id, lane):
  - If ref is {:node, address}: Return BoundValue(run_id, address).
  - If ref is {:map, address}:  Return BoundList(run_id, address).
  - If ref is {:element, over}:                ; a map lane's element; lane is %{index: e}, e a 0-based lane index
    - Let list be ResolveRef(over, run_id, lane).   ; over is {:node, _} (list-valued) or {:map, _}
    - Return Enum.at(list, lane.index).             ; ZERO-BASED: lane.index ∈ 0..(width-1), matching lane address [i,0,e,0]

BoundValue(run_id, address):                   ; the single-agent producer fold (agent/synthesize/gather)
  - Fold the journal for the agent_committed at address with iteration == 0.
  - Return that event's payload.result.        ; exactly one such event exists once the producer has committed

BoundList(run_id, address):                    ; a map's ordered lane-result list
  - Let width be the width of the map_started at address (payload.width).
  - Return the List [ BoundValue(run_id, address ++ [e, 0]) for e in 0..(width - 1) ], in ascending e order.
```

`BoundValue` and `BoundList` are pure folds over already-committed events; `{:element, over}` never
folds directly but indexes the resolved list zero-based, so a `map`-lane agent template resolving
`@element_name` (env `{:element, over}`, §10.9.2; `lane = %{index: e}`, §10.6.4) yields the `e`-th
element of `over`'s resolved collection. Top-level bindings resolve at `iteration = 0`. Every
per-form compile step (the recursive compile entry `parse/2` delegates to per form, §5) threads an
additional in-scope `binding_env` — a trailing-argument extension, not an overload: the in-scope
`binding_env` at top level, the **empty** env `%{}` at the four nested positions (where templates
are actively rejected), and the element-extended env at the `map` lane.

**Journal events.** The dataflow **core** (Template + `let` + injection + `emit`) adds **zero** new
event types: `let` rides the producer's existing `agent_committed`; injection rides
`agent_committed.prompt` / `agent_attempt_rejected.prompt`; `emit` rides `run_completed.value`.
Deferred `gather` would also ride one ordinary `agent_committed`. Only the **deferred** `map` adds
two events (`map_started`, `map_completed`, §10.9.2). This preserves §7.1's "journal is the single
source of truth": every bound value is a fold over an event the producer already commits.

**Result shape & exit codes.** Unchanged from §7. A template that fails name resolution (Rules
T.4/T.5) or violates a template-shape rule (Rules T.1–T.3, T.6–T.9) is a **compile-time** error
located at the offending declaration (exit 6, validation — §7.5), never a runtime failure. A
schema-bound injected `agent` still fails closed on malformed structured output (retry-then-fail,
exit 8) exactly as §6.4.2; the rendered prompt changes what the agent is asked, not the error
model.

**Error model (pinned).** §10 introduces **no new** runtime error channel for the implemented
core. `let` and an injected `agent` inherit §6.1's abort/propagate model verbatim (a producer
failure aborts the run; its consumer never runs, so a bound value is unreachable only when the run
has already halted). Deferred `gather` would inherit the same model. The one new **runtime** failure
deferred `map` can raise — `MapOverNotAList` when `over:` resolves to a non-list (§10.9.2) — is a
crash of the live writer (exit 1), never a silent coercion, consistent with Principle 4 (fail
closed).

### 10.12 Conformance rollup

An implementation of the shipped dataflow core MUST satisfy DF-T1..DF-T4 (template),
DF-L1..DF-L4 (`let` over `agent`/`synthesize`), DF-P1..DF-P3 (top-level injection),
DF-E1..DF-E4 (`emit`), and DF-C1 (pipeline-by-composition). It MUST keep `gather` and `map`
out of the accepted surface until those DEFER sections are promoted, and it MUST reject the two
excluded idioms per DF-X1 (`select`/`when`) and DF-X2 (`reduce`). A future promotion of the
deferred idioms MUST additionally satisfy DF-G1..DF-G2 (`gather`) and DF-M1..DF-M5 (`map`).

Promotion of §10 into §1–§8 MUST also apply the §10.3 amendments in lockstep: it MUST NOT
surface an inert `%Template{}` where a reader expects a prompt string (§6.4-commit′ / §7.2′ /
§7.3′), and it MUST widen the closed-vocabulary count according to the live baseline without
weakening any of C2–C9 — every amendment is a strengthening, so the observably-equivalent clause
(§8) and every shipped invariant continue to hold.

---

## 11. Authoring guide for agents

This section is a practical guide for an agent authoring a workflow. It is non-normative;
§1–§8 plus the implemented §10 dataflow core are binding; DEFER/PROPOSED parts of §10 are not.

### 11.1 How to write a valid workflow

```elixir
defmodule MyFlow do
  use Workflow

  workflow "my-flow" do
    phase("scope")
    log("starting")
    agent("Do one unit of scoped work. Return prose.")
    return(:ok)
  end
end
```

Requirements you MUST meet:

1. `use Workflow`, then one `workflow "literal-name" do … end` block.
2. Every base prompt, name, and value is a **compile-time literal string/atom** — never a
   variable, never `"… #{interpolation} …"`, never a function call. For dataflow, use only
   `let` over a previous `agent`/`synthesize` and render with `~P` holes like `<%= @draft %>`.
3. The block terminates with a final `return(<literal>)` or `emit(~P"...")`.
4. Inside a loop body use only `agent`, `log`, `phase`, `collect`.
5. Compile with `mix compile`; every mistake is a located compile error.

Note (terminal placement): `return` and `emit` set the terminal value and must be the final
top-level statement. There is no early-exit or "return early on a condition" construct in this
vocabulary; a `return(:early)` followed by more top-level work is rejected by the compiler.
Put the `return`/`emit` you want as the result **last**.

### 11.2 The closed vocabulary at a glance

| Combinator | Shape | What it does |
|---|---|---|
| `phase("name")` | unique string | marks a milestone |
| `log("msg")` | literal string | emits a static log line |
| `agent("prompt")` | literal string | one agent turn (schemaless) |
| `agent("prompt", schema: …, retries: n)` | schema required with opts | fail-closed structured turn |
| `agent("prompt", label: "read:docs")` | label with or without schema | display label only; no semantic effect |
| `let :name = agent(…)` | top-level producer | binds the producer's journaled result for later `~P` rendering |
| `let :name = synthesize(…)` | top-level producer | binds a synthesized result for later `~P` rendering |
| `agent(~P"… <%= @name %> …")` | top-level only | renders previous `let` bindings into a prompt |
| `emit(~P"… <%= @name %> …")` | final top-level only | terminal value rendered from previous `let` bindings |
| `return(:atom)` | literal | terminal value |
| `parallel([agent(…), …])` | list of agents | barrier fan-out |
| `pipeline([items…], [agent(…), …])` | items × stages | per-item lanes, no barrier — **the item is a journal label only; it is NOT injected into stage prompts** (§3.4, §11.4 Use-case G) |
| `verify("subject", voters: N \| lenses: [..], threshold: …)` | literal subject | verification panel |
| `judge([cands…], by: [:c], pick: :max_score \| :min_score)` | literal candidates | scoring panel |
| `synthesize([inputs…], "prompt")` | literals | fold inputs into one turn |
| `while_budget reserve: N do … end` | body | loop while budget remains |
| `until_dry rounds: N, seen_by: [..] do … collect(into: :acc) end` | body must collect | loop until dry |
| `collect(into: :acc)` | body-only | fold iteration result into accumulator |
| `fan_out width: budget_slices(per: N) do agent(…) end` | agent lane | budget-scaled fan-out (**requires a run budget** — crashes without one; see §11.4 Use-case F) |

Not combinators: `budget_slices(per: N)` (only a `fan_out` width); the `until:` predicate
forms `count(:acc)`, `budget_remaining()`, `all_of([..])`, `any_of([..])`.

> *(Proposed §10 — dataflow: `gather(~P"…")` and `map :el, over: :xs, max: N do agent(…) end`
> remain DEFER; `reduce` and `select`/`when` remain REJECT.)*

Note (`phase`/`log` inside a loop body fire **once for the whole loop**, not per iteration):
both are keyed by `(type, address)` (§6.3), and a body node has one fixed address, so a body
`phase`/`log` commits exactly once — on the first iteration that reaches it — and is skipped
on every later pass. A `while_budget … do agent(…); log("did one unit") end` emits **one**
`log_emitted`, not one per iteration. To observe **per-iteration** progress, do **not** use a
body `log`; read the per-pass events instead — `iteration_started`, `loop_decision`, and
`accumulate` (§7.2) each carry the `iteration` index.

### 11.3 Top mistakes the compiler rejects (and the fix)

| Mistake | Error | Fix |
|---|---|---|
| Interpolated prompt `agent("do #{x}")` | interpolation is not allowed | Bind a previous producer with `let`, then render it with `agent(~P"do <%= @x %>")` or `emit(~P"do <%= @x %>")`. |
| Unbound dataflow assign `emit(~P"Report: <%= @draft %>")` with no previous `let :draft` | unbound template assign | Add `let :draft = agent("Draft the report.")` before the template, or use a literal `return`. |
| Template in a nested position `parallel([agent(~P"Improve <%= @draft %>")])` | template prompts are only allowed on top-level agents | Move the template agent to top level and bind its result with `let`, or keep nested agents literal-only. |
| Calling a helper `agent(build_prompt())` | external module call raises | Inline the literal prompt. |
| `agent("go", retries: 1)` with no schema | requires a `schema:` | Add `schema: %{…}` or drop the options. |
| `agent("go", label: :bad)` | label must be a string literal | Use a display string such as `label: "read:docs"`. |
| `agent("go", schema: %{type: "object"})` (atom keys) | *compiles*, but validation silently no-ops (accepts all output — `schema["type"]` is `nil`, §6.4.2) | Use **string** keys: `schema: %{"type" => "object", "properties" => %{…}, "required" => […]}`. |
| `return`/`emit` missing | workflow must terminate with `return` or `emit` | Add final `return(:ok)` (or any literal) or final `emit(~P"…")`. |
| `collect` at top level | must appear inside a loop body | Put it inside `while_budget`/`until_dry`. |
| `until_dry` body without `collect` | body must `collect` | Add `collect(into: :name)`. |
| `verify("f", voters: 3, lenses: [:a])` | not both | Pick one panel selector. |
| `verify("f", voters: 2, threshold: :majority)` | (works, but 2-panel majority = unanimous) | Use `>= 3` voters if you want true majority. |
| `fan_out width: 4` | must be `budget_slices(per: N)` | Use `width: budget_slices(per: 4)`. |
| `parallel([log("x")])` | branches must be agents | Every branch is one `agent(…)`. |
| Duplicate `phase("p")` | duplicate phase name | Give each phase a unique name. |
| `while_budget reserve: 8 do return(:ok) end` | `return` not allowed in a body | Return after the loop, at top level. |

### 11.4 Worked use-cases

**Use-case Dataflow 1 — draft → improve-this-draft → emit-report.** Bind the first
agent's journaled output, render it into a second top-level agent, then render the terminal
report with `emit`. No interpolation is used; the only dynamic holes are `~P` assigns over
previous `let` bindings:

```elixir
workflow "draft-improve-report" do
  let :draft = agent("Draft a concise project status update. Return prose.")

  let :improved = agent(~P"""
  Improve this draft for clarity and actionability.

  Draft:
  <%= @draft %>
  """)

  emit(~P"""
  # Project Status Report

  <%= @improved %>
  """)
end
```

**Use-case Dataflow 2 — review-gated pipeline by composition.** The DSL does not branch on
the review result. Instead, write the review into the next prompt and ask one later agent to
apply the gate semantically: if the review approves, return the draft unchanged; otherwise
revise it. This is a sequential `let` chain plus injection, not a new `pipeline` combinator:

```elixir
workflow "review-gated-composition" do
  let :draft = agent("Write a migration plan. Return prose.")

  let :review = agent(~P"""
  Review the migration plan. Return APPROVE or CHANGES plus brief rationale.

  Draft:
  <%= @draft %>
  """)

  let :final = agent(~P"""
  Apply this review gate to the draft.

  If the review says APPROVE, return the draft unchanged.
  If it says CHANGES, revise the draft to address the rationale.

  Draft:
  <%= @draft %>

  Review:
  <%= @review %>
  """)

  emit(~P"<%= @final %>")
end
```

**Use-case A — bounded iterative worker.** Do units of work until the budget runs low,
reserving 8 units:

```elixir
workflow "loop-until-budget" do
  while_budget reserve: 8 do
    agent("Do one unit of work toward the goal.")
  end
  return(:done)
end
```

**Use-case B — adversarial verification panel.** Check a claim from three perspectives,
surviving on majority:

```elixir
workflow "adversarial-verify" do
  verify("the reported bug reproduces on main",
    lenses: [:correctness, :security, :repro],
    threshold: :majority
  )
  return(:done)
end
```

**Use-case C — judge, then independently synthesize.** Score candidate plans, then fold all
candidates into one write-up:

```elixir
workflow "judge-panel" do
  judge(["plan A", "plan B", "plan C"], by: [:feasibility, :impact], pick: :max_score)
  synthesize(["plan A", "plan B", "plan C"],
    "Compare these plans and write up the strongest, justifying the choice.")
  return(:done)
end
```

Caution (`judge`'s winner does **not** flow into `synthesize`, Principle 8): `judge`
journals its winner (`judge_settled.winner`, §7.2), but panels are **observational** — that
winner is **never** passed to any later node. The `synthesize` agent sees only its own
literal `inputs` (all three candidates) and its literal `prompt`; it has **no** way to learn
which plan `judge` picked. A prompt like `"Write up the winning plan."` is therefore
**unanswerable** — the agent cannot know the winner — so this workflow instead asks
`synthesize` to re-derive the strongest plan from the candidates it can actually see. To
*act* on `judge`'s verdict, fold the journal **after** the run (`Status.judgments`, §7.3)
outside the workflow; there is no in-vocabulary judge→synthesize data flow (Principles 6, 8).

**Use-case D — dryness loop.** Keep discovering items until two consecutive rounds add
nothing new (deduped by `:id`):

```elixir
workflow "loop-until-dry" do
  until_dry rounds: 2, seen_by: [:id] do
    agent("Find more edge cases. Return a JSON array of objects, each with an \"id\" field.",
      schema: %{"type" => "array"})
    collect(into: :edge_cases)
  end
  return(:done)
end
```

Caution (`seen_by` needs the field to actually be present, §6.6.1): dedup projects each item
onto `[:id]`, so **every** harvested item MUST carry an `"id"`. The bare
`%{"type" => "array"}` schema above does **not** enforce that — it relies on the prompt
contract, so a round of id-less items all project to `%{id: nil}`, collapse to one, and the
loop can go dry after `rounds` even when real work was found. To make the requirement
fail-closed instead of silent, give the array object-typed items:

```elixir
until_dry rounds: 2, seen_by: [:id] do
  agent("Find more edge cases.",
    schema: %{"type" => "array",
              "items" => %{"type" => "object",
                           "properties" => %{"id" => %{"type" => "string"}},
                           "required" => ["id"]}})
  collect(into: :edge_cases)
end
```

**Use-case E — budget-bounded discovery with an early-stop predicate.** Keep discovering
items while the run still has budget above a reserve, but **stop early** once enough items
have been collected. The `until:` predicate references the `:items` accumulator the body
`collect`s into, and combines two early-stop conditions with `any_of` (stop when either
holds); `budget_remaining()` reads the live ledger (§6.7.1). Note the body **must**
`collect(into: :items)` for `count(:items)` to ever be non-zero (§3.8 note):

```elixir
workflow "budget-bounded-discovery" do
  while_budget reserve: 200,
    until: any_of([count(:items) >= 5, budget_remaining() < 500]) do
    agent("Emit one newly discovered item as a JSON array.",
      schema: %{"type" => "array"})
    collect(into: :items)
  end
  return(:done)
end
```

The loop still terminates unconditionally under `max_iterations` (default `1000`, §1.3
Principle 5) even if neither `until:` condition ever fires; the predicate only stops it
sooner. `all_of([...])` is the conjunction form (stop only when **every** listed condition
holds). The `budget_remaining()` operand reads the budget supplied at invocation
(`Workflow.Run.run(mod, provider: …, budget: N)`, §7.6); run without a `:budget` it is
`:infinity`, so `budget_remaining() < 500` is never true and only `count(:items) >= 5` (or
`max_iterations`) can stop the loop.

**Use-case F — budget-scaled fan-out (N identical replicas).** Scale the **number** of lanes
to the remaining budget and run one agent per lane. Every lane runs the **identical** prompt,
so this launches N **independent replicas** of the same task — `fan_out` injects nothing
per-branch (§3.9), so it cannot hand each lane a different slice. **Precondition:** `fan_out`
REQUIRES the run to have a budget — without one, `budget_remaining()` is `:infinity` and the
`fan_out` **raises at run time** (a run crash, exit 1; §6.10), because there is no budget to
slice. Always set a budget when you use `fan_out`:

```elixir
workflow "budget-fan-out" do
  fan_out width: budget_slices(per: 1000) do
    # A deliberately branch-agnostic prompt: every replica runs THIS exact text.
    agent("Investigate the search space and report findings.")
  end
  return(:done)
end
# Invoke with a budget (see §7.6 for the full entry API and options):
#   Workflow.Run.run(mod, provider: {MyProvider, []}, budget: 8000)
# `:provider` is REQUIRED; `:budget` is in total tokens; omit it and `fan_out` crashes.
```

Caution (fan_out lanes are identical replicas, §3.9): every lane runs the byte-identical
prompt above; no per-branch index or slice is handed to a lane. `budget_slices(per: 1000)`
decides **how many** replicas run (one per 1000 remaining tokens), **not** what each does. A
prompt like `"Investigate one slice of the search space"` is a **footgun** — no lane can know
which slice it is, so all N lanes do the same undifferentiated work. Use `fan_out` when N
independent replicas are what you want (e.g. diverse sampling of the same investigation); it
**cannot** partition work across lanes.

If `remaining` is smaller than `per` the computed width is `0`, which is legal: the region
runs zero lanes and leaves the result unchanged (§6.10). Unlike `while_budget` (which
tolerates an unbounded run), `fan_out` on an unbounded run is a hard crash — this asymmetry
is the one budget precondition to remember.

**Use-case G — per-item pipeline (the item is a journal label, NOT injected).** `pipeline`
runs one lane **per item**, each lane running the stage agents **sequentially** with **no**
barrier between items. The single most counterintuitive fact: a stage prompt does **not**
receive its item — every lane runs the **identical** literal stage prompts, and the item is
retained **only** as a journal label (`pipeline_started.items`, §7.2) recording which item a
lane ran (§3.4). There is no value binding (Principle 6), so an author who wants a lane to
act on its item MUST write that content into the prompt **literally**:

```elixir
# WRONG — every lane runs the same prompt; "the file" is not bound to file_a / file_b.
workflow "pipeline-wrong" do
  pipeline(["file_a.ex", "file_b.ex"], [agent("Analyze the file and report issues.")])
  return(:done)
end
# Both lanes journal the identical prompt "Analyze the file and report issues.";
# the items ["file_a.ex","file_b.ex"] appear only in pipeline_started.items as labels.
```

Because the item is never spliced in, express the per-item work as the pipeline's *shape*
(stages the same across items) and put anything item-specific into the literal stage text —
or, if each item needs a different prompt, use separate `agent` statements instead of a
pipeline:

```elixir
# RIGHT — the pipeline expresses a fixed 2-stage process applied per item; the stage
# prompts are deliberately item-agnostic (they operate on "the provided file"), and the
# journal's pipeline_started.items records which item each lane corresponds to.
workflow "pipeline-right" do
  pipeline(["file_a.ex", "file_b.ex"],
    [agent("Summarize the provided file's responsibilities."),
     agent("List the provided file's likely failure modes.")])
  return(:done)
end

# If the two files genuinely need DIFFERENT prompts, do not use pipeline — write the
# literal prompts out, one agent per item:
workflow "per-item-distinct" do
  agent("Analyze file_a.ex and report issues.")
  agent("Analyze file_b.ex and report issues.")
  return(:done)
end
```

Each `agent` prompt in production is a compile-time heredoc string with structured XML-style
sections (task, structured_output_contract, verification_loop, action_safety) — never
interpolated.

---

## Appendix A: Notation Conventions

**Grammar.** A `::` production is **lexical** (source characters to tokens; no ignored
characters between terminals). A `:` production is **syntactic** (tokens to tree; ignored
tokens permitted between terminals). `Symbol?` = optional, `Symbol+` = one or more,
`Symbol*` = zero or more, `A but not B` = `A` excluding `B`, `[lookahead != X]` = not
followed by `X`. Terminals are in `monospace`.

**Algorithms.** `Name(args):` followed by ordered steps executed top to bottom: `Let x be
…` introduces a value, `If … :` branches, `Return …` yields, `Raise …` signals a defined
error. Every path returns or raises. Sub-algorithms are referenced by call.

**Data collections.** List (ordered, duplicates allowed); Set / ordered set; Map / ordered
map. Ordered variants are used only where order is observable.

**RFC 2119 keywords** are interpreted per §8, normative only in uppercase.

## Appendix B: Grammar Summary

Lexical (`::`) — inherited from Elixir; the DSL-relevant subset:

```
StringLiteral :: `"` StringCharacter* `"`
IntegerLiteral :: `-`? Digit+
FloatLiteral :: `-`? Digit+ `.` Digit+ ((`e` | `E`) (`+` | `-`)? Digit+)?
Atom :: `:` AtomName
BooleanLiteral :: `true` | `false`
NilLiteral :: `nil`
```

Syntactic (`:`) — the workflow surface:

```
WorkflowDefinition : `workflow` StringLiteral `do` WorkflowBody `end`
WorkflowBody : Statement*
Statement : PhaseStmt | LogStmt | AgentStmt | LetStmt | EmitStmt | ReturnStmt | ParallelStmt
          | PipelineStmt | VerifyStmt | JudgeStmt | SynthesizeStmt
          | WhileBudgetStmt | UntilDryStmt | FanOutStmt
LoopBody : BodyStatement+
BodyStatement : AgentStmt | LogStmt | PhaseStmt | CollectStmt
Predicate : Comparison | `all_of` `(` `[` Predicate+ `]` `)` | `any_of` `(` `[` Predicate+ `]` `)`
Comparison : Operand CompareOp IntegerLiteral
Operand : `count` `(` Atom `)` | `budget_remaining` `(` `)`
```

(Per-combinator argument and option productions are in §3; validation predicates in §5.)
