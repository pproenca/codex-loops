# Codex Loops Workflow DSL Specification

- **Status**: Draft
- **Version**: 0.1.0
- **Created**: 2026-07-06
- **Editors**: Codex Loops maintainers

This document specifies the **Codex Loops Workflow DSL**: a path-loaded,
Elixir-shaped data language for authoring deterministic, replayable agent workflows. It is written
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

The Workflow DSL is a **declarative, closed-vocabulary language with Elixir surface
syntax**. A script contains exactly one bare, top-level
`workflow "name" do … end` block. When the script path is validated or started,
`Workflow.Script` parses the source as AST data and lowers it into an inert
`%Workflow.Tree{}` — an ordered list of plain `%Workflow.Node.*{}` structs that contain no
functions, closures, or captured runtime state. The workflow source is never compiled or
evaluated. A separate interpreter executes the tree and records every decision and paid
effect in an append-only journal.

The DSL exists to describe **generic workflow orchestration** — sequencing paid turns,
explicitly wiring data edges, fanning out bounded work, and running bounded loops — in a
form that is **deterministic, serializable, and provably terminating**. Product vocabulary
such as "review", "cold read", or "repair" is library sugar unless this specification gives
a proof that it cannot lower to the generic core (§9).

### 1.1 Shape

Declarative and imperative-sequenced: statements execute top to bottom, but every
statement is a static declaration, not an expression that computes a value. The DSL is a
*surface* over a plain compiler function. There is no declaration macro or generated
workflow module.

### 1.2 Non-goals

The following are deliberately **out of scope** and MUST NOT be expressible:

- **General computation.** A workflow cannot run arbitrary Elixir, define modules or
  imports, define variables whose
  values are computed by host code, perform arithmetic, or choose an arbitrary subtree by
  branching on agent output. The only value-binding form is `let`, which binds a name to a
  lexically preceding producer's **journaled** output for deterministic rendering or closed
  projection (§10.5).
- **Non-determinism.** No node reads a clock, a random source, the environment, the
  filesystem, or any external module. Wall-clock and randomness are *unrepresentable*.
- **Side effects outside the vocabulary.** No spawning shells, no I/O, no network calls,
  no module imports from inside a workflow body.
- **Runtime linting.** Determinism is not enforced by an execution-time checker; it is a static
  property of the vocabulary and its load-time validation rules.

### 1.3 Design principles (the tie-breakers)

These principles resolve every ambiguity this document does not foresee. When two
readings are possible, the reading that upholds these principles is correct.

1. **Core calculus before product vocabulary.** The normative core is the small set of
   semantic primitives in §2.4: inert markers, paid `agent` turns, static `let`
   bindings to journaled producer outputs, terminal values, bounded `loop`, bounded
   `fanout`, and closed predicates. Product terms (`verify`, `judge`, `refine`,
   `reviewer`, `cold_read`, `repair`) are library/domain sugar unless a section explicitly
   proves the term cannot be expressed by those primitives. *Pre-resolves:* a new domain
   workflow first tries to desugar; it does not earn a primitive by being common.

2. **Explicit data edges, no ambient phase context.** A node may consume data only through a
   statically resolved `BindingRef`, an accumulator name, or an explicit loop/fanout lane binding
   stored in the compiled tree. `phase` is display/read-model metadata only; it is never an
   implicit input to a prompt, predicate, key, or provider call. *Pre-resolves:* no node can
   silently read "the current phase" or "the previous result" except through a named edge.

3. **Runtime decisions inspect only journaled values.** Every observable decision
   (`loop` continue/stop, `fanout` width, predicate result, convergence/agreement result,
   terminal success/failure) is either read from a prior journal event or computed by a pure
   fold over journaled values, then journaled before it can affect execution. *Pre-resolves:*
   resume never recomputes a past decision from mutable source or live process state.

4. **Conditions use a closed, typed predicate vocabulary.** A condition is not Elixir code.
   It is one of the predicate nodes in §3.8 (`all`, `any`, count/budget comparisons,
   `agree`, and JSON-path predicates), with pinned truth semantics and no host callbacks.
   *Pre-resolves:* a truth value is never supplied by a closure, a module call, truthiness, or
   an implementation-defined predicate.

5. **Loops/fanout are bounded and have explicit exhaustion behavior.** Every `loop` has a
   `max_iterations` in `1..1000`; every runtime-width `fanout` has a positive integer
   structural cap or a budget-derived width whose zero/unbounded-budget behavior is pinned.
   A loop that reaches its cap returns the declared `on_exhausted:` result (`:stop`, `:fail`,
   or `:accept_current`); it never spins or guesses. *Pre-resolves:* non-progressing bodies,
   zero-width fanouts, and non-convergence all have specified outcomes.

6. **High-level conveniences desugar to the core calculus.** Surface conveniences MAY be
   offered, but their lowering MUST be stated as an algorithm that produces inert core data,
   preserves addresses, and defines any library projection events. If the desugaring cannot
   be written, the spec MUST say why before admitting a new primitive. *Pre-resolves:*
   `refine`, `reviewer`, `cold_read`, and `repair` are not core merely because they are
   product features.

7. **Path loading produces inert data and validates before execution.**
   `Workflow.Script.load_tree/1` accepts one bounded UTF-8 file, parses it without
   evaluation, and passes its single workflow block to `Workflow.Compiler.compile/3`.
   The compiler lowers AST to serializable structs, stores no closures or process
   references, and validates every static rule before a writer can start. *Pre-resolves:*
   no validation is deferred to the interpreter, and no macro, module reflection, or
   generated accessor is required to run the tree.

---

## 2. Lexical Grammar

### 2.1 The DSL uses Elixir surface syntax

The Workflow DSL **defines no lexer of its own**. A workflow's source text is ordinary
Elixir source. Elixir's own tokenizer and parser turn that text into a quoted abstract
syntax tree (`Macro.t()`), and the DSL compiler (`Workflow.Compiler.compile/3`) operates on
that AST — not on a character stream. Consequently:

- **Character set, encoding, whitespace, line terminators, and comments** are exactly
  Elixir's. Source is UTF-8 Elixir; whitespace is insignificant except as a token
  separator; `#` begins a line comment; comments do not nest. None of these are the
  DSL's to redefine.
- **Case sensitivity** is Elixir's: identifiers and atoms are case-sensitive.
- **The combinator names are not reserved Elixir words.** `agent`, `phase`, `verify`, etc. are
  recognized structurally — a local call form `name(args)` whose `name` atom is in the
  closed vocabulary. They are keywords *of the DSL grammar*, not of the Elixir lexer, and
  are recognized only as inert call-shaped AST inside the one top-level `workflow` block.

The reference loader accepts at most 1 MiB of valid UTF-8. It invokes the Elixir
parser with existing-atoms-only behavior and a finite encoder for atoms shipped in the
runtime, so an external script cannot grow the VM atom table. A module definition,
`use`, import, module attribute, or any second top-level form is rejected before lowering.

An implementation MAY reuse a host language other than Elixir, but it MUST accept the same
*surface forms* (§3) and produce the same *tree* (§4); this document describes the Elixir
embedding, which is normative for the reference implementation.

### 2.2 Token kinds the DSL reads

Only a subset of Elixir tokens is meaningful to the DSL. The lexical productions below
describe that subset. They are Elixir's own productions, restated for completeness; an
implementation MUST accept exactly the simple string/number/atom forms below and reject
other Elixir token shapes in DSL positions.

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
AtomName :: (`a`–`z` | `_`) (Letter | Digit | `_`)*
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
interpolated prompt fails the "must be a literal string" check (§5) — it is a
load-time validation error, never a runtime concatenation.

### 2.3 Literal admissibility

Every value a combinator accepts as data (prompts, names, `return` values, `verify`
subjects, `judge` candidates, `pipeline` items, `synthesize` inputs, schema maps) MUST be
a **static literal**. Formally, the AST MUST satisfy `Macro.quoted_literal?/1`: it is
built only from scalars (integers, floats, booleans, `nil`, atoms, binaries), lists,
tuples, and maps whose contents are themselves literals. A form that contains a variable
reference or a function call is **not** a literal and is rejected.

### 2.4 Closed surface vocabulary and core primitives

The vocabulary is closed, but **surface names are not all primitives**. A parser MUST reject
any local call outside the sets below (or outside a contextual position named below), yet an
implementation MUST compile library/domain names by desugaring them to the core calculus.

Core semantic forms:

```
agent  log  phase  let  return  emit  emit_result  loop  until  fanout  collect
```

Library/domain surface forms that MUST lower to the core forms:

```
parallel  pipeline  while_budget  until_dry  verify  judge
synthesize  fan_out  refine
```

Deferred surface forms:

```
gather  map
```

`gather` and `map` are specified in §10.9 but remain **DEFER** and MUST be rejected until
promoted. `reduce`, `select`, and `when` are explicitly **REJECTED** (§10.10).

Contextual names:

- `collect` is core but **body-only**: valid only inside a `loop` body or a library loop
  body after desugaring (§3.7). A top-level `collect` is a validation error.
- `until` is core but **body-only**: it is valid only inside a `loop` body, where it
  journals a closed predicate decision and can stop that loop before later body nodes run.
- `budget_slices(per: N)` is not a standalone combinator. It is a `WidthExpr` usable only
  by `fanout`/`fan_out` width forms (§3.9).
- `reviewer`, `cold_read`, and `repair` are library-only declarations inside `refine`
  sugar (§9). They MUST NOT appear as top-level statements and MUST NOT produce core node
  kinds of their own.
- Predicate heads (`all`, `any`, `agree`, `all_of`, `any_of`, `count`,
  `budget_remaining`, `path_exists`, `path_non_empty`, `path_count`, `path_equals`) are
  valid only inside predicate positions (§3.8). They are not statements.

Inside a loop body the core body vocabulary is exactly `agent`, `log`, `phase`, `until`,
`fanout`, and `collect`, with the placement restrictions in §5.7. Library forms MAY be
accepted in a body only when their desugaring is to one of those body forms; the reference
currently admits only the legacy body subset (`agent`, `log`, `phase`, `collect`) for
backward compatibility.

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
  - LetStmt
  - ReturnStmt
  - EmitStmt
  - EmitResultStmt
  - LoopStmt
  - FanoutStmt
  - LibrarySugarStmt

LibrarySugarStmt :
  - ParallelStmt
  - PipelineStmt
  - VerifyStmt
  - JudgeStmt
  - SynthesizeStmt
  - WhileBudgetStmt
  - UntilDryStmt
  - FanOutStmt
  - RefineStmt
```

`WorkflowDefinition` is the entire file, not a form nested inside a module. The
file MUST contain exactly one such definition and no sibling top-level forms.

TerminalStmt :
  - ReturnStmt
  - EmitStmt
  - EmitResultStmt

`collect` is not in `Statement`: it appears only in `BodyStatement` (§3.7). A top-level
`collect` parses syntactically as a call but is rejected by validation (§5.6).

### 3.1 Simple statements

```
PhaseStmt  : `phase` `(` StringLiteral `)`
LogStmt    : `log` `(` StringLiteral `)`
ReturnStmt : `return` `(` Literal `)`
EmitResultStmt : `emit_result` `(` BindingRefAtom `)`
LetStmt    : `let` BindingRefAtom `=` Producer
BindingRefAtom :: `:` AtomName
Producer :
  - AgentStmt
  - SynthesizeStmt
  - RefineStmt
  - GatherStmt
  - `(` MapStmt `)`
```

- `phase` names a milestone. Its `StringLiteral` name MUST be unique within its lexical
  phase scope (§5.10.1).
- `log` emits a static message. No interpolation.
- `return` sets the workflow's terminal value. `Literal` MUST satisfy §2.3. A workflow
  MUST terminate with a final `return`, `emit`, or `emit_result` (§5.10.2, §10.7, §10.7a).
- `emit_result` emits the structured result of a result-capable binding. A result-capable
  binding is one whose producer defines a JSON-encodable public projection (§10.7a).
- `let` is static binding syntax. It inserts the producer node at the `let`'s address
  and records the binding name to that producer's journaled output; it creates no runtime
  node of its own (§10.5).

### 3.2 Agent

```
AgentStmt : `agent` `(` StringLiteral AgentOpts? `)`
AgentOpts : `,` KeywordList
```

The optional `KeywordList` is a literal Elixir keyword list drawn only from the keys
`schema:`, `retries:`, and `label:`. `schema:` MUST be a literal JSON Schema map;
module aliases, function calls, and schema DSL declarations are rejected. `retries:` is an
integer from `0` through `5`, default `2`
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
is a literal); a conforming implementation SHOULD emit a validation warning when a
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
eligible at once). The runtime-wide cap of eight tasks still applies; a node option can
only reduce that bound.

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

### 3.7 Generic loops and loop bodies

```
LoopStmt : `loop` KeywordList `do` LoopBody `end`
WhileBudgetStmt : `while_budget` KeywordList `do` LoopBody `end`  ; library sugar
UntilDryStmt    : `until_dry`    KeywordList `do` LoopBody `end`  ; library sugar

LoopBody      : BodyStatement+
BodyStatement :
  - AgentStmt
  - LogStmt
  - PhaseStmt
  - UntilStmt
  - FanoutStmt
  - CollectStmt

CollectStmt : `collect` `(` `[` `into:` Atom `]` `)`
UntilStmt   : `until` `(` Predicate `)`
```

The generic `loop` options are:

- `max_iterations:` REQUIRED, an integer literal from `1` through `1000`.
- `until:` OPTIONAL, a `Predicate` (§3.8). Omitted means the loop stops only by
  `max_iterations`.
- `on_exhausted:` OPTIONAL, one of `:stop | :fail | :accept_current`; default `:stop`.
  Exhaustion means `iteration >= max_iterations` before `until:` has evaluated true.

The `do … end` block is Elixir block sugar. A `LoopBody` MUST contain at least one
`BodyStatement`. Data consumed inside the body MUST enter through explicit bindings,
accumulators, or the lane variables of a nested `fanout`; there is no ambient phase context.
A body `until(P)` evaluates `P` at that point in the body. If true, it stops the current
loop and skips the remaining body statements for that iteration; if false, execution
continues with the following body statement. It is not a general branch and cannot select
between arbitrary subtrees.

Legacy loop forms are library sugar:

- `while_budget reserve: R, until: P?, max_iterations: M? do B end` desugars to
  `loop max_iterations: (M || 1000), until: any([budget_remaining() <= R, P?]) do B end`,
  with the `P?` term omitted when no author predicate is supplied.
- `until_dry rounds: N, seen_by: S?, max_iterations: M? do B end` desugars to
  `loop max_iterations: (M || 1000), until: dry(rounds: N, seen_by: (S || [])) do B end`.

The reference compiler currently admits the legacy body subset (`agent`, `log`, `phase`,
`collect`) and rejects nested loops. A conforming core implementation MAY admit the full
generic body vocabulary above, but MUST still enforce the explicit `max_iterations` cap and
the predicate semantics in §6.7–§6.8.

### 3.8 The closed predicate sub-grammar

Every `until:`, gate, and agreement condition is drawn from this **closed typed predicate
grammar**. Predicate names are contextual; they are not statements and cannot call host code.

```
Predicate :
  - Comparison
  - DryPredicate
  - AgreePredicate
  - PathPredicate
  - `all`    `(` `[` Predicate (`,` Predicate)* `]` `)`
  - `any`    `(` `[` Predicate (`,` Predicate)* `]` `)`
  - `all_of` `(` `[` Predicate (`,` Predicate)* `]` `)`  ; legacy alias of `all`
  - `any_of` `(` `[` Predicate (`,` Predicate)* `]` `)`  ; legacy alias of `any`

Comparison : Operand CompareOp IntegerLiteral
Operand :
  - `count` `(` Atom `)`
  - `budget_remaining` `(` `)`
  - `path_count` `(` BindingRefAtom `,` JsonPointerString `)`

DryPredicate : `dry` `(` `[` `rounds:` IntegerLiteral (`,` `seen_by:` AtomList)? `]` `)`

AgreePredicate :
  `agree` `(` BindingRefAtom `,` `[` `path:` JsonPointerString `,`
    `equals:` Literal `,` `threshold:` AgreementThreshold `]` `)`

AgreementThreshold :
  - `:all`
  - `:any`
  - IntegerLiteral

PathPredicate :
  - `path_exists`    `(` BindingRefAtom `,` JsonPointerString `)`
  - `path_non_empty` `(` BindingRefAtom `,` JsonPointerString `)`
  - `path_equals`    `(` BindingRefAtom `,` JsonPointerString `,` Literal `)`

CompareOp : one of `>` `<` `>=` `<=` `==`
AtomList  : `[` Atom (`,` Atom)* `]`
JsonPointerString :: `"` JsonPointerCharacter* `"`
JsonPointerCharacter :: SourceCharacter but not `"` or `\`
JsonPointerCharacter :: `\` (`"` | `\`)
```

`all`/`any` (and legacy aliases `all_of`/`any_of`) require at least one nested predicate.
`count(:name)` reads the global accumulator named by `collect(into: :name)`.
`budget_remaining()` reads the journaled ledger. `path_*` predicates and `agree` resolve a
statically resolved `BindingRefAtom` to an already-journaled value and inspect it with RFC 6901 JSON
Pointer rules (§6.8). `agree(:reviews, path: "/approved", equals: true, threshold: :all)`
is true iff the bound value is a list and the required number of elements have a value at
`/approved` JSON-equal to `true`.

A `loop` whose `until:` predicate contains one or more `dry(...)` predicates derives the
loop body's `seen_by` list from those predicates. All `dry` predicates in one `until:` tree
MUST specify the same `seen_by` list (or all omit it, equivalent to `[]`); conflicting
`seen_by` lists are a load-time error. A `dry` predicate outside a `loop until:` position
is invalid; body `until(...)` predicates MUST use non-dry predicates.

No predicate performs arithmetic beyond the single comparison production. No predicate uses
truthiness: every predicate returns exactly `true` or `false` by the algorithms in §6.8.

> Note (accumulator name must match a `collect`). A `count(<atom>)` operand is meaningful
> only if some body `collect(into: <atom>)`s into that **exact same** atom. An unmatched name
> resolves to an empty accumulator (`0`) and the loop can stop only by another predicate or by
> exhaustion.

### 3.9 Generic fanout and budget-scaled fan-out sugar

```
FanoutStmt : `fanout` KeywordList `do` FanoutBody `end`
FanOutStmt : `fan_out` KeywordList `do` AgentLane `end`  ; library sugar
FanoutBody :
  - AgentLane
  - LaneList
LaneList : `lanes` `(` `[` Lane (`,` Lane)* `]` `)`
Lane : `[` AgentStmt (`,` AgentStmt)* `]`
AgentLane : AgentStmt+

WidthExpr :
  - IntegerLiteral
  - `budget_slices` `(` `[` `per:` IntegerLiteral (`,` `max:` IntegerLiteral)? `]` `)`
  - `path_count` `(` BindingRefAtom `,` JsonPointerString `,` `[` `max:` IntegerLiteral `]` `)`
```

`fanout` keys are drawn from:

- `width:` REQUIRED, a `WidthExpr`.
- `max_concurrency:` OPTIONAL, a positive integer literal.
- `bind:` OPTIONAL, a literal atom naming the ordered list of lane results for later
  predicates/templates. If present at top level, it is a statically resolved `BindingRef` to this
  fanout's journaled result list (`{:fanout, address, :global}`) and enters scope **after**
  the `fanout` node. If present inside a loop body, it is a loop-local `BindingRef`
  (`{:fanout, address, {:loop_local, loop_address}}`) for the current iteration only and may
  be referenced only by later body `until(...)` predicates or by the owning loop's
  post-body/library projection rules. A `fanout` binding is never in scope inside that
  fanout's own lane prompts.
- `on_zero:` OPTIONAL, one of `:complete | :fail`; default `:complete`.

The body MUST be either one non-empty lane of `agent(…)` calls, repeated for the decided
width, or an explicit non-empty `lanes([...])` list of non-empty lanes. An explicit
`LaneList` is used by library desugarings that need heterogeneous prompts or schemas
(`parallel`, `verify`, `judge`, `refine`); for a `LaneList`, `width:` MUST be the integer
literal equal to the lane count. A fixed `IntegerLiteral` width MUST be non-negative; zero
is valid only for a repeated lane and is handled by `on_zero:`.
`budget_slices(per: N, max: M?)` is runtime-decided from the ledger; `per` MUST be positive,
`max` when present MUST be positive, and an unbounded run is a runtime crash unless the
width decision was already journaled on resume (§6.10). `path_count(:xs, "/items", max: M)`
is runtime-decided from a lexically preceding binding and MUST use the explicit `max:` cap.
Every newly resolved width is additionally limited by the runtime-wide maximum of 64 lanes.

The legacy `fan_out width: budget_slices(per: N) do B end` desugars to
`fanout width: budget_slices(per: N), on_zero: :complete do B end`.

> Note (no implicit per-branch injection). A `fanout` lane receives per-branch data only
> through an explicit lane binding supplied by a future `map` promotion (§10.9) or a library
> desugaring that records such a binding in the tree. The legacy `fan_out` form supplies no
> lane binding: every branch runs the byte-identical prompt(s), and the branch index appears
> only in the branch address.

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
core `%Workflow.Node.*{}` structs. These structs are the semantic model: **inert,
serializable data with zero closures**. Surface conveniences MUST be eliminated before or
during tree construction by `Desugar(form, env)` (§4.3.1): after compilation, no core
interpreter step may need to know that a node was written with product vocabulary such as
`reviewer`, `cold_read`, or `repair`.

`Workflow.Script.load_tree/1` returns the tree directly as `{:ok, tree}`. There is no
workflow module, reflection callback, or generated accessor.

### 4.1 The tree container

`%Workflow.Tree{}`:

| Field | Type | Default | Notes |
|---|---|---|---|
| `name` | `String.t() \| nil` | `nil` | Set by `Workflow.Compiler.compile/3` from the top-level string literal. |
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

### 4.3 Core node struct catalog

Each core node's enforced keys and defaults. Every node except width/predicate helper
structs has `address :: address()`. An implementation MAY keep compatibility structs for
legacy surfaces, but conformance is judged by their specified core desugaring.

| Node | Enforced keys | Defaults / extra fields | Non-address field types |
|---|---|---|---|
| `Phase` | `[:address, :name]` | — | `name :: String.t()` |
| `Log` | `[:address, :message]` | — | `message :: String.t()` |
| `Agent` | `[:address, :prompt]` | `label: nil, schema: nil, retries: 2` | `prompt :: String.t()`; `label :: String.t() \| nil`; `schema :: map() \| nil`; `retries :: non_neg_integer()` |
| `Return` | `[:address, :value]` | — | `value :: term()` |
| `Emit` | `[:address, :template, :bindings]` | — | `template :: Template.t()`; `bindings :: %{atom() => BindingRef}` |
| `EmitResult` | `[:address, :binding_ref]` | — | `binding_ref :: BindingRef` |
| `Loop` | `[:address, :body, :max_iterations]` | `until: nil, on_exhausted: :stop` | `body :: [struct()]`; `until :: Predicate.t() \| nil`; `max_iterations :: pos_integer()`; `on_exhausted :: :stop \| :fail \| :accept_current` |
| `Until` | `[:address, :predicate]` | — | `predicate :: Predicate.t()` |
| `Fanout` | `[:address, :width, :lanes]` | `bind: nil, max_concurrency: nil, on_zero: :complete, repeated: true` | `width :: WidthExpr.t()`; `lanes :: [[Agent.t()]]`; `repeated :: boolean()`; `bind :: atom() \| nil`; `max_concurrency :: pos_integer() \| nil`; `on_zero :: :complete \| :fail` |
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

The legacy `Parallel`, `Pipeline`, `WhileBudget`, `UntilDry`, `Verify`, `Judge`,
`Synthesize`, and `FanOut` rows document the reference implementation's compatibility
structs. They are **not** additional core primitives. A non-Elixir conforming
implementation MAY skip these structs and construct only the core `Loop`, `Fanout`, `Agent`,
`Collect`, marker, binding, and terminal nodes, provided the observable journal and result
match the desugaring below.

### 4.3.1 Desugaring contract

`Desugar(form, env)` is a static, total function over valid surface forms. It returns
only inert core nodes and an updated binding environment.

```
Desugar(form, env):
  - If form is a core form: Return CoreLower(form, env).
  - If form is a library form: Return the core tree specified by that form's section.
  - If the section gives no desugaring: Return a located validation finding.
```

`CoreLower(form, env)` is the per-core-form compile algorithm defined by that form's grammar
and validation rules (§3, §5): it checks the AST shape, constructs only inert structs, and
returns any binding-environment updates. It does not execute workflow code.

Required library lowerings:

- `while_budget` and `until_dry` lower to `Loop` as specified in §3.7.
- `fan_out` lowers to `Fanout` as specified in §3.9.
- `parallel` lowers to `Fanout` with fixed width `length(branches)`, one branch lane per
  source agent, and no bound result list.
- `pipeline` lowers to `Fanout` with fixed width `length(items)` and each lane's stages
  addressed as `address ++ [item_index, stage_index]`; the item list remains journal-label
  metadata only and is not ambient data.
- `synthesize(inputs, prompt)` lowers to an ephemeral schemaless `Agent` whose prompt is the
  pinned literal composition described in §6.3.
- `verify` and `judge` lower to `Fanout` plus closed result projections whose reducers are
  the `agree`/score algorithms in §6.10; their verdicts are journaled values, not control
  flow.
- `refine` lowers to the generic producer → bounded `Loop` → reviewer `Fanout` →
  `agree`/path-predicate convergence pattern in §9.0. `reviewer`, `cold_read`, and `repair`
  are contextual records used only by that lowering.

The lowering MUST preserve stable addresses. If a library surface historically exposed
library-specific events (for example `refine_*`), those events are library projection events:
they MAY be emitted in addition to core events, but no core decision may depend on them
unless they are themselves journaled before the decision that reads them.

### 4.4 Static template pre-expansion

Several combinators pre-expand into a grid or lane of inert `%Agent{}` templates **while
the script is loaded**, so the tree already contains every paid turn (fully addressed) before the
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
into the fixed template **while loading**, and the composed prompt is later journaled
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

`fan_out` is the **only** combinator whose fan width is not statically fixed: its
body is stored with placeholder addresses and re-addressed per branch at runtime (§6.10),
because the width is a runtime budget decision. Like `pipeline` (and unlike
`synthesize`/`verify`/`judge`, which inject their data), a `fan_out` lane receives **no**
per-branch content or index — every branch runs the identical literal lane prompt; the branch
index appears only in the address, never in the prompt (§3.9).

Voter and scorer agents are always `retries: 0` and schema-bound, so a malformed vote or
score is a **hard panel failure**, never a re-roll.

### 4.5 Literal schemas

`agent`'s `schema:` option accepts only a literal JSON Schema map validated by
§6.4.2. The compiler materializes that map into the `%Agent{}` node. Module aliases,
function calls, schema modules, and a schema sub-DSL are outside the language and MUST be
rejected. This keeps path-loaded scripts inert and prevents loading or executing author
modules.

---

## 5. Validation (static semantics)

All validation runs while the path is loaded, before execution, in
`Workflow.Script.load_tree/1` and `Workflow.Compiler.compile/3`. No validation is
deferred to the interpreter.

### 5.0 Tagged result and finding shape

`compile/3` returns one of two tagged results:

1. **Success** — `{:ok, %Workflow.Tree{}}`.
2. **Located finding** — `{:error, %Workflow.Compiler.Finding{}}`, used for
   wrong-argument shapes, per-option errors, forbidden forms, and whole-language
   invariants. `Workflow.Script` formats it into a typed `Workflow.Script.Error` for the
   scheduler API.

A `%Finding{}` carries `message`, optional `form` (the offending AST), `file`, `line`, and
optional `hint`. `file`/`line` come from the caller's `%Macro.Env{}` and the offending
form's line metadata, so an error names the exact line in the author's file. When `form`
is `nil` (whole-DSL invariants) the render shows location only; otherwise it renders a
rustc-style snippet with a caret underline.

An implementation MUST report every validation failure as a typed, located load error at
the offending declaration. It MUST NOT accept an invalid workflow and defer the error to
execution time.

### 5.1 Forbidden-form catalog

Any form that is not a recognized combinator call returns a located
`Workflow.Compiler.Finding`.

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

**Rule 5.3.4 — Schema is a literal map.** `schema:` MUST be a literal JSON Schema map
satisfying `Macro.quoted_literal?/1`. A non-map, non-literal map, module alias, or function
call is rejected.

```counter-example
agent("go", schema: "not a map")   # `agent` schema must be a literal map
```

**Rule 5.3.5 — Retries is bounded.** `retries:` MUST be an integer from `0` through `5`
(default `2`; at most six paid attempts including the initial call).

```counter-example
agent("go", schema: %{"type" => "object"}, retries: -1)   # must be a non-negative integer
```

```counter-example
agent("go", schema: %{"type" => "object"}, retries: 6)    # retries must be at most 5
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

### 5.7 Loops (`loop`, `while_budget`, `until_dry`) and body vocabulary

**Rule 5.7.0 — Generic `loop` options are closed and bounded.** `loop` MUST parse as
`[opts, [do: block]]`. `opts` keys MUST be drawn from
`[:max_iterations, :until, :on_exhausted]`; `max_iterations:` is REQUIRED and MUST be an
integer literal from `1` through `1000`; `until:` when present MUST parse as a `Predicate`; and
`on_exhausted:` when present MUST be one of `:stop | :fail | :accept_current`. An invalid
generic loop is a load-time finding; exhaustion is never left to runtime policy. If the
`until:` tree contains `dry(...)`, every `dry` node in that tree MUST carry the same
`seen_by` list after defaulting omitted `seen_by` to `[]`.

```counter-example
loop until: path_exists(:x, "/done") do
  agent("go")
end                          # `loop` requires a literal positive `max_iterations:`
```

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

**Rule 5.7.4 — `max_iterations:` is bounded.** On compatibility loops it is optional
(default `1000`); whenever present it MUST be an integer from `1` through `1000`.

```counter-example
until_dry rounds: 1, max_iterations: 0 do
  agent("go", schema: %{"type" => "array"})
  collect(into: :i)
end                          # `max_iterations` must be a positive integer
```

```counter-example
loop max_iterations: 1001 do
  agent("go")
end                          # `max_iterations` must be between 1 and 1000
```

**Rule 5.7.5 — `seen_by:` is a list of atoms.** Optional; default `[]`. Never a function.

```counter-example
until_dry rounds: 1, seen_by: [1] do
  agent("go", schema: %{"type" => "array"})
  collect(into: :i)
end                          # `seen_by` must be a list of field names (atoms)
```

**Rule 5.7.6 — A loop body is non-empty and body-vocabulary only.** A body MUST contain at
least one node. The generic core body vocabulary is
`[:agent, :log, :phase, :until, :fanout, :collect]`; the reference compatibility subset for
`while_budget`/`until_dry` remains `[:agent, :log, :phase, :collect]`. `parallel`,
`pipeline`, `let`, `return`, `verify`, `judge`, `synthesize`, `refine`, `emit`, and `emit_result`
are rejected inside a body unless a future section gives an explicit core desugaring and
binding-scope rule. **Loops do not nest in the reference compatibility surface:** because
the admitted body vocabulary excludes `loop`, `while_budget`, and `until_dry`, no legacy
loop body can contain another loop. A generic-core implementation MAY admit nested `loop`
  only if each nested loop has its own literal `max_iterations` and address-isolated
decision events.

**Rule 5.7.6a — body `until` is closed, ordered, and loop-local.** `until(Predicate)` is
valid only in a `loop` body. Its predicate MUST satisfy §5.9, MUST NOT contain `dry(...)`,
and MAY reference only global
bindings that are lexically in scope before the loop plus loop-local `fanout bind:` names
declared by earlier body statements in the same loop body. A loop-local name MUST NOT
shadow a global binding or another loop-local binding. Such names are not visible after the
loop and are resolved with the current iteration index. A loop MUST NOT combine a header
`until:` option with a body `until(...)`, and a body MUST contain at most one `until(...)`;
this keeps each `(loop address, iteration)` decision single-source.

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

### 5.8 `fanout` and `fan_out`

**Rule 5.8.0 — Generic `fanout` options are closed and bounded.** `fanout` MUST parse as
`[opts, [do: block]]`; keys MUST be drawn from
`[:width, :max_concurrency, :bind, :on_zero]`. `width:` is REQUIRED and MUST be a
`WidthExpr` (§3.9). `max_concurrency:` when present MUST be a positive integer literal.
`bind:` when present MUST be a literal atom matching `AtomName` and MUST NOT shadow an
in-scope global binding or a loop-local binding already declared in the same body.
`on_zero:` when present MUST be `:complete` or `:fail`.
The body MUST be either one non-empty `AgentLane` or a non-empty `LaneList`. If it is a
`LaneList`, `width:` MUST be a positive integer literal equal to the number of lanes. If it
is a repeated `AgentLane`, an integer width MUST be a literal from `0` through `64`. An
explicit lane list therefore also contains at most 64 lanes. Runtime
width expressions (`budget_slices`, `path_count`) are valid only with a single repeated
lane; their structural caps (`per:` and `max:` where present/required) MUST be positive
integer literals, and the runtime clamps their newly decided width to 64. A `path_count`
width expression MUST reference a global binding; it MUST
NOT reference a loop-local `fanout bind:` name.

```counter-example
fanout width: path_count(:items, "/rows") do
  agent("go")
end                          # path-count fanout width requires an explicit `max:`
```

```counter-example
fanout width: budget_slices(per: 10) do
  lanes([[agent("a")], [agent("b")]])
end                          # heterogeneous lanes require fixed literal width
```

```counter-example
fanout width: 65 do
  agent("go")
end                          # literal fanout width must be at most 64
```

**Rule 5.8.1 — legacy `fan_out` width is exactly `budget_slices(per: N)`.** REQUIRED;
`N` a positive integer. Any other form (arbitrary arithmetic, a bare integer) is rejected.

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

**Rule 5.9.1 — Predicate operands and thresholds are closed and typed.** The left operand
of a comparison MUST be `count(<accumulator-atom>)`, `budget_remaining()`, or
`path_count(<binding>, <pointer>)`; the right MUST be a literal integer; the operator MUST
be one of `> < >= <= ==`. `all`/`any` and legacy `all_of`/`any_of` require at least one
nested predicate. `dry(rounds: N, seen_by: S?)` requires `N >= 1` and `S` a literal atom
list when present. `agree(binding, path: pointer, equals: literal, threshold: t)` requires a
lexically preceding binding, a valid JSON Pointer, a JSON-convertible literal, and
`threshold` of `:all | :any | positive integer`. Path predicates require the same binding,
pointer, and JSON-literal checks. Anything else is rejected. (The compiler does not require
the accumulator atom to match a `collect(into:)` in the body; an unmatched name resolves to
an empty accumulator forever — see the note in §3.8.)

```counter-example
while_budget reserve: 0, until: count(:items) >= size() do
  agent("go", schema: %{"type" => "array"})
  collect(into: :items)
end                          # a predicate threshold must be a literal integer
```

```counter-example
loop max_iterations: 3, until: agree(:reviews, path: "/ok", equals: true, threshold: :most) do
  agent("go")
end                          # agreement threshold is outside the closed vocabulary
```

```counter-example
loop max_iterations: 3, until: path_equals(:r, "open", true) do
  agent("go")
end                          # JSON Pointer strings must be "" or start with "/"
```

### 5.10 Whole-DSL invariants (findings)

**Rule 5.10.1 — Phase names unique *per lexical scope*.** Phase-name uniqueness is
enforced **independently within each lexical scope**, not globally across the workflow. A
scope is either the **top-level statement list** or the body of **one individual loop**
after desugaring (`loop`, including legacy `while_budget` / `until_dry`). The compiler
carries a **separate** seen-set per scope: the top-level `build` starts a fresh set, and
each loop body's `build_body` starts its own fresh set. In the reference compatibility
surface loops do **not** nest; if a generic-core implementation admits nested `loop`
statements, each nested loop body creates its own lexical phase scope.
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

**Rule 5.10.2 — A workflow MUST end with a terminal statement.** The top-level node list
MUST end with exactly one terminal statement: `return`, `emit`, or `emit_result`.
`return` supplies a literal terminal value (§3.1); `emit` supplies a rendered template
value (§10.7); `emit_result` supplies a structured result value from a result-capable
binding (§10.7a). Any top-level node after a terminal statement is rejected. A workflow
with no terminal statement raises a finding located at the workflow declaration line.

```counter-example
workflow "x" do
  phase("p")
  log("hi")                  # workflow must end with return/emit/emit_result
end
```

**Rule 5.10.2a — `emit_result` is a final top-level terminal over one result-capable
binding.** `emit_result` MUST appear only at top level, MUST be the final top-level node,
and MUST take exactly one literal binding atom. The binding MUST resolve, while loading,
to a result-capable producer: a producer whose section defines a JSON-encodable public
projection for structured terminal output. In the shipped library surface, only `refine`
defines such a projection.

Pinned findings:

- Unknown binding: `` `emit_result` references unknown binding :r ``.
- Non-result binding: `` `emit_result` requires a result-capable binding; :a is bound to agent ``.
- Non-atom argument: `` `emit_result` expects a literal binding atom ``.

```counter-example
while_budget reserve: 0, max_iterations: 1 do
  emit_result(:r)             # `emit_result` is top-level only
end
```

```counter-example
emit_result(result(:r))       # argument must be one literal binding atom
```

```counter-example
let :a = agent("draft")
emit_result(:a)               # `agent` bindings are not result-capable
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
- **An expected provider failure is data, not a writer crash.** If `CallProvider` returns
  an `ExpectedProviderFailure` (§6.4.1), an ordinary `agent` commits `agent_failed` with
  `reason = {:provider_failure, kind, detail}`, preserves the provider-supplied
  `usage`/`activity`, halts the run, and yields
  `{:error, {:provider_failure, address, kind, detail}}`. The provider failure is not
  schema-retried: no decoded model output exists to validate. This clause is distinct from
  a provider bug (malformed return, raise, exit, malformed usage/activity/detail), which
  still crashes the live writer. `refine` reviewer lanes deliberately handle expected
  provider failures differently: they journal non-terminal role-failure data and continue
  the convergence loop with consensus false (§9.7).
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
  `CallProvider` returning malformed data, raising, or exiting (§6.4.1) — is
  **not** a schema `{:failed, …}`: it is not caught and converted, it **propagates** off the
  lane task and **crashes the live writer**, exactly as a top-level provider crash does.
  Terminal lane settlements wait for result gathering, but `agent_started` and
  `agent_activity` append synchronously from the lane. Thus a region marker and one or more
  starts/activity entries may already be in the journal, while no terminal lane event or
  `*_settled` / `*_completed` marker is written. An unsettled start forces terminal
  `outcome_unknown`. The current caller may observe `{:error, {:run_crashed, reason}}`
  (no `run_completed`). This is distinct from a schema `{:failed, …}` lane, which **is**
  committed (its events land, first-in-input-order reason becomes the halt) and yields
  `{:malformed_output, address, reason}` (exit 8) — a provider crash yields `run_crashed`
  (exit 1, or 130 when `reason` is `:killed`).
- **A crash** (writer process death) surfaces to the caller as
  `{:error, {:run_crashed, reason}}` via a process monitor. Before re-raising an unexpected
  catchable defect, the writer appends `run_failed`; if an attempt is unsettled, its reason
  is `outcome_unknown`. An untrappable kill leaves the start marker for the next resume
  preflight to settle as `outcome_unknown`. No path redelivers that attempt.
- **An unknown paid outcome is terminal.** A durable `agent_started` without a matching
  settlement means the provider may have completed or charged. Resume appends
  `run_failed({:outcome_unknown, attempt})`, performs no provider call, and returns the
  typed unknown-outcome error.
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
    - Return {:error, FailureReturn(status.failure)}.
      ; status.failure is the LAST agent_failed (last-wins fold, §7.3); for a single-failure
      ; run this equals the first, but for a 2+-lane failure it is the LAST failing lane —
      ; a resume therefore returns a DIFFERENT tuple than the initial run did (§6.1, §7.3).
  - If UnsettledAttempt(prior) returns {:ok, attempt}:
    - Commit Event.run_failed({:outcome_unknown, attempt}).
    - Return {:error, {:outcome_unknown, attempt}}.
  - Return {RunTree(run_id, tree, provider, budget, script_path, prior)}.

FailureReturn(failure):
  - If failure.reason is {:outcome_unknown, attempt}:
    - Return {:outcome_unknown, attempt}.
  - If failure.reason is {:provider_failure, kind, detail}:
    - Return {:provider_failure, failure.address, kind, detail}.
  - If failure.reason is {:did_not_converge, address, reason}:
    - Return {:did_not_converge, address, reason}.
  - If failure.reason is {:invalid_refine_input, address, reason}:
    - Return {:invalid_refine_input, address, reason}.
  - If failure.reason is {:loop_exhausted, address, iterations}:
    - Return {:loop_exhausted, address, iterations}.
  - If failure.reason is {:fanout_failed, address, iteration, reason}:
    - Return {:fanout_failed, address, iteration, reason}.
  - If failure.reason is {:fanout_failed, address, reason}:     ; legacy top-level shape
    - Return {:fanout_failed, address, nil, reason}.
  - Return {:malformed_output, failure.address, failure.reason}.
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
`phase_entered`, `log_emitted`, `agent_started`, `agent_committed`, `agent_attempt_rejected`, `agent_failed`,
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

This allocation rule does not change workflow decisions: `agent_activity` is telemetry,
while the writer still controls semantic traversal/order and positional replay. Each
activity entry is synchronously appended before its post-commit notification. The writer
assigns monotonically increasing `activity_index` values within an attempt; distinct
repeated entries remain visible even when their fields are byte-identical.

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

`RunNode(node, run_id, provider, prior, ctx)` returns `{:cont, ctx}`, `{:halt, ctx, reason}`,
or, only inside a loop body, `{:loop_stop, ctx, reason}`, by node kind:

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
  *(Dataflow/refine addendum: the current compiler enforces terminal-final placement for top-level
  `return`, `emit`, and `emit_result`; a top-level node after any terminal is rejected. The
  base last-wins model remains historical context for §1–§8; see §10.7 and §10.7a.)*
- **`Agent`** — see RunAgent (§6.4).
- **`Collect`** — see RunCollect (§6.6).
- **`Until`** — see RunUntil (§6.7); valid only when `ctx.loop_address` and `ctx.iteration`
  identify the owning loop pass.
- **`Loop`** — RunLoop (§6.7).
- **`Fanout`** — RunFanout (§6.10).
- **`WhileBudget`** / **`UntilDry`** — compatibility loop sugar (§3.7); desugar to a
  generic `Loop` and then run `RunLoop`, emitting the generic `loop_decision` payloads.
- **`Parallel`** / **`Pipeline`** / **`Verify`** / **`Judge`** / **`FanOut`** —
  compatibility fanout/panel sugar (§6.8–6.10).
- **`Synthesize`** — construct an ephemeral `%Agent{address: node.address, prompt:
  "<prompt>\n\nInputs: <inspect(inputs)>", schema: nil, retries: 0}` and delegate to
  RunAgent, reusing the ordinary journaled/keyed/resumable agent path.

`RunNodes` walks nodes in source order and propagates the first non-`{:cont, ctx}` outcome.
`{:loop_stop, ctx, reason}` is consumed only by the immediately enclosing `LoopCore`; a
top-level `RunTree` never receives it because `until` is loop-body-only by validation.

Structural markers are **positional** — reused verbatim on resume if already journaled,
otherwise committed. They key on the tuples below:

- **Positional markers** (`phase_entered`, `log_emitted`, and every region/boundary marker
  except generic `fanout_started`/`fanout_completed` markers, which are handled below:
  `parallel_started`/`parallel_completed`, `pipeline_started`/`pipeline_completed`,
  `verify_started`/`verify_settled`, `judge_started`/`judge_settled`,
  `fan_out_started`/`fan_out_completed`,
  `loop_completed`) are keyed by `(type, address)` and
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

Generic `fanout_started`/`fanout_completed` are positional at top level and
iteration-qualified inside loop bodies. They carry the current `ctx.iteration` in their
payload and key on `(type, address, iteration_or_nil)` through the specialized helpers in
§6.10, so replay never recomputes width and one loop iteration never reuses another
iteration's width/result list.

This is why a region resumed after a mid-region crash (§6.9) reproduces **exactly** the
crash-free journal: the `*_settled` / `*_completed` marker is written **at most once per
address**, so a resumed run never appends a duplicate settle event and the Status fold
(§7.3), which appends a fresh `verifications`/`judgments` entry on each such event, stays
identical to the crash-free fold (C4, §8). Wherever §6.9–§6.10 say "commit
Event.`verify_settled`(…)" (or any other start/settle/complete marker except the
specialized generic `fanout_started`/`fanout_completed`) the operation is `CommitMarker` —
an implementation MUST NOT unconditionally re-commit a region marker on resume.

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

### 6.4 Agent turn and at-most-once resolution

```
RunAgent(node, run_id, provider, prior, ctx):
  - Let {iteration} be ctx.iteration.
  - Let {outcome} be ResolveIdempotency(prior, node.address, iteration).
  - If {outcome} is {:committed, result, _usage}:
    - Return {:cont, ctx with last_result = result}.        ; replay, never re-run
  - If {outcome} is {:failed, reason}:
    - If reason is {:provider_failure, kind, detail}:
      - Return {:halt, ctx, {:provider_failure, node.address, kind, detail}}.
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

`UnsettledAttempt(events)` finds the first `agent_started` whose
`(address, iteration, attempt)` has no matching `agent_committed`,
`agent_attempt_rejected`, or covering `agent_failed` settlement. The run-level preflight
in §6.2 executes this check before any further node can run. Therefore `RunAgent` only
sees fresh attempts or attempts whose earlier paid calls have durable settlements.

```
CommitAttempt(node, run_id, provider, iteration, attempt, ctx):
  - Let {key} be IdempotencyKey(run_id, node.address, iteration, attempt).
  - Let {ctx} be Commit(Event.agent_started(node, iteration, key), ctx).
    ; this durable marker MUST precede the provider effect
  - Let {provider_outcome} be CallProvider(provider, node.prompt, node.schema, key).  ; §6.4.1
  - If {provider_outcome} is {:provider_failure, kind, detail, usage, activity}:
    - Let {reason} be {:provider_failure, kind, detail}.
    - Let {ctx} be Commit(Event.agent_failed(node, iteration, attempt + 1, reason, usage, activity), ctx).
    - Return {:halt, ctx, {:provider_failure, node.address, kind, detail}}.
  - Otherwise {provider_outcome} is {:ok, output, usage, activity}.
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
  - Let {ctx} be Commit(Event.agent_failed(node, iteration, attempt + 1, reason, nil, []), ctx).
  - Return {:halt, ctx, {:malformed_output, node.address, reason}}.
```

Each paid attempt is committed **incrementally**: `agent_started` lands before the call,
and a rejection lands before the next attempt. A crash after the start marker but before
settlement creates an unknowable outcome. The runtime MUST NOT redeliver that attempt; the
run-level preflight journals `run_failed` with `{:outcome_unknown, attempt}`. This provides
at-most-once invocation at the cost of possibly losing an unjournaled result. The
`IdempotencyKey` remains a stable attempt identity for providers, activity, and settlement,
but Codex Loops does not claim or depend on backend request deduplication.

An expected provider failure consumes exactly one attempt. It is committed as `agent_failed`
immediately and is not retried by the workflow runtime, because there is no candidate
`output` to pass through `Schema.Validate`. If a provider wants a transient failure retried
inside a backend-specific transport layer, it MUST do so before returning from `run_agent/4`;
once `ExpectedProviderFailure` crosses the provider port it is a terminal provider outcome
for that idempotency key.

### 6.4.1 CallProvider (the provider port)

A provider is a pair `{module, opts}`. `CallProvider` is the single seam between the
deterministic runner and a non-deterministic backend:

```
CallProvider({module, opts}, prompt, schema, key):
  - Let {raw} be module.run_agent(prompt, schema, key, opts).
  - Return NormalizeProviderOutcome(raw).
```

The reference Codex provider runs one external process per attempt through
`Workflow.Containment`. The boundary rejects input above 16 MiB, stops stdout above
16 MiB, uses a monotonic absolute deadline (30 minutes by default), and discards stderr.
Timeout, input-limit, and output-limit outcomes are finite failures; stdout is accumulated
as bounded iodata, never by unbounded binary concatenation. Concurrent branch tasks have
their own finite 31-minute deadline so a stalled child cannot leave a writer waiting
forever.

- **Inputs.** `prompt :: String.t()` (this node's literal prompt — never a splice of any
  other node's output), `schema :: map() | nil` (the node's JSON-schema map, or `nil` for a
  schemaless turn), `key :: IdempotencyKey` (§6.5), and the backend-specific `opts`.
- **Provider return.** A conforming backend MUST return either a `ProviderSuccess` or an
  `ExpectedProviderFailure`.

  ```
  ProviderSuccess :
    - {:ok, result, usage}
    - {:ok, result, usage, activity}

  ExpectedProviderFailure :
    - {:error, {:provider_failure, kind, detail, usage, activity}}
  ```

  `kind` MUST be exactly one of `:quota_exceeded | :model_limit | :timeout |
  :unavailable | :backend`:

  - `:quota_exceeded`: account, rate, billing, or quota exhaustion prevented completion.
  - `:model_limit`: the request exceeds context, output, schema, or model capability
    limits and will not succeed unchanged.
  - `:timeout`: the provider did not produce a terminal result before a configured deadline.
  - `:unavailable`: the backend or service is temporarily unreachable or unable to accept work.
  - `:backend`: the contained process or provider protocol failed without a more specific class.

  `NormalizeProviderOutcome` converts the success three-tuple form to
  `{:ok, result, usage, []}` and converts `ExpectedProviderFailure` to
  `{:provider_failure, kind, detail, usage, activity}`. `result` is the decoded provider
  output (`term()`; for a schema-bound turn a decoded JSON value — a map, list, or scalar).
  success `usage` is normalized by `NormalizeProviderSuccessUsage`; `nil` contributes a
  zero `%Usage{}`. Expected-failure `usage` is normalized by
  `NormalizeProviderFailureUsage`; `nil` remains `nil` because some provider failures have
  no billable usage to report.
  `activity` is an ordered list of JSON objects describing provider progress (§7.2).

  Expected provider failure values are data, not crashes. Invalid return shapes, malformed
  failure data, raised exceptions, unexpected process exits, malformed streams, missing final
  results, unknown `turn.failed`/`error` frames, and malformed `usage`/`activity` are provider
  bugs. Provider bugs crash the live writer; the caller observes
  `{:error, {:run_crashed, reason}}` (§6.1, §7.4), mapped to exit 1 (or 130 when `reason` is
  `:killed`) per §7.5.

  ```
  JsonValue :
    - null
    - boolean
    - integer
    - string
    - JsonArray
    - JsonObject

  JsonArray : ordered list of JsonValue
  JsonObject : map with string keys and JsonValue values
  ProviderFailureDetailValue : JsonValue
  ```

  Provider failure `detail` uses this integer-only JSON subset. Floats, NaN, Infinity,
  atoms, tuples, structs, PIDs, functions, and maps with non-string keys are malformed
  failure data and MUST crash the writer.

  ```
  NormalizeProviderSuccessUsage(value):
    - If value is nil: Return %Usage{input_tokens: 0, output_tokens: 0, total_tokens: 0}.
    - If value is %Usage{input_tokens, output_tokens, total_tokens} and all three fields are
      non-negative integers: Return value.
    - If value is %{"input_tokens" => i, "output_tokens" => o, "total_tokens" => t} and i,
      o, and t are non-negative integers: Return %Usage{input_tokens: i, output_tokens: o,
      total_tokens: t}.
    - Otherwise raise a provider bug.

  NormalizeProviderFailureUsage(value):
    - If value is nil: Return nil.
    - Otherwise Return NormalizeProviderSuccessUsage(value).
  ```

  ```
  NormalizeProviderOutcome(raw):
    - If raw is {:ok, result, usage}:
      - Return {:ok, result, NormalizeProviderSuccessUsage(usage), []}.
    - If raw is {:ok, result, usage, activity} and activity is a JSON array:
      - Return {:ok, result, NormalizeProviderSuccessUsage(usage), activity}.
    - If raw is {:error, {:provider_failure, kind, detail, usage, activity}},
      kind is one of the five expected kinds, detail is a ProviderFailureDetailValue,
      and activity is a JSON array:
      - Return {:provider_failure, kind, detail, NormalizeProviderFailureUsage(usage), activity}.
    - Otherwise raise a provider bug.
  ```

  Public JSON usage is always
  `%{"inputTokens" => i, "outputTokens" => o, "totalTokens" => t}` or `null` inside role
  failure records when no usage exists.
- **Activity sink.** The runner MAY add `activity_sink: (Activity.t() -> non_neg_integer())` to `opts`. A
  backend that receives it MAY call it for non-terminal progress while the turn is running.
  The sink normalizes and synchronously journals each call as `agent_activity` with the
  next local `activity_index`, then broadcasts a post-commit refresh notification and
  returns the index. The backend's terminal `activity` list is reconciled to those indices
  before `agent_committed` / `agent_attempt_rejected` is written. The activity sink is
  telemetry only: it does not change validation, retry, attempt identity, or workflow
  results.
- **Codex `--output-schema` strictness.** The Codex provider passes a schema-backed turn's
  schema to the CLI with `--output-schema`. Before writing that temporary schema file, it
  normalizes every object schema recursively to force `"additionalProperties" => false`,
  overriding any author-supplied value. This provider-port normalization is for Codex/OpenAI
  structured-output strictness; it does not mutate `%Agent{schema}` in the inert tree, and
  the writer still validates the returned value against the original schema map.
- **Turn independence and attempt identity.** Because `CallProvider` receives only `(prompt, schema, key,
  opts)`, no conversation state, thread, or prior result is carried between turns. Every
  agent turn is independent; all context an agent needs MUST be present in its own literal
  prompt (Principle 6). The `key` identifies the attempt in journal records and may be used
  by a backend for tracing or its own deduplication, but the scheduler never reissues an
  unsettled attempt and makes no exactly-once backend claim.
  *(Proposed §10 — dataflow: a proposed extension would widen the `prompt` input and this Turn-independence clause to §6.4.1′, admitting a deterministically-rendered template materialized to a `String.t()` by a pure journal fold before the call; `CallProvider`'s `(prompt, schema, key, opts)` signature is unchanged; see §10.)*

**Provider-port callbacks.** A provider module has two callbacks:

| callback | signature | required? | when called |
|---|---|---|---|
| `c:run_agent/4` | `run_agent(prompt, schema, key, opts) -> ProviderSuccess \| ExpectedProviderFailure` | **REQUIRED** | once per paid attempt (§6.4) |
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
- **Call-time provider outcome.** A provider that **resolved** may later return an
  `ExpectedProviderFailure`; that is handled as data by §6.4 and is **never** an exit-4
  `provider-config` failure. A provider that returns any other malformed shape or raises
  (§6.4.1, `NormalizeProviderOutcome`) crashes the live writer mid-run and surfaces as
  `{:error, {:run_crashed, reason}}` ⇒ exit 1, or 130 when `reason` is `:killed`.

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
   SHOULD warn during validation when a literal schema map's top-level `"type"` string key is
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

### 6.5 Attempt identity

```
IdempotencyKey = %{run_id, node_path :: address, iteration :: non_neg_integer, attempt :: non_neg_integer}
```

- The logical turn identity is `(run_id, node_path, iteration)`.
- `iteration` is `0` for any node outside a dynamic loop; inside `while_budget`/`until_dry`
  it is the real per-iteration index, so the same body address keys a **distinct** paid
  effect each pass.
- `attempt` (zero-based) refines the logical identity into a single physical provider
  invocation. The writer journals this full key in `agent_started` before invoking the
  provider. An unsettled full key is never invoked again.

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
  to include them). The coupling is unchecked while loading, so this is a footgun: if the
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

Generic `Loop` execution is the normative core algorithm. Legacy `while_budget` and
`until_dry` first desugar to `Loop` (§3.7), then run this algorithm and emit the generic
`loop_decision` payload shape in §7.2. There is no second normative loop event format.

```
RunLoop(node, run_id, provider, prior, ctx):
  - Return LoopCore(node, run_id, provider, prior, ctx, 0).

LoopCore(node, run_id, provider, prior, ctx, iteration):
  - Let {decision, ctx} be DecideCore(node, run_id, prior, ctx, iteration).
  - If {decision} is {:stop, reason}:
    - Commit Event.loop_completed(node, iteration, exhausted: false, reason: reason).
    - Return {:cont, ctx}.
  - If {decision} is {:exhausted, :stop}:
    - Commit Event.loop_completed(node, iteration, exhausted: true, reason: :max_iterations).
    - Return {:cont, ctx}.
  - If {decision} is {:exhausted, :accept_current}:
    - Commit Event.loop_completed(node, iteration, exhausted: true, reason: :max_iterations).
    - Return {:cont, ctx}.       ; library projections may fold last journaled values explicitly
  - If {decision} is {:exhausted, :fail}:
    - Commit Event.loop_exhausted(node, iteration, :max_iterations).
    - Return {:halt, ctx, {:loop_exhausted, node.address, iteration}}.
  - Otherwise {decision} is :continue.
  - Let {seq} be IterationMarker(run_id, node, iteration, ctx.seq).
  - Let {body_ctx} be ctx with {seq: seq, iteration: iteration,
      loop_address: node.address, seen_by: LoopSeenBy(node.until), last_result: nil}.
  - Let {r} be RunNodes(node.body, run_id, provider, prior, body_ctx).
  - If {r} is {:cont, body_ctx'}:
    - Return LoopCore(node, run_id, provider, prior, ctx with seq = body_ctx'.seq, iteration + 1).
  - If {r} is {:loop_stop, body_ctx', reason}:
    - Commit Event.loop_completed(node, iteration + 1, exhausted: false, reason: reason).
    - Return {:cont, ctx with seq = body_ctx'.seq}.
  - If {r} is {:halt, body_ctx', reason}:
    - Return {:halt, ctx with seq = body_ctx'.seq, reason}.
```

```
DecideCore(node, run_id, prior, ctx, iteration):
  - If a `loop_decision` for (node.address, iteration, source_address: nil) is in {prior}:
    - Return {ReplayLoopDecision(payload), ctx}.
  - If {iteration} >= node.max_iterations:
    - Let {decision} be {:exhausted, node.on_exhausted}.
    - Commit Event.loop_decision(node, iteration, decision,
        predicate_result: nil, exhausted: true, source_address: nil).
    - Return {decision, ctx}.
  - If node.until is not nil:
    - Let {result} be Predicate.Evaluate(node.until,
        PredicateContext(run_id, node.address, iteration)).
    - If {result} is true:
      - Let {decision} be {:stop, :until}.
      - Commit Event.loop_decision(node, iteration, decision,
          predicate_result: true, exhausted: false, source_address: nil).
      - Return {decision, ctx}.
  - Commit Event.loop_decision(node, iteration, :continue,
      predicate_result: false, exhausted: false, source_address: nil).
  - Return {:continue, ctx}.
```

`ReplayLoopDecision(payload)` returns the journaled decision verbatim; it MUST NOT
re-evaluate `node.until`, even if the source file changed before resume. Thus the
predicate's truth value is represented by the journaled `loop_decision` event before it
affects execution.

```
LoopSeenBy(nil): Return [].
LoopSeenBy(predicate):
  - Let {dry_nodes} be every Dry predicate reachable in predicate.
  - If {dry_nodes} is empty: Return [].
  - Return the single seen_by list shared by every Dry predicate.
    ; Validation already rejected conflicting lists (§5.7.0).
```

`Until` — body-local loop stop:

```
RunUntil(node, run_id, prior, ctx):
  - Assert ctx.loop_address is not nil and ctx.iteration is an integer.
  - If a `loop_decision` for (ctx.loop_address, ctx.iteration, source_address: node.address)
    is in {prior}:
    - Let {decision} be ReplayLoopDecision(payload).
    - If {decision} is {:stop, reason}: Return {:loop_stop, ctx, reason}.
    - Otherwise Return {:cont, ctx}.
  - Let {result} be Predicate.Evaluate(node.predicate,
      PredicateContext(run_id, ctx.loop_address, ctx.iteration)).
  - If {result} is true:
    - Let seq' be Commit Event.loop_decision(ctx.loop_address, ctx.iteration, {:stop, :until},
        predicate_result: true, exhausted: false, source_address: node.address).
    - Return {:loop_stop, ctx with seq = seq', :until}.
  - Let seq' be Commit Event.loop_decision(ctx.loop_address, ctx.iteration, :continue,
      predicate_result: false, exhausted: false, source_address: node.address).
  - Return {:cont, ctx with seq = seq'}.
```

A loop may have either a top-level `until:` option, which is evaluated before the pass by
`DecideCore`, or body `until(...)` statements, which are evaluated at their source position.
Both use the same closed predicate semantics and the same `loop_decision` event shape; the
`source_address` distinguishes a body stop point from the loop header.

Historical note: older reference sketches named compatibility structs `WhileBudget` and
`UntilDry` directly. A conforming implementation MAY keep such structs internally, but it
MUST lower them to the generic `Loop` decision model before execution or emit byte-equivalent
generic loop events.

`PredicateContext(run_id, loop_address, iteration) = %{run_id: run_id,
accumulators: Accumulator.Of(run_id), remaining: Ledger.Remaining(run_id),
loop_address: loop_address, iteration: iteration}` for loop predicates. Gate/library
predicates MAY pass the same map without `loop_address` only when they do not contain
`dry`; a `dry` predicate outside a loop is a load-time error.

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
`:x` — see the global-by-name rule in §6.6.1. `until_dry` stops (§6.7 `DecideCore`)
once `DryStreak(...) >= node.rounds`.

**Termination guarantee.** Termination is delivered **unconditionally** by the
`max_iterations` cap: `DecideCore` returns `{:exhausted, action}` the moment
`iteration >= node.max_iterations`, and `iteration` strictly increases by one per
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
    - If it is `agent_failed` and payload.usage is not nil:
      Set {spent} to spent + payload.usage.total_tokens.
    - If it is `refine_role_failed` and payload.usage is not nil:
      Set {spent} to spent + payload.usage.total_tokens.
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
- **Rejected and expected-failed attempts still pay.** `agent_committed`,
  `agent_attempt_rejected`, `agent_failed` with provider usage, and `refine_role_failed`
  with provider usage add to `spent`. A schema-exhaustion `agent_failed` has `usage == nil`
  because its paid rejected attempts were already charged individually.
- **Monotonicity.** Because every `usage.total_tokens` is `>= 0`, `spent` is monotonically
  non-decreasing and `remaining` monotonically non-increasing across a run (see §6.7's
  termination note for why non-increasing does not by itself imply termination).

### 6.8 `until:` predicate evaluation

```
Predicate.Evaluate(pred, ctx):
  - If {pred} is Compare{op, left, right}:
    - Return ApplyCompare(op, Resolve(left, ctx), right).
  - If {pred} is Dry{rounds, seen_by}:
    - Return DryStreak(ctx.run_id, ctx.loop_address, ctx.iteration) >= rounds.
      ; `seen_by` is stored on the loop/collect events and affects accumulation, not this fold.
  - If {pred} is PathExists{ref, pointer}:
    - Return PathResolve(ResolveRef(ref, ctx.run_id,
        %{loop_address: ctx.loop_address, iteration: ctx.iteration}), pointer) is {:present, _}.
  - If {pred} is PathNonEmpty{ref, pointer}:
    - Return PathNonEmpty(PathResolve(ResolveRef(ref, ctx.run_id,
        %{loop_address: ctx.loop_address, iteration: ctx.iteration}), pointer)).
  - If {pred} is PathEquals{ref, pointer, literal_json}:
    - Let {lookup} be PathResolve(ResolveRef(ref, ctx.run_id,
        %{loop_address: ctx.loop_address, iteration: ctx.iteration}), pointer).
    - If {lookup} is :missing: Return false.
    - Otherwise {lookup} is {:present, value}; Return JSONEqual(value, literal_json).
  - If {pred} is Agree{ref, pointer, literal_json, threshold}:
    - Return Agree(ResolveRef(ref, ctx.run_id,
        %{loop_address: ctx.loop_address, iteration: ctx.iteration}), pointer, literal_json, threshold).
  - If {pred} is AllOf{ps}: Return true iff Evaluate holds for every p in ps.
  - If {pred} is AnyOf{ps}: Return true iff Evaluate holds for some p in ps.

Resolve(Count{acc}, ctx)  = length(ctx.accumulators[acc] or []).
Resolve(BudgetRemaining{}, ctx) = ctx.remaining.
Resolve(PathCount{ref, pointer}, ctx) =
  PathCount(PathResolve(ResolveRef(ref, ctx.run_id,
    %{loop_address: ctx.loop_address, iteration: ctx.iteration}), pointer)).

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

Path and agreement helpers:

```
PathResolve(value, ""):
  - Return {:present, value}.

PathResolve(value, pointer):
  - Split {pointer} on "/" after the leading slash; unescape "~1" to "/" and "~0" to "~".
  - Let {current} be {value}.
  - For each token:
    - If {current} is a JSON object/map and contains string key token: set current to current[token].
    - Else if {current} is a map and has an existing atom key whose Atom.to_string(key) == token:
      set current to current[key]. Implementations MUST NOT create atoms from pointer tokens.
    - Else if {current} is a JSON array/list and token is a canonical base-10 array index
      ("0" or a non-empty digit sequence not starting with "0") whose integer value is less
      than length(current): set current to that zero-based element.
    - Else Return :missing.
  - Return {:present, current}.

PathNonEmpty(:missing): Return false.
PathNonEmpty({:present, nil}): Return false.
PathNonEmpty({:present, value}) when value is a binary: Return byte_size(value) > 0.
PathNonEmpty({:present, value}) when value is a list: Return length(value) > 0.
PathNonEmpty({:present, value}) when value is a map: Return map_size(value) > 0.
PathNonEmpty({:present, _scalar}): Return true.   ; false and 0 are non-empty scalars

PathCount(:missing): Return 0.
PathCount({:present, nil}): Return 0.
PathCount({:present, value}) when value is a list: Return length(value).
PathCount({:present, value}) when value is a map: Return map_size(value).
PathCount({:present, _scalar}): Return 1.
```

`path_count` counts list elements and object members; it never counts string bytes or
characters. Missing paths and present `nil` both count as `0`; only present `nil` satisfies
`path_exists`.

```
Agree(value, pointer, literal_json, threshold):
  - If {value} is not a list: Return false.
  - Let {matches} be 0.
  - For each {item} in {value}, in list order:
    - Let {lookup} be PathResolve(item, pointer).
    - If {lookup} is {:present, v} and JSONEqual(v, literal_json): increment {matches}.
  - If {threshold} is :all: Return matches == length(value) and length(value) > 0.
  - If {threshold} is :any: Return matches >= 1.
  - If {threshold} is integer n: Return matches >= n.
```

`agree` over an empty list is false for `:all`, false for `:any`, and false for every
positive integer threshold. This avoids vacuous convergence.

```
JSONEqual(a, b):
  - nil equals nil.
  - booleans equal only the same boolean.
  - integers equal only the same integer value.
  - floats equal only the same finite numeric value in hosts that admit floats here.
  - strings equal only byte-identical strings.
  - arrays/lists equal iff they have the same length and pairwise JSONEqual elements.
  - objects/maps equal iff they have the same string-key set and JSONEqual values for every key.
  - Values of different JSON kinds are not equal.
```

Predicate literal validation converts atom literals to strings, `nil` to JSON null,
booleans/integers/floats/strings to the corresponding JSON scalar, lists recursively, and
maps to string-keyed JSON objects; it rejects functions, tuples, structs, PIDs/references,
non-finite floats, non-string/non-atom map keys, and duplicate object keys after
atom-to-string conversion.

### 6.9 Barrier and per-item fan-out — `parallel`, `pipeline`

`Parallel`:

```
RunParallel(node, run_id, provider, prior, ctx):
  - Let {seq} be CommitMarker(parallel_started, node, prior, ctx.seq).   ; payload %{address, branch_count}
  - Let {cap} be min(node.max_concurrency or max(length(node.branches), 1), 8).
  - Let {results} be RunConcurrently(node.branches, cap, fn branch ->
      BuildAgent(branch, run_id, provider, prior, 0) end).     ; off-thread, no journal writes
  - Let {r} be CommitLanes(results, run_id, seq).             ; commit each branch's events in branch order
  - If {r} is {:ok, seq'}:
    - Return {:cont, ctx with seq = CommitMarker(parallel_completed, node, prior, seq')}.
  - If {r} is {:halt, seq', reason}: Return {:halt, ctx with seq = seq', reason}.
```

`Pipeline` is identical except: it commits `pipeline_started` (payload `%{address, items,
item_count, stage_count}`), fans out over `node.lanes` (each lane runs its stages
**sequentially** via `RunLane(stages, run_id, provider, prior, 0)`), joins with no barrier,
and commits `pipeline_completed`.

`RunConcurrently(inputs, cap, fun)` runs `fun` over `inputs` with at most `min(cap, 8)` in flight,
**ordered** (results in input order), with a finite 31-minute branch deadline. Terminal
lane results are gathered and committed in input order. `agent_started` and
`agent_activity` are exceptional because each is synchronously appended before or during
the provider effect; their physical sequence reflects observed concurrent arrival. Read
projections canonicalize agent ordering by address/iteration/attempt. `fun` may return only a lane result
(`{:ok, …}` or `{:failed, …}`); if the provider crashes off-thread inside a lane (§6.4.1),
that crash **propagates** through `RunConcurrently` and crashes the writer before
`CommitLanes` runs, so the region commits **no terminal settlement** lane events (§6.1),
although durable starts/activity may already exist. An unsettled start makes the run
`outcome_unknown`; otherwise it is a
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
BuildAgent(node, run_id, provider, prior, iteration):
  - Let {iteration} be a non-negative integer supplied by the owning traversal; top-level,
    panel, pipeline, and legacy fan-out lanes pass 0, while a generic fanout inside a loop
    passes the current loop iteration.
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
RunLane(stages, run_id, provider, prior, lane_iteration):
  - Let {events} be an empty List and {result} be nil.
  - For each {stage} in stages, in order:
    - Let {r} be BuildAgent(stage, run_id, provider, prior, lane_iteration).
      ; each stage re-addressed while loading (§4.4)
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
  effect is keyed by its own static address); only the lanes themselves run
  concurrently up to `cap` (§6.11).

### 6.10 Verify, Judge, Fan-out

`Verify`:

```
RunVerify(node, run_id, provider, prior, ctx):
  - Let {seq} be CommitMarker(verify_started, node, prior, ctx.seq).    ; %{address, mode, voter_count, threshold}
      ; `mode` is the atom TAG :voters or :lenses (ModeTag(node.mode)), NOT the node's mode tuple.
      ; voter_count and threshold carry the arity, so the tuple's payload is fully recoverable.
  - Let {results} be RunConcurrently(node.voters, max(length(node.voters),1),
      fn voter -> BuildAgent(voter, run_id, provider, prior, 0) end).
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
    - Let {r} be BuildAgent(scorer, run_id, provider, prior, 0). ; resume-aware (§6.9), addr node.address ++ [c,k]
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

`Fanout` — the generic core fan-out region:

```
RunFanout(node, run_id, provider, prior, ctx):
  - Let {fanout_iteration} be ctx.iteration when ctx.loop_address is not nil, otherwise nil.
  - Let {lane_iteration} be fanout_iteration when not nil, otherwise 0.
  - Let {width, seq} be DecideFanoutWidth(node, run_id, prior, ctx.seq, fanout_iteration).
  - If {width} is 0 and node.on_zero is :fail:
    - Let seq' be Commit Event.fanout_failed(node, :zero_width, fanout_iteration).
    - Let reason be {:fanout_failed, node.address, fanout_iteration, :zero_width}.
    - Return {:halt, ctx with seq = seq', reason}.
  - Let {branches} be MaterializeFanoutBranches(node, width).
  - Let {cap} be min(node.max_concurrency or max(width, 1), 8).
  - Let {results} be RunConcurrently(branches, cap,
      fn branch -> RunLane(branch, run_id, provider, prior, lane_iteration) end).
  - Let {r} be CommitLanes(results, run_id, seq).
  - If {r} is {:ok, seq'}:
    - Return {:cont, ctx with seq = CommitFanoutCompleted(node, prior, seq', fanout_iteration)}.
  - If {r} is {:halt, seq', reason}: Return {:halt, ctx with seq = seq', reason}.

DecideFanoutWidth(node, run_id, prior, seq, fanout_iteration):
  - If a `fanout_started` for (node.address, fanout_iteration) is in {prior}:
    - Return {that event's payload.width, seq}.
  - Else width = min(ComputeFanoutWidth(node.width, run_id), 64).
  - Let seq' be CommitFanoutStarted(node, width, prior, seq, fanout_iteration).
  - Return {width, seq'}.

CommitFanoutStarted(node, width, prior, seq, fanout_iteration):
  - If a `fanout_started` for (node.address, fanout_iteration) is in {prior}: Return seq.
  - Commit Event.fanout_started(node, width, node.bind, fanout_iteration) through the serialized append boundary.
    ; payload %{address, iteration: fanout_iteration, width_expr, width, bind}
  - Return the advanced seq.

CommitFanoutCompleted(node, prior, seq, fanout_iteration):
  - If a `fanout_completed` for (node.address, fanout_iteration) is in {prior}: Return seq.
  - Commit Event.fanout_completed(node, fanout_iteration) through the serialized append boundary.
    ; payload %{address, iteration: fanout_iteration}
  - Return the advanced seq.

MaterializeFanoutBranches(node, width):
  - If width == 0: Return [].
  - If node.repeated is true:
    - Let lane_template be the single lane in node.lanes.
    - Return the List [RebaseBody(lane_template, node.address ++ [i]) for i in 0..(width - 1)].
  - Otherwise node.repeated is false:
    - Assert length(node.lanes) == width.      ; guaranteed by validation (§5.8.0)
    - Return the List [RebaseBody(node.lanes[i], node.address ++ [i]) for i in 0..(width - 1)].
```

`ComputeFanoutWidth`:

- For an integer literal width `N`, return `N`.
- For `budget_slices(per: P, max: M?)`, if `Ledger.Remaining(run_id)` is `:infinity`,
  raise `ArgumentError("budget_slices requires a bounded run (no budget target set)")`;
  otherwise return `div(max(remaining, 0), P)` capped to `M` when `M` is present.
- For `path_count(ref, pointer, max: M)`, resolve the global `ref` by `ResolveRef(ref,
  run_id, nil)`, compute `PathCount(PathResolve(value, pointer))`, and return
  `min(count, M)`. Validation rejects loop-local refs in width expressions (§5.8.0).

The width decision is journaled in `fanout_started.width` before any branch runs. Resume
MUST replay the journaled width and MUST NOT re-read budget or bound values for that fanout.
Zero width with `on_zero: :complete` commits start/completed markers, runs no lanes, and
leaves `ctx.last_result` unchanged.
Top-level generic fanout markers use `iteration: nil`, but their lane agents run at
iteration `0`; loop-body generic fanout markers and lane agents both use the owning loop
iteration.

`FanOut` — the legacy budget-scaled surface:

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
  - Let {cap} be min(node.max_concurrency or max(width, 1), 8).
  - RunConcurrently(branches, cap,
      fn branch -> RunLane(branch, run_id, provider, prior, 0) end); CommitLanes.
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

**Panels are observational unless explicitly bound.** Legacy `verify` and `judge` journal
`verify_settled` / `judge_settled` projections but do not implicitly alter control flow.
No node may read `ctx.last_result` as ambient panel context. A predicate may inspect a panel
or fanout outcome only when that outcome has an explicit static binding (`let` or
`fanout bind:`) and the predicate is one of the closed forms in §3.8/§6.8 (`agree`,
`path_exists`, `path_non_empty`, `path_count`, `path_equals`, `all`, `any`, or the
count/budget comparisons). **The language still has no arbitrary conditional or branching
combinator:** predicates can stop bounded loops or gates with pinned exhaustion behavior,
but cannot select an arbitrary subtree. A legacy verdict or winner therefore cannot alter
what runs next by itself; a reaction must be expressed as an explicit journaled data edge or
outside the workflow by folding the journal (`Status.verifications` / `Status.judgments`,
§7.3).

### 6.11 Concurrency: what is parallel vs serial

- `fanout` branches, `parallel` branches, `pipeline` lanes, `verify` voters, `judge`
  **candidate lanes**, and `fan_out` branches MAY run concurrently up to their `cap`. The
  `cap` sources are:
  `fanout`/`parallel`/`pipeline`/`fan_out` take `node.max_concurrency`; omitted means every
  lane is eligible. `verify` and `judge` make every panel lane eligible. In every case the
  effective cap is `min(requested-or-width, 8)`. Terminal settlements are gathered and
  committed in input order. Pre-effect `agent_started` and streamed `agent_activity`
  append synchronously as concurrent tasks reach them, so their journal order is arrival
  order; projections sort agents by stable address, iteration, and attempt.
- Within a `fanout` lane, a `pipeline` lane, a `fan_out` branch, or a `judge` candidate lane, the constituent
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

The supervised journal process owns the single write connection. Folds and run-index reads
use short-lived read-only SQLite connections, so API and LiveView reads do not serialize
through the writer mailbox. Event blobs are limited to 16 MiB and decoded with safe ETF
decoding; workflow loading cannot introduce new atoms.

### 7.2 Event constructors and payload keys

Unless a payload-value pin below says a payload is exact or that a key is absent, the
table lists the keys emitted by the current constructor, not a closed payload schema for
replay. Existing event types MAY grow additive payload keys under the same event type.
New additive keys MUST be introduced so older events that lack the key still fold, and
folds/readers MUST ignore unknown payload keys so the journal remains compatible with the
additive log policy in §7.1.

| `type` | Payload keys |
|---|---|
| `:run_started` | `tree_name, tree_version, node_count, budget, script_path` (no address) |
| `:phase_entered` | `address, name` |
| `:log_emitted` | `address, message` |
| `:agent_started` | `address, iteration, attempt, idempotency_key, label, prompt` |
| `:agent_committed` | `address, iteration, idempotency_key, label, prompt, result, usage, activity` |
| `:agent_activity` | `address, iteration, attempt, activity_index, label, prompt, entry` |
| `:agent_attempt_rejected` | `address, iteration, attempt, label, prompt, output, reason, usage, activity` |
| `:agent_failed` | `address, iteration, attempts, reason, usage, activity` (last event for a top-level fail; `usage`/`activity` are `nil`/`[]` for schema exhaustion and provider-supplied for expected provider failures; inside a concurrent region later lane events may follow it in seq order — the run's halt reason is the **first** `agent_failed` (§6.1), while the Status fold's `failure` is the **last** `agent_failed` in seq order (§7.3)) |
| `:parallel_started` / `:parallel_completed` | `address, branch_count` / `address` |
| `:pipeline_started` / `:pipeline_completed` | `address, items, item_count, stage_count` / `address` |
| `:iteration_started` | `address, iteration` |
| `:loop_decision` | `address, iteration, decision` (`:continue` \| `{:stop, reason}` \| `{:exhausted, action}`), `predicate_result, exhausted, source_address?` |
| `:loop_completed` | `address, iterations, exhausted?, reason?` |
| `:loop_exhausted` | `address, iterations, reason` (terminal failure for generic `loop on_exhausted: :fail`) |
| `:accumulate` | `address, into, iteration, seen_by, added, size` |
| `:verify_started` / `:verify_settled` | `address, mode, voter_count, threshold` / `address, confirmations, total, threshold, survived` |
| `:judge_started` / `:judge_settled` | `address, candidates, criteria` / `address, scores, pick, winner` |
| `:fanout_started` / `:fanout_completed` | `address, iteration?, width_expr, width, bind` / `address, iteration?` |
| `:fanout_failed` | `address, iteration?, reason` (terminal failure for `fanout on_zero: :fail`) |
| `:fan_out_started` / `:fan_out_completed` | `address, per, width` / `address` (legacy sugar payload) |
| `:refine_started` | `address, input, max_rounds, until, on_non_convergence, max_concurrency, reviewer_timeout_ms, gates, reviewers, reviser, artifact_schema_version, review_schema_version, review_adapter_versions` |
| `:refine_round_started` | `address, round, artifact` |
| `:refine_role_failed` | `address, role, role_address, round, reviewer, reviewer_index, attempts, reason, detail, usage, activity` |
| `:refine_gate_evaluated` | `address, gate, predicate, result, input_round, input_refs` |
| `:refine_round_decision` | `address, round, consensus, approval_count, total, reviewer_decisions, artifact, open_findings, role_failures, failed_reviewers, report_snippets` |
| `:refine_completed` | `address, converged, final_round, rounds, artifact, open_findings, role_failures, failed_reviewers, cold_read, report_snippets` |
| `:refine_non_converged` | `address, reason, final_round, rounds, artifact, open_findings, role_failures, failed_reviewers, cold_read, report_snippets` |
| `:refine_input_invalid` | `address, input, reason` |
| `:run_completed` | `value` (terminal on success path; no address) |
| `:run_failed` | `reason` (terminal unexpected failure or `{:outcome_unknown, attempt}`) |

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
- **`agent_started.idempotency_key` / `agent_committed.idempotency_key`** is the §6.5 `IdempotencyKey` map **verbatim** — the
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
  `(address, iteration, attempt)` when emitted by the runner's activity sink. The writer
  assigns each sink observation exactly one increasing index and appends it synchronously
  before notification. Distinct repeated entries use distinct indices and are preserved
  even when their content is identical.
- **`agent_committed.activity` / `agent_attempt_rejected.activity`** are ordered lists of
  activity entry maps for the completed attempt. Entries MAY carry `activity_index` when the
  runner reconciles them with streamed `agent_activity` events; read-model folds use that
  index to avoid counting the same streamed/final activity twice, never value-only dedupe.
- **`agent_failed.usage` / `agent_failed.activity`** are present on every `agent_failed`.
  Schema-exhaustion failures write `usage: nil, activity: []` because each paid rejected
  attempt has already been journaled as `agent_attempt_rejected`. Expected provider failures
  write the provider-supplied normalized `usage` and `activity` from §6.4.1 so failed turns
  remain visible in token/tool accounting.

`run_completed` is the terminal success event; on failure the terminal event is
`agent_failed`, `loop_exhausted`, `fanout_failed`, `refine_non_converged`,
`refine_input_invalid`, or `run_failed` and **no**
`run_completed` is written. Control-flow outcomes
(`loop_decision`, `fanout_started` width keyed by address plus optional iteration,
`fan_out_started` width, `verify_settled`, `judge_settled`) are journaled
so that resume replays rather than recomputes them. A canonical minimal run journals, in
order: `run_started, phase_entered, log_emitted, agent_started, agent_committed,
run_completed` with contiguous `seq` `0..5` when the provider emits no activity.

### 7.3 Status fold (read model)

`Workflow.Status.of(run_id) = Journal.fold(run_id) |> fold(run_id)` is a **pure** reducer
over the journal (it consults no process state). `state` transitions:

```
:pending --run_started--> :running --run_completed---------> :completed
                                    --run_failed------------> :failed
                                    --agent_failed----------> :failed
                                    --loop_exhausted--------> :failed
                                    --fanout_failed---------> :failed
                                    --refine_non_converged--> :failed
                                    --refine_input_invalid--> :failed
```

The fold accumulates `logs`, `agents`, `rejected`, `accumulators`, `verifications`,
`judgments`, `refines`, `usage` (summed from `agent_committed`, `agent_attempt_rejected`,
`agent_failed` with usage, and `refine_role_failed` with usage), `tool_activity` (ordered
provider activity entries with raw event refs), and sets `result = value` on
`run_completed`. Every clause increments `event_count`, so the fold is total.

**List-projection shapes (pinned).** These projections live in the `Workflow.Status` struct
returned by `Workflow.Status.of/1` (§7.6). Of them, **only `logs` (verbatim) and
`agentCount = length(agents)`** surface in the minimal §7.5 run-projection envelope; the
full §7.5 projection additionally exposes `agents`, `rejected`, `verifications`,
`judgments`, `refines`, `toolActivity`, and `rawRefs` for inspect/status clients that need
  the data behind the counts. Logs and event-style projections preserve `seq` order;
  agent projections are upserted and sorted by `(address, iteration, attempt)` so
  concurrent start/activity arrival cannot reorder the public list:

- **`logs`** is an ordered list of **bare `message` strings** — exactly the `log_emitted`
  payload's `message` binary (§7.2), **not** a map. On each `log_emitted` the fold appends
  `payload.message`. (Because a body `log` commits at most once per address, §6.3, a loop
  emits one entry, not one per iteration.)
- **`agents`** is an ordered list of agent projections. `agent_started` upserts a
  `:running` projection before the provider call, and `agent_activity` augments that
  attempt so long-running turns are visible before they settle. On
  `agent_committed`, the fold upserts the same `(address, iteration)` projection with
  `status: :completed` and the projected payload
  `%{address, iteration, label, prompt, result, usage, idempotency_key, activity}`. On
  `agent_failed`, the fold upserts a `status: :failed` projection using the latest matching
  rejection for `label`, `prompt`, `activity`, and phase placement, so an exhausted
  rejected-only agent remains selectable in read surfaces. If `agent_failed.reason` is
  `{:provider_failure, kind, detail}`, the failed projection MUST include
  `%{provider_failure: %{kind, detail}, usage, activity}` from the `agent_failed` payload
  rather than fabricating a rejected output. `agentCount` in the envelope (§7.5) is exactly
  `length(agents)`.
  *(Proposed §10 — dataflow: a proposed extension pins the projected `prompt` — and the `agent_committed.prompt` / `agent_attempt_rejected.prompt` payload keys (§7.2) — to the rendered `String.t()`, never an inert `%Template{}`; see §10.)*
- **`rejected`** is an ordered list appending, on each `agent_attempt_rejected`, the map
  `%{address, iteration, attempt, label, prompt, output, reason, activity}`.
- **`verifications`** / **`judgments`** append, on each `verify_settled` / `judge_settled`,
  the map `%{address, confirmations, total, threshold, survived}` /
  `%{address, scores, pick, winner}` respectively.
- **`refines`** upserts one projection per `refine_started.address`. The projection shape is
  `%{address, state, converged, rounds, final_round, open_findings, final_open_defects,
  failed_reviewers, role_failures, artifact_preview, reviewer_decisions, cold_read,
  report_snippets, raw_refs}`. `artifact_preview` is the first 4096 bytes of the latest
  `refine_round_started.artifact`, `refine_round_decision.artifact`, or terminal refine
  artifact, with no ellipsis added. `raw_refs` is a map with exactly these keys:
  `%{started, rounds, decisions, role_failures, gates, gate_role_agents, terminal, journal}`.
  Each ref is `%{run_id, seq, type, address}`; `started` and `terminal` are one ref or `nil`,
  the other keys are ordered lists. `gates` contains every `refine_gate_evaluated` event for
  the refine address, including a true `:halt` gate that produces a failed
  `refine_non_converged` run with no downstream `emit_result`. `gate_role_agents` contains
  every `agent_activity`, `agent_committed`, `agent_attempt_rejected`, or `agent_failed` event
  whose address is the cold-read or repair role address (`refine.address ++ [3]` or
  `refine.address ++ [4]`). `journal` is the seq-ordered concatenation of every ref used by
  the refine projection, including `started`, `rounds`, `decisions`, `role_failures`,
  `gates`, `gate_role_agents`, and `terminal`. `final_open_defects` is the derived list of
  terminal `open_findings` plus `role_failures` normalized as role-failure defect records
  (§9.11 `FinalOpenDefectJSON`), preserving Claude-style final reports without making
  role failures masquerade as successful reviewer findings.
- **`tool_activity`** appends every `agent_activity` entry and every terminal activity entry
  carried by `agent_committed`, `agent_attempt_rejected`, `agent_failed`, or
  `refine_role_failed`, each with a raw ref `%{run_id, seq, type, address}`. No semantic
  interpretation of provider-specific tool payloads is required; the ordered entries are the
  tool/transcript read surface.

Two conforming implementations therefore emit **byte-identical** `logs` (and the other list
projections) for the same journal.

**Failure projection (last-wins, pinned).** On **every** `agent_failed` the fold sets
`failure = %{address, attempts, reason}` and `state = :failed` **unconditionally** — there
is **no** state guard, so a later `agent_failed` **overwrites** an earlier one. On
`refine_non_converged`, the fold sets
`failure = %{address: address, attempts: 0, reason: {:did_not_converge, address, reason}}`,
where `reason` is `refine_non_converged.payload.reason`;
on `refine_input_invalid`, it sets
`failure = %{address: address, attempts: 0, reason: {:invalid_refine_input, address, reason}}`.
On `loop_exhausted`, it sets
`failure = %{address: address, attempts: 0, reason: {:loop_exhausted, address, iterations}}`.
On `fanout_failed`, it sets
`failure = %{address: address, attempts: 0, reason: {:fanout_failed, address, iteration, reason}}`.
On `run_failed({:outcome_unknown, attempt})`, it marks the matching running agent unknown
and sets failure to `%{address: attempt.address, iteration: attempt.iteration,
attempts: attempt.attempt + 1, reason: {:outcome_unknown, attempt}}`. Other `run_failed`
events set a run-crash failure with no node address.
The folded `failure` is therefore the **last** terminal failure event in `seq` order. In the
common case — a single `agent_failed` (a top-level fail-closed node, or a concurrent region
with exactly one failing lane) or one terminal refine failure — last equals first, so the
folded `failure` matches the halt reason `run` returned (§6.2) and what
`status`/`inspect`/`resume` report.

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

The final value of a completed run is the `run_completed` payload's `value`, supplied by the
workflow's final terminal statement (§5.10.2):

- `return(literal)` stores that static literal.
- `emit(~P"...")` stores the rendered UTF-8 text.
- `emit_result(:binding)` stores the binding's structured public JSON projection. In this
  version the only result-capable binding is `refine`, whose public result shape is
  `RefineResultJSON` (§9.11).

A provider's per-turn `result` is opaque (`term()`), accompanied by
`%Usage{input_tokens, output_tokens, total_tokens}` (all `non_neg_integer()`, summed
field-wise). Provider results are distinct from terminal `emit_result` projections: a
provider may return host terms, but `emit_result` MUST write a JSON-encodable structured
projection to `run_completed.value`.

Run API return values:

- `{:ok, run_id}` on completion.
- `{:error, {:malformed_output, address, reason}}` on fail-closed abort.
- `{:error, {:provider_failure, address, kind, detail}}` when a provider returns an
  expected failure (`kind` = `:quota_exceeded | :model_limit | :timeout | :unavailable`) for
  an ordinary agent turn.
- `{:error, {:loop_exhausted, address, iterations}}` when a generic loop reaches
  `max_iterations` with `on_exhausted: :fail`.
- `{:error, {:fanout_failed, address, iteration, reason}}` when a generic fanout reaches a
  declared terminal failure such as `on_zero: :fail`; `iteration` is `nil` for top-level
  fanouts.
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
| `:provider_failure` | `provider-failure` | 7 |
| `:validation` | `validation` | 6 |
| `:malformed_output` | `malformed-output` | 8 |
| `:did_not_converge` | `did-not-converge` | 9 |
| `:invalid_refine_input` | `invalid-refine-input` | 10 |
| `:loop_exhausted` | `loop-exhausted` | 11 |
| `:fanout_failed` | `fanout-failed` | 12 |
| `:killed` | `killed` | 130 |
| `:runtime` | `runtime` | 1 |

Success exits `0`. Run-outcome mapping: `{:error, {:provider_config, reason}}` — raised
**before** the run starts by `ResolveProvider` (§6.4.1) when the selected provider cannot be
configured or resolved (a module that does not export `run_agent/4`, or a `validate_config/1`
that returns `{:error, reason}` because required configuration is absent) → exit 4;
`{:provider_failure, …}` → exit 7; `{:malformed_output, …}` → exit 8;
`{:did_not_converge, …}` → exit 9; `{:invalid_refine_input, …}` → exit 10;
`{:loop_exhausted, …}` → exit 11; `{:fanout_failed, …}` → exit 12;
`{:run_crashed, :killed}` → exit 130; `{:run_crashed, _}` and `{:already_running, _}` → exit
1; a compile/validation failure of the workflow script → exit 6; a missing script file, a
bad option, an **absent/`nil` `:provider`** option
(`{:usage, :provider}`, §6.4.1), or a resume with no resolvable script path
(`{:no_script_path, run_id}`, §6.2) → exit 2. The `provider-config` code (exit 4) is the
pre-run provider-resolution failure. After a provider resolves, an `ExpectedProviderFailure`
from `run_agent/4` is `{:provider_failure, address, kind, detail}` (exit 7); only provider
bugs — malformed return shapes, malformed expected-failure data, raises/exits, malformed
streams, or malformed usage/activity — are `{:run_crashed, reason}` (exit 1, §6.4.1).

The run projection envelope (for `run`/`test`/`resume`/`status`/`inspect`) carries
**exactly** these fields: `runId, state, treeName, phase, logs, agentCount, eventCount,
usage, result, failure, agents, rejected, verifications, judgments, refines, toolActivity,
rawRefs`, plus a `command` field added by the caller. Here `logs` is the §7.3 `logs`
projection verbatim — an ordered (seq-order) JSON array of the `log_emitted` **message
strings** — and `agentCount` is `length(agents)` (the §7.3 `agents` list); `usage` is
`%{"inputTokens", "outputTokens", "totalTokens"}` including expected-failure usage; `failure`
is `nil` or `%{"address", "attempts", "reason" => inspect(reason)}`. `agents`, `rejected`,
`verifications`, `judgments`, `refines`, and `toolActivity` are the §7.3 list projections
rendered to JSON. `rawRefs` is a top-level map containing at least
`%{"journal" => [%{"runId", "seq", "type", "address"?}]}` for every folded event, where
`"address"` is present when the event payload has a node/refine address. Implementations MAY
include backend transcript/artifact locators when the provider exposes stable opaque refs;
such refs are data only and MUST NOT be dereferenced by the workflow runtime.

`result` is encoded by `TerminalJSON(run_completed.value)`:

```
TerminalJSON(value):
  - If value is a `RefineResultJSON` projection (§9.11): Return value unchanged.
  - If value is JSON-encodable: Return value unchanged.
  - Otherwise Return inspect(value).
```

The `inspect/1` fallback is permitted only for literal `return` values or other non-result
legacy terminal values. A conforming implementation MUST NOT stringify an `emit_result`
projection: `emit_result(:r)` remains structured JSON in the envelope.

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
*observable* behavior — the committed journal events, the run result, and the
exit code. A conforming implementation MAY use any internal strategy (any concurrency
schedule, any storage engine, any host language) provided the observable result obeys these
algorithms. Terminal lane settlements commit in input order; synchronous pre-effect start
and activity events commit in concurrent arrival order, while public agent projections use
stable address order (§6.11).

Normative requirements a conforming implementation MUST satisfy:

- **C1 (core calculus before product vocabulary).** It MUST reject, while loading, any
  form outside the closed vocabulary in §2.4. It MUST treat library/domain surface forms as
  desugaring targets, not as implicit semantic primitives. `gather`/`map` remain DEFER and
  `reduce`/`select` remain REJECT.
- **C2 (determinism by absence).** It MUST NOT provide any workflow-body construct that
  reads a clock, randomness, environment, filesystem, or external module. Determinism
  MUST be a property of the vocabulary, not a runtime linter.
- **C3 (inert tree).** The compiled tree MUST be closure-free, serializable data.
- **C3b (explicit data edges).** A node MUST consume runtime data only through compiled
  `BindingRef`s, accumulator names, or explicit loop/fanout lane bindings. It MUST NOT read
  ambient phase, process state, prior provider conversations, or a hidden "last result"
  except where a core algorithm names that edge (`collect` over the immediately preceding
  body result).
- **C4 (journal as truth).** All read surfaces (status/inspect/resume/live views) MUST be
  pure folds over the journal. Runtime decisions MUST inspect only journaled values, and
  resume MUST replay journaled decisions, not recompute them.
  Resume recompiles the tree from the (mutable) journaled `script_path` and trusts it as-is;
  the reference does **not** journal a tree fingerprint or verify tree identity on resume
  (§6.2, §7.6). (A structural tree-identity check is a possible future hardening, not a
  conformance requirement.)
  - **C4b (multi-failure result exception).** For a concurrent region in which 2+ lanes
    commit `agent_failed`, the initial `run` returns the **first** failing lane's reason
    while resume/status return the **last** (last-wins Status fold). A conforming
    implementation MUST reproduce **both** projections exactly; this is the single,
    pinned exception to "resume replays journaled decisions" (§6.1, §7.3).
- **C5 (at-most-once effects).** A paid effect MUST be identified by `(run_id, node_path,
  iteration, attempt)`. The writer MUST durably append `agent_started` before invoking it.
  If no matching settlement exists, resume MUST terminate with `outcome_unknown` and MUST
  NOT redeliver the attempt. A result may be unknowable; exactly-once is not claimed.
- **C6 (fail closed).** A schema-backed agent whose output fails validation MUST retry
  on-thread up to its retry budget and then fail the node and abort the run with exit 8;
  it MUST NOT coerce, default, or accept malformed structured output.
- **C7 (bounded termination and exhaustion).** Every loop and runtime-width fanout MUST be
  structurally bounded. Termination MUST be guaranteed by literal caps (`max_iterations`,
  `max:`) or by the pinned budget width algorithm; an implementation MUST honor the declared
  exhaustion behavior (`:stop`, `:fail`, `:accept_current`, zero-width completion/failure)
  and MUST NOT rely on body progress to terminate.
  The reference additionally caps fanout width at 64 and in-flight workflow tasks at 8;
  external turns and branch joins MUST have finite deadlines and bounded input/output.
- **C8 (located errors).** Every validation failure MUST be reported as a typed load error
  located at the offending declaration in the author's source.
- **C9 (closed typed predicates).** Every condition MUST be one of the predicate forms in
  §3.8 and MUST evaluate by §6.8. An implementation MUST NOT admit arbitrary functions,
  closures, host expressions, truthiness, or implementation-defined predicates.
- **C10 (journaled value binding only).** Every flowed value MUST be journaled by a
  lexically preceding producer and resolved by a pure fold. Rendering MUST use inert
  templates and deterministic projections; an implementation MUST NOT cache values in live
  process state or include values in idempotency keys.
- **C11 (path-first inert loading).** The Elixir reference MUST accept exactly one bare
  top-level workflow form, parse it as bounded existing-atom AST data, and validate through
  `Workflow.Script.load_tree/1` plus `Workflow.Compiler.compile/3`. It MUST NOT compile or
  evaluate source, expand author macros, load schema modules, or use module reflection.

An implementation MAY add new node kinds and new event types (the log is additive), but it
MUST preserve existing addresses (§4.2) and MUST keep folds total over unknown types. It
MUST NOT weaken C1–C11.

---

## 9. `refine` V1

> **Status: Implemented library sugar / normative desugaring.** `refine` is an accepted
> surface convenience, not a core primitive. The compiler MAY carry an inert
> `%Workflow.Node.Refine{}` compatibility struct, but its required semantics are the
> desugaring in §9.0 to the generic producer, bounded `loop`, reviewer `fanout`, closed
> `agree`/path predicates, and terminal projection rules. `reviewer`, `cold_read`, and
> `repair` are contextual declarations used by this sugar only; they MUST NOT become core
> nodes.

### 9.0 Desugaring to the core calculus

`refine` expresses a bounded convergence loop. It is admissible as library sugar because it
can be expressed by generic core constructs plus library-owned schemas and projections.

```
DesugarRefine(node, env):
  - Lower the input producer or binding to an explicit artifact binding.
  - Build a Loop with max_iterations = node.max_rounds and
    on_exhausted = node.on_non_convergence (:fail -> :fail, :accept_current -> :accept_current).
  - In each loop iteration:
    - Build a reviewer Fanout whose width is the literal reviewer count and whose lane
      agents are the pre-addressed reviewer agents, with `bind:` set to a loop-local
      reviewer-results name.
    - Insert a body `until(...)` node whose predicate is
      `agree(reviewer_results, path: "/approved", equals: true, threshold: :all)` combined
      with the absence of blocking findings by the path predicates in §6.8. If it evaluates
      true, the loop stops before the reviser and exposes the current artifact.
    - Otherwise run the reviser Agent over the current artifact, open findings, and role
      failures, and use its journaled result as the next iteration's artifact.
  - If configured, run cold-read and repair gates as post-loop library fanouts/agents whose
    predicates are the generic path predicates in §3.8/§6.8.
  - Expose two pure journal folds: artifact projection for template rendering and structured
    result projection for `emit_result`.
```

The desugaring is conceptual: a conforming implementation does not have to materialize a
textual `loop` form, but it MUST produce the same addresses, journal decisions, role
idempotency keys, terminal success/failure behavior, and public projection. Any
`refine_*` events in this section are library projection/replay events. They are allowed
because they are journaled before downstream decisions read them; they are not evidence that
`refine`, `reviewer`, `cold_read`, or `repair` are core primitives.

### 9.1 Purpose

`refine` is a top-level, bindable library convenience for one bounded adversarial convergence loop.
It accepts either an inline artifact-producing `agent` or an existing binding, runs a static
panel of reviewers in parallel, revises when any reviewer is non-clear, and terminates by
unanimous clearance, accepted non-convergence, failed non-convergence, or invalid input.

The goal is to express the recurring Claude-style pattern:

1. produce or resolve a draft artifact,
2. run adversarial reviewers in parallel,
3. feed blocking findings to a reviser,
4. repeat until every reviewer agrees or the round bound is reached.

`refine` V1 deliberately does **not** add arbitrary JS-style control flow, dynamic reviewer
generation, child workflows, worktree isolation, large collection fan-out, or custom
consensus predicates.

### 9.2 Surface grammar

Both Elixir call forms are accepted and MUST lower to the same two-argument AST shape
`{:refine, meta, [input_ast, opts_ast]}`:

```elixir
refine(agent("Draft."), reviewers: [...], revise_with: agent("Fix."), until: :unanimous, max_rounds: 5)

refine agent("Draft."),
  reviewers: [...],
  revise_with: agent("Fix."),
  until: :unanimous,
  max_rounds: 5
```

```
Statement :
  - existing statements...
  - RefineStmt

LetProducer :
  - AgentStmt
  - SynthesizeStmt
  - RefineStmt

RefineStmt :
  - `refine` RefineInput `,` RefineOpts
  - `refine` `(` RefineInput `,` RefineOpts `)`

RefineInput :
  - AgentStmt
  - BindingRefAtom

BindingRefAtom :: `:` AtomName

RefineOpts : KeywordList
  required exactly once: reviewers:, revise_with:, until:, max_rounds:
  optional at most once: on_non_convergence:, max_concurrency:, gates:

ReviewerSpec : `reviewer` `(` Atom `,` StringLiteral ReviewerOpts? `)`
ReviewerOpts : `,` KeywordList       ; only adapter:
ReviewerList : `[` ReviewerSpec `,` ReviewerSpec+ `]`
```

`RefineInput` does not accept `SynthesizeStmt` or nested `RefineStmt` directly. Authors bind
those producers first:

```elixir
let :draft = synthesize(inputs, "Summarize.")

let :final =
  refine :draft,
    reviewers: [
      reviewer(:spec, "Find implementability gaps."),
      reviewer(:runtime, "Find replay and journal bugs.")
    ],
    revise_with: agent("Revise using the blocking findings."),
    until: :unanimous,
    max_rounds: 5
```

### 9.3 Validation rules

**R1 — `refine` is top-level only.**

It MUST be rejected inside loop bodies, `parallel`, `pipeline`, `fan_out`, `verify`,
`judge`, or another `refine`.

```counter-example
while_budget reserve: 0, max_iterations: 3 do
  refine agent("draft"), reviewers: [reviewer(:a, "check"), reviewer(:b, "check")],
    revise_with: agent("fix"), until: :unanimous, max_rounds: 3
end
```

**R2 — `reviewer/2` is contextual syntax.**

`reviewer/2` is valid only inside the `reviewers:` list and is not a top-level combinator.

```counter-example
reviewer(:spec, "check the spec")
```

**R3 — `reviewers:` is a literal list of at least two unique reviewer specs.**

Uniqueness is by reviewer atom name, compared exactly after parsing the atom literal.
Reviewer names MUST match `AtomName` (the same lexical recognizer used by `let` binding
names in §10.5.1); dynamic atoms, strings, module aliases, and atoms ending in `?` or `!`
are rejected. Reviewer prompts MUST be literal strings; templates, interpolated strings,
variables, and non-string terms are rejected. A reviewer MAY supply `adapter:` with one of
the literal atoms `:findings_v1 | :defects_v1 | :violations_v1 | :concerns_v1`; when omitted
the adapter is `:findings_v1`. Unknown keys, repeated keys, non-literal adapters, and
unknown adapter atoms are rejected while loading.

```counter-example
refine agent("draft"), reviewers: [reviewer(:a, "check")],
  revise_with: agent("fix"), until: :unanimous, max_rounds: 3
```

```counter-example
refine agent("draft"), reviewers: [reviewer(:a, "x"), reviewer(:a, "y")],
  revise_with: agent("fix"), until: :unanimous, max_rounds: 3
```

```counter-example
refine agent("draft"), reviewers: [reviewer(:a, "x", adapter: :anything), reviewer(:b, "y")],
  revise_with: agent("fix"), until: :unanimous, max_rounds: 3
```

**R4 — option cardinality is exact and unknown options are rejected.**

Required keys: `reviewers:`, `revise_with:`, `until:`, `max_rounds:`. Optional keys:
`on_non_convergence:`, `max_concurrency:`, `gates:`. Required keys MUST appear exactly once;
optional keys MUST appear at most once. `gates:` is the closed gate option language in §9.13;
it is not a general branch body.

```counter-example
refine agent("draft"), reviewers: [], reviewers: [],
  revise_with: agent("fix"), until: :unanimous, max_rounds: 3
```

**R5 — `until:` is exactly `:unanimous`.**

```counter-example
refine agent("draft"), reviewers: [reviewer(:a, "x"), reviewer(:b, "y")],
  revise_with: agent("fix"), until: :majority, max_rounds: 3
```

**R6 — `max_rounds:` is a positive integer literal.**

```counter-example
refine agent("draft"), reviewers: [reviewer(:a, "x"), reviewer(:b, "y")],
  revise_with: agent("fix"), until: :unanimous, max_rounds: 0
```

**R7 — `max_concurrency:` is a positive integer literal when present.**

When omitted, it defaults to the reviewer count.

```counter-example
refine agent("draft"), reviewers: [reviewer(:a, "x"), reviewer(:b, "y")],
  revise_with: agent("fix"), until: :unanimous, max_rounds: 3, max_concurrency: "2"
```

**R8 — `on_non_convergence:` is `:fail | :accept_current`.**

It defaults to `:fail`.

```counter-example
refine agent("draft"), reviewers: [reviewer(:a, "x"), reviewer(:b, "y")],
  revise_with: agent("fix"), until: :unanimous, max_rounds: 3, on_non_convergence: :retry_forever
```

**R9 — inline producer and reviser agents are role-owned.**

Inline producer and reviser agents MUST use literal string prompts only. Their `schema:`
option is rejected because `refine` owns the role schemas and normalization rules. Template
or dataflow setup is supported by binding first and passing the binding:

```elixir
let :draft = agent(~P"Draft from <%= @notes %>")
let :final = refine :draft, reviewers: [...], revise_with: agent("Fix."),
  until: :unanimous, max_rounds: 5
```

`revise_with:` MUST be exactly a bare `agent("literal prompt")` form. V1 rejects reviser
options, `schema:`, template prompts, and interpolation; refine owns the reviser schema,
retry policy, prompt materialization, and normalization.

```counter-example
refine agent("draft"), reviewers: [reviewer(:a, "x"), reviewer(:b, "y")],
  revise_with: agent(~P"Fix <%= @draft %>"), until: :unanimous, max_rounds: 3
```

### 9.4 Semantic model

```
%Workflow.Node.Refine{
  address: address(),
  input: {:producer, Agent.t()} | {:binding, name :: atom(), ref :: BindingRef},
  reviewers: [%{index: non_neg_integer(), name: atom(), prompt: String.t(),
                adapter: reviewer_adapter(), agent: Agent.t()}],
  reviser: Agent.t(),
  until: :unanimous,
  max_rounds: pos_integer(),
  on_non_convergence: :fail | :accept_current,
  max_concurrency: pos_integer(),
  gates: RefineGates.t()
}
```

```
reviewer_adapter() = :findings_v1 | :defects_v1 | :violations_v1 | :concerns_v1
```

The shared `BindingRef` union (§10.11) includes:

```
{:node, address()} | {:map, address()} | {:fanout, address(), fanout_scope()} | {:refine, address()}
```

`let :x = refine ...` records `:x -> {:refine, address}`.
`BoundRefineArtifact({:refine, address})` reads `refine_completed.payload.artifact` for
template rendering, while `BoundRefineResult({:refine, address})` reads the structured
result projection for `emit_result`.

Addresses and paid-effect iteration slots:

```
inline producer [i, 0],    iteration 0
reviewer j      [i, 1, j], iteration r
reviser         [i, 2],    iteration r, produces artifact for round r + 1
refine node     [i]
```

### 9.5 Role normalization

`refine` owns two closed role schemas. These schemas are applied before the role-specific
normalizers below, and authored `schema:` options are rejected by Rule R9.

Artifact schema version 1 is exactly:

```elixir
%{
  "type" => "object",
  "required" => ["artifact"],
  "additionalProperties" => false,
  "properties" => %{
    "artifact" => %{"type" => "string"}
  }
}
```

The default findings adapter schema (`:findings_v1`) is exactly:

```elixir
%{
  "type" => "object",
  "required" => ["approved", "findings"],
  "additionalProperties" => false,
  "properties" => %{
    "approved" => %{"type" => "boolean"},
    "cross_expert_note" => %{"type" => "string"},
    "report_snippet" => %{"type" => "string"},
    "findings" => %{
      "type" => "array",
      "items" => %{
        "type" => "object",
        "required" => ["id", "blocking", "issue", "fix"],
        "additionalProperties" => false,
        "properties" => %{
          "id" => %{"type" => "string"},
          "blocking" => %{"type" => "boolean"},
          "issue" => %{"type" => "string"},
          "fix" => %{"type" => "string"}
        }
      }
    }
  }
}
```

#### 9.5.1 Artifact normalization

Inline producer and reviser provider output MUST normalize before `agent_committed` is
journaled. Accepted provider output is exactly `%{"artifact" => binary}` with no extra
fields and `String.valid?(binary) == true`. The committed `agent_committed.result` is the
artifact binary itself, not the object.

Bound input accepts either a valid UTF-8 binary or exactly `%{"artifact" =>
valid_utf8_binary}`. All other bound values are invalid, including `{:map, address}`
bindings, unbound refs, invalid UTF-8 binaries, maps with extra or missing keys, and
structured non-artifact values.

Invalid bound input commits the terminal event `refine_input_invalid` and fails the run. It
is not an unjournaled crash.

Pinned invalid-input reasons:

```
:unsupported_map_binding
:unbound_binding
:artifact_not_binary
:artifact_invalid_utf8
:artifact_object_unexpected_shape
:artifact_value_unsupported
```

The other literal adapters reuse the same closed field types and differ only in top-level
and item field names:

| adapter | required top-level fields | item array field | item issue field | item fix field | approval rule |
|---|---|---|---|---|---|
| `:findings_v1` | `approved, findings` | `findings` | `issue` | `fix` | `approved == true` |
| `:defects_v1` | `pass, defects` | `defects` | `issue` | `fix` | `pass == true` |
| `:violations_v1` | `pass, violations` | `violations` | `issue` | `fix` | `pass == true` |
| `:concerns_v1` | `verdict, concerns` | `concerns` | `concern` | `recommendation` | `verdict == "approve"` |

For every adapter, each item MUST normalize to `id`, `blocking`, `issue`, and `fix`.
`id`, the adapter's issue field, and the adapter's fix field are required non-empty valid
UTF-8 binaries. `blocking` is required for `:findings_v1`, `:defects_v1`, and
`:concerns_v1`. For `:violations_v1`, an item MAY omit `blocking` and instead provide
`severity`; severities `"blocker"`, `"blocking"`, `"critical"`, and `"error"` are blocking,
and all other severities are non-blocking. `cross_expert_note` and `report_snippet` are
OPTIONAL top-level valid UTF-8 binaries on every adapter schema and are normalized into the
committed reviewer result's `"report_snippets"` list. They are copied from committed
reviewer results into `refine_round_decision.report_snippets`, never into `open_findings`.

The schema selected for a reviewer role is a pure function of its literal `adapter:`. An
authored reviewer cannot provide an arbitrary schema; adding an adapter requires adding a
new literal atom and its complete schema/normalizer to this specification.

```
ReviewerAdapterSchema(adapter):
  - If adapter is :findings_v1: Return the default findings adapter schema above.
  - If adapter is :defects_v1:
    - Return AdapterObjectSchema("pass", "defects", "issue", "fix", require_blocking: true).
  - If adapter is :violations_v1:
    - Return AdapterObjectSchema("pass", "violations", "issue", "fix", require_blocking: false).
  - If adapter is :concerns_v1:
    - Return AdapterObjectSchema("verdict", "concerns", "concern", "recommendation",
        require_blocking: true).

AdapterObjectSchema(approval_field, array_field, issue_field, fix_field, opts):
  - Return a JSON-schema object with `additionalProperties: false`, required fields
    `[approval_field, array_field]`, and `properties`:
    - approval_field: boolean for `pass`, string enum `["approve", "changes"]` for `verdict`;
    - optional top-level `cross_expert_note` and `report_snippet` fields as strings;
    - array_field: array of objects with `additionalProperties: false`;
    - each item requires `id`, issue_field, fix_field, and also `blocking` when
      opts.require_blocking is true;
    - item `properties` contain `id`, issue_field, and fix_field as strings; `blocking` as
      boolean; and, for `:violations_v1`, optional `severity` as string.
```

#### 9.5.2 Reviewer normalization

Reviewer committed result is exactly:

```elixir
%{
  "approved" => boolean(),
  "findings" => [
    %{"id" => binary(), "blocking" => boolean(), "issue" => binary(), "fix" => binary()}
  ],
  "report_snippets" => [binary()]
}
```

For every adapter, including `:findings_v1`, this is the adapter-normalized shape; the
committed `agent_committed.result` MUST always be this canonical map, never the raw
provider map. `"report_snippets"` is always present, including `[]`, and contains the
selected adapter output's optional
`cross_expert_note` followed by optional `report_snippet`, omitting absent fields and empty
strings. Extra fields outside the selected
adapter schema are rejected. Reviewer normalization failure is treated like schema failure:
journal `agent_attempt_rejected`; because reviewers use `retries: 0`, a reviewer-role
failure then journals `refine_role_failed` rather than terminal `agent_failed` (§9.7).

A review is clear iff `approved == true` and no finding has `blocking == true`.

Open findings have this exact event shape:

```elixir
%{reviewer: atom(), reviewer_index: non_neg_integer(), id: binary(), issue: binary(), fix: binary()}
```

Only blocking findings from non-clear reviewers are open findings. Duplicate IDs within one
reviewer are deduped by exact binary `id`; first occurrence wins. Open findings are ordered
by reviewer index ascending, then `id` bytewise ascending.

If a reviewer is non-clear but has no blocking finding, insert:

```elixir
%{
  reviewer: name,
  reviewer_index: index,
  id: "__codex_loops_no_blocking_finding__",
  issue: "Reviewer did not approve but returned no blocking finding.",
  fix: "Revise the artifact to address this reviewer, or return approved: true with no blocking findings."
}
```

Reviewer decisions have this exact shape, in reviewer index order:

```elixir
%{reviewer: atom(), reviewer_index: non_neg_integer(), approved: boolean(), clear: boolean(),
  adapter: reviewer_adapter(), status: :completed | :failed}
```

For a `refine_role_failed` reviewer, the corresponding decision is present with
`approved: false`, `clear: false`, `status: :failed`, and the reviewer's literal adapter.

Role failures have this exact shape:

```elixir
%{
  role: :reviewer | :cold_read | :repair,
  address: address(),
  role_address: address(),
  round: non_neg_integer() | nil,
  reviewer: atom() | nil,
  reviewer_index: non_neg_integer() | nil,
  attempts: pos_integer(),
  reason: term(),
  detail: term() | nil,
  usage: Usage.t() | nil,
  activity: [map()]
}
```

`reason` is one of `{:provider_failure, kind, detail}`, `{:malformed_output, reason}`,
`{:reviewer_timeout, timeout_ms}`, `{:reviewer_crashed, reason}`,
`{:cold_read_timeout, timeout_ms}`, `{:cold_read_crashed, reason}`, or
`{:repair_failed, reason}`. Reviewer role failures are ordered by reviewer index ascending,
then by their journal `seq` when a reviewer somehow produces more than one role-failure
record for the same round. Gate role failures (`:cold_read`, `:repair`) sort after reviewer
round failures in gate execution order.

### 9.6 Prompt construction

Materialized prompt strings are the strings passed to the provider and journaled in ordinary
`agent_*` events.

`ReviewerPrompt(base, round, artifact)` is exactly:

```text
base
"\n\n--- CODEX LOOPS REFINE REVIEW INPUT ---\n"
"round: " <> Integer.to_string(round) <> "\n"
"artifact-bytes: " <> Integer.to_string(byte_size(artifact)) <> "\n"
"artifact:\n"
artifact
"\n--- END CODEX LOOPS REFINE REVIEW INPUT ---"
```

`ReviserPrompt(base, round, artifact, open_findings, role_failures)` is exactly:

```text
base
"\n\n--- CODEX LOOPS REFINE REVISION INPUT ---\n"
"round: " <> Integer.to_string(round) <> "\n"
"current-artifact-bytes: " <> Integer.to_string(byte_size(artifact)) <> "\n"
"current-artifact:\n"
artifact
"\nblocking-finding-count: " <> Integer.to_string(length(open_findings)) <> "\n"
SerializeFindings(open_findings)
"reviewer-role-failure-count: " <> Integer.to_string(length(role_failures)) <> "\n"
SerializeRoleFailures(role_failures)
"--- END CODEX LOOPS REFINE REVISION INPUT ---"
```

`SerializeFindings` concatenates entries in order. Index is 1-based decimal with no leading
zeroes:

```text
"finding " <> Integer.to_string(index) <> ":\n"
"reviewer: " <> Atom.to_string(f.reviewer) <> "\n"
"reviewer-index: " <> Integer.to_string(f.reviewer_index) <> "\n"
"id-bytes: " <> Integer.to_string(byte_size(f.id)) <> "\n"
"id:\n" <> f.id <> "\n"
"issue-bytes: " <> Integer.to_string(byte_size(f.issue)) <> "\n"
"issue:\n" <> f.issue <> "\n"
"fix-bytes: " <> Integer.to_string(byte_size(f.fix)) <> "\n"
"fix:\n" <> f.fix <> "\n"
```

`SerializeRoleFailures` concatenates entries in order. `reason` and `detail` are rendered
with `inspect/1` under the same host/version caveat as §4.4:

```text
"role-failure " <> Integer.to_string(index) <> ":\n"
"reviewer: " <> Atom.to_string(f.reviewer) <> "\n"
"reviewer-index: " <> Integer.to_string(f.reviewer_index) <> "\n"
"reason:\n" <> inspect(f.reason) <> "\n"
"detail:\n" <> inspect(f.detail) <> "\n"
```

`ColdReadPrompt(base, projection)` is exactly:

```text
base
"\n\n--- CODEX LOOPS REFINE COLD READ INPUT ---\n"
"artifact-bytes: " <> Integer.to_string(byte_size(projection.artifact)) <> "\n"
"artifact:\n"
projection.artifact
"\nopen-finding-count: " <> Integer.to_string(length(projection.open_findings)) <> "\n"
SerializeFindings(projection.open_findings)
"role-failure-count: " <> Integer.to_string(length(projection.role_failures)) <> "\n"
SerializeRoleFailures(projection.role_failures)
"--- END CODEX LOOPS REFINE COLD READ INPUT ---"
```

`RepairPrompt(base, projection)` is exactly `ReviserPrompt(base, projection.final_round,
projection.artifact, projection.open_findings ++ ColdReadOpenFindings(projection.cold_read),
projection.role_failures)`, where `ColdReadOpenFindings(%{state: :completed})` returns that
cold-read state's `open_findings` and all other cold-read states return `[]`.

### 9.7 Execution

For `max_rounds = N`, review rounds are `0..N-1`. Reviser runs only for rounds `0..N-2`.

```
RunRefine(node):
  - Capture runtime reviewer_timeout_ms and commit/replay refine_started.
  - Resolve artifact:
    - producer input: RunRoleAgent([i,0], iteration 0, ArtifactSchemaV1, ArtifactNormalizer)
      If the role agent returns an agent failure, halt with that `agent_failed` result and do
      not write `refine_round_started`, `refine_round_decision`, or any terminal refine event.
    - binding input: BoundArtifact(ref); on error commit refine_input_invalid and halt.
  - For r in 0..N-1:
    - Commit/replay refine_round_started(address, r, artifact).
    - Run reviewers [i,1,j] at iteration r concurrently with RunReviewerRoleAgent, cap
      max_concurrency, bounded by reviewer_timeout_ms from refine_started.payload.
    - Commit reviewer lane events and `refine_role_failed` records in reviewer index order.
      A reviewer role failure is **not** a run halt. Preserve every successful reviewer
      output from the same round and keep the failed lane as structured data.
    - Compute/replay refine_round_decision.
    - If consensus: return FinalizeRefine(node, artifact, base_terminal: :completed,
      base_reason: nil, converged: true, round: r, open_findings: [], role_failures: []).
    - If r == N-1:
      - If on_non_convergence is :fail:
        return FinalizeRefine(node, artifact, base_terminal: :non_converged,
          base_reason: :max_rounds, converged: false, round: r, open_findings, role_failures).
      - If on_non_convergence is :accept_current:
        return FinalizeRefine(node, artifact, base_terminal: :completed,
          base_reason: nil, converged: false, round: r, open_findings, role_failures).
    - Run reviser [i,2] at iteration r with ArtifactSchemaV1 and ArtifactNormalizer.
      If the reviser role agent returns an agent failure, halt with that `agent_failed`
      result and do not write a later `refine_round_started`, `refine_non_converged`,
      or `refine_completed`.
    - Set artifact to reviser committed result.
```

`RunRoleAgent` wraps normal agent attempt handling for artifact-producing roles. Provider
output is schema-validated against `ArtifactSchemaV1`, then role-normalized, then committed.
Schema or normalization failure journals `agent_attempt_rejected`; after retries are
exhausted it journals terminal `agent_failed` exactly like existing fail-closed agents.
Inline producer and reviser retries MUST journal each rejected attempt before the next paid
retry is attempted, so a crash between attempts resumes at the first unjournaled attempt and
never loses a paid failed attempt. Committed role results are normalized only.

`RunReviewerRoleAgent` is the reviewer-specific variant. It validates provider output
against the reviewer adapter's role-owned schema (§9.5.2), normalizes to the canonical
review map, and returns either `{:ok, events, review}` or
`{:role_failed, events, role_failure}`. It MUST NOT return terminal `{:failed, ...}` for an
expected reviewer failure. The following reviewer failures become `role_failure` data:

- an `ExpectedProviderFailure` from §6.4.1 (`reason = {:provider_failure, kind, detail}`);
- schema or adapter-normalization exhaustion after the reviewer's retry budget
  (`reason = {:malformed_output, reason}`);
- reviewer timeout (`reason = {:reviewer_timeout, timeout_ms}`);
- reviewer lane exit caught by the refine reviewer scheduler
  (`reason = {:reviewer_crashed, reason}`).

Malformed provider return shapes, malformed expected-failure data, raised provider
exceptions, malformed streams, and malformed usage/activity remain provider bugs (§6.4.1)
and crash the live writer; `RunReviewerRoleAgent` MUST NOT turn provider bugs into
role-failure data.

Reviewer fanout uses the existing concurrent-region lane discipline (§6.9) with a different
settlement contract: workers run off-thread and MUST NOT write the journal directly; the
single writer commits lane events and `refine_role_failed` records in reviewer index order;
each paid effect uses `ResolveIdempotency`; and scheduling remains unobservable. There is no
"first failing reviewer" halt reason, because reviewer role failures are part of the
round's decision data. Reviewer lanes MUST be bounded by an explicit finite timeout. The
timeout is an operational runtime constant, not a DSL author option: the writer captures it
as `reviewer_timeout_ms` in `refine_started.payload`, then execution and resume use that
journaled value. A reviewer lane that exits or times out before producing a schema-valid
review is converted into a `refine_role_failed` event at the refine address, not an
`agent_failed` event.

```
CommitReviewerLanes(results, run_id, seq):
  - Let {seq'} be seq, {reviews} be [], and {role_failures} be [].
  - For each reviewer lane result in reviewer index order:
    - If lane is {:ok, events, review}:
      - Set {seq'} to CommitAll(run_id, seq', events).
      - Append review to {reviews}.
    - If lane is {:role_failed, events, failure}:
      - Set {seq'} to CommitAll(run_id, seq', events).
      - Set {seq'} to CommitAll(run_id, seq', [Event.refine_role_failed(failure)]).
      - Append failure to {role_failures}.
  - Return {:ok, seq', reviews, role_failures}.
```

`refine_started` is authoritative after it is journaled. On resume, role prompts, retries,
labels, reviewers, input descriptor, `max_concurrency`, `gates`, and
`reviewer_timeout_ms` MUST be read from `refine_started.payload`, not from recompiled source
at the same address.

`ReplayDecision(address, round)` is replay-idempotent:

- If a `refine_round_decision` event exists at key `(type, address, round)`, return that payload
  verbatim, including `artifact`, `reviewer_decisions`, `open_findings`, and `consensus`. Do not
  re-run reviewers, re-normalize reviewer results, recompute findings, or re-render a reviser
  prompt from the recompiled source.
- If no decision exists, compute it only from a **settled reviewer set**: for each reviewer
  declared in `refine_started.payload.reviewers`, exactly one of the following MUST already
  be journaled for the round: a reviewer `agent_committed` event at
  `(address ++ [1, reviewer_index], iteration = round)`, or a `refine_role_failed` event
  for that reviewer/round. A partial reviewer set is not enough to compute a decision.
  `consensus` is true iff every reviewer has a committed clear review and
  `role_failures == []`; any role failure makes consensus false while preserving successful
  reviewer findings. `report_snippets` is rebuilt only from committed reviewer
  `agent_committed.result["report_snippets"]` values, in reviewer index order, so a crash
  after reviewer commit but before `refine_round_decision` never loses snippet data.

### 9.8 Output and event payloads

Payload descriptors store plain maps, never Agent structs.

```elixir
input =
  %{kind: :producer, address: [i, 0], prompt: binary(), retries: non_neg_integer(), label: binary() | nil}
  | %{kind: :binding, name: atom(), ref: BindingRef}

reviewer_descriptor =
  %{index: non_neg_integer(), name: atom(), address: [i, 1, j], prompt: binary(),
    adapter: reviewer_adapter(), retries: 0, label: binary() | nil}

reviser_descriptor =
  %{address: [i, 2], prompt: binary(), retries: non_neg_integer(), label: binary() | nil}

cold_read_descriptor =
  nil |
  %{name: atom(), address: [i, 3], prompt: binary(), adapter: reviewer_adapter(),
    retries: 0, label: binary() | nil, when: gate_predicate()}

repair_descriptor =
  nil |
  %{address: [i, 4], prompt: binary(), retries: non_neg_integer(),
    label: binary() | nil, when: gate_predicate()}

gate_descriptor =
  %{cold_read: cold_read_descriptor, repair: repair_descriptor,
    halt_when: gate_predicate() | nil}

raw_ref = %{run_id: binary(), seq: non_neg_integer(), type: atom(), address: address() | nil}
```

```
refine_started
  key: (type, address)
  payload:
    %{address, input, max_rounds, until: :unanimous, on_non_convergence,
      max_concurrency, reviewer_timeout_ms, gates: gate_descriptor,
      reviewers: [reviewer_descriptor],
      reviser: reviser_descriptor, artifact_schema_version: 1, review_schema_version: 1,
      review_adapter_versions: %{findings_v1: 1, defects_v1: 1, violations_v1: 1, concerns_v1: 1}}

refine_round_started
  key: (type, address, round)
  payload: %{address, round, artifact}

refine_round_decision
  key: (type, address, round)
  payload:
    %{address, round, consensus, approval_count, total,
      reviewer_decisions: [reviewer_decision], artifact, open_findings: [open_finding],
      role_failures: [role_failure], failed_reviewers: [atom()], report_snippets: [binary()]}

refine_role_failed
  key: (type, address, role, round, role_address)
  payload:
    %{address, role, role_address, round, reviewer, reviewer_index,
      attempts, reason, detail, usage, activity}

refine_gate_evaluated
  key: (type, address, gate)
  payload:
    %{address, gate: :cold_read | :repair | :halt, predicate: gate_predicate() | nil,
      result: boolean(), input_round, input_refs: [raw_ref]}

refine_completed
  key: (type, address)
  payload:
    %{address, converged, final_round, rounds, artifact, open_findings: [open_finding],
      role_failures: [role_failure], failed_reviewers: [atom()], cold_read: cold_read_state | nil,
      report_snippets: [binary()]}

refine_non_converged
  key: (type, address)
  payload:
    %{address, reason: :max_rounds | {:gate, gate_predicate()}, final_round, rounds, artifact, open_findings: [open_finding],
      role_failures: [role_failure], failed_reviewers: [atom()], cold_read: cold_read_state | nil,
      report_snippets: [binary()]}

refine_input_invalid
  key: (type, address)
  payload: %{address, input, reason}
```

`open_findings`, `role_failures`, `failed_reviewers`, and `report_snippets` are always
present, including `[]`. `failed_reviewers` is the list of reviewer names from
`role_failures`, ordered by reviewer index and deduped first occurrence wins. `cold_read` is
`nil` unless a closed cold-read gate (§9.13) is configured and has run.

`refine_non_converged` folds to failed status; resume returns
`{:error, {:did_not_converge, address, reason}}`, where `reason` is the event payload's
`reason` (`:max_rounds` or `{:gate, gate_predicate()}`).

`refine_input_invalid` folds to failed status; resume returns
`{:error, {:invalid_refine_input, address, reason}}`.

`refine_completed` folds as successful refine output. `BoundRefineArtifact({:refine,
address})` returns `payload.artifact`, whether `converged` is true or false.
`BoundRefineResult({:refine, address})` returns the durable result projection defined in
§9.11.

### 9.9 §7 run-model integration

§7.2 directly includes the refine event constructors listed in §9.8.
`refine_role_failed` and `refine_gate_evaluated` are **non-terminal** read-model/replay data;
they MUST NOT set run state to `:failed`. Two refine events are terminal failure events:
`refine_non_converged` and `refine_input_invalid`. They are terminal in the same sense as
`agent_failed`: no `run_completed` is written after them.

§7.3 state transitions become:

```
:pending --run_started----------> :running --run_completed----------> :completed
                                            --agent_failed-----------> :failed
                                            --loop_exhausted---------> :failed
                                            --fanout_failed----------> :failed
                                            --refine_non_converged---> :failed
                                            --refine_input_invalid---> :failed
```

Failure projection remains the single `%{address, attempts, reason}` map:

- On `agent_failed`, keep the existing `%{address, attempts, reason}` projection.
- On `loop_exhausted`, set
  `failure = %{address: address, attempts: 0, reason: {:loop_exhausted, address, iterations}}`.
- On `fanout_failed`, set
  `failure = %{address: address, attempts: 0, reason: {:fanout_failed, address, iteration, reason}}`.
- On `refine_non_converged`, set
  `failure = %{address: address, attempts: 0, reason: {:did_not_converge, address, reason}}`,
  where `reason` is `refine_non_converged.payload.reason`.
- On `refine_input_invalid`, set
  `failure = %{address: address, attempts: 0, reason: {:invalid_refine_input, address, reason}}`.

§7.4 run API return values add:

- `{:error, {:did_not_converge, address, reason}}` when `on_non_convergence: :fail`
  reaches `max_rounds` (`reason == :max_rounds`) or a `halt_when:` gate fires
  (`reason == {:gate, gate_predicate()}`).
- `{:error, {:invalid_refine_input, address, reason}}` when a bound input cannot normalize to
  an artifact.

§6.2 resume uses the folded failure projection for both new terminal events, so resuming a run
failed by `refine_non_converged` returns `{:error, {:did_not_converge, address, reason}}`,
where `reason` is either `:max_rounds` or `{:gate, gate_predicate()}`; resuming a run
failed by `refine_input_invalid` returns
`{:error, {:invalid_refine_input, address, reason}}`. The JSON failure envelope remains the §7.5
shape; both new failures serialize with `"attempts": 0` and `"reason": inspect(reason)`.

The CLI mappings for these refine terminal failures are part of the §7.5 source-of-truth
table: `:did_not_converge` serializes as `did-not-converge` with exit code `9`, and
`:invalid_refine_input` serializes as `invalid-refine-input` with exit code `10`.

### 9.10 Migration guidance

| Claude workflow pattern | `refine` V1 support | Migration |
|---|---:|---|
| Static producer plus parallel adversarial reviewers plus reviser loop | Supported | `let :x = refine agent(...), reviewers: [...], revise_with: agent(...), until: :unanimous, max_rounds: N` |
| Bound draft from earlier dataflow | Supported | `let :draft = ...`; then `let :final = refine :draft, ...` if the bound value is a valid artifact |
| Consensus gate checking every reviewer approval | Supported | Built into `until: :unanimous` |
| Blocking findings drive reviser prompt | Supported | Built-in normalized `open_findings` and `ReviserPrompt` |
| Direct `synthesize(...)` as refine input | Unsupported | Bind first, then `refine :draft` |
| Direct nested `refine(...)` as refine input | Unsupported | Bind first, then `refine :previous` |
| Dynamic reviewer list from runtime data | Unsupported | Keep orchestration outside V1; future collection dataflow may address this |
| Large collection fan-out over files/issues | Unsupported by `refine` | Use existing `parallel`/`pipeline`/`fan_out`; dataflow `map` remains deferred |
| Arbitrary JS loop condition or majority threshold | Unsupported | V1 is `max_rounds` plus unanimous consensus only |

### 9.11 §10 dataflow integration

§10.5 `Producer` includes `RefineStmt` as a bindable producer. `let :x = refine ...` inserts
the refine node at address `[i]`, records `BindingEnv[:x] = {:refine, [i]}`, commits no
`let` event, and exposes two deterministic folds:

- `BoundRefineArtifact({:refine, address})` returns `refine_completed.payload.artifact` for
  text rendering in `~P`.
- `BoundRefineResult({:refine, address})` returns the structured result projection for
  `emit_result(:x)` (§10.7a).

The structured projection is the public JSON object `RefineResultJSON`:

```json
{
  "artifact": "<string>",
  "converged": true,
  "rounds": 1,
  "finalRound": 0,
  "openFindings": [],
  "finalOpenDefects": [],
  "roleFailures": [],
  "failedReviewers": [],
  "reviewerDecisions": [],
  "coldRead": null,
  "reportSnippets": [],
  "rawRefs": {"journal": []}
}
```

`RefineResultJSON` MUST use exactly these string keys. It MUST NOT contain atom keys, atom
values, tuples, structs, or `inspect/1`-only terms. The nested shapes are:

```elixir
OpenFindingJSON =
  %{"reviewer" => string(), "reviewerIndex" => non_neg_integer(),
    "id" => string(), "issue" => string(), "fix" => string()}

RoleFailureDefectJSON =
  %{"kind" => "role_failure", "role" => "reviewer" | "cold_read" | "repair",
    "roleAddress" => [non_neg_integer()],
    "reviewer" => string() | nil, "reviewerIndex" => non_neg_integer() | nil,
    "id" => string(), "issue" => string(), "fix" => string(),
    "reason" => ReasonJSON}

FinalOpenDefectJSON =
  OpenFindingJSON | RoleFailureDefectJSON

ReviewerDecisionJSON =
  %{"reviewer" => string(), "reviewerIndex" => non_neg_integer(),
    "approved" => boolean(), "clear" => boolean(),
    "adapter" => string(), "status" => "completed" | "failed"}

RoleFailureJSON =
  %{"role" => "reviewer" | "cold_read" | "repair",
    "roleAddress" => [non_neg_integer()], "round" => non_neg_integer() | nil,
    "reviewer" => string() | nil, "reviewerIndex" => non_neg_integer() | nil,
    "attempts" => pos_integer(), "reason" => ReasonJSON,
    "detail" => JsonValue | string() | nil, "usage" => UsageJSON | nil,
    "activity" => [JsonObject]}

ReasonJSON =
  %{"code" => "provider_failure", "kind" => string(), "detail" => JsonValue}
  | %{"code" => "malformed_output", "detail" => string()}
  | %{"code" => "reviewer_timeout" | "cold_read_timeout", "timeoutMs" => non_neg_integer()}
  | %{"code" => "reviewer_crashed" | "cold_read_crashed" | "repair_failed", "detail" => string()}

ColdReadJSON =
  %{"state" => "completed", "openFindings" => [OpenFindingJSON],
      "reviewerDecision" => ReviewerDecisionJSON, "reportSnippets" => [string()],
      "repaired" => boolean()}
  | %{"state" => "failed", "roleFailure" => RoleFailureJSON, "repaired" => false}
```

Role failure conversion is normative. `BoundRefineResult` and every JSON status projection
that exposes role failures MUST use these algorithms; they MUST NOT expose internal atoms,
tuples, structs, or host `inspect/1` strings directly.

```
RoleFailureToJSON(f):
  - Return %{
      "role" => Atom.to_string(f.role),
      "roleAddress" => f.role_address,
      "round" => f.round,
      "reviewer" => if f.reviewer == nil, do: nil, else: Atom.to_string(f.reviewer),
      "reviewerIndex" => f.reviewer_index,
      "attempts" => f.attempts,
      "reason" => ReasonToJSON(f.reason),
      "detail" => RoleFailureDetailToJSON(f.detail),
      "usage" => UsageToJSON(f.usage),
      "activity" => ActivityToJSON(f.activity)
    }.

ReasonToJSON({:provider_failure, kind, detail}):
  - Return %{"code" => "provider_failure", "kind" => Atom.to_string(kind),
      "detail" => ProviderFailureDetailToJSON(detail)}.
ReasonToJSON({:malformed_output, detail}):
  - Return %{"code" => "malformed_output", "detail" => DiagnosticString(detail)}.
ReasonToJSON({:reviewer_timeout, timeout_ms}):
  - Return %{"code" => "reviewer_timeout", "timeoutMs" => timeout_ms}.
ReasonToJSON({:cold_read_timeout, timeout_ms}):
  - Return %{"code" => "cold_read_timeout", "timeoutMs" => timeout_ms}.
ReasonToJSON({:reviewer_crashed, detail}):
  - Return %{"code" => "reviewer_crashed", "detail" => DiagnosticString(detail)}.
ReasonToJSON({:cold_read_crashed, detail}):
  - Return %{"code" => "cold_read_crashed", "detail" => DiagnosticString(detail)}.
ReasonToJSON({:repair_failed, detail}):
  - Return %{"code" => "repair_failed", "detail" => DiagnosticString(detail)}.

ProviderFailureDetailToJSON(detail):
  - Return detail unchanged.  ; §6.4.1 already requires ProviderFailureDetailValue.

RoleFailureDetailToJSON(nil): Return nil.
RoleFailureDetailToJSON(detail) when detail is a ProviderFailureDetailValue: Return detail.
RoleFailureDetailToJSON(detail) when detail is a binary: Return detail.
RoleFailureDetailToJSON(detail): Return DiagnosticString(detail).

UsageToJSON(nil): Return nil.
UsageToJSON(%Usage{input_tokens: i, output_tokens: o, total_tokens: t}):
  - Return %{"inputTokens" => i, "outputTokens" => o, "totalTokens" => t}.

ActivityToJSON(activity):
  - Return activity unchanged.  ; provider activity was validated as [JsonObject] at §6.4.1.
```

`DiagnosticString` is the only way non-JSON diagnostic terms enter the public structured
result. It is deterministic and host-independent for the term classes this specification
allows role failures to journal:

```
DiagnosticString(term):
  - Return DeterministicJSONEncode(DiagnosticValue(term)).

DiagnosticValue(term):
  - nil, boolean, integer, or binary string -> the same JSON scalar.
  - atom -> %{"atom" => Atom.to_string(term)}.
  - list -> map DiagnosticValue over elements in order.
  - tuple -> %{"tuple" => [DiagnosticValue(element_0), ...]}.
  - map -> %{"map" => entries}, where entries is the list of
    %{"key" => DiagnosticValue(key), "value" => DiagnosticValue(value)} sorted by
    DeterministicJSONEncode(DiagnosticValue(key)) bytewise ascending.
  - any other host value -> %{"opaque" => "unsupported"}.

DeterministicJSONEncode(value):
  - Encode JSON without insignificant whitespace.
  - Encode object keys in bytewise ascending order.
  - Encode strings with the JSON escapes required by RFC 8259.
```

Crash and malformed-output details that need more fidelity than
`%{"opaque" => "unsupported"}` MUST be converted to a binary or JSON value before the
`refine_role_failed` event is committed. Once committed, public conversion is exactly the
fold above.

`UsageJSON` is `%{"inputTokens" => i, "outputTokens" => o, "totalTokens" => t}`. `rawRefs`
contains JSON refs `%{"runId" => string(), "seq" => non_neg_integer(), "type" => string(),
"address" => [non_neg_integer()]}`.
`finalOpenDefects` is a list of `FinalOpenDefectJSON` values: the `openFindings` list
unchanged, followed by `RoleFailuresAsDefects(roleFailures)`. It preserves failed reviewer
lanes and gate-role failures as explicit defects without pretending they were successful
review findings. `rawRefs` contains at least the terminal `refine_completed` journal ref and
every `refine_round_decision`, `refine_role_failed`, `refine_gate_evaluated`, and gate-role
`agent_activity`, `agent_committed`, `agent_attempt_rejected`, or `agent_failed` journal ref
used to build the projection.

```
RoleFailuresAsDefects(role_failures):
  - Let failures be the list produced by mapping each role failure through RoleFailureToJSON.
  - Return the List produced by mapping each RoleFailureJSON f in failures, in order, to:
    %{
      "kind" => "role_failure",
      "role" => f["role"],
      "roleAddress" => f["roleAddress"],
      "reviewer" => f["reviewer"],
      "reviewerIndex" => f["reviewerIndex"],
      "id" => "role_failure:" <> f["role"] <> ":" <> AddressPathString(f["roleAddress"]),
      "issue" => "Refine role failed: " <> f["reason"]["code"],
      "fix" => "Re-run or revise with the available successful findings; provider/runtime detail: " <> RenderJSONDetail(f["detail"]),
      "reason" => f["reason"]
    }
```

`RoleFailureDefectJSON` is deliberately not an `OpenFindingJSON`: `:cold_read` and `:repair`
failures can have `reviewer == nil` and `reviewerIndex == nil`. Its `kind` is always
`"role_failure"`, and its `id` is prefixed with `"role_failure:"` so consumers can
distinguish infrastructure/role failures from reviewer-authored findings without guessing
from nullable reviewer fields.
`AddressPathString(address)` returns the slash-separated decimal path with a leading slash
and no trailing slash; for example `[4, 3]` becomes `"/4/3"`.
`RenderJSONDetail(nil) = ""`; for a string it returns the string; for any other `JsonValue`
it returns deterministic JSON encoding with object keys sorted bytewise ascending.

`cold_read_state()` in journal payloads is `nil` when no cold-read ran, otherwise the
internal atom-keyed form of the completed/failed variants above. `ColdReadJSON` is its
public JSON projection. The conversion is key-by-key and atom values become the strings
shown in `ColdReadJSON`.

The shared §10.11 `BindingRef` union includes `{:refine, address}`. `ResolveRef` adds:

```
ResolveRef(ref, run_id, lane):
  - If ref is {:refine, address}: Return BoundRefineArtifact(run_id, address).

BoundRefineArtifact(run_id, address):
  - Fold the journal for the refine_completed event at address.
  - Return that event's payload.artifact.

BoundRefineResult(run_id, address):
  - Fold the journal for the refine_completed event at address.
  - Fold the journal for all refine_round_decision, refine_role_failed, and
    refine_gate_evaluated events whose payload.address == address, plus gate-role
    agent_activity, agent_committed, agent_attempt_rejected, and agent_failed events whose
    payload.address is address ++ [3] or address ++ [4].
  - Convert the internal projection to `RefineResultJSON` above.
  - Return that public JSON object.
```

`{:refine, address}` is valid only after `refine_completed`; a terminal
`refine_non_converged` or `refine_input_invalid` produces no bound value because the run is
failed and no downstream node executes. `on_non_convergence: :accept_current` still writes
`refine_completed`, so it is bindable.

### 9.12 Conformance

Reviewers MAY run in any order or in parallel, since all observable reviewer events commit in
reviewer index order and `OpenFindings` is totally ordered. Scheduling MUST NOT affect the
verdict, the revision prompt, the terminal event, or the bound artifact.

### 9.13 Closed schema-bound gates for cold-read, repair, and halt

`refine` admits one narrow gate option language. It is **not** a top-level combinator, not a
general `if`, and not a branch body: each gate can only trigger a built-in refine action
over the current structured refine result projection.

```
RefineGates : `[` RefineGate (`,` RefineGate)* `]`
RefineGate :
  - `cold_read:` ColdReadGate
  - `repair_when:` GatePredicate
  - `halt_when:` GatePredicate

ColdReadGate : `[` `reviewer:` ReviewerSpec `,` `when:` GatePredicate `]`

GatePredicate :
  - `path_exists` `(` JsonPointerString `)`
  - `path_non_empty` `(` JsonPointerString `)`
  - `path_count` `(` JsonPointerString `)` CompareOp IntegerLiteral
  - `path_equals` `(` JsonPointerString `,` Literal `)`

CompareOp : `>` | `<` | `>=` | `<=` | `==`
JsonPointerString :: `"` JsonPointerCharacter* `"`      ; same raw-string rule as §10.4.1
```

Validation is load-time and closed:

- `gates:` MUST be a literal keyword list containing each gate key at most once.
- `cold_read:` lowers its `ReviewerSpec` to a `cold_read_descriptor` at address
  `address ++ [3]`; `repair_when:` lowers the existing `revise_with:` agent to a
  `repair_descriptor` at address `address ++ [4]`. Both descriptors are stored in
  `refine_started.payload.gates`; resume MUST use those journaled descriptors.
- `JsonPointerString` MUST be a literal RFC 6901 pointer string beginning with `"/"` or the
  empty string `""`; invalid escape sequences (`~` not followed by `0` or `1`) are rejected.
- `path_equals` literals MUST pass `GateLiteralToJSON` below while loading; unsupported
  literal kinds and duplicate object keys after atom-to-string conversion are rejected.
- A gate predicate evaluates against the provisional `BoundRefineResult` projection (§9.11),
  not against arbitrary agent output. Unknown paths evaluate to missing; they do not raise.
- `repair_when:` and `halt_when:` MAY both be present. Execution order is fixed:
  cold-read, then repair, then halt. A true `halt_when:` after the cold-read/repair pass
  wins over completion and commits `refine_non_converged` with
  `reason: {:gate, gate_predicate()}`.

Gate evaluation is a pure operation over the public `RefineResultJSON` shape (§9.11). Before
evaluating a gate, the provisional internal projection is converted to the same string-keyed
JSON object shape that `emit_result` would expose. Gate lookup does not use the template
formatter's `JsonPointer.Get`, because gates must distinguish a missing path from a present
JSON `null`.

```
GatePredicate.Evaluate(predicate, projection):
  - Let json be RefineResultJSON(projection).
  - If predicate is path_exists(pointer):
    - Return GatePointer.Resolve(json, pointer) is {:present, _}.
  - If predicate is path_non_empty(pointer):
    - Let lookup be GatePointer.Resolve(json, pointer).
    - If lookup is :missing: Return false.
    - Otherwise let lookup be {:present, value}; Return GateNonEmpty(value).
  - If predicate is path_count(pointer) op n:
    - Let count be GateCount(GatePointer.Resolve(json, pointer)).
    - Return CompareInteger(count, op, n).
  - If predicate is path_equals(pointer, literal):
    - Let lookup be GatePointer.Resolve(json, pointer).
    - If lookup is :missing: Return false.
    - Otherwise let lookup be {:present, value}.
    - Let literal_json be GateLiteralToJSON(literal).  ; validation already proved this succeeds
    - Return JSONEqual(value, literal_json).

GatePointer.Resolve(value, pointer):
  - If pointer == "": Return {:present, value}.
  - Split pointer on "/" after the leading slash; unescape "~1" to "/" and "~0" to "~".
  - Let current be value.
  - For each token:
    - If current is a JSON object and contains string key token: set current to current[token].
    - Else if current is a JSON array and token is a canonical base-10 array index
      (`"0"` or a non-empty digit sequence not starting with `"0"`) whose integer value is
      less than length(current): set current to that zero-based element.
    - Else Return :missing.
  - Return {:present, current}.

GateNonEmpty(value):
  - If value is null: Return false.
  - If value is a JSON string: Return byte_size(value) > 0.
  - If value is a JSON array: Return length(value) > 0.
  - If value is a JSON object: Return map_size(value) > 0.
  - Otherwise Return true.  ; booleans and numbers are present non-null scalars; no truthiness

GateCount(:missing): Return 0.
GateCount({:present, null}): Return 0.
GateCount({:present, value}) when value is a JSON array: Return length(value).
GateCount({:present, value}) when value is a JSON object: Return map_size(value).
GateCount({:present, _scalar}): Return 1.  ; strings, booleans, and numbers are scalars

CompareInteger(left, op, right):
  - `>`  returns left > right.
  - `<`  returns left < right.
  - `>=` returns left >= right.
  - `<=` returns left <= right.
  - `==` returns left == right.
```

`path_count` therefore counts list elements and object members; it does not count string
bytes or characters. A missing path and a present JSON `null` both have count `0`, but only
the latter satisfies `path_exists`.

`path_equals` has no runtime coercion. Its right-hand literal is converted once during
validation:

```
GateLiteralToJSON(literal):
  - nil -> null.
  - boolean, binary string, or integer -> the same JSON scalar.
  - atom -> Atom.to_string(atom) as a JSON string.
  - list -> map GateLiteralToJSON over elements in order.
  - map -> convert each key:
    - string key -> same string key.
    - atom key -> Atom.to_string(key).
    - any other key -> validation error.
    Then convert values recursively and reject if two keys become the same string.
  - float, tuple, PID/function/reference, or any other literal kind -> validation error.

JSONEqual(a, b):
  - null equals null.
  - booleans equal only the same boolean.
  - strings equal only byte-identical strings.
  - integers equal only the same integer value.
  - arrays equal iff they have the same length and pairwise JSONEqual elements.
  - objects equal iff they have the same string-key set and JSONEqual values for every key.
  - Values of different JSON kinds are not equal.
```

Consequences: `path_equals("/x", nil)` is true for a present JSON `null` and false for a
missing `/x`; `path_equals("/x", :approved)` compares to the JSON string `"approved"`;
`path_equals("/x", "1")` does not equal the JSON integer `1`; `path_non_empty("/x")` is
true for `false` and `0` because gates do not use truthiness.

Execution is deterministic, journaled, and bounded:

```
FinalizeRefine(node, artifact, base_terminal, base_reason, converged, round, open_findings, role_failures):
  - Let projection be ProvisionalRefineResult(..., cold_read: nil, report_snippets).
  - Let {cold_result} be ReplayOrEvaluateGate(node, :cold_read, projection).
  - If cold_result is true:
    - Let {projection} be RunOrReplayColdRead(node, projection).
  - Let {repair_result} be ReplayOrEvaluateGate(node, :repair, projection).
  - If repair_result is true:
    - Let {projection} be RunOrReplayRepair(node, projection).
  - Let {halt_result} be ReplayOrEvaluateGate(node, :halt, projection).
  - If halt_result is true:
    - Commit/replay refine_non_converged with reason {:gate, node.gates.halt_when}.
    - Return {:halt, ctx, {:did_not_converge, node.address, {:gate, node.gates.halt_when}}}.
  - If base_terminal is :non_converged:
    - Commit/replay refine_non_converged with reason base_reason.
    - Return {:halt, ctx, {:did_not_converge, node.address, base_reason}}.
  - Commit/replay refine_completed with projection.
  - Return {:cont, ctx with last_result = projection.artifact}.

ReplayOrEvaluateGate(node, gate, projection):
  - If node.gates has no descriptor/predicate for gate: Return false.
  - If a refine_gate_evaluated event exists for (node.address, gate): Return payload.result.
  - Let result be GatePredicate.Evaluate(predicate, projection).
  - Commit refine_gate_evaluated(address, gate, predicate, result,
      input_round: projection.final_round, input_refs: projection.raw_refs.journal).
  - Return result.
```

`refine_gate_evaluated` is the replay boundary for gate booleans. Resume MUST NOT
re-evaluate a gate whose event is already journaled, even if a script edit would change the
predicate. It reuses the journaled `result` and the journaled descriptors in
`refine_started.payload.gates`.

Cold-read is one replayable reviewer-role effect:

```
RunOrReplayColdRead(node, projection):
  - Let descriptor be refine_started.payload.gates.cold_read.
  - Let outcome be ResolveIdempotency(prior, descriptor.address, 0).
  - If outcome is {:committed, review, _usage}:
    - Return projection with cold_read from that committed canonical review.
  - If a refine_role_failed exists with role: :cold_read and role_address == descriptor.address:
    - Return projection with cold_read = %{state: :failed, role_failure, repaired: false}
      and role_failures including that failure.
  - Otherwise run RunReviewerRoleAgent with role :cold_read, address descriptor.address,
    iteration 0, adapter descriptor.adapter, prompt ColdReadPrompt(descriptor.prompt, projection),
    and the same reviewer_timeout_ms captured in refine_started.
  - On success, commit its ordinary agent events at [i,3] and return projection with
    cold_read = %{state: :completed, open_findings, reviewer_decision, report_snippets,
      repaired: false}.
  - On expected provider/schema/timeout/crash lane failure, commit refine_role_failed with
    role: :cold_read, reviewer: descriptor.name, reviewer_index: nil, round: nil, and return
    projection with cold_read failed. Do not fail the run.
```

Repair is one replayable artifact-role effect:

```
RunOrReplayRepair(node, projection):
  - Let descriptor be refine_started.payload.gates.repair.
  - Let outcome be ResolveIdempotency(prior, descriptor.address, 0).
  - If outcome is {:committed, artifact, _usage}:
    - Return projection with artifact replaced by artifact and cold_read.repaired = true
      when cold_read.state is :completed.
  - If a refine_role_failed exists with role: :repair and role_address == descriptor.address:
    - Return projection with that role_failure appended, artifact unchanged, and
      cold_read.repaired unchanged or false.
  - Otherwise run an artifact role agent at [i,4], iteration 0, with ArtifactSchemaV1 and
    ArtifactNormalizer over RepairPrompt(descriptor.prompt, projection).
  - On success, commit ordinary agent events at [i,4], replace artifact with the normalized
    artifact, and set cold_read.repaired = true when cold_read.state is :completed.
  - On ExpectedProviderFailure or schema/normalization exhaustion, commit refine_role_failed
    with role: :repair, reviewer: nil, reviewer_index: nil, round: nil, and reason
    {:repair_failed, underlying_reason}. Do not crash and do not commit terminal
    agent_failed; artifact remains unchanged.
```

Gate role effects use ordinary idempotency keys `(run_id, [i,3], 0, attempt)` and
`(run_id, [i,4], 0, attempt)`. Their successful paid attempts are ordinary
`agent_committed` events and their rejected schema attempts are ordinary
`agent_attempt_rejected` events, so budget, tool activity, raw refs, and resume reuse follow
§6.4/§7.3 automatically. Their expected role failures are `refine_role_failed` events, so
budget and tool activity are folded by §6.7.1 and §7.3. Provider bugs still crash the writer.

This gate language covers the observed corpus cases:

- cold-read only when a structured result has defects (`path_non_empty("/openFindings")`);
- repair only when a cold-read returns defects (`path_non_empty("/coldRead/openFindings")`);
- halt when a schema-bound build/review report says work is blocked
  (`path_equals("/build/status", "blocked")`).

It deliberately cannot select an arbitrary subtree, run unbounded loops, call user code, or
evaluate host-language predicates.

---

## 10. Dataflow core and proposed extensions

> **Status: dataflow core implemented; remaining surface proposed/deferred.** The reference
> implementation has shipped the zero-new-event dataflow core: `let :name = agent(...)`,
> `let :name = synthesize(...)`, `let :name = refine(...)` where `refine` is a library
> producer sugar (§9), top-level `agent(~P"...")` prompt injection over previous `let`
> bindings, terminal `emit(~P"...")`, and structured terminal `emit_result(:name)`. This
> section is the normative home for the dataflow addendum; §1–§8 define the generic core
> calculus and this section supplies the detailed template/binding machinery.
> `SPEC-DATAFLOW-PROPOSAL.md` remains design provenance, not the primary spec.
>
> **Clearly delimited PROPOSED surface.** `gather` and `map` remain **DEFER**; their detailed
> rules are specified below as proposed future work and are not implemented by the current
> reference compiler. `reduce` and `select`/`when` remain **REJECT**. The §10.3 Principle 6 →
> 6′ reconciliation and its amendments are presented as **PROPOSED** amendments to the base
> normative body as historical provenance; the current §1–§8 text has already adopted the
> journaled-values-only rule.
>
> Notation is identical to the rest of this document (Appendix A): a `::` production is
> **lexical**, a `:` production is **syntactic**. RFC 2119 keywords in the implemented core
> describe shipped requirements; RFC 2119 keywords under sections explicitly marked DEFER,
> PROPOSED, or REJECT fix future or excluded behavior precisely.

### 10.1 Purpose & the governing rule (design principles)

**The base problem: outputs flow only through named journal edges.** Earlier drafts of the
§1–§8 DSL produced values it could not reuse. An
`agent`, a `verify`/`judge` panel, and a `synthesize` each commit a result to the journal
(`agent_committed.result`, `verify_settled`, `judge_settled` — §7.2), but a later node may
read them only by an explicit `let`/`BindingRef` or accumulator edge. Prompt interpolation is
still forbidden; §6.4.1 fixes the provider port so the prompt is either literal or the
materialized result of an inert template over journaled bindings. The `agent → collect →
accumulator` edge (§6.6) carries collected content into a named accumulator and its count into
closed predicates. The worked dataflow boundaries (§11.4 C/F/G) remain: `judge`'s winner is
never implicitly passed to `synthesize`; a
`pipeline` stage never sees its item; a `fan_out` lane is a byte-identical replica.
The implemented dataflow core opens one narrow edge for `agent`/`synthesize` outputs: bind the
producer with `let`, render it through `~P`, and consume it from a later top-level `agent` or
`emit`.

**The thesis: add DATA FLOW, not CONTROL FLOW.** This extension would add the ability to **flow
a journaled value into a later prompt, a template terminal value, or a closed structured result
projection** — and deliberately **not** add control flow: no general `if`, no value-dependent
choice of which subtree runs, no unbounded iteration, no arbitrary computation. It changes only
*what data a node's prompt/terminal projection is derived from*, never which nodes run or how
many times. The deferred `map` proposal is the one
possible exception: it would add bounded, capped fan-out over a journaled collection and remains
outside the implemented core.

**The governing rule (the spine).** Three clauses apply to every idiom in §10:

1. **Flow only journaled values, and only through closed projections.** A value MAY flow from
   node *P* into node *Q*'s prompt or an `emit` terminal **iff** *P*'s output is already a
   committed journal event **before** *Q* executes, and the flow happens through the
   deterministic, total, closure-free `RenderText` of §4.4 — widened here (§10.4) to accept
   journaled values as input. A value MAY flow into `emit_result` only through that producer's
   explicitly specified result projection (§10.7a), never through `RenderText`. No interpolation
   (`"… #{expr} …"`), no computed value, no closure ever enters a prompt or structured result.
2. **Transform collections with nodes only — never lambdas.** The implemented core has no
   collection transform beyond existing `synthesize`. The deferred future forms keep the same
   rule: per-element work uses a **node** (`map`, one agent per element) and folding a collection
   into one value uses a **node** (`gather`, one agent over the whole collection). No
   `Enum.map(fn … end)`, no anonymous function, ever (Rule 5.1.1 still holds; §10.4's struct
   stays closure-free).
3. **Bound every fan-out.** If the deferred `map` ships, its runtime width MUST carry a
   **static structural cap** (`max: <pos-int literal>`), exactly as every loop carries
   `max_iterations` (Principle 5). Width `= min(observed_length, max)`; the region has at most
   `max` lanes and provably terminates.

### 10.2 Verdict summary — per-idiom decisions

| Idiom | Verdict | One-line reason |
|---|---|---|
| **Template layer** (§10.4) | **ADOPT / IMPLEMENTED** — foundation | Nothing flows without it; inert struct + load-time binary scanner + the render §4.4 already defines. Closure-free by construction. |
| **`let`** (§10.5) | **ADOPT / IMPLEMENTED CORE** | The keystone; currently binds `agent(...)`, `synthesize(...)`, and `refine(...)`. No new `let` effect/event/key — a bound value is a fold over the producer's journaled output (`agent_committed` or `refine_completed.payload.artifact`). |
| **prompt injection** (§10.6) | **ADOPT / IMPLEMENTED CORE** | The edge authors want ("improve this draft"); top-level `agent(~P"...")` renders previous `let` bindings and rides the existing `agent_committed.prompt`. |
| **`emit`** (§10.7) | **ADOPT / IMPLEMENTED CORE** | Pure render, no paid effect; makes "flow N results into one document" a first-class terminal. |
| **pipeline-with-dataflow** (§10.8) | **ADOPT / IMPLEMENTED by composition** | Falls out of `let` + injection + sequencing — no new combinator. |
| **`gather`** (§10.9) | **DEFER** | `synthesize` over journaled inputs; ship when folding several bound outputs recurs. |
| **`map`** (§10.9) | **DEFER** | Heaviest: runtime-decided width, per-lane re-addressing, structural `max:` cap, a new region + two new events. Single-agent lanes in Tier 1. |
| **`reduce`** (§10.10) | **REJECT** (Tier 1) | Drifts toward in-language computation; `gather` + accumulators cover real needs. |
| **`select` / `when`** (§10.10) | **REJECT** | It is **control** flow, not data flow — violates Principles 2, 3, and 6 and the thesis. |

**Build order.** (1) **Complete:** dataflow core = Template + `let` over `agent`/`synthesize`/`refine` +
top-level injection + `emit`, one coherent slice (unlocks pipeline-with-dataflow for free, adds
**zero** new events). (2) **DEFER:** `gather`. (3) **DEFER:** `map`. (4) **Never, absent a hard
wall:** `reduce`, `select`/`when`. §9 `refine` is implemented library sugar whose completed
artifact is bindable by the same `let` machinery.

### 10.3 Reconciliation — Principle 6 → 6′ and the proposed amendments

This section is a principled **strengthening** of "no value binding", not a loosening. The
render §4.4 *already* splices data into prompts (`verify` splices `<subject>`, `judge` splices
`<candidate>`, `synthesize` splices `Inputs: <inspect(inputs)>`); the implemented language is
"only **static literal** data in prompts, through `RenderText`." This extension changes
exactly one thing: it widens the *source* of `RenderText`'s input from "a static literal"
to "a value already committed to the journal." The render itself is unchanged.

When promoted, §10 would amend the following shipped clauses. Each amendment is a strengthening.
These are presented as **proposed amendments**; the shipped clauses in §1–§8 are unchanged and
carry only the one-line forward-reference notes that point here.

- **Principle 6 → Principle 6′ (journaled-values-only, deterministic-projection-only).** A name MAY
  be bound (via `let`, §10.5) only to a value **already committed to the journal** by a
  lexically-preceding node. A bound value MAY flow into a later node **only** through
  `RenderText` (§10.4) over an **inert `%Template{}`** whose only dynamic parts are
  assigns-referencing-bindings, or into `emit_result` through an explicitly specified public
  result projection (§10.7a). It MUST NOT flow through interpolation, a closure, arithmetic, a
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
- **Rule 5.3.1 → Rule 5.3.1′ (agent prompt admits an inert `%Template{}`).** The literal-only gate
  requires `is_binary(prompt)`; a `~P` template lowers to the AST tuple `{:sigil_P, meta, …}`, for
  which `is_binary/1` is false, so the literal-only rule categorically rejects it. The amendment: the
  agent-prompt AST is admissible iff **either** `is_binary(prompt)` **or** it is a `{:sigil_P, _, _}`
  node lowered by `compile/3` to an inert closure-free `%Template{}` in an admissible position
  (Rule P.1). This is a strengthening: it admits only the checked, closure-free `%Template{}` and
  still rejects every variable, call form, interpolation, and computed prompt the literal-only rule rejects.
- **§2.3 Literal admissibility → §2.3′ (a `~P` template is a `Macro.quoted_literal?` exemption).**
  The literal-only rule requires every prompt/data value to satisfy `Macro.quoted_literal?/1`; a sigil is a
  call-form AST (`{:sigil_P, …}`), not a quoted literal, so the literal-only rule rejects it. The amendment:
  a prompt / `emit` / `gather` template MAY be a `~P` sigil that lowers to an inert, closure-free
  `%Template{}`, exempt from the `Macro.quoted_literal?` requirement **precisely because** it lowers
  to inert struct data (§10.4.2). Interpolation, closures, and
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
- **The closed-vocabulary cluster → explicit core/sugar split.** Clauses that formerly fixed
  a combinator *count* now reference §2.4's closed surface vocabulary and the core/sugar
  distinction: **Principle 1** says product vocabulary must desugar before becoming primitive;
  **§2.4 → §2.4′** separates core forms, library forms, deferred forms, rejected
  forms, and contextual names; **§8 C1 → C1′** rejects any form outside that split; **Rule
  5.1.3**'s vocabulary set widens only by named entries with their own `compile/3` clauses;
  **§11.2** at-a-glance table documents the accepted authoring surface. `collect` remains
  **body-only**. The implemented dataflow core currently recognizes `let`, `emit`, and
  `emit_result`; `gather` and `map` remain DEFER.
- **Separately (terminal-value amendment): §5.10.2** ("a workflow MUST contain a `return`") is
  widened by `emit` and `emit_result` to "a final `return`, `emit`, or `emit_result`"
  (§10.7 / §10.7a / DF-E2 / DF-ER1).

Every amendment is a strengthening. C2–C8 (except C1 → C1′) are untouched; `map` extends C7 with
one more structural cap (`map.max`) and loses nothing.

### 10.4 The template layer — Verdict: ADOPT (foundation)

Prompt injection (§10.6) and `emit` (§10.7) both render bound values into text through a
**logic-less, inert template**. The `~P` template reuses **only the ideas** of EEx/HEEx — the
`<%= @assign %>` hole surface and load-time assigns-dependency tracking — and reuses **none of
EEx's code**: no `EEx.tokenize`, no `EEx.Engine`, no embedded Elixir, no compile-to-closure. A
`~P` template is lowered by a **hand-rolled binary scanner**, a plain function called from
`Workflow.Compiler.compile/3` — the same single validation locus every other combinator uses —
never by a self-expanding sigil macro.

> **Note — no `sigil_P` macro exists.** `~P` is surface syntax only. No `defmacro sigil_P` is
> defined or imported; `compile/3` recognizes the raw AST term
> `{:sigil_P, meta, [{:<<>>, _, [raw]}, mods]}` in an admissible prompt position and lowers it
> with the plain function `Workflow.Template.parse/2`, keeping all template validation inside
> `compile/3`.

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
AssignHole :: `<%=` TemplateWS* HoleExpr TemplateWS* `%>`
HoleExpr ::
  - AssignExpr
  - FormatExpr
AssignExpr :: `@` AssignName
FormatExpr ::
  - `path` `(` AssignExpr `,` JsonPointerString `)`
  - `flatten` `(` AssignExpr (`,` JsonPointerString)? `)`
  - `count` `(` AssignExpr (`,` JsonPointerString)? `)`
  - `numbered_findings` `(` AssignExpr (`,` JsonPointerString)? `)`
  - `truncate` `(` AssignExpr `,` IntegerLiteral `)`
StatementTag :: `<%` [lookahead != `=` and != `#` and != `%`] TagBody `%>`
CommentTag :: `<%#` TagBody `%>`
LiteralEscapeTag :: `<%%` TagBody `%>`
TagBody :: (SourceCharacter but not the sequence `%>`)*
AssignName :: (Letter | `_`) (Letter | Digit | `_`)*   ; recognizer ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/
JsonPointerString :: `"` JsonPointerCharacter* `"`      ; RFC 6901 pointer literal after unescaping
JsonPointerCharacter :: SourceCharacter but not `"` or `\`
JsonPointerCharacter :: `\` (`"` | `\`)
TemplateWS :: U+0020 | U+0009 | U+000A | U+000D         ; space, tab, LF, CR
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
all dynamic holes in the closed `HoleExpr` vocabulary above.

**10.4.2 The inert `%Template{}` struct (semantic model).**

```
%Workflow.Template{
  segments :: [String.t()],   ; alternating literal text runs; length(holes) + 1
  holes    :: [TemplateHole.t()],
  assigns  :: [String.t()]    ; referenced assign names, in source order, duplicates retained
}
```

- Every `segments` entry is a **binary** (a slice of `raw`), never a charlist. For `n` holes,
  `segments` contains `n + 1` entries: the literal text before the first hole, the text between
  holes, and the final tail. Empty text runs are retained. `holes` stores parsed inert
  formatter records in the same order as the holes. `assigns` stores the scanned assign names
  as strings in source order and is used for name-resolution; a formatted hole still
  contributes its underlying assign name.
- An `@name` inside a template is **template syntax, not Elixir** — a scanned run of characters,
  never a variable or module-attribute AST node. The struct holds **zero closures** and is
  stored directly in the inert tree (Principle 7).
- **Addressing.** A `%Template{}` has **no address** — inert data embedded in a consuming node's
  field, exactly like `%Workflow.Node.BudgetSlices{}` (§4.2). It is rendered *within* the
  execution of the node that holds it (an `agent`, §10.6, or `emit`, §10.7), under that node's key.

**10.4.3 Load-time lowering (a hand-rolled binary scanner).** `Workflow.Template.parse/2` is a plain
compiler function — a direct binary scanner over `raw` — called by `compile/3` the moment it
matches a `{:sigil_P, meta, [{:<<>>, _, [raw]}, mods]}` node in an admissible prompt position; it
does not assign semantics to `mods`; current modifiers are accepted as a no-op and MUST NOT affect
the lowered template. It calls **no** `EEx.tokenize`, **no** `EEx.Engine`, and **never**
`Code.string_to_quoted` on a hole body.

```
Template.parse(raw, env):              ; a plain function CALLED FROM compile/3 — no macro expansion
  - If raw contains the two-byte sequence `#{`: Return {:error, Finding at the sigil} (Rule T.9).
  - Return Scan(raw, empty List, empty List, empty List, env).

Scan(source, segments, holes, assigns, env):
  - If source contains no `<%`:
    - Return {:ok, %Template{segments: reverse([source | segments]),
                             holes: reverse(holes),
                             assigns: reverse(assigns)}}.
  - Let literal be the bytes before the first `<%`.
  - Let rest be the bytes after that opener.
  - Return ScanTag(literal, rest, segments, holes, assigns, env).

ScanTag(literal, rest, segments, holes, assigns, env):    ; rest is the suffix after `<%`
  - If rest begins with `=`:
    - If the suffix after `=` contains no `%>`: Return {:error, Finding: missing `%>`} (Rule T.6).
    - Let body be the bytes strictly between `=` and the first `%>`.
    - Let trimmed be body with leading/trailing TemplateWS removed.
    - Let {hole} be ParseHoleExpr(trimmed).
    - If {hole} is {:ok, hole}:
      - Let remaining be the bytes after the first `%>`.
      - Return Scan(remaining, [literal | segments], [hole | holes], [hole.assign | assigns], env).
    - Otherwise: Return {:error, Finding: only closed template holes are allowed} (Rules T.1, T.3, T.10).
  - Otherwise:
    - Return {:error, Finding: only closed template holes are allowed} (Rules T.2, T.7, T.8).

ParseHoleExpr(trimmed):
  - If trimmed matches AssignExpr: Return {:ok, %{op: :identity, assign: name, args: []}}.
  - If trimmed matches one of the five FormatExpr productions exactly:
    - Validate any JsonPointerString with ParseJsonPointer.
    - Validate any IntegerLiteral as a non-negative integer for truncate.
    - Return {:ok, %{op, assign: name, args}}.
  - Return :error.
```

Every branch recurses on a strictly shorter suffix, returns, or raises — there is no
fall-through. "No embedded Elixir" is a **structural** guarantee of the recognizer, not a
validation applied after admitting a superset. The formatter names are not function calls;
they are byte-recognized grammar terminals with fixed semantics. Assign names are stored as
strings; binding resolution compares them to `Atom.to_string(binding_name)`, so no template
assign atom is created.

**10.4.4 Validation rules (each with the smallest counter-example).** Template-*shape* rules are
enforced by the scanner as `parse/2` lowers the node; forbidden **expression** forms take the
forbidden-form `raise` path, a rejected **tag shape** with no embedded expression yields a
`Finding`, both anchored at the sigil's `meta`. Name-resolution rules are checked by the
**consuming** combinator's `parse/2` walk under the threaded `BindingEnv`.

- **Rule T.1 — a hole is a bare assign or a closed formatter.**
  `~P"Improve <%= @draft + 1 %>"` (arithmetic) and
  `~P"Improve <%= String.upcase(@draft) %>"` (a host call) are rejected. The only admitted
  formatter names are `path`, `flatten`, `count`, `numbered_findings`, and `truncate`.
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
- **Rule T.10 — JSON Pointer literals are checked.** `~P"<%= path(@r, \"open\") %>"` is
  rejected because the pointer does not start with `"/"` or equal `""`; `~P"<%= path(@r,
  \"/a~2b\") %>"` is rejected because `~2` is not an RFC 6901 escape.

**10.4.5 Render.** Rendering reuses §4.4's `RenderText` unchanged.

```
RenderTemplate(template, run_id, bindings, lane):
  - Let parts be TemplateParts(template, bindings, lane).
  - Return RenderText.of(run_id, parts).

TemplateParts(template, bindings, lane):
  - Let parts be the List [{:text, first(template.segments)}].
  - For each pair {hole, text} from zip(template.holes, tail(template.segments)), in order:
    - Let ref be the binding whose atom key string equals hole.assign.
    - Let value_part be ResolvePart(ref, lane).
    - Append ApplyFormatter(hole, value_part, run_id, lane) to parts.
    - Append {:text, text} to parts.
  - Return parts.

ResolvePart(ref, lane):
  - If ref is {:node, address}: Return {:bound_value, ref}.
  - If ref is {:fanout, address, scope}: Return {:bound_list, ref}.
  - If ref is {:map, address}: Return {:bound_list, ref}.      ; deferred map/gather support
  - If ref is {:refine, address}: Return {:bound_refine, ref}.
  - If ref is {:element, over}: Resolve per the deferred map lane rules in §10.11.

ApplyFormatter(hole, value_part, run_id, lane):
  - If hole.op is :identity:
    - If value_part is {:bound_refine, ref}: Return {:bound_refine_artifact, ref}.
    - Return value_part.                                        ; preserves existing RenderText behavior
  - Let value be MaterializeFormatterPart(value_part, run_id, lane).
  - If hole.op is :path: Return JsonPointer.Get(value, hole.args.pointer).
  - If hole.op is :flatten: Return Flatten(JsonPointer.Get(value, hole.args.pointer or "")).
  - If hole.op is :count: Return Count(JsonPointer.Get(value, hole.args.pointer or "")).
  - If hole.op is :numbered_findings:
    - Return NumberedFindings(JsonPointer.Get(value, hole.args.pointer or "")).
  - If hole.op is :truncate: Return Truncate(RenderText(value), hole.args.max_bytes).

MaterializeFormatterPart(value_part, run_id, lane):
  - If value_part is {:bound_value, ref}: Return ResolveRef(ref, run_id, lane).
  - If value_part is {:bound_list, ref}: Return ResolveRef(ref, run_id, lane).
  - If value_part is {:bound_refine, {:refine, address}}: Return BoundRefineResult(run_id, address).
  - If value_part is {:bound_refine_artifact, ref}: Return ResolveRef(ref, run_id, lane).
  - Otherwise Return value_part.

JsonPointer.Get(value, ""): Return value.
JsonPointer.Get(value, pointer):
  - Split pointer on "/" after the leading slash; unescape "~1" to "/" and "~0" to "~".
  - For each token:
    - If current value is a map and has string key token: step to that value.
    - Else if current value is a map and has an existing atom key whose `Atom.to_string(key) == token`:
      step to that value. Implementations MUST NOT create atoms from pointer tokens.
    - Else if current value is a list and token is a base-10 non-negative integer less than length(list):
      step to that zero-based element.
    - Else Return nil.
  - Return current value.

Flatten(value):
  - If value is a list: recursively flatten list elements left-to-right.
  - Otherwise Return [value].

Count(value):
  - If value is nil: Return 0.
  - If value is a list or map: Return length(value) or map_size(value).
  - Otherwise Return 1.

NumberedFindings(value):
  - Let list be Flatten(value).
  - For each item with 1-based index i:
    - If item is a map, read string keys "id", "issue", and "fix" (falling back to atom keys).
      Missing keys render as "".
      Emit "#{i}. [#{id}] #{issue}\n   Fix: #{fix}".
    - Otherwise emit "#{i}. " <> RenderText(item).
  - Join emitted lines with "\n".

Truncate(binary, max_bytes):
  - Return the longest prefix of binary whose byte_size is <= max_bytes and which ends on a
    valid UTF-8 boundary. No ellipsis is added.

RenderText(term):                       ; §4.4 VERBATIM (the shipped Workflow.Compiler.to_text/1)
  - If term is a binary: Return term unchanged.
  - Otherwise: Return inspect(term).
```

> **Note — the one place determinism is weaker.** `Kernel.inspect/1` has no canonical map-key
> order across Elixir versions, so a runtime string-keyed provider map is byte-stable only for a
> fixed host `inspect/1`. Authors needing cross-host byte stability MUST bind **binary** values
> (or pre-render via `map`). Binary bindings render byte-identically everywhere.

> **Note — structured bindings default to Elixir `inspect/1`; use formatters for stable
> projections.** A bare `<%= @bugs %>` still renders a decoded JSON term through
> `inspect/1`. Authors who need a stable slice of structured data SHOULD use
> `path(@bugs, "/items")`, `count(@bugs, "/items")`, `numbered_findings(@review,
> "/openFindings")`, or `truncate(@draft, 4000)` rather than depending on whole-value
> `inspect/1`.

**10.4.6 Conformance (template layer).**

- **DF-T1.** A `~P` template MUST be lowered by `compile/3` (via `Workflow.Template.parse/2`) while loading
  to an inert `%Template{}` whose `segments` entries are all binaries; it MUST NOT compile to a
  closure or quoted expression, and the scanner MUST NOT call `EEx.tokenize`, `EEx.Engine`, or
  `Code.string_to_quoted` on a hole body. The implemented core rejects raw `#{` (Rule T.9) and
  treats sigil modifiers as no-op surface metadata.
- **DF-T2.** The scanner MUST admit only closed `HoleExpr` holes and literal text and MUST accept
  and reject **exactly** the §10.4.1 language — every other `<%…` opener and every raw `#{`
  opener is a caller-located validation error at the sigil's `meta`.
- **DF-T3.** `RenderTemplate` MUST render assign values through §4.4's `RenderText` unchanged, so a
  template and the corresponding `verify`/`judge` splice render an identical binary identically.
- **DF-T4.** `template.assigns` MUST list referenced assign names in source order as strings,
  usable for name-resolution and binding resolution without re-scanning `segments`.

### 10.5 `let` — name a journaled output — Verdict: ADOPT

`let` binds a static **name to an address**; the value is always fetched by folding the
journal (`BoundValue`). It creates no new value, no new paid effect, no new event, and no key.
For `agent` and `synthesize` producers, the producer's own `agent_committed` is the binding's
sole record. For `refine` producers, `refine_completed` is the sole binding record.

**10.5.1 Surface (syntactic) grammar.**

```
LetStmt : `let` BindingRefAtom `=` Producer
BindingRefAtom :: `:` AtomName   ; LEXICAL — one atom-literal token `:name`, no whitespace
AtomName :: (`a`–`z` | `_`) (Letter | Digit | `_`)*   ; implemented binding-name recognizer; NO trailing ?/!
Producer :
  - AgentStmt                 ; binds the agent's journaled result ({:node, addr})
  - SynthesizeStmt            ; synthesize's output is an ordinary agent output
  - RefineStmt                ; binds refine_completed artifact ({:refine, addr})
  - GatherStmt                ; DEFER, §10.9 (when adopted) — binds one agent_committed
  - `(` MapStmt `)`           ; DEFER, §10.9 — binds the ORDERED LIST of the map's lane results ({:map, addr})
```

The implemented core accepts `AgentStmt`, `SynthesizeStmt`, and `RefineStmt`. `GatherStmt` and
`MapStmt` are listed here to keep the future extension closed and explicit, but both remain
**DEFER** and MUST be rejected by the current compiler. `AgentStmt`/`SynthesizeStmt`/`RefineStmt`/
future `GatherStmt` are paren-call forms that need no extra parentheses. Future `MapStmt` is the
**only** block-bearing producer and MUST be parenthesized — `let :xs = (map … do … end)` —
because without parens the `do…end` attaches to `let` (the outermost paren-less call), leaving
`map` bodyless.
`compile/3` matches the uniform one-arg shape
`{:let, meta, [{:=, _, [name_ast, producer_ast]}]}`, requires `name_ast` to be an atom literal,
and dispatches `producer_ast` back through the ordinary per-form entry under the in-scope
`binding_env`, so every producer kind lowers unchanged. It MUST reject the two-arg
`{:let, _, [_, [do: _]]}` shape (an un-parenthesized `map`) with a caller-located hint (Rule L.5),
never repair it by reattaching the block.

**10.5.2 Inert representation + addressing + idempotency.**

The implemented core has **no `%Workflow.Node.Let{}` struct**. `let` is static binding
syntax: the producer node is inserted into the top-level node list at address `[i]`, exactly where
an unbound producer would have appeared, and `BindingEnv` records `name → {:node, [i]}`. `let`
therefore introduces **no key** of its own; the producer keys exactly as any agent/synthesize
turn. The bound value is **not** part of any key (keys stay value-free, Principle 2). A `refine`
binding records `name → {:refine, [i]}` and resolves through the `refine_completed` event; future
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
  - Return r.                                                   ; the binding is static; nothing extra committed
```

`RunLet` is conceptual only in the implemented core: execution runs the producer's ordinary path.
Determinism, at-most-once effect handling, and replay-safety are inherited verbatim. For an `agent`/`synthesize`
producer the producer commits one `agent_committed` at `[i]`, keyed and resumable exactly as any
agent; on resume the binding is re-derived by `ResolveRef` (`{:node} → BoundValue` folding that
same event). For `refine`, the producer commits its own refine events and the binding is
re-derived by `ResolveRef` (`{:refine} → BoundRefineArtifact` folding `refine_completed`). For
a future `gather`, the same one-`agent_committed` rule would apply. For a future `map` producer
the producer commits its own `map_started`/`map_completed` (§10.9.2) and its lanes' per-lane
`agent_committed`s; the binding is re-derived by `ResolveRef` (`{:map} → BoundList`, DF-M4) —
`let` itself still commits nothing. `let` adds no effect and no non-determinism, and runs exactly
one node (it does not iterate).

**10.5.5 Journal events. None new** — the producer's journaled output is the binding's sole
record: `agent_committed` for `agent`/`synthesize`, and `refine_completed` for `RefineStmt`.
A `let_bound{…}` marker would be pure redundancy; omitted per
Principle 3.

**10.5.6 Conformance.**

- **DF-L1.** A `let` MUST bind a literal-atom name to a single producer node and MUST introduce
  **no** journal event or key of its own. In the implemented core, `agent`, `synthesize`, and
  `refine` are bindable producers; the binding is the producer's own `agent_committed` or
  `refine_completed` event. Future `gather`
  would follow the one-`agent_committed` rule; future `map` would bind the ordered lane list
  resolved via `BoundList` per DF-M4, and the `map`'s `map_started`/`map_completed` would be the
  **producer's** events, not `let`'s. `let` is the sole value-binding construct admitted by the
  narrowed non-goals in §1.2.
- **DF-L2.** A bound value MUST be resolvable **only** by a pure fold over the journal via
  `ResolveRef` (`{:node} → BoundValue`, `{:refine} → BoundRefineArtifact`,
  `{:fanout} → BoundFanoutList`, `{:map} → BoundList`); an implementation MUST NOT cache
  the value in process state.
- **DF-L3.** `let` binding names are top-level only in Tier 1; a `let`-bound reference MUST
  resolve at `iteration = 0`. If a `let` name is rebound, subsequent consumers MUST resolve
  to the latest lexically-preceding binding, while earlier consumers keep the address
  captured when they were parsed. Loop-local `fanout bind:` names are not `let` bindings;
  they follow the scoped `{:fanout, address, {:loop_local, loop_address}}` rule in §10.11
  and resolve with the current loop iteration.
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
`synthesize` stays literal-only) — panels stay literal-only (Principles 2 and 6); (2) nested
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
returning a static literal (`return`).

**10.7.1 Surface grammar.** `EmitStmt : `emit` `(` TemplateLiteral `)`` — **template-only**,
where `TemplateLiteral` is the §10.6.1 syntactic symbol for a `~P` sigil token (its raw
content is the §10.4.1 lexical `Template` language).

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
- **Rule E.2 — final terminal from `return`, `emit`, or `emit_result`.** §5.10.2 is widened:
  a workflow MUST end with a final top-level `return`, `emit`, or `emit_result`; each sets the
  terminal value. A workflow with a `let` but no final terminal is rejected (no terminal value),
  and any top-level node after a terminal is rejected.
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
- **DF-E2.** A workflow MUST end with a final top-level `return`, `emit`, or `emit_result`;
  that final terminal node supplies the terminal value.
- **DF-E3.** `emit` MUST commit no paid effect and MUST NOT allow later top-level nodes; the
  compiler enforces terminal-final placement.
- **DF-E4.** `emit`'s argument MUST be a `~P` `Template`; `parse/2` MUST match `{:emit, meta,
  [{:sigil_P, _, _}]}` and actively reject any non-template argument with a caller-located `Finding`
  — never stringify it via `to_text/1`.

### 10.7a `emit_result` — emit structured terminal data — Verdict: ADOPT

`emit` is text rendering. `emit_result` is the distinct structured terminal surface: it
places a result-capable binding's deterministic projection directly into `run_completed.value`
without converting it through `RenderText`, `inspect/1`, or a template.

**10.7a.1 Surface grammar.**

```
EmitResultStmt : `emit_result` `(` BindingRefAtom `)`
```

The argument is exactly one literal binding atom. The current result-capable producer set is
`refine` only; `agent`, `synthesize`, deferred `gather`, and deferred `map` are not
result-capable unless a future section defines a result projection for them.

**10.7a.2 Execution algorithm.**

```
RunEmitResult(node, run_id, ctx):
  - Let ref be node.binding_ref.                         ; resolved while loading
  - If ref is {:refine, address}:
    - Let value be BoundRefineResult(run_id, address).   ; §9.11
    - Return {:cont, ctx with return = value}.
```

`emit_result` commits no event of its own. The structured value is journaled only as
`run_completed.value`, exactly like `return` and `emit`. It is deterministic because
`BoundRefineResult` is a pure fold over already-journaled refine events. The value MUST be
the public JSON-encodable `RefineResultJSON` shape (§9.11); implementations MUST NOT store
the internal atom-keyed projection in `run_completed.value`.

**10.7a.3 Validation and conformance.**

- **DF-ER1.** `emit_result` MUST be top-level and final, sharing Rule 5.10.2a.
- **DF-ER2.** `emit_result` MUST NOT accept a `~P` template or literal value. Text belongs to
  `emit`; literals belong to `return`; structured result projections belong to
  `emit_result`.
- **DF-ER3.** The emitted value MUST be the result projection, not the artifact-only binding
  used by template rendering. For `refine`, this is `BoundRefineResult`, including
  `artifact`, `converged`, `rounds`, `openFindings`, `finalOpenDefects`,
  `roleFailures`, `failedReviewers`, `coldRead`, `reportSnippets`, and `rawRefs`.

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

- **Grammar.** `GatherStmt : `gather` `(` TemplateLiteral `)`` — template-only. A literal
  `gather("...")` is rejected because it would be indistinguishable from `synthesize` with no
  journaled inputs and would contradict `gather`'s purpose as a fold over bound values.
- **Struct + addressing.** `gather` is dispatched as a **schemaless agent turn** — an ephemeral
  `%Agent{schema: nil, retries: 0}` built at **runtime** over its rendered template — analogous to
  how the implemented `synthesize` is dispatched: while loading `synthesize` keeps its own
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
    unexpressible; `max:` is a structural termination cap resolved while loading, never a binding
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
      BuildMapAgent(lane_agent, run_id, provider, prior, lane) end). ; deferred map helper threads lane into §10.6.4 EffectivePrompt
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
flow**, and the thesis is *data flow, not control flow* (§10.1). It violates Principles 2, 3,
and 6 and §6.10 ("no conditional or branching combinator"): it chooses **which subtree runs** on a runtime value.
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
  (C2; Principles 2 and 6).

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

**Binding resolution (shared by every idiom).** `BindingRef` is `{:node, address}` |
`{:refine, address}` | `{:fanout, address, fanout_scope}` | `{:map, address}` |
`{:element, over_ref}`, where `fanout_scope` is `:global` or `{:loop_local, loop_address}`.
`BindingEnv` is a load-time ordered map `name(atom) → BindingRef` threaded through parsing so
only lexically-preceding bindings are in scope (Rule T.5); there is **no** runtime name→value map.
The implemented core emits `{:node, address}` refs for `agent`/`synthesize` producers and
`{:refine, address}` refs for `refine` producers. Top-level `fanout bind: :name` emits
`{:fanout, address, :global}`; a loop-body `fanout bind: :name` emits
`{:fanout, address, {:loop_local, loop_address}}`. `{:map, address}` is support for the
deferred `map` producer's ordered result list, and `{:element, over_ref}` belongs only to the
deferred `map` lane scope. At runtime a reference is resolved by the pure journal fold
`ResolveAssign → ResolveRef`, defined for these `BindingRef` shapes:

```
ResolveAssign(name, bindings, run_id, lane):   ; bindings :: %{atom() => BindingRef} (the node's field)
  - Let ref be bindings[name].                 ; name resolved while loading (Rules T.4/T.5); always present
  - Return ResolveRef(ref, run_id, lane).

ResolveRef(ref, run_id, lane):
  - If ref is {:node, address}: Return BoundValue(run_id, address).
  - If ref is {:refine, address}: Return BoundRefineArtifact(run_id, address).
  - If ref is {:fanout, address, :global}: Return BoundFanoutList(run_id, address, nil).
  - If ref is {:fanout, address, {:loop_local, loop_address}}:
    - Assert lane.loop_address == loop_address and lane.iteration is an integer.
    - Return BoundFanoutList(run_id, address, lane.iteration).
  - If ref is {:map, address}:  Return BoundList(run_id, address).
  - If ref is {:element, over}:                ; a map lane's element; lane is %{index: e}, e a 0-based lane index
    - Let list be ResolveRef(over, run_id, lane).   ; over is {:node, _} (list-valued) or {:map, _}
    - Return Enum.at(list, lane.index).             ; ZERO-BASED: lane.index ∈ 0..(width-1), matching lane address [i,0,e,0]

BoundValue(run_id, address):                   ; the single-agent producer fold (agent/synthesize/gather)
  - Fold the journal for the agent_committed at address with iteration == 0.
  - Return that event's payload.result.        ; exactly one such event exists once the producer has committed

BoundRefineArtifact(run_id, address):          ; refine producer fold
  - Fold the journal for the refine_completed at address.
  - Return that event's payload.artifact.

BoundRefineResult(run_id, address):            ; structured refine result fold
  - Fold the journal for the refine_completed at address.
  - Fold all refine_round_decision, refine_role_failed, and refine_gate_evaluated events
    whose payload.address == address, plus gate-role agent_activity, agent_committed,
    agent_attempt_rejected, and agent_failed events whose payload.address is
    address ++ [3] or address ++ [4].
  - Return the §9.11 `RefineResultJSON` public projection.

BoundFanoutList(run_id, address, iteration):   ; a generic fanout's ordered lane-result list
  - Let event_iteration be iteration when not nil, otherwise 0.
  - Let width be the width of the fanout_started at address whose payload.iteration is
    iteration or absent when iteration is nil (payload.width).
  - If width == 0: Return [].
  - For each lane index e in 0..(width - 1), in ascending order:
    - Let lane_address be address ++ [e].
    - Let committed be the agent_committed events whose payload.address is prefixed by
      lane_address and whose payload.iteration == event_iteration, in address order within
      the lane.
    - If committed is empty: raise a malformed journal error.
    - Append the result of the last committed event in that lane.
  - Return the appended list.

BoundList(run_id, address):                    ; a map's ordered lane-result list
  - Let width be the width of the map_started at address (payload.width).
  - Return the List [ BoundValue(run_id, address ++ [e, 0]) for e in 0..(width - 1) ], in ascending e order.
```

`BoundValue`, `BoundRefineArtifact`, `BoundFanoutList`, and `BoundList` are pure folds over
already-committed events; `{:element, over}` never folds directly but indexes the resolved list
zero-based, so a `map`-lane agent template resolving `@element_name` (env `{:element, over}`,
§10.9.2; `lane = %{index: e}`, §10.6.4) yields the `e`-th element of `over`'s resolved
collection. Top-level bindings resolve at `iteration = 0`. Every per-form compile step (the
recursive compiler entry delegates to each form, §5) threads an additional in-scope
`binding_env` — a trailing-argument extension, not an overload: the in-scope `binding_env` at top
level, the **empty** env `%{}` at the four nested positions (where templates are actively
rejected), and the element-extended env at the `map` lane.

**Journal events.** The dataflow **core** (Template + `let` + injection + `emit` +
`emit_result`) adds **zero** new event types: `let` rides the producer's existing
`agent_committed`/`refine_completed`; injection rides `agent_committed.prompt` /
`agent_attempt_rejected.prompt`; `emit` and `emit_result` ride `run_completed.value`.
Deferred `gather` would also ride one ordinary `agent_committed`. Only the **deferred** `map`
adds two events (`map_started`, `map_completed`, §10.9.2). This preserves §7.1's "journal is
the single source of truth": every bound value is a fold over an event the producer already
commits.

**Result shape & exit codes.** Unchanged from §7 except for `emit_result`, which places a
structured result projection in `run_completed.value`. A template that fails name resolution
(Rules T.4/T.5) or violates a template-shape rule (Rules T.1–T.3, T.6–T.10) is a
**load-time** error located at the offending declaration (exit 6, validation — §7.5),
never a runtime failure. A schema-bound injected `agent` still fails closed on malformed
structured output (retry-then-fail, exit 8) exactly as §6.4.2; the rendered prompt changes
what the agent is asked, not the error model.

**Error model (pinned).** §10 introduces **no new** runtime error channel for the implemented
core. `let` and an injected `agent` inherit §6.1's abort/propagate model verbatim (a producer
failure aborts the run; its consumer never runs, so a bound value is unreachable only when the run
has already halted). Deferred `gather` would inherit the same model. The one new **runtime** failure
deferred `map` can raise — `MapOverNotAList` when `over:` resolves to a non-list (§10.9.2) — is a
crash of the live writer (exit 1), never a silent coercion, consistent with Principle 4 (fail
closed).

### 10.12 Conformance rollup

An implementation of the shipped dataflow core and refine library binding surface MUST satisfy DF-T1..DF-T4 (template),
DF-L1..DF-L4 (`let` over `agent`/`synthesize`/`refine`), DF-P1..DF-P3 (top-level injection),
DF-E1..DF-E4 (`emit`), DF-ER1..DF-ER3 (`emit_result`), and DF-C1
(pipeline-by-composition). It MUST keep `gather` and `map` out of the accepted surface until
those DEFER sections are promoted, and it MUST reject the two excluded idioms per DF-X1
(`select`/`when`) and DF-X2 (`reduce`). A future promotion of the deferred idioms MUST
additionally satisfy DF-G1..DF-G2 (`gather`) and DF-M1..DF-M5 (`map`).

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
workflow "my-flow" do
  phase("scope")
  log("starting")
  agent("Do one unit of scoped work. Return prose.")
  return(:ok)
end
```

Requirements you MUST meet:

1. Put exactly one bare, top-level `workflow "literal-name" do … end` block in the file;
   do not define a module or use/import a macro.
2. Every base prompt, name, and value is a **static literal string/atom** — never a
   variable, never `"… #{interpolation} …"`, never a function call. For dataflow, use only
   `let` over a previous `agent`/`synthesize` and render with `~P` holes like `<%= @draft %>`.
3. The block terminates with a final `return(<literal>)`, `emit(~P"...")`, or
   `emit_result(:refine_binding)`.
4. Inside a generic `loop` body use only `agent`, `log`, `phase`, `until`, `fanout`, and
   `collect`; legacy `while_budget`/`until_dry` bodies use only `agent`, `log`, `phase`,
   and `collect`.
5. Call `workflow_validate` on the script path; every mistake is a typed, located
   validation error before execution.

Note (terminal placement): `return`, `emit`, and `emit_result` set the terminal value and
must be the final top-level statement. There is no early-exit or "return early on a
condition" construct in this vocabulary; a `return(:early)` followed by more top-level work
is rejected by the compiler. Put the terminal you want as the result **last**.

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
| `emit_result(:name)` | final top-level only | structured terminal result from a result-capable binding (`refine`) |
| `return(:atom)` | literal | terminal value |
| `parallel([agent(…), …])` | list of agents | barrier fan-out |
| `pipeline([items…], [agent(…), …])` | items × stages | per-item lanes, no barrier — **the item is a journal label only; it is NOT injected into stage prompts** (§3.4, §11.4 Use-case G) |
| `verify("subject", voters: N \| lenses: [..], threshold: …)` | literal subject | verification panel |
| `judge([cands…], by: [:c], pick: :max_score \| :min_score)` | literal candidates | scoring panel |
| `synthesize([inputs…], "prompt")` | literals | fold inputs into one turn |
| `loop max_iterations: N, until: P, on_exhausted: :stop do … end` | body | bounded core loop |
| `while_budget reserve: N do … end` | sugar | loop while budget remains |
| `until_dry rounds: N, seen_by: [..] do … collect(into: :acc) end` | sugar; body must collect | loop until dry |
| `collect(into: :acc)` | body-only | fold iteration result into accumulator |
| `fanout width: N, bind: :xs do lanes([...]) end` | lane list or repeated lane | bounded core fan-out, optionally bound as an ordered list |
| `fan_out width: budget_slices(per: N) do agent(…) end` | sugar | budget-scaled fan-out (**requires a run budget** — crashes without one; see §11.4 Use-case F) |

Not combinators: `budget_slices(per: N)` (only a `fan_out` width); the `until:` predicate
forms `count(:acc)`, `budget_remaining()`, `all([..])`, `any([..])`, legacy
`all_of([..])`/`any_of([..])`, `dry(...)`, `agree(...)`, and `path_*`.

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
| `return`/`emit`/`emit_result` missing | workflow must terminate with a final terminal | Add final `return(:ok)` (or any literal), final `emit(~P"…")`, or `emit_result(:review_loop)` for a result-capable binding. |
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

Caution (`judge`'s winner does **not** flow into `synthesize`, Principles 2 and 6): `judge`
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

Each `agent` prompt in production is a static heredoc string with structured XML-style
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
AtomName :: (`a`–`z` | `_`) (Letter | Digit | `_`)*
BooleanLiteral :: `true` | `false`
NilLiteral :: `nil`
```

Syntactic (`:`) — the workflow surface:

```
WorkflowDefinition : `workflow` StringLiteral `do` WorkflowBody `end`
WorkflowBody : Statement*
Statement : PhaseStmt | LogStmt | AgentStmt | LetStmt | EmitStmt | EmitResultStmt
          | ReturnStmt | LoopStmt | FanoutStmt | LibrarySugarStmt
LibrarySugarStmt : ParallelStmt | PipelineStmt | VerifyStmt | JudgeStmt | SynthesizeStmt
                 | WhileBudgetStmt | UntilDryStmt | FanOutStmt | RefineStmt
LoopStmt : `loop` KeywordList `do` LoopBody `end`
FanoutStmt : `fanout` KeywordList `do` FanoutBody `end`
FanoutBody : AgentLane | LaneList
AgentLane : AgentStmt+
LaneList : `lanes` `(` `[` Lane (`,` Lane)* `]` `)`
Lane : `[` AgentStmt (`,` AgentStmt)* `]`
LoopBody : BodyStatement+
BodyStatement : AgentStmt | LogStmt | PhaseStmt | UntilStmt | FanoutStmt | CollectStmt
UntilStmt : `until` `(` Predicate `)`
Predicate : Comparison | DryPredicate | AgreePredicate | PathPredicate
          | `all` `(` `[` Predicate (`,` Predicate)* `]` `)`
          | `any` `(` `[` Predicate (`,` Predicate)* `]` `)`
          | `all_of` `(` `[` Predicate (`,` Predicate)* `]` `)`
          | `any_of` `(` `[` Predicate (`,` Predicate)* `]` `)`
Comparison : Operand CompareOp IntegerLiteral
Operand : `count` `(` Atom `)` | `budget_remaining` `(` `)`
        | `path_count` `(` BindingRefAtom `,` JsonPointerString `)`
DryPredicate : `dry` `(` `[` `rounds:` IntegerLiteral (`,` `seen_by:` AtomList)? `]` `)`
AgreePredicate : `agree` `(` BindingRefAtom `,` `[` `path:` JsonPointerString `,`
                 `equals:` Literal `,` `threshold:` AgreementThreshold `]` `)`
PathPredicate : `path_exists` `(` BindingRefAtom `,` JsonPointerString `)`
              | `path_non_empty` `(` BindingRefAtom `,` JsonPointerString `)`
              | `path_equals` `(` BindingRefAtom `,` JsonPointerString `,` Literal `)`
AgreementThreshold : `:all` | `:any` | IntegerLiteral
AtomList : `[` Atom (`,` Atom)* `]`
BindingRefAtom :: `:` AtomName
```

(Per-combinator argument and option productions are in §3; validation predicates in §5.)
