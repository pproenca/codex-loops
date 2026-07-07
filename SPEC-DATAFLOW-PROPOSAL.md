# Codex Loops Workflow DSL — Tier-1 Dataflow Extension (PROPOSAL)

- **Status**: Proposed / design-stage
- **Version**: 0.6.0 (proposal; revised after sixth adversarial panel — see §F.25–§F.27)
- **Created**: 2026-07-06
- **Editors**: Codex Loops maintainers
- **Extends**: `SPEC.md` (the implemented language, §1–§8) and its proposed `refine` combinator (§9)

> **Status of this document.** Everything here is **non-normative with respect to the
> implemented language** (`SPEC.md` §1–§8). No conforming implementation of `SPEC.md` §1–§8
> parses or executes any construct in this proposal. This is a design for a *dataflow
> extension* written to the same completeness bar as `SPEC.md`: a developer with zero access
> to the maintainers could implement each ADOPT-recommended idiom from this document alone,
> and two independent teams could not diverge. Section references of the form `SPEC §N`
> point at the authoritative `SPEC.md`; bare `§N` references point within this proposal.
>
> Notation is identical to `SPEC.md` (Appendix A): a `::` production is **lexical**, a `:`
> production is **syntactic**; `Symbol?`/`Symbol+`/`Symbol*`; `A but not B`; algorithms are
> named functions with ordered steps (`Let`, `If … :`, `Return`, `Raise`). RFC 2119 keywords
> are normative only in uppercase (`SPEC §8`).

---

## Verdict summary — per-idiom decisions

*This is the decision surface that informs the published PRD ([`pproenca/codex-loops` #13](https://github.com/pproenca/codex-loops/issues/13), `ready-for-agent`). Full rationale, the build order, and the mechanical closure argument are in **§E**; each idiom's section heading below carries the same verdict inline.*

| Idiom | Verdict | Ships in | One-line reason |
|---|---|---|---|
| **Template layer** (§B) | **ADOPT** — foundation | Core slice | Nothing flows without it; inert struct + compile-time **binary scanner** + the render `SPEC §4.4` already defines. Closure-free by construction (§D.1). |
| **`let`** (§C.1) | **ADOPT** | Core slice | The keystone; every value edge composes from it. No new effect/event/key — a bound value is a fold over the producer's existing `agent_committed`. |
| **prompt injection** (§C.2) | **ADOPT** | Core slice | The edge authors want ("improve this draft"); the rendered prompt rides the existing `agent_committed.prompt`. |
| **`emit`** (§C.7) | **ADOPT** | Core slice | Pure render, no paid effect; makes "flow N results into one document" a first-class terminal. |
| **pipeline-with-dataflow** (§C.6) | **ADOPT** by composition | Core slice (free) | Falls out of `let` + injection + sequencing — no new combinator. (Extending the `pipeline` *combinator* is DEFERRED.) |
| **`gather`** (§C.5) | **DEFER** | After core, on recurrence | `synthesize` over journaled inputs; ship when folding several bound outputs recurs. Light to add. |
| **`map`** (§C.4) | **DEFER** | Last, behind demonstrated need | Heaviest: runtime-decided width, per-lane re-addressing, structural `max:` cap, a new region + two new events. Single-agent lanes in Tier 1. |
| **`reduce`** (§C.8.2) | **REJECT** (Tier 1) | — | Drifts toward in-language computation; `gather` + accumulators cover real needs. |
| **`select` / `when`** (§C.8.1) | **REJECT** | — | It is **control** flow, not data flow — violates Principle 8 and the thesis (§A.2). |

**Governing rule (§A.3).** Add data flow, not control flow: flow only values the journal already holds, only through the deterministic render `SPEC §4.4` already defines — widened from literals to journaled values under an exhaustive, compile-time-checked whitelist. A *strengthening* of "no value binding" (Principle 6 → 6′), not a loosening.

**Build order (§E).** (1) `refine` (`SPEC §9`) first — standing priority · (2) **dataflow core** = Template + `let` + injection + `emit`, one coherent slice (unlocks pipeline-with-dataflow for free, adds zero new events) · (3) `gather` · (4) `map` · (5) never, absent a hard wall: `reduce`, `select`/`when`.

---

## A. Purpose & the governing rule

### A.1 The problem: outputs flow nowhere

The implemented DSL (`SPEC.md`) produces values it cannot use. An `agent`, a `verify`/`judge`
panel, and a `synthesize` all commit a decoded result to the journal
(`agent_committed.result`, `verify_settled`, `judge_settled` — `SPEC §7.2`), but **no later
node can read any of them**. `SPEC §1.3` Principle 6 (*No value binding*) forbids naming a
runtime value; `SPEC §2.2` forbids prompt interpolation; `SPEC §6.4.1` fixes the provider
port so that "prompt is **this node's literal prompt — never a splice of any other node's
output**". The one in-vocabulary value edge — `agent → collect → accumulator` (`SPEC §6.6`,
dataflow-ground §5) — carries only a **count** into a loop's early-stop predicate; the item
**content** never reaches another prompt. The worked "outputs flow nowhere" cases
(`SPEC §10.4` C/F/G) enshrine this: `judge`'s winner is never passed to `synthesize`; a
`pipeline` stage never sees its item; a `fan_out` lane is a byte-identical replica.

Authors keep hitting this wall. The pattern they *want* is: an agent drafts, a second agent
improves **that draft**, a third emits a report **from those results**. Today that requires
either (a) collapsing the whole pipeline into one mega-prompt (losing the paid-effect
granularity, retries, and journal that make the runner worth using) or (b) post-processing
the journal **outside** the workflow (losing composability).

### A.2 The thesis: add DATA FLOW, not CONTROL FLOW

This proposal adds the ability to **flow a journaled value into a later prompt or the
terminal result**. It deliberately does **not** add control flow — no general `if`, no
value-dependent choice of which subtree runs, no unbounded iteration, no arbitrary
computation. Everything below is a *dataflow* extension: it changes what data a node's prompt
is rendered from, never which nodes run or how many times (except the one bounded, capped
fan-out, `map`, which is provably terminating by a structural cap exactly like every existing
loop).

### A.3 The governing rule (the spine)

Three clauses, applied to every idiom in this document:

1. **Flow only journaled values, and only through deterministic renders.** A value may flow
   from node *P* into node *Q*'s prompt (or the terminal result) **iff** *P*'s output is
   already a committed journal event **before** *Q* executes, and the flow happens through a
   **deterministic, total, closure-free render** — the `RenderText` algorithm of `SPEC §4.4`,
   widened here (§B) to accept journaled values as input. No arbitrary interpolation
   (`"… #{expr} …"`), no computed value, no closure ever enters a prompt.

2. **Transform collections only with nodes or closed operators — never lambdas.** To turn a
   collection into per-element work you use a **node** (`map`, which runs an agent per
   element) or to turn a collection into one value you use a **node** (`gather`, one agent
   over the whole collection). No `Enum.map(fn … end)`, no anonymous function, ever
   (`SPEC §5.1.1` still holds; §D.1 proves the extended tree stays closure-free).

3. **Bound every fan-out and loop.** The one construct whose width is a runtime quantity
   (`map` over a bound collection) carries a **compile-time structural cap** (`max: <pos-int
   literal>`), exactly as every loop carries `max_iterations` (`SPEC §1.3` Principle 5). Width
   = `min(observed_length, max)`; the region has at most `max` lanes and provably terminates
   (§D.3).

### A.4 Reconciliation — a principled STRENGTHENING of "no value binding"

This proposal **amends** the following **nine** normative clauses of the shipped `SPEC.md` — seven in
the value-injection cluster; the one `SPEC §1.2` Non-goal ("MUST NOT be expressible") whose
"General computation" bullet bans value binding outright; and the five-part **closed-vocabulary
cluster** that fixes the top-level combinator *count*, which widens from **13** to **17** named
combinators (item 9). The enumeration is exhaustive **by the mechanical closure rule stated below**
(not by hand-inspection, which has under-counted on five successive passes — the F.16/F.18/F.26/F.28 exhaustiveness-miss class);
in particular `SPEC §1.2` → §1.2′ is item 8 and the closed-vocabulary cluster → the **17-way** vocabulary
(§A.4(8′)) is item 9, closing the omission the prior eight-item enumeration left (F.28):

1. `SPEC §1.3` Principle 6 → **Principle 6′** (§A.4(3));
2. `SPEC §8` C9 → **C9′** (§A.4(4));
3. `SPEC §6.4.1` — the provider port's `prompt` input + Turn-independence clause → **§6.4.1′** (§A.4(5));
4. `SPEC §6.4` — the agent **commit path** (which value is stored in the `prompt` payload of every prompt-bearing agent event) → **§6.4-commit′** (§A.4(6));
5. `SPEC §7.2` — the `agent_committed.prompt` payload semantics → **§7.2′** (§A.4(6));
6. `SPEC §7.3` — the `agents` read-projection's `prompt` field → **§7.3′** (§A.4(6));
7. `SPEC §7.2` — the `agent_attempt_rejected.prompt` payload semantics → **§7.2-rejected′** (§A.4(6));
8. `SPEC §1.2` — the "General computation" Non-goal bullet ("MUST NOT be expressible … There is no value-binding construct") → **§1.2′** (§A.4(7)).
9. The **closed-vocabulary cluster** — the five shipped clauses that fix the top-level combinator *count* — → the **17-way** vocabulary (§A.4(8′)): `SPEC §1.3` Principle 1 → **Principle 1′**, `SPEC §2.4` → **§2.4′**, `SPEC §8` C1 → **C1′**, `SPEC` Rule 5.1.3's vocabulary set (widened to include the four new names, so they are no longer "unknown bare calls"), and the `SPEC §10.2` "closed vocabulary at a glance" table (extended with the four new rows).

(Separately, `SPEC §5.10.2` — "a workflow MUST contain a `return`" — is widened by `emit` to "a
`return` **or** an `emit`". That is a *terminal-value* amendment, orthogonal to value injection; it
is specified and tracked at §C.7.2 / DF-E2, and is called out here only so this enumeration omits
nothing.) Each amendment is a strengthening, not a weakening, for the reasons below.

**The mechanical closure rule (how a stranger re-derives this set without trusting the list).** A
hand-maintained enumeration has proven not to converge (three → six → seven → eight → nine items over
five passes). So the set is defined **derivably**, not by inspection: *this extension amends every
shipped normative clause of `SPEC.md` that (a) states a top-level-combinator **count**, (b) restates
the **no-value-binding** ban, or (c) fixes the **prompt / commit-payload / read-projection payload
type**.* A reader re-derives the exact set by grepping `SPEC.md` for each load-bearing literal and
checking every hit is amended above:

- **(a) count:** `grep -nE "\b13\b|13-way|13 top-level|13 combinator"` → `SPEC §1.3` Principle 1, `SPEC §2.4`, `SPEC §8` C1, `SPEC §10.2` table (all → §A.4(8′)); and `grep -n "not in\s*$" ` / Rule 5.1.3's "vocabulary" (→ §A.4(8′)).
- **(b) no value binding:** `grep -niE "no value.binding|value-binding construct|no.*binding"` → `SPEC §1.3` Principle 6 (→ 6′, §A.4(3)), `SPEC §8` C9 (→ C9′, §A.4(4)), `SPEC §1.2` General-computation bullet (→ §1.2′, §A.4(7)).
- **(c) payload type:** `grep -niE "literal prompt|node\.prompt|agent_committed\.prompt|agent_attempt_rejected\.prompt|agents.*projection"` → `SPEC §6.4.1` (→ §6.4.1′, §A.4(5)), `SPEC §6.4` commit path + `SPEC §7.2`/`§7.3` (→ §6.4-commit′/§7.2′/§7.2-rejected′/§7.3′, §A.4(6)).

Any hit that is **not** in the amendment set above is a spec bug; the grep is the acceptance test for
this section's exhaustiveness, replacing the enumeration-by-inspection that under-counted five times.

**(1) The render already exists and is already normative.** `SPEC §4.4` *already* defines
`RenderText` and *already* splices data into prompts: `verify` splices `<subject>`, `judge`
splices `<candidate>`, `synthesize` splices `Inputs: <inspect(inputs)>`. The implemented
language is **not** "no data in prompts" — it is "only **compile-time-literal** data in
prompts, through `RenderText`." This proposal changes exactly **one** thing: it widens the
*source* of `RenderText`'s input from "a compile-time literal" to "a value already committed
to the journal." The **render itself is unchanged** — same algorithm, same byte-for-byte
output rules (`SPEC §4.4`). We are not inventing interpolation; we are feeding an existing,
pinned renderer from a new, equally-deterministic source.

**(2) The old rule was a blunt ban hiding an uncontrolled edge.** Principle 6 bans *all*
binding, yet the language *still* flows data (accumulators feed `count()`; panels set
`ctx.last_result`; `synthesize` splices literals). The ban is therefore both too strong
(it forbids the obviously-safe "improve this draft" edge) and not the real safety property.
The real safety property is: *a flowed value must be a deterministic function of
already-journaled data.* This proposal states **that** property directly and checks it
exhaustively, replacing a slogan with a decidable whitelist.

**(3) The amended principle is a tighter predicate, not a looser one.** Principle 6 is
replaced by:

> **Principle 6′ — Journaled-values-only, deterministic-render-only.** A name MAY be bound
> (via `let`, §C.1) only to a value that is **already committed to the journal** by a
> lexically-preceding node. A bound value MAY flow into a later node **only** through
> `RenderText` (§B) over an **inert `%Template{}`** whose only dynamic parts are
> assigns-referencing-bindings. It MUST NOT flow through interpolation, a closure, arithmetic,
> a general conditional, or any computed value. Every prompt and terminal value remains a
> **deterministic function of journaled data** (`SPEC §1.3` Principle 3). *Pre-resolves:* a
> workflow may reference an earlier result, but only one the journal already holds and only
> through a pinned render — never by capturing, computing, or branching on it.

This forbids strictly more than "arbitrary interpolation would allow" and only permits the
narrow, checked case. It **preserves** determinism (§D.2), replay-safety (§D.2, §D.4),
closure-freedom (§D.1), and bounded termination (§D.3).

**(4) `SPEC §8` C9 is strengthened, not dropped.** C9 ("no value binding") becomes:

> **C9′ (bound values are journaled and deterministically rendered).** An implementation MUST
> require that every value flowed into a prompt or terminal result is (a) a value committed to
> the journal by a lexically-preceding node, resolved by a **pure fold** over the journal, and
> (b) rendered by the deterministic, closure-free `RenderText` (§B). It MUST reject any prompt
> or value form that is not a compile-time literal **or** an inert `%Template{}` over in-scope
> bindings. Interpolation, closures, arithmetic-in-prompts, and computed values remain
> rejected (`SPEC §5.1`, `SPEC §2.2`).

Every other conformance clause is untouched **except C1, whose 13-way count becomes 17-way
(C1′, §A.4(8′))**; **C2–C8 are untouched**. `map` extends C7 with one more structural cap;
nothing weakens.

**(5) `SPEC §6.4.1` provider port — `prompt` input widened to a rendered template.**
`SPEC §6.4.1` is still fully normative and, as written, states `prompt :: String.t()` is
"this node's literal prompt — **never a splice of any other node's output**", and its
Turn-independence clause requires "all context an agent needs MUST be present in its own
**literal** prompt." A rendered injected prompt (§C.2.4) *is* a splice of another node's
output, so §6.4.1-as-shipped would force a conforming implementation to reject a template
prompt while §C.2.4 forces it to accept one. To remove that silent contradiction, §6.4.1's
`prompt` input and Turn-independence clause are replaced by:

> **§6.4.1′ — `prompt` input (widened).** `prompt :: String.t()` — EITHER this node's
> literal prompt OR the deterministic `RenderTemplate` (§B.6) of an inert `%Template{}`
> (§B.3) over already-journaled bindings; **never** an arbitrary interpolation, closure,
> computed value, or live splice. Turn independence is **PRESERVED**: the injected prompt is
> **materialized to a `String.t()` by a pure journal fold before the call** and then journaled
> verbatim in the `prompt` payload of whichever prompt-bearing agent event the call produces —
> `agent_committed.prompt` on success, `agent_attempt_rejected.prompt` on a fail-closed retry
> (§6.4-commit′) — **at commit** (with the provider `result`/`output`), never re-rendered on replay
> (DF-P3); there is **no** prompt-only pre-call journal event (§C.2.5).
> So `CallProvider` still receives only `(prompt, schema, key, opts)` — no conversation state,
> thread, or live reference to any other node. Every agent turn remains self-contained: the
> string it receives is a complete rendering of already-committed data, not a handle to another
> node's output. `CallProvider`'s signature, hard-match on `{:ok, result, usage}`, and
> idempotency-key contract are otherwise unchanged.

This is strictly narrower than "arbitrary interpolation": the only admissible non-literal
`prompt` is a pinned render over journaled data. §C.2.4 and DF-P1 cite **§6.4.1′**.

**(6) `SPEC §6.4` commit path + `SPEC §7.2`/`§7.3` projection — the stored prompt is the rendered
string, never the inert struct, on EVERY prompt-bearing agent event.** `SPEC §6.4`'s commit rule
stores `node.prompt` verbatim in the `prompt` payload of the two prompt-bearing agent events —
`agent_committed` (`address, iteration, idempotency_key, prompt, result, usage`) and
`agent_attempt_rejected` (`address, iteration, attempt, prompt, output, reason, usage`), `SPEC §7.2`
(dataflow-ground §1) — and `SPEC §7.3`'s `agents` read-projection appends
`%{address, prompt, result, usage, idempotency_key}` — **observable output** consumed by the
`SPEC §7.5` envelope and the status UI. (`agent_failed` carries `address, iteration, attempts,
reason` — **no** `prompt` key, `SPEC §7.2` — so it needs no amendment.) For a **template-prompt**
agent, `node.prompt` holds an inert `%Template{}` **struct**, not a string, so a conforming
`SPEC §6.4`/`§7.2`/`§7.3` implementation would surface that struct under `prompt` where every reader
expects a rendered prompt string. A template-prompt agent WITH a schema and `retries > 0` (admitted
by Rule C.2.3, and on the day-one ADOPT slice) commits an `agent_attempt_rejected` on each
fail-closed retry (`SPEC §6.4` CommitAttempt); under the still-normative base rule its
`agent_attempt_rejected.prompt` would be the `%Template{}` struct while its eventual
`agent_committed.prompt` is the rendered string — a struct-vs-string divergence on a **single node's
own events**, the exact defect this cluster exists to eliminate. So the amendment MUST reach **both**
events, not only `agent_committed`. To close it, `SPEC §6.4`'s commit path and
`SPEC §7.2`/`§7.3`'s projection semantics are replaced by:

> **§6.4-commit′ / §7.2′ / §7.2-rejected′ / §7.3′.** For a template-prompt agent, the commit path
> MUST store the materialized `EffectivePrompt(node, run_id, lane) :: String.t()` (§C.2.4) in the
> `prompt` payload of **EVERY prompt-bearing agent event it writes — both `agent_committed.prompt`
> (§7.2) AND `agent_attempt_rejected.prompt` (§7.2)** — **in place of** `node.prompt`. (`agent_failed`
> has no `prompt` key, so it is untouched.) Consequently `agent_committed.prompt` and
> `agent_attempt_rejected.prompt` always carry the **rendered binary**, and the `SPEC §7.3` `agents`
> projection's `prompt` field carries that rendered binary — **never** the inert `%Template{}`
> struct that `node.prompt` holds. `EffectivePrompt` is provably **stable across attempts**: the
> template's producers commit before the consumer runs (define-before-use, §B.5.5) and their
> `agent_committed`s are immutable, so every attempt — rejected or committed — renders a
> byte-identical string, and journaling the rendered prompt on a rejected attempt therefore never
> disagrees with the one journaled on the eventual commit. A literal-prompt agent is unchanged (its
> `node.prompt` is already the string). Every shipped reader of `agent_committed.prompt`,
> `agent_attempt_rejected.prompt`, and the `agents` projection therefore continues to observe a
> `String.t()`, and the type of that observable output is preserved, not altered.

This narrows nothing an author can express; it pins the value flowing into three shipped observable
surfaces (`agent_committed.prompt`, `agent_attempt_rejected.prompt`, and the `agents` projection) so
no implementation can diverge on whether they carry a string or a struct. §C.2.4, DF-P2, and DF-P3
cite **§6.4-commit′**.

**(7) `SPEC §1.2` Non-goal — the "no value-binding construct" bullet is surgically narrowed to §1.2′,
NOT dropped.** `SPEC §1.2` ("The following are deliberately **out of scope** and MUST NOT be
expressible") states, in its **General computation** bullet: *"A workflow cannot compute values at
runtime, bind variables, branch on agent output, or perform arithmetic. There is no value-binding
construct."* That single bullet bundles **four** distinct bans; this proposal reopens **exactly one**
(value binding, via `let` §C.1) and preserves the other three untouched. A blanket amendment would
wrongly reopen "branch on agent output" and "arithmetic" (which the proposal keeps unexpressible — no
`select`, §C.8.1; no arithmetic holes, Rule B.5.1), so the amendment is **surgical**: it edits **only**
the General-computation bullet, and leaves every other Non-goal (Non-determinism, Side-effects, Runtime
linting) and every other ban of this bullet intact:

> **§1.2′ — General computation (narrowed).** A workflow cannot compute values at runtime, branch on
> agent output, or perform arithmetic. The **only** value-binding construct is `let` (§C.1), which
> binds a name to an **already-journaled** output for deterministic render under Principle 6′
> (§A.4(3)); it cannot capture, compute, or branch on a runtime value. Apart from `let`, there is no
> value-binding construct, and value-dependent **control** flow (branching on agent output) remains
> unexpressible (Principle 8, §C.8.1).

This is a **strengthening, not a weakening**, exactly as §A.4(3): `SPEC §1.2` previously banned *all*
binding as a blunt proxy for "no capture / no compute / no branch"; §1.2′ states the real property
directly — bind only journaled values, render only deterministically — while keeping the arithmetic and
branch-on-output bans of the same bullet, and the Non-determinism / Side-effects / Runtime-linting
Non-goals, **fully** intact. Nothing an author could not previously express becomes expressible except
the one narrow, checked `let` edge. DF-L1 (§C.1.6) cites **§1.2′**, exactly as DF-P1 cites §6.4.1′.

**(8′) The closed-vocabulary count is widened 13 → 17 via the design's own sanctioned extension path —
a STRENGTHENING, not a weakening.** This proposal adds four new *named* top-level combinators — `let`
(§C.1.1 `LetStmt`), `map` (§C.4.1 `MapStmt`), `gather` (§C.5.1 `GatherStmt`), and `emit` (§C.7.1
`EmitStmt`) — as new alternatives of `SPEC §3`'s `Statement` nonterminal (§C "Top-level grammar
integration"). Five shipped clauses fix the combinator *count* at 13 and must therefore be amended in
lockstep, or a conforming implementation of the shipped clauses would reject `let :d = agent("draft")`
as an unknown bare call outside the 13-way vocabulary (`SPEC` Rule 5.1.3, `SPEC §8` C1) on the day-one
ADOPT slice — a two-implementers divergence on the most-shipped path:

> **Principle 1′ (closed vocabulary, 17-way).** `SPEC §1.3` Principle 1 is replaced by: "The DSL has
> exactly **17** top-level combinators (§2.4′) — the shipped 13 plus `let`, `map`, `gather`, and
> `emit`. Any form outside the vocabulary is a compile error. New capability is added by adding a
> combinator to the closed set, never by allowing arbitrary Elixir." (`collect` remains **body-only**,
> as shipped.)
>
> **§2.4′ (recognized names, 17-way).** `SPEC §2.4`'s recognized top-level-combinator name set widens
> from 13 to **17**, adding `let`, `map`, `gather`, `emit`.
>
> **C1′ (closed vocabulary, 17-way).** `SPEC §8` C1 is replaced by: "It MUST reject, at compile time,
> any form outside the **17-way** vocabulary (and the body vocabulary inside loops), per §5."
>
> **Rule 5.1.3 (vocabulary widened).** The "vocabulary" set that `SPEC` Rule 5.1.3 tests against now
> includes `let`/`map`/`gather`/`emit`, so those four are **not** "unknown bare calls" — each has its
> own `parse/2` clause (DF-L4 §C.1.6, DF-M* §C.4.6, DF-G* §C.5.6, DF-E* §C.7.6).
>
> **§10.2′ (at-a-glance table extended).** `SPEC §10.2`'s "closed vocabulary at a glance" table gains
> four rows: `let :name = <producer>`, `map :el, over: :xs, max: N do agent(…) end`,
> `gather([:xs], ~P"…")`, and `emit(~P"…")`.

This is a **strengthening via the design's own extension mechanism**, not a weakening. Principle 1
itself states the sanctioned way to extend: *"New capability is added by adding a combinator to the
closed set, never by allowing arbitrary Elixir."* Widening the closed set from 13 to 17 **named**
combinators is exactly that path — the set stays **closed** (`SPEC` Rule 5.1.3 still rejects every
name outside it), and arbitrary Elixir stays rejected (Principle 1′, `SPEC §2.2`, `SPEC §5.1`). No
combinator is loosened; four are added under the same closed-set discipline the shipped 13 obey.

---

## B. The template layer (specified first — it underpins injection and emit)  ·  Verdict: ADOPT (foundation)

Prompt injection (§C.2) and `emit` (§C.7) both render bound values into text. The renderer is
a **logic-less, inert template**. This layer reuses **only the *ideas* from EEx/HEEx** — the
`<%= @assign %>` hole surface and compile-time assigns-dependency tracking — and reuses **none
of EEx's code**: no `EEx.tokenize`, no `EEx.Engine`, no `handle_expr`, no embedded Elixir, no
compile-to-closure. A `~P` template is lowered by a **hand-rolled binary scanner** (§B.4) — a
**plain compiler function** invoked from
`Workflow.Compiler.parse/2` — the same single, directly-testable validation locus every other
combinator uses — never by a self-expanding sigil macro (§B.4).

> **Note — no `sigil_P` macro exists.** `~P` is **surface syntax only**. No `defmacro sigil_P`
> is defined or imported anywhere; if one were, it would be dead code (the workflow body is
> handed to `parse/2` **unexpanded**, and `parse/2` never `Macro.expand`s the block, so a
> `sigil_P` body would never run). Instead `parse/2` recognizes the raw AST term
> `{:sigil_P, meta, [{:<<>>, _, [raw]}, _mods]}` in an admissible prompt position (§C.6 lists
> them) and lowers it with the plain function `Template.lower/3` (§B.4). This keeps **all**
> template validation inside `parse/2`, escapable into the inert tree by the unchanged
> `workflow/2` shell.

### B.1 What we reuse from EEx/HEEx (ideas only), and what we deliberately drop

We rip two **ideas** from EEx/HEEx — the `<%= @assign %>` hole surface and compile-time
assigns-dependency tracking — and reuse **none of EEx's code**. In particular we do **not** call
`EEx.tokenize/2`: its token tuples deliver hole bodies as **charlists** (and, on statement/block
forms, as `:start_expr`/`:end_expr` markers), so a fold over them would have to re-parse each hole
body with `Code.string_to_quoted` — which is the exact seam where arbitrary embedded Elixir could
sneak back in, and whose token shapes are an unstable internal that has changed across Elixir
versions. Instead a **hand-rolled binary scanner** (§B.4) walks the single raw sigil binary
directly, so "no embedded Elixir" is a **structural** property of the recognizer, not an
after-the-fact validation.

| EEx/HEEx mechanism | Reused? | How it appears here |
|---|---|---|
| The **tokenizer** `EEx.tokenize/2` | **DROPPED — do not call** | Its `{:text, charlist, _}` / `{:expr, ~c"=", raw_source_charlist, _}` / `:start_expr`/`:end_expr` tuples hand back charlists and raw source (not ASTs), forcing a `Code.string_to_quoted` re-parse and admitting a superset of §B.2 (comments, `<%%`, arbitrary exprs). `Template.lower/3` (§B.4) uses a **direct binary scanner** over `raw` instead; nothing is tokenized (by EEx or otherwise) at run time. |
| A custom `EEx.Engine` intercepting each expression (`handle_expr`) | **DROPPED — do not implement** | An `EEx.Engine` *is* the compile-to-quoted mechanism we reject; it emits `quote do … Access.get(assigns, …) end` closures. `Template.lower/3` implements **no** engine and **no** `handle_expr`; it folds scanned segments to the inert `%Template{}` with ordinary pattern matching. |
| Assigns-dependency tracking (which `@assigns` a template needs) | **Reused (as a data derivation)** | `%Template{}.assigns` is the ordered set of referenced assign names — used for name-resolution validation (§B.5) and binding resolution (§C.2). It is a `for`-comprehension over `segments`, not an engine hook. |
| **Compile the body to a quoted expression / closure over `assigns`** | **DROPPED** | `Template.lower/3` returns an **inert `%Template{}` struct** (a list of data segments), never a `fn assigns -> … end` or a `quote` block. |
| **Arbitrary embedded Elixir** (`<%= func(x) + 1 %>`, `<% if … %>`) | **DROPPED** | Only `<%= @name %>` is admissible. Any other expression is a compile error (§B.5). This is the load-bearing difference from EEx: an EEx template is Turing-complete; a `%Template{}` is a `printf` with named holes. |
| HEEx HTML-awareness / safe escaping | **Not applicable** | Prompts are plain text, not HTML; `RenderText` (`SPEC §4.4`) is the sole escaping rule. |

### B.2 Surface grammar

A template is written with the `~P` sigil (**P** for *prompt*), whose content is a string
restricted to text and assign holes. The grammar below defines the language of the **`raw` binary**
the sigil delivers (the delimiter is out of scope — see the note after the grammar), written as a
**maximal-munch lexical grammar with lookahead**, so it is unambiguous: at every position the lexer
either begins a
`Tag` (whenever the two characters `<%` appear) or consumes one `TextChar`. Only one tag shape —
`AssignHole` — is admissible; every other tag shape (`StatementTag`, `CommentTag`,
`LiteralEscapeTag`) is a grammar-**recognized** construct that validation **rejects** with a
caller-located diagnostic (§B.5). Making the non-`=` openers first-class productions — rather
than letting them fall through to text — is what keeps the grammar (§B.2), the validation (§B.5),
and the reference scanner (§B.4) accepting and rejecting the **same** strings (§F.8).

```
Template :: Segment*          ; the lexical grammar OF the `raw` binary the `~P` sigil delivers (see note below); ~P is uppercase, so raw is a single literal binary with no interpolation
Segment ::
  - Tag
  - TextRun
TextRun :: TextChar+
TextChar :: SourceCharacter [lookahead != EExTagOpen]
EExTagOpen :: `<` `%`
Tag ::
  - AssignHole                 ; the ONLY admissible tag (renders); all others are rejected in §B.5
  - StatementTag               ; `<% … %>` (no `=`) — rejected (Rule B.5.2)
  - CommentTag                 ; `<%# … %>` — rejected (Rule B.5.7)
  - LiteralEscapeTag           ; `<%%` — rejected (Rule B.5.8)
AssignHole :: `<%=` TemplateWS* `@` AssignName TemplateWS* `%>`
StatementTag :: `<%` [lookahead != `=` and != `#` and != `%`] TagBody `%>`
CommentTag :: `<%#` TagBody `%>`
LiteralEscapeTag :: `<%%` TagBody `%>`
TagBody :: (SourceCharacter but not the sequence `%>`)*
AssignName :: Letter (Letter | Digit | `_`)*   ; Letter is `A`–`Z` `a`–`z`; recognizer ~r/\A@([A-Za-z][A-Za-z0-9_]*)\z/ (§B.4)
TemplateWS :: WhiteSpace | LineTerminator    ; SPEC §2.1 lexemes — space, tab, and line terminators
```

> **Note — the sigil delimiter is out of scope for §B.2 (normative).** `Template` is the grammar
> of the **`raw` binary** the `~P` sigil delivers — **not** of the sigil call including its
> delimiters. Which delimiter pair encloses the sigil (`~P"…"`, `~P"""…"""`, `~P[…]`, `~P/…/`,
> `~P|…|`, `~P(…)`, `~P{…}`, `~P<…>`, `~P'…'`, …) is **Elixir's own sigil-lexer concern and out of
> scope for §B.2**: any Elixir sigil delimiter is admissible, and the template's lexical input is
> the **verbatim `raw` binary** the sigil produces (the single literal delivered as
> `{:<<>>, _, [raw]}`, §B.4). This is what keeps §B.2 and the §B.4 reference recognizer in **exact
> agreement by construction** — both operate on `raw`, never on the delimiter — and it is why an
> author embeds a literal delimiter **character** by choosing an alternate delimiter (`~P[Fix <%=
> @x %>]`) rather than a backslash-escape (§B.2 below; F.17(1), F.22). A non-Elixir host that has no
> sigil lexer supplies `raw` by whatever means its surface provides; §B.2 constrains only `raw`.

- `~P"…"` (single line) and `~P"""…"""` (heredoc) are both admissible, as are the alternate
  sigil delimiters above; the delimiters are Elixir's own and never enter `raw`. Because `~P` is an **uppercase** sigil, its content undergoes **no
  escape-sequence processing**: the sigil delivers the **verbatim source binary** (exactly like
  `~S`), so an inline `~P"a\nb"` carries the two literal characters `\` and `n`, **not** a line
  terminator (`quote(do: ~P"a\nb")` yields the raw binary `"a\\nb"`). An uppercase `~P` applies
  **no** escape processing at all: `\n`, `\t`, and `\\` are **not** interpreted (`~P"a\\b"` is the
  four bytes `a`, `\`, `\`, `b`). The closing delimiter simply may not appear unescaped in the
  body; to embed a literal delimiter **character**, authors choose an alternate sigil delimiter
  (`~P[…]`, `~P/…/`, `~P|…|`) or a heredoc — **not** a backslash-escape such as `\"`, which an
  uppercase sigil deprecates (and a future Elixir may reject outright). **To put a real newline in a template, use a heredoc
  `~P"""…"""` (whose line breaks are real line terminators in `raw`) or a literal line break —
  never an inline `\n`.** This no-escape behavior is the sibling of the no-interpolation property
  below (an uppercase sigil neither interpolates `#{…}` nor processes escapes) and is exactly what
  lets `Template.lower/3` (§B.4) be a pure **verbatim slicer** over `raw`. Every multi-line
  template in this document is therefore written as a heredoc.
- An `AssignHole` is **exactly** `<%= @name %>` — the opener `<%=`, then optional template
  whitespace (space, tab, **or line terminators** — a hole may span lines in a heredoc), an
  at-sign, an assign name, more optional template whitespace, and `%>`. No expression, no
  filter, no default.

**Disambiguation (normative).** Wherever the two-character sequence `<%` (`EExTagOpen`) begins, it
MUST be lexed as the start of a `Tag`, **never** as `TextChar`s (maximal munch, encoded by the
`[lookahead != EExTagOpen]` restriction on `TextChar`). Consequently **no** `<%…` sequence is ever
derivable as template text: `<%= @name %>` is the one `Tag` that renders; `<% … %>` (statement),
`<%# … %>` (comment), and `<%%` (literal-escape) are `Tag`s the grammar recognizes and §B.5
**rejects** with a caller-located diagnostic (Rules B.5.2, B.5.7, B.5.8). A literal `<%` therefore
cannot appear in template text (an intentional, rarely-needed omission — prompts do not contain
template tags). An `EExTagOpen` that is **not** closed by `%>` before end-of-template is a
caller-located compile error (Rule B.5.6), **not** a fallback to text. Because every `<%…` opener
is a recognized-then-classified `Tag` (never silent text, never a silently-dropped span), two
independent parsers converge on the same accept/reject verdict for **every** input.

**Why the whitespace admits line terminators.** `TemplateWS` matches `SPEC §2.1`'s full
whitespace-and-line-terminator lexeme set so a hole may span lines in a heredoc
(`~P"""<%=\n@draft\n%>"""`). The reference scanner (§B.4) trims `TemplateWS` from both ends of a
hole body itself, so the grammar and the scanner admit exactly the same holes; there is no
external tokenizer whose whitespace behavior the grammar must chase.

> **Note — why a sigil, not a function call, and why uppercase.** `~P` is chosen for two
> load-bearing reasons, both about surface syntax (there is **no** `sigil_P` macro — §B intro
> note). (1) It marks "this string is a template" *syntactically*, so a reader (and `parse/2`,
> which matches the `{:sigil_P, …}` AST node structurally) can tell a template from an ordinary
> prompt at a glance — a plain `template("…")` call would still be distinguishable to `parse/2`,
> but the sigil reads better and cannot be confused with a runtime helper. (2) **Uppercase**
> `~P` is required, not incidental: Elixir's uppercase sigils do **not** interpolate `#{…}`, so
> the sigil's content is always a **single raw binary** delivered as `{:<<>>, _, [raw]}` with no
> embedded expression AST. That is precisely what makes the whole template a **compile-time
> literal** the compiler can lower deterministically (a lowercase `~p` would admit `#{}` and
> reintroduce interpolation, defeating the closure-free guarantee). This property is
> **normative**: a conforming `~P` MUST carry a single literal binary as its content.

### B.3 The inert `%Template{}` struct (semantic model)

```
%Workflow.Template{
  segments :: [Segment],   # ordered; the template lowered to data
  assigns  :: [atom()]     # ordered set (insertion order) of distinct assign names referenced
}

Segment :: {:text, String.t()} | {:assign, atom()}
```

- `segments` is the template split into a `List` of literal text runs and assign holes, in
  source order. The real-newline segment `{:text, "Improve this:\n"}` arises from a **heredoc**
  (or a literal line break) — e.g. the heredoc whose second physical line is `Improve this:`
  followed by a hole lowers to `[{:text, "Improve this:\n"}, {:assign, :draft}, {:text, "\n"}]`,
  the `\n`s being real line terminators in `raw`. By contrast the **inline** form
  `~P"Improve this:\n<%= @draft %>"` lowers to `[{:text, "Improve this:\\n"}, {:assign, :draft}]`
  — that text run holds the two **literal** characters `\` and `n`, never a newline, because an
  uppercase `~P` does no escape processing (§B.2). This is why every multi-line template here uses
  the heredoc form.
- **Assign names are template syntax, not Elixir.** An `@name` inside a `~P` template is a run of
  characters scanned from the raw binary (§B.4), **never** an Elixir variable or module attribute
  AST node — so macro hygiene simply does not apply, and no implementer should reach for `var!` or
  `Module.get_attribute` to resolve one. This is precisely why the closure-free/escapable claim
  (§D.1) holds: there is no `@`-attribute lookup or variable capture at compile time.
- `assigns` is the **assigns-dependency set** ripped from HEEx: the distinct assign atoms the
  template references, in first-appearance order. It is derived from `segments`
  (`for {:assign, a} <- segments, uniq`) and cached on the struct so validation and binding
  resolution need not re-scan.
- The struct contains **zero closures** and is `Macro.escape`-able into a compile-time
  constant (`SPEC §1.3` Principle 7). This is the whole point of dropping EEx's compile-to-fn.

**Addressing.** A `%Template{}` has **no address** — it is inert data embedded in a consuming
node's field, exactly as `%Workflow.Node.BudgetSlices{}` has no address (`SPEC §4.2`). It
never keys an idempotency key or a journal event on its own; it is rendered *within* the
execution of the node that holds it (an `agent` §C.2, or `emit` §C.7), under that node's key.

### B.4 Compile-time lowering (a hand-rolled binary scanner, a plain `parse/2` function, NOT a macro)

`Template.lower/3` is a **plain compiler function** — a **direct binary scanner** over the single
raw template binary — that turns it into a `%Template{}` at compile time. `Workflow.Compiler.parse/2`
calls it while walking the workflow body — the moment it matches a
`{:sigil_P, meta, [{:<<>>, _, [raw]}, mods]}` AST node in an admissible prompt position (§C.6) —
first checking that `mods == []` (equivalently the empty charlist `~c""`, since `~c"" === []` — a
no-modifier sigil quotes with `mods == []`; a non-empty `mods` is a caller-located `Finding` at
`meta`, Rule B.5.9) and then lowering `raw` —
exactly as `parse/2` today calls the plain functions `verify_prompt/2`, `score_prompt/2`, and
`to_text/1`. It is **not** a sigil macro and does **not** run during macro expansion; all of its
validation therefore lives in the one directly-testable locus (`parse/2`), unit-testable against
`quote do … end` input. It calls **no** `EEx.tokenize`, **no** `EEx.Engine`, and **never**
`Code.string_to_quoted` — a hole body is classified by byte pattern, never re-parsed as Elixir.

```
Template.lower(raw, meta, env):        ; a plain function CALLED FROM parse/2 — no macro expansion; raw is a single literal binary
  - Return Scan(raw, "", empty List, meta, env).

Scan(rest, pending, segments, meta, env):
  ; rest is the unscanned suffix of raw; pending is the accumulated text run (a BINARY);
  ; segments is the List of {:text, binary} | {:assign, atom} built so far.
  - If {rest} is the empty binary "":
    - Let {segments'} be FlushText(pending, segments).
    - Let {assigns} be the distinct {name} from every {:assign, name} in {segments'}, first-appearance order.
    - Return {:ok, %Template{segments: {segments'}, assigns: {assigns}}}.
  - If {rest} begins with the two-byte prefix `<%` (EExTagOpen):
    - Return ScanTag({rest}, FlushText(pending, segments), meta, env).
  - Otherwise ({rest} begins with one SourceCharacter {c}):
    - Return Scan(the suffix of {rest} after {c}, {pending} <> {c}, {segments}, meta, env).

FlushText(pending, segments):
  - If {pending} is "": Return {segments}.
  - Return {segments} with {:text, pending} appended.

ScanTag(rest, segments, meta, env):    ; {rest} begins with `<%`
  - If {rest} begins with `<%%` (LiteralEscapeTag):
    - Return {:error, Finding at {meta}:
        "a ~P template admits no literal-escape tags (`<%% … %>`); only `<%= @name %>` holes"}.   ; Rule B.5.8
  - If {rest} begins with `<%#` (CommentTag):
    - Return {:error, Finding at {meta}:
        "a ~P template admits no comments (`<%# … %>`); only `<%= @name %>` holes"}.              ; Rule B.5.7
  - If {rest} contains no `%>`:
    - Return {:error, Finding at {meta}:
        "unterminated `<%…` tag — a ~P template hole must be `<%= @name %>`"}.                    ; Rule B.5.6
  - Let {after} be the suffix of {rest} after the first `%>`.
  - If {rest} begins with `<%=` (a value hole; the 3-byte opener `<%=`):
    - Let {body} be the bytes of {rest} strictly between the 3-byte opener `<%=` and the first `%>`.
    - Let {trimmed} be {body} with leading and trailing TemplateWS (§B.2) removed.
    - If {trimmed} matches ~r/\A@([A-Za-z][A-Za-z0-9_]*)\z/ capturing {name}:      ; a bare @name
      - Return Scan({after}, "", {segments} with {:assign, String.to_atom(name)} appended, meta, env).
    - Otherwise:                                        ; arithmetic, a call, a block-opener (`<%= for … do %>`), or empty
      - Raise CompileError located at {meta} via the FORBIDDEN-FORM path (the same path
        `parse/2` uses when it meets a bare `fn` in a workflow body):
        "a ~P template hole must be a bare assign `<%= @name %>` — got `<%=` <trimmed> `%>`".     ; Rules B.5.1, B.5.3
  - Otherwise ({rest} begins with `<%` not followed by `=`, `#`, or `%` — a StatementTag):
    - Raise CompileError located at {meta} (forbidden-form path):
      "a ~P template admits no control statements or blocks (`<% … %>`); only `<%= @name %>` holes".   ; Rule B.5.2
```

- **Total by construction.** Every text segment is a **binary** (a slice of `raw`), so `%Template{}`
  never carries a charlist and §B.6's `out <> chars` is always `binary <> binary` — the render is
  total (contrast: an EEx `{:text, charlist, _}` fed to `binary <> charlist` would raise). Every
  branch of `Scan`/`ScanTag` either recurses on a **strictly shorter** suffix, returns `{:ok, …}`,
  returns `{:error, Finding}`, or raises; there is no fall-through, so no input "falls off the end."
- **No `EEx`, no `Code.string_to_quoted`, no closure.** The scanner classifies each `<%…` opener by
  its byte prefix and either emits `{:assign, name}` for a well-formed `<%= @name %>` or rejects the
  tag; it **never** parses a hole body as Elixir. The result is the inert `%Template{}` struct —
  **no `quote` block, no `fn`** is ever emitted. "No embedded Elixir" is therefore a **structural**
  guarantee of the recognizer, not a validation applied after admitting a superset. An implementer
  MUST NOT reintroduce `EEx.tokenize`/`EEx.Engine`/`Code.string_to_quoted` for hole bodies.
- **Dual diagnostic channel, single locus, single anchor.** Every diagnostic originates in `parse/2`
  (via `lower/3`) through the compiler's existing machinery, and **both channels anchor at the `~P`
  sigil node's `meta`**, so one bad template reports exactly one source line (never two): a
  **`Finding`** (at `meta`) for a rejected *tag shape* with no embedded expression — unterminated
  (Rule B.5.6), comment (B.5.7), literal-escape (B.5.8) — and the **forbidden-form `raise`** (also
  anchored at `meta`, the same channel a stray `fn` triggers) for the morally-forbidden *expression*
  forms that carry embedded Elixir — a non-`@name` value hole (arithmetic/call/block-opener, Rules
  B.5.1/B.5.3) and a control statement (Rule B.5.2). Name-resolution (Rules B.5.4/B.5.5) is a
  **`Finding`** raised by the consuming combinator's `parse/2` walk under the threaded `BindingEnv`
  (§B.5, §C.2), anchored at the consuming statement. There is **no** second validation locus: a
  `~P` node is validated wholly inside `parse/2`. (`String.to_atom/1` here is safe: `name` comes from
  a **compile-time** template literal authored in the workflow source — bounded, author-controlled,
  exactly like a `let :name` label — never from runtime input.)

**Conformance of the lowering (normative).** The **§B.2 grammar is the normative definition of an
admissible template**, and `Template.lower/3` above is the **reference recognizer**. Because the
scanner emits a `{:text, binary}` for every maximal run of `SourceCharacter`s containing no `<%`, an
`{:assign, name}` for **exactly** a well-formed `<%= @name %>` hole, and a caller-located rejection
for **every** other `<%…` opener (statement, block-opener, comment, literal-escape, unterminated, or
non-`@name` value hole), it accepts and rejects **exactly** the strings §B.2 derives — **no more,
no less** — *by construction* rather than by narrowing a tokenizer's superset. Grammar (§B.2) and
algorithm (§B.4) therefore **cannot diverge**: there is no unenumerated token kind to fall through
(contrast an EEx fold, which must additionally reject comment/`<%%`/arbitrary-expr tokens the
tokenizer emits). A non-Elixir host MAY use any recognizer provided it accepts exactly the §B.2
grammar and produces the §B.3 struct.

### B.5 Validation rules (each with the smallest counter-example)

All template rules are checked **inside `parse/2`** (caller-located, `SPEC §5.0`) — there is no
separate macro-expansion validation step. Template-*shape* rules (B.5.1–B.5.3, B.5.6, B.5.7,
B.5.8) are enforced by the `Template.lower/3` scanner (§B.4) the moment `parse/2` lowers the
`{:sigil_P, …}` node: forbidden **expression** forms (a non-`@name` value hole, a control
statement/block) take the forbidden-form `raise` path, and a rejected **tag shape** with no
embedded expression (unterminated, comment, literal-escape) yields a `Finding` — both anchored at
the sigil's `meta` (§B.4). Name-resolution rules (B.5.4/B.5.5 — does an assign resolve to a
binding?) are checked by the **consuming** combinator's `parse/2` walk in a binding scope (§C.2,
§C.7), because that is where the in-scope bindings are known. Both channels are the compiler's
ordinary diagnostics; neither originates in a sigil macro.

**Rule B.5.1 — A hole is a bare assign.** An `<%= … %>` whose expression is not exactly
`@name` is rejected.

```counter-example
~P"Improve <%= @draft + 1 %>"      # arithmetic in a hole — DO NOT CROSS (§A.3.1)
```

```counter-example
~P"Improve <%= String.upcase(@draft) %>"   # a function call in a hole is not admissible
```

**Rule B.5.2 — No control statements.** A `<% … %>` statement form (no `=`) is rejected.

```counter-example
~P"<% if @ok do %>yes<% end %>"    # a general `if` in a template — DO NOT CROSS (§A.3)
```

**Rule B.5.3 — No block expressions.** A block form is rejected. A block-opening value hole
(`<%= … do %>`) is a non-`@name` `<%=` body, so the scanner rejects it on the forbidden-form
`raise` path together with Rule B.5.1.

```counter-example
~P"<%= for x <- @xs do %><%= x %><% end %>"   # a comprehension/closure — DO NOT CROSS
```

**Rule B.5.4 — Every referenced assign resolves to an in-scope binding (name resolution).**
Checked by the consuming combinator: every atom in `template.assigns` MUST be a `let`-bound
name (§C.1) or a `map`-element name (§C.4) in **lexical scope at the consuming node**. An
unbound assign is a caller-located finding at the consuming statement.

```counter-example
workflow "x" do
  agent(~P"Improve <%= @ghost %>")   # `@ghost` is bound by no preceding `let` — REJECTED
  return(:ok)
end
```

**Rule B.5.5 — Define-before-use.** An assign MUST resolve to a binding whose producer
**lexically precedes** the consuming node in the same or an enclosing scope. A forward or
self reference is rejected. (This is what guarantees the producer is journaled before the
consumer renders — §D.4.)

```counter-example
workflow "x" do
  agent(~P"Refer to <%= @later %>")   # used before it is bound — REJECTED
  let :later = agent("produce it")
  return(:ok)
end
```

**Rule B.5.6 — An `EExTagOpen` must be closed by `%>` (maximal-munch consequence).** By the §B.2
disambiguation clause, the sequence `<%` (`EExTagOpen`) MUST begin a `Tag` and can never fall back
to text. A `<%…` opener with no closing `%>` before end-of-template (an unterminated tag) is
therefore a **caller-located `Finding`** (raised by the `Template.lower/3` scanner, §B.4), not a
template that silently contains literal `<%` text.

```counter-example
~P"literal <%= tag"     # `<%=` opens a hole that never closes with `@name %>` — REJECTED (not text)
```

**Rule B.5.7 — No comment tags.** A `<%# … %>` comment tag is a grammar-recognized `CommentTag`
(§B.2) that the scanner rejects with a caller-located `Finding` — it is **not** silently dropped
and **not** literal text. (This is the smuggled-non-determinism seam §F.8 closes: without a
recognized `CommentTag` production, one implementer might treat `<%# … %>` as text, another might
drop it.)

```counter-example
~P"keep <%# a note %> this"     # a comment tag — REJECTED (not text, not silently dropped)
```

**Rule B.5.8 — No literal-escape tags.** A `<%%` literal-escape tag (EEx's way of writing a
literal `<%`) is a grammar-recognized `LiteralEscapeTag` (§B.2) that the scanner rejects with a
caller-located `Finding`. A literal `<%` is intentionally inexpressible in a `~P` template (§B.2
disambiguation); the escape is rejected rather than silently honored so the two documents agree.

```counter-example
~P"escaped <%% not-a-tag %>"    # a literal-escape tag — REJECTED (a literal `<%` is inexpressible)
```

**Rule B.5.9 — A `~P` sigil MUST carry empty modifiers.** An uppercase sigil admits a trailing
modifier charlist (the `_mods` slot of `{:sigil_P, meta, [{:<<>>, _, [raw]}, mods]}`); e.g.
`~P"…"x` quotes with `mods = ~c"x"`, whereas a **no-modifier** sigil quotes with `mods == []`
(equivalently the empty charlist `~c""`, since `~c"" === []`). A `~P` template assigns **no** meaning
to any modifier, so a non-empty `mods` (any `mods != []`) is a caller-located **`Finding`** at the
sigil's `meta` (raised by `parse/2` when
it matches the sigil node, before `Template.lower/3` runs), never silently ignored. This pins the
recognizer's accept-set: two implementers cannot diverge by one ignoring `mods` and one
interpreting it.

```counter-example
~P"<%= @x %>"x    # a `~P` sigil modifier `x` — REJECTED (a `~P` template takes no modifiers)
```

### B.6 The deterministic RenderText algorithm

Rendering a `%Template{}` reuses the **exact** value-rendering of `SPEC §4.4` (binary
pass-through, else `inspect/1`), widened only in that the assign values come from the journal.
`RenderTemplate` is the total, closure-free function that turns a template plus a resolution
context into a string:

```
RenderTemplate(template, run_id, bindings, lane):
  - Let {out} be the empty binary "".
  - For each {segment} in template.segments, in order:
    - If {segment} is {:text, text}:               ; {text} is always a BINARY (§B.4 scanner)
      - Set {out} to {out} <> text.                ; binary <> binary — total; never a charlist
    - If {segment} is {:assign, name}:
      - Let {value} be ResolveAssign(name, bindings, run_id, lane).   ; §C.2 / §C.4
      - Set {out} to {out} <> RenderText({value}).                    ; SPEC §4.4, VERBATIM
  - Return {out}.

RenderText(term):                                 ; SPEC §4.4, restated — UNCHANGED
  - If {term} is a binary: Return {term} unchanged.   ; no added quotes
  - Return inspect(term).                              ; Elixir Kernel.inspect/1
```

- **Total render.** Every `{:text, text}` segment carries a **binary** (the §B.4 scanner slices
  `raw`, never a charlist), so `out <> text` is `binary <> binary` and cannot raise. `RenderText`
  is `SPEC §4.4` **verbatim**: a binary flows through unquoted (cross-host normative), a non-binary
  renders as `inspect/1` (byte-normative for the Elixir embedding only; `SPEC §4.4`'s host-scoped
  clause applies identically here). Authors who need a byte-stable journaled prompt across hosts
  MUST bind **binary** values.
- **Note (map-key ordering — normative hedge).** The one thing this proposal newly flows through
  `inspect/1` that shipped `SPEC §4.4` never did is a **runtime journaled map**: dataflow-ground §1
  pins provider results as string-keyed JSON maps, whereas every value `SPEC §4.4` inspects (a
  `verify` subject, a `judge` candidate, `synthesize` inputs) is a **compile-time literal** whose
  inspected bytes are fixed at compile time. `Kernel.inspect/1` does **not** guarantee a canonical map
  key order across Elixir versions, so even the within-Elixir-embedding byte-normativity above holds
  only for a **fixed host `inspect/1`** — same Elixir version, equal maps from equal JSON decode; two
  hosts (or two Elixir versions) MAY render different bytes for the **same** bound map. Authors
  requiring a byte-stable journaled prompt or terminal MUST bind **binary** values, or pre-render each
  element to a binary via `map` (§C.4) before `gather`/`emit`. This is the one place the extension's
  determinism story is strictly weaker than the shipped literal-only story it inherits, and this hedge
  is normative, not advisory.
- `RenderTemplate` reads **no** clock and **no** external state; its only inputs are the
  template (compile-time data), the immutable journal (via `ResolveAssign`), and the lane
  index. It is therefore a **pure fold** — the same property that makes accumulators and
  `Status` pure (`SPEC §1.3` Principle 3). Determinism and replay-safety of every flowed value
  reduce to the determinism of `ResolveAssign`'s journal fold (§D.2).

### B.7 Conformance (template layer)

- **T1.** A `~P` template MUST be lowered **by `Workflow.Compiler.parse/2`** (via the plain
  function `Template.lower/3`, a direct binary scanner over the raw sigil binary — §B.4) at compile
  time to an inert `%Template{}` of the §B.3 shape whose `{:text, …}` segments are all **binaries**.
  It MUST NOT compile to a closure, a quoted expression, or any form holding a function reference
  (Principle 7, C3), and the scanner MUST NOT call `EEx.tokenize`, `EEx.Engine`, or
  `Code.string_to_quoted` on any hole body. An implementation MUST NOT define or import a `sigil_P`
  macro and MUST NOT lower templates during macro expansion; `parse/2` recognizes the
  `{:sigil_P, …}` AST node structurally, and its content MUST be a single literal binary (uppercase
  `~P` never interpolates, §B.2). A `~P` sigil MUST carry **empty** modifiers (`mods == []`,
  equivalently the empty charlist `~c""`); a non-empty `mods` charlist MUST be a caller-located
  `Finding` at the sigil's `meta` (Rule B.5.9).
- **T2.** The scanner MUST admit **only** `<%= @name %>` holes and literal text, and MUST accept
  and reject **exactly** the §B.2 language — no more, no less. Every other `<%…` opener
  (non-`@name` value hole, statement/block, comment, literal-escape, unterminated) MUST be a
  caller-located compile error anchored at the sigil's `meta`, and every such rejection MUST
  originate in `parse/2` (Rules B.5.1–B.5.3, B.5.6, B.5.7, B.5.8) — never in a separate sigil-macro
  expansion and never a silently-dropped span.
- **T3.** `RenderTemplate` MUST render assign values through `SPEC §4.4`'s `RenderText`
  unchanged (binary pass-through, else `inspect/1`), so a template and the corresponding
  `verify`/`judge` splice render an identical binary identically.
- **T4.** `template.assigns` MUST be the distinct referenced assign names in first-appearance
  order, and MUST be usable for name-resolution validation and binding resolution without
  re-scanning `segments`.

---

## C. The idioms

Each idiom is specified to the full 8-part bar: surface grammar, inert node struct (+ how it
extends addressing and the idempotency key), validation rules each with the smallest
counter-example, a function-style execution algorithm (proving determinism, exactly-once,
replay-safety, bounded termination), journal events, and an RFC-2119 conformance clause.

**Top-level grammar integration (normative).** `LetStmt` (§C.1.1), `MapStmt` (§C.4.1),
`GatherStmt` (§C.5.1), and `EmitStmt` (§C.7.1) are new alternatives of `SPEC §3`'s top-level
workflow-body `Statement` nonterminal — joining `AgentStmt`, which §C.2.1 extends in place. They
are admissible **only** at top level: **none** is an alternative of the loop-body statement set
(`SPEC §5.7.6`) or of the `map`-body statement set (§C.4.1 `AgentLane : AgentStmt`), which the
top-level-only validation rules (C.1.4, C.4.4, C.5.3, C.7.3) enforce and this grammar attachment
reflects. Below the statement level these productions add only two nonterminals: `Prompt`
(§C.2.1, `StringLiteral | Template`) and `Template` (§B.2). The goal symbol therefore stays
closed — every nonterminal any new production references is defined here or in §B.

**The compile-time binding environment (shared by every idiom).** The compiler threads a
`BindingEnv` — an **ordered map** `name(atom) → BindingRef` — through parsing, accumulating a
binding as each `let`/`map` is parsed, so only **lexically-preceding** bindings are in scope
(§B.5.5). A nested scope (a `map` body) inherits the enclosing env and extends it with its
element binding.

**Where the `BindingEnv` threads (normative locus).** The `BindingEnv` is an explicit accumulator
threaded **through the per-form entry itself**, alongside the `seen`/`index` accumulators the
statement-dispatch fold (`build/5`) already carries. This is load-bearing: a bindings-bearing node's
`bindings` map (§C.2.2, §C.7.2) and a `map` lane's `@element` resolution (§C.4.2) must be materialized
**where the node is constructed** — inside the per-form entry, which is where the `%Agent{}`/`%Map{}`
struct is built — so the entry MUST receive the `BindingEnv`. The entry is therefore **widened** to
`node(form, address, env, binding_env)` (and its body-form / map-body-lane equivalents), where `env`
remains the `Macro.Env` and `binding_env` is the threaded compile-time `BindingEnv`. This is the
compile-time twin of the runtime lane-threading widening F.19 applied to `RunLane`/`BuildAgent` — a
**uniform** trailing-argument arity change, not an overload (every clause gains the same parameter;
most ignore it, exactly as `parallel`/`pipeline`/`fan_out` ignore F.19's `lane`). The statement fold
`build/5`:

- passes the in-scope `binding_env` into each `node/4` call (initially the empty env);
- **extends** `binding_env` **after** each `let`/`map` returns — recording `name → {:node|:map, addr}`
  — so only **lexically-preceding** bindings are ever in scope (define-before-use, Rule B.5.5);
- leaves `binding_env` unchanged across a non-binding statement.

**The 4th-argument decision at ALL of the compiler's `node/…` call sites (normative — no site is left
open).** Widening the per-form entry to `node(form, address, env, binding_env)` forces a 4th argument
at **every** existing call site of the base compiler's `node/3`, not only `build/5`. The base compiler
calls `node/3` from **five** sites; this proposal adds a **sixth** (the `map` lane). Each site's 4th
argument is pinned here so two implementers cannot diverge on which env a nested agent resolves against:

| # | Call site (base `compiler.ex` locus) | 4th arg `binding_env` passed | Why |
|---|---|---|---|
| 1 | `build/5` top-level statement dispatch (`compiler.ex:122`) | the **in-scope** `binding_env` (accumulated across preceding `let`/`map`) | top-level is the only region that introduces bindings; a top-level `agent`/`gather`/`emit` resolves its assigns here |
| 2 | `agent_branches` for `parallel` (`compiler.ex:471`) | the **empty** env `%{}` | a `parallel` branch is a nested agent position; template prompts are **rejected** there (Rule C.2.4), so no binding ever resolves |
| 3 | `pipeline_stages` (`compiler.ex:538`) | the **empty** env `%{}` | a `pipeline` stage is a nested agent position; template prompts are **rejected** there (Rule C.2.4) |
| 4 | `agent_lane` for `fan_out` (`compiler.ex:979`) | the **empty** env `%{}` | a `fan_out` body agent is a nested agent position; template prompts are **rejected** there (Rule C.2.4) |
| 5 | `body_node → node` for loop bodies (`compiler.ex:661`) | the **empty** env `%{}` | a loop-body agent is a nested agent position; template prompts are **rejected** there (Rule C.2.4) |
| 6 | the **new** `map` lane (§C.4.2) | the **element-extended** env `Map.put(binding_env, element_name, {:element, over})` | the map body is the one nested region that DOES bind a name (`@element`); its single lane `agent` resolves `@element` (and any enclosing top-level binding) here |

Sites 2–5 pass the **empty** env deliberately, not by oversight: a `parallel` branch, a `pipeline`
stage, a `fan_out` body agent, and a loop-body agent introduce **no** binding, and — by the adjudicated
scope decision below — **may not carry a `%Template{}` prompt at all**. The empty env means such a
template would fail name resolution, but the rejection is made an **active guard** (next paragraph), so
the diagnostic is precise ("templates are not admissible in a `parallel` branch") rather than a
misleading "unbound assign `@draft`" for a name that IS bound at top level. Site 6 is the sole nested
region that extends the env, and it extends it by **exactly one** disjoint element binding (Rule C.4.5).

**Adjudicated scope decision (normative): a `~P` template is admissible ONLY in a top-level or
map-lane agent prompt, a top-level `gather`, or a top-level `emit` — nowhere else — and the four nested
agent positions ACTIVELY reject it.** The four nested folds — `agent_branches` (parallel, `L471`),
`pipeline_stages` (`L538`), `agent_lane` (fan_out, `L979`), and `body_node`/`build_body` (loop bodies,
`L661`) — each carry an **active guard**, in the same discipline as Rule C.2.4/C.7.4: when the
`AgentStmt` they are about to build has a prompt argument matching `{:sigil_P, meta, _}`, the fold emits
a caller-located `Finding` at the sigil's `meta` — *"a `~P` template prompt is not admissible in a
`parallel` branch / `pipeline` stage / `fan_out` body / loop body; template prompts are admissible only
in a top-level or `map`-lane `agent`"* — and does **not** build the node. This is an **intentional
guard**, not an accident of empty-env name-resolution failure. Consequently the dataflow graph's value
edges stay lexically obvious: a bound value flows into exactly the four whitelisted positions, and the
runtime `lane` argument of `EffectivePrompt`/`RenderTemplate` remains drawn from `{nil (top level),
%{index: e} (map lane)}` (§C.2.4, L1195) with no third case — a nested template agent, if admitted,
would have demanded a `lane` for a `parallel`/`pipeline`/`fan_out`/loop position and reintroduced
define-before-use-across-a-barrier reasoning the restriction eliminates. (Adjudication and the rejected
permissive alternative: F.29, §F.)

Each **prompt-bearing** clause — `agent` (§C.2), `gather` (§C.5), `emit` (§C.7) — resolves its
`%Template{}.assigns` against the received `binding_env` **at construction time**: it folds each atom
in `template.assigns` to its `BindingRef`, raises the caller-located name-resolution findings (Rules
B.5.4/B.5.5) at the consuming form when an assign is unbound or forward-referenced, and stores the
resulting `%{atom => BindingRef}` map in the node's `bindings` field (§C.2.2 construction step). The
**`map`** clause (§C.4.2) parses its single lane `agent` under the **element-extended** env
`Map.put(binding_env, element_name, {:element, over})` — a disjoint extension (Rule C.4.5) — so the
lane agent's own `node/4` resolves `@element` and populates its `bindings` in the extended scope; the
top-level `build/5` fold could never supply this binding, because `element_name` is in scope **only**
inside the map body.

> **Note (supersedes F.24(3), normative).** This retracts the fifth-pass pin (F.24(3)) that the
> `BindingEnv` is threaded **only** at the `build/5` statement-dispatch level and that the per-form
> entry "carries **no** `BindingEnv` … the name-resolution fold reads its scope from that threaded
> `BindingEnv`." That pin was self-contradictory: the node struct is **constructed inside** the
> per-form entry (verified against `lib/workflow/compiler.ex`, where `build/5` only post-inspects the
> node `node/3` returns), so under it the entry could populate no `bindings` field and could never
> reach a `map` lane's `@element` (bound only in the map-body scope the top-level fold never enters).
> The widened-entry locus above is the adopted resolution; see F.25 for the adjudication (widen the
> per-form entry, F.19-style, over a separate `resolve_bindings` pass over the inert tree).

```
BindingRef ::
  - {:node, address}              ; a `let`-bound producer output (a journaled agent_committed)
  - {:map, address}               ; a `let`-bound `map` producer; resolves to the ORDERED LIST of its lanes' results (§C.4, DF-M4)
  - {:element, over_ref}          ; a `map` per-element binding; over_ref is the collection's BindingRef
```

`BindingEnv` is a **compile-time artifact** (its values are addresses — compile-time
constants, escapable). It never survives into the runtime tree except as the resolved
`bindings` map a consuming node carries (§C.2). There is **no runtime name→value map** and
**no process state**; a bound value is always re-derived by folding the journal (§D.2).

> **Note — binding/element names are author-source atoms (no atom-exhaustion).** A `let`/`map`
> binding name and a `map` `ElementName` become atoms via `String.to_atom` over the **workflow
> source literal** — bounded, author-controlled, and compile-time, on exactly the same
> author-source-only path as a `phase` name or a template assign name (§B.4). None is ever derived
> from runtime input, so a reviewer of the Elixir port should not flag `String.to_atom` at these
> sites as a trust-boundary atom-exhaustion risk; it is the identical guarantee §B.4 states for
> template assign names.

**Runtime resolution (shared).** Every assign resolves to a value by a pure journal fold:

```
ResolveAssign(name, bindings, run_id, lane):
  - Let {ref} be bindings[name].                       ; compile-time-resolved BindingRef
  - Return ResolveRef(ref, run_id, lane).

ResolveRef({:node, address}, run_id, _lane):
  - Return BoundValue(run_id, address).                ; the producer's journaled result
ResolveRef({:map, address}, run_id, _lane):            ; a `let`-bound map — DF-M4
  - Return BoundList(run_id, address).                 ; the ordered List of the map's lane results
ResolveRef({:element, over_ref}, run_id, lane):
  - Let {collection} be ResolveRef(over_ref, run_id, lane).
  - Return Index({collection}, lane.index).            ; this lane's element

BoundValue(run_id, address):                           ; a pure fold, like Idempotency.resolve (SPEC §6.4)
  - Let {events} be Journal.Fold(run_id).
  - Let {e} be the `agent_committed` in {events} with payload.address == address
      and payload.iteration == 0.                      ; top-level bindings resolve at iteration 0
  - If {e} exists: Return e.payload.result.
  - Raise BindingUnresolved(address).                  ; unreachable if define-before-use (B.5.5) held — see §D.4

BoundList(run_id, map_address):                        ; the map's bound value — DF-M4; a pure fold, no new event
  - Let {W} be MapWidth(run_id, map_address).          ; the journaled width — from map_started (§C.4.5)
  - Return the List [ BoundValue(run_id, map_address ++ [e, 0]) for {e} from 0 to {W} - 1 inclusive ],
      in STRICT ascending lane order 0..W-1.           ; each lane is a single agent at sub-address [e, 0] (§C.4.1)
  - If {W} is 0: the List is [].                        ; a width-0 map binds []

MapWidth(run_id, map_address):
  - Let {events} be Journal.Fold(run_id).
  - Let {s} be the `map_started` in {events} with payload.address == map_address.
  - If {s} exists: Return s.payload.width.
  - Raise BindingUnresolved(map_address).              ; unreachable once the map has run (define-before-use, §D.4)

Index(list, i) when list is a List and 0 <= i < length(list): Return the i-th element (0-based).
Index(_, _): Raise BindingIndexError.                  ; guarded by map's width = min(len, max), §C.4
```

`BoundValue`/`BoundList` are the **exact** shape of `Idempotency.resolve/3` (`SPEC §6.4`,
dataflow-ground §1): fold the journal, match on address, take `payload.result`. `BoundList` folds
the **same** `agent_committed` machinery once per lane and reads the width from the **existing**
`map_started` event — it introduces **no** new journal event (DF-M4 is a resolution rule only,
keeping §C.4.5's "two new events" count unchanged). It reuses the single source of truth; it
invents no new state. `lane` is `nil` outside a `map` body and `%{index: i}` inside lane `i` of a
`map`.

> **Note (observably-equivalent, non-normative).** Each `ResolveAssign` above is written as a
> fresh `Journal.Fold(run_id)` for clarity, so a node with *k* assigns reads as *k* folds. An
> implementation MAY fold the journal **once** and resolve **all** of a node's bindings (and a
> map's whole lane List) against that single projection — mirroring how `Accumulator.of/1` folds
> once (`SPEC §6.6.1`) — keeping the mechanism honestly O(journal) rather than O(assigns ×
> journal). The observable result is identical (`SPEC §8`, observably-equivalent clause).

---

### C.1 `let` — name a journaled output  ·  Verdict: ADOPT

**Purpose.** Bind a compile-time **name** to the output of a single producer node, so later
nodes may reference it (§C.2) or `emit` may render it (§C.7). `let` binds a **name to an
address** at compile time; the **value** is always fetched by folding the journal
(`BoundValue`). It creates no new value and no new paid effect — the producer's own
`agent_committed` is the binding's journal record.

**C.1.1 Surface grammar.**

```
LetStmt : `let` BindingRefAtom `=` Producer
BindingRefAtom :: `:` AtomName   ; LEXICAL (double-colon `::`): ONE atom-literal token `:name` — the `:` and AtomName are a single token with NO whitespace between them; there is no separate syntactic `:` terminal (that would denote `let ::name`)
AtomName :: Letter (Letter | Digit | `_`)*   ; Letter is `A`–`Z` `a`–`z` (the §B.2 AssignName char class); reused by §C.4.1. Deliberately NO trailing `?`/`!`: `:ok?`/`:done!` are valid Elixir atoms but NOT admissible binding names — kept in AssignName's char class so every bound name is template-referenceable (Rule C.1.1)
Producer :
  - AgentStmt                 ; the common case — binds the agent's journaled result ({:node, addr})
  - SynthesizeStmt            ; synthesize's output is an ordinary agent output (SPEC dataflow-ground §1)
  - GatherStmt                ; §C.5 (when adopted) — binds one agent_committed
  - `(` MapStmt `)`           ; §C.4 — binds the ORDERED LIST of the map's lane results ({:map, addr}, DF-M4);
                              ;   a block-bearing producer MUST be parenthesized (§C.1.2 AST-pinning; Rule C.1.5)
```

`AgentStmt`, `SynthesizeStmt`, and `GatherStmt` are **paren-call** forms that delimit their own
arguments and carry no `do…end` block, so they need no extra parentheses on a `let` right-hand
side. `MapStmt` is the **only** block-bearing producer, and it MUST be wrapped in parentheses —
`let :xs = (map … do … end)` — for the AST reason pinned in §C.1.2 (without them the `do…end`
block is hijacked onto `let`, leaving the `map` bodyless).

`let :draft = agent("Write a draft.")`. Each producer is either (a) a single node that commits
one `agent_committed` (an `agent`, a `synthesize`, or a `gather` — all of which reduce to one
agent turn), binding `name → {:node, addr}`; or (b) a `map` (§C.4), a bounded fan-out that binds
`name → {:map, addr}` — the **ordered List** of its lanes' terminal results, resolved by
`BoundList` (§C shared resolution, DF-M4). Binding `map` **closes the dataflow graph**: a
`map`'s per-lane outputs are otherwise unreferenceable, which would re-create the exact "outputs
flow nowhere" wall (§A.1) this proposal dissolves. An **unbound** `map` (a bare `map … do … end`
statement, not on a `let` right-hand side) is **fire-and-forget**: its lane outputs are committed
but unreferenceable (DF-M4). Panels (`verify`/`judge`) are **not** bindable producers (their
outcome is a fold, not an agent output, and Principle 8 keeps them observational — §C.1.4).

**C.1.2 Surface→AST lowering (pinned, normative — mirrors §B.4's sigil pinning).** `let` introduces
`=` to a DSL whose every other statement is a bare call, so its AST must be pinned as precisely as
§B.4 pins the `~P` sigil node, or two teams diverge. Because `let` is a paren-less call and `=` is a
low-precedence operator, `parse/2` receives `let` as a call whose **sole argument is a match
node**. The normative shape is the **uniform one-arg** form:

```
{:let, meta, [{:=, _match_meta, [name_ast, producer_ast]}]}     ; the ONE-arg shape parse/2 matches
```

where (1) `name_ast` is an **atom literal** (`:draft`) — the binding name (Rule C.1.1); and (2)
`producer_ast` is the ordinary quoted form of the producer call (`{:agent, …}`, `{:synthesize, …}`,
`{:gather, …}`, or `{:map, …}`). `parse/2` matches this one-arg shape, then **dispatches
`producer_ast` back through the ordinary per-form entry** (the entry widened to carry `binding_env`,
§C intro) **under the in-scope `binding_env`**, so the existing agent / synthesize / gather / map
clauses lower it **unchanged** — a producer whose own prompt is a `%Template{}` therefore resolves its
assigns against the same in-scope `binding_env` — and `let` performs no producer-specific parsing and
no do-block surgery. The canonical `let :draft = agent("Write a draft.")` therefore quotes to:

```
{:let, m, [{:=, m2, [:draft, {:agent, m3, ["Write a draft."]}]}]}
```

**Block-bearing producers MUST be parenthesized.** A `map` carries a `do…end` block. Written
**without** parens — `let :patches = map :f, over: :xs, max: 3 do … end` — the `do…end` attaches to
the **outermost** paren-less call, which is `let`, **not** `map`, so the source quotes to the
**two-arg** shape

```
{:let, meta, [{:=, _, [:patches, {:map, _, [:f, [over: :xs, max: 3]]}]}, [do: body]]}
```

— the `map` call is left **bodyless** and the lane `body` is hijacked onto `let`. That is a
**different** AST than the semantics assume (§C.4.2 requires the `%Map{}` to carry its lane `body`),
so `parse/2` MUST reject it (Rule C.1.5): the two-arg `{:let, _, [_, [do: _]]}` shape is detectable
and rejected with a caller-located hint to add parentheses — never silently repaired by splicing
`[do: body]` back onto the `map` args. **With** parens — `let :patches = (map :f, over: :xs, max: 3
do … end)` — the parenthesized group is a single expression, the `do…end` stays on the `map`, and
the whole statement quotes to the uniform one-arg shape

```
{:let, meta, [{:=, _, [:patches, {:map, mm, [:f, [over: :xs, max: 3], [do: body]]}]}]}
```

so `parse/2` dispatches a well-formed `{:map, …}` (body intact) through the per-form entry (§C intro)
with **zero** reattachment surgery. This makes the surface→AST mapping uniform across **every**
producer kind.

**C.1.2a Inert node struct + addressing + idempotency.**

```
%Workflow.Node.Let{
  address :: address(),
  name    :: atom(),
  body    :: struct()          ; the single producer node (an %Agent{}/%Synthesize{}/%Gather{}/%Map{})
}
```

- **Addressing.** A top-level `let` at position `i` has address `[i]`; its producer `body` is
  re-addressed to `[i, 0]` (a one-child region, like a single-branch `parallel`). The binding
  environment records `name → {:node, [i, 0]}` for an agent/synthesize/gather producer, or
  `name → {:map, [i, 0]}` for a `map` producer (whose lanes are then at `[i, 0, e, 0]`, §C.4.2).
- **Idempotency key.** `let` introduces **no** key of its own. The producer at `[i, 0]` keys
  exactly as any agent (or, for a `map`, each lane keys per §C.4.2): the bound value is **not**
  part of any key (keys stay value-free — `SPEC §1.3` Principle 2).
- **Address stability.** `let` is additive; it never renumbers existing addresses
  (`SPEC §4.2`). A `let` wrapping an agent shifts that agent's address by one level `[i]→[i,0]`
  relative to a bare `agent`, so `let` is **not** transparent sugar for a bare `agent` at the
  same slot; it is its own node kind occupying slot `[i]`.
- **Why a wrapper node, not compile-time erasure (a design choice, not a necessity).** A leaner
  alternative would **erase** `let` entirely — record `name → {:node, [i]}` in `BindingEnv` and
  place the producer directly at slot `[i]`, with no `%Let{}` node and no `[i,0]` addressing
  level. That is coherent (the binding is already a pure compile-time `BindingEnv` fact, and
  `RunLet` is an inert pass-through that commits nothing of its own, §C.1.4). This spec keeps the
  explicit `%Let{}` wrapper anyway, for three reasons beyond address bookkeeping: (1) **Uniform
  positional tree** — every top-level statement lowers to exactly one node struct at its slot, so
  the tree, the `SPEC` snapshot projection, `inspect`, and the status UI enumerate statements
  positionally without a special "this slot produced zero nodes" case that erasure would force.
  (2) **The binding name survives into the inert tree** as `%Let{}.name` — visible, auditable data
  in the `%Tree{}` itself, rather than living only in the compile-time-discarded `BindingEnv`; a
  reader of the lowered tree can see which producer is named what. (3) **Producer-kind uniformity**
  — the wrapper makes the surface→AST→tree mapping identical across every producer kind
  (`agent`/`synthesize`/`gather`/`map`) with zero per-producer addressing rules, where erasure
  would place a `map` producer at `[i]` and its lanes at `[i, e, 0]` (vs. `[i, 0, e, 0]` here),
  re-introducing exactly the addressing asymmetry §C.4.2 avoids. The `%Let{}` is inert data with a
  trivial pass-through `RunLet`, so it costs **nothing** at runtime and escapes fine (§D.1); the
  wrapper is chosen for tree-uniformity and auditability, not because erasure is unsound.

**C.1.3 Validation rules (smallest counter-examples).**

**Rule C.1.1 — Binding name is a literal atom matching `AtomName`.** A `let`/`map` binding name
(and a `map` `ElementName`, §C.4.1) MUST be a literal atom whose printable form matches `AtomName`
(§C.1.1 grammar) — `Letter (Letter | Digit | `_`)*`, the **same** character class as a template
`@assign` (§B.2 `AssignName`). A trailing `?` or `!` — `:ok?`, `:done!`, which **are** valid Elixir
atom literals — does **not** match `AtomName` and is **REJECTED** (a caller-located `Finding` at the
statement). *Adjudication:* the restriction is adopted over widening `AtomName` to admit `[?!]?`,
because `AssignName` (§B.2) — the template `@name` reference surface — has no trailing `?`/`!`
either; widening only the binding name would mint a bound name (`:ok?`) that **no** `~P` template
could ever reference (`<%= @ok? %>` is not derivable, §B.2), an asymmetry two authors would reason
about differently. Keeping both surfaces in one character class makes every bound name
template-referenceable and the restriction decidable.

```counter-example
let x = agent("go")           # `let` name must be a literal atom, written `let :x = …`
```

```counter-example
let :ok? = agent("go")        # trailing `?` — not an AtomName; a bound name must match §B.2's char class — REJECTED
```

**Rule C.1.2 — Producer is a bindable node.** The right-hand side MUST be one
`agent`/`synthesize`/`gather` form (bound as `{:node, addr}`) **or** a `map` (§C.4, bound as
`{:map, addr}` — DF-M4).

```counter-example
let :v = verify("claim", voters: 3)   # a panel is not bindable (its outcome is a fold, §C.1.4)
```

```counter-example
let :v = log("hi")            # `log` commits no result to bind
```

**Rule C.1.3 — Binding names are unique per scope.** Two `let :x` in the same scope collide
(caller-located at the second), mirroring phase-name uniqueness (`SPEC §5.10.1`).

```counter-example
workflow "x" do
  let :d = agent("a")
  let :d = agent("b")         # duplicate binding name `:d` in the same scope — REJECTED
  return(:ok)
end
```

**Rule C.1.4 — `let` is top-level-only (Tier-1 restriction).** A `let` inside a loop body or
a `map` body is rejected. Bindings resolve at `iteration = 0` (`BoundValue`), so a per-loop-
iteration binding is out of Tier-1 scope; keep `let` at top level where iteration is always
`0`.

```counter-example
while_budget reserve: 8 do
  let :d = agent("go")        # `let` is not in the loop body vocabulary — REJECTED
end
```

**Rule C.1.5 — A block-bearing producer MUST be parenthesized.** A `let` whose right-hand side is
a `map` (the only block-bearing producer, §C.1.1) written **without** enclosing parentheses quotes
to the two-arg `{:let, _, [_, [do: _]]}` shape (§C.1.2) — the `do…end` hijacked onto `let`, the
`map` left bodyless. `parse/2` MUST detect this two-arg shape and reject it with a caller-located
finding hinting to add parentheses; it MUST NOT silently splice the block back onto the `map`.

```counter-example
let :x = map :y, over: :ys, max: 3 do   # block-bearing producer un-parenthesized — REJECTED
  agent(~P"<%= @y %>")                   # hint: write `let :x = (map :y, over: :ys, max: 3 do … end)`
end
```

**C.1.4 Execution algorithm.**

```
RunLet(node, run_id, provider, prior, ctx):
  - Let {r} be RunNode(node.body, run_id, provider, prior, ctx).   ; the producer's OWN path — agent (SPEC §6.4) or map (RunMap, §C.4.4)
  - Return {r}.                                                     ; the binding is compile-time; nothing extra committed
```

- A `map` producer runs its ordinary `RunMap` (§C.4.4), committing `map_started`/`map_completed`
  and its lanes; the `{:map, addr}` binding is then a pure `BoundList` fold (§C shared resolution)
  — `let` adds no event of its own for either producer kind (§C.1.5).

- **Determinism / exactly-once.** `RunLet` is a pass-through to the ordinary agent path
  (`SPEC §6.4`): the producer commits one `agent_committed` at `[i, 0]`, keyed and resumable
  exactly as any agent. `let` adds no effect and no non-determinism.
- **Replay-safety.** On resume the producer replays from its journaled `agent_committed`
  (`SPEC §6.4` `ResolveIdempotency`); the binding is re-derived by `BoundValue` folding that
  same event. No process state carries the value.
- **Termination.** `let` runs exactly one node; it does not iterate.

**C.1.5 Journal events.** **None new.** The producer's `agent_committed` (`SPEC §7.2`) is the
binding's sole journal record; `BoundValue` folds it. (A `let_bound{address, name}` marker
would be pure redundancy — the value and address are already journaled — so it is deliberately
omitted, per "journal is the single source of truth, bindings are folds," `SPEC §1.3`
Principle 3.)

**C.1.6 Conformance.**

- **DF-L1.** A `let` MUST bind a literal-atom name to a single node that commits an
  `agent_committed`, and MUST introduce **no** journal event or idempotency key of its own. `let` is
  the **sole** value-binding construct admitted by the narrowed Non-goal **§1.2′** (§A.4(7)): it binds
  a name to an **already-journaled** output only, never a captured, computed, or branched-on runtime
  value.
- **DF-L2.** A bound value MUST be resolvable **only** by a pure fold over the journal
  (`BoundValue`); an implementation MUST NOT cache the value in process state.
- **DF-L3.** Binding names MUST be unique per lexical scope and MUST be top-level only in
  Tier 1; a bound reference MUST resolve at `iteration = 0`.
- **DF-L4.** `parse/2` MUST recognize `let` as the uniform one-arg `{:let, _, [{:=, _, [name,
  producer]}]}` shape (§C.1.2), MUST require `name` to be an atom literal, and MUST dispatch
  `producer` through the ordinary node path so every producer kind reuses its existing clause
  unchanged. It MUST reject the two-arg `{:let, _, [_, [do: _]]}` shape (an un-parenthesized
  block-bearing producer) as a caller-located compile error (Rule C.1.5), never repair it by
  reattaching the block.

---

### C.2 Prompt injection — a prompt that references a bound value  ·  Verdict: ADOPT

**Purpose.** Let an `agent`'s prompt be a `%Template{}` (§B) that renders in-scope bindings,
so a downstream agent acts on an upstream journaled result. This is the core dataflow edge.

**C.2.1 Surface grammar.** Extend `AgentStmt` (`SPEC §3.2`) so the prompt may be a template:

```
AgentStmt : `agent` `(` Prompt AgentOpts? `)`
Prompt :
  - StringLiteral            ; the existing literal form (SPEC §3.2) — unchanged
  - Template                 ; a ~P template (§B.2) — admissible ONLY when this AgentStmt is top-level or a map lane (Rule C.2.4)
```

**The grammar admits `Template` in every `AgentStmt`; validation narrows it.** `AgentStmt` is one
nonterminal shared by top-level agents, `map` lanes, and the four nested positions (`parallel`
branches, `pipeline` stages, `fan_out` bodies, loop bodies), so the grammar production above admits a
`Template` prompt syntactically everywhere an agent may appear. **Rule C.2.4** (an active validation
guard) then rejects a `Template` prompt in the four nested positions caller-located — leaving it
admissible **only** in a top-level or `map`-lane agent. This grammar-admits / validation-narrows split
is the same discipline `SPEC` uses for its other whitelist rules; the position restriction lives in
Rule C.2.4 and the §C-intro scope decision (F.29), not in this production.

```elixir
agent(~P"""
Improve this draft, addressing every weakness:

<%= @draft %>
""", schema: …)
```

**C.2.2 Inert node struct + addressing + idempotency.** The `%Agent{}` struct (`SPEC §4.3`)
is widened so `prompt` may hold a `%Template{}` **plus** its resolved bindings:

```
%Workflow.Node.Agent{
  address  :: address(),
  prompt   :: String.t() | %Template{},     ; widened from String.t()
  bindings :: %{atom() => BindingRef} | %{},  ; compile-time-resolved; %{} for a literal prompt
  schema   :: map() | nil,
  retries  :: non_neg_integer()              ; default 2
}
```

- `bindings` maps each assign in `template.assigns` to the `BindingRef` it resolved to **at
  compile time** (an address = a compile-time constant, so `bindings` is escapable, Principle
  7). It is `%{}` for the existing literal-prompt form, which therefore behaves **identically**
  to today (perfect backward compatibility).
- **How `bindings` is materialized (the construction step, normative).** When the `agent` clause
  `node/4` builds this `%Agent{}` under the threaded `binding_env` (§C intro), it constructs
  `bindings` by folding `template.assigns`: for each atom `a`, `bindings[a] = binding_env[a]`, raising
  the caller-located finding (Rule B.5.4/B.5.5) at the `agent` form if `a` is absent or
  forward-referenced. A literal-string prompt has no assigns, so `bindings` is `%{}`. The resulting
  `%{atom => BindingRef}` map holds only atoms and addresses (lists of non-negative integers, `SPEC
  §4.2`) — pure compile-time constants with **no** closure — so it is `Macro.escape`-able and the whole
  `%Tree{}` still escapes to a compile-time constant (`workflow/2` shell, §D.1). The **identical**
  construction step materializes `%Gather{}`'s (§C.5.2) and `%Emit{}`'s (§C.7.2) `bindings` from their
  own clauses' `binding_env`; a `map` lane agent's `bindings` is materialized the same way under the
  element-extended env (§C.4.2).
- **Addressing / idempotency: unchanged.** The agent keys exactly as `SPEC §6.5`:
  `(run_id, address, iteration, attempt)`. The **rendered** prompt is **not** part of the key
  (value-free keys, Principle 2); it is journaled in `agent_committed.prompt` (`SPEC §7.2`),
  which is exactly where a `verify`/`judge`-composed prompt is already journaled (§B.6, §D.2).

**C.2.3 Validation rules (smallest counter-examples).**

**Rule C.2.1 — A template prompt's assigns all resolve (name resolution + define-before-use).**
Every atom in `template.assigns` MUST be in `BindingEnv` at this statement (Rules B.5.4,
B.5.5). Otherwise a caller-located finding.

```counter-example
workflow "x" do
  agent(~P"Improve <%= @draft %>")   # no preceding `let :draft` — unbound assign — REJECTED
  return(:ok)
end
```

**Rule C.2.2 — Interpolation is still rejected (unchanged from SPEC §2.2).** A literal-string
prompt with `#{…}` is a call form, not a binary, and is rejected exactly as today. Injection
does **not** open interpolation; the **only** dynamic prompt form is a `%Template{}`.

Note that inside a `~P` template `#{…}` is **not** interpolation and is **not** rejected: because
`~P` is an uppercase sigil (§B.2), `#{…}` is inert literal text — the characters flow verbatim
through the scanner into a `{:text, …}` segment (§B.4) and then through `RenderText` unchanged
(§B.6). So `~P"has #{x} y"` renders the literal string `has #{x} y`; the `#{x}` is never a spliced
value and never a compile error. (The rejected form above is a **literal string** `"…#{…}…"`,
which lowers to an interpolation AST — a `{:<<>>, …}` with an expression segment — not a binary.)

```counter-example
agent("Improve #{draft}")     # Elixir interpolation in a literal string — still a compile error (SPEC §2.2)
```

**Rule C.2.3 — Options unchanged.** `schema:`/`retries:` rules (`SPEC §5.3`) apply verbatim to
a template-prompt agent.

**Rule C.2.4 — Template positions are a closed whitelist (panels stay literal-only; nested agents
reject templates).** A `%Template{}` is admissible in **exactly four** positions: a **top-level**
`agent` prompt (§C.2), a **`map`-lane** `agent` prompt (§C.4.2), a **top-level** `gather` template
(§C.5), and a **top-level** `emit` template (§C.7). A `~P` template in **any other** position is
**rejected** caller-located. There are two rejection families:

1. **Observational / literal-only positions** — a `verify`/`judge` subject or candidate, a `return`
   value, a `phase`/`log` argument. These stay compile-time-literal-only (base `SPEC §5.5`, `SPEC
   §5.3`), keeping panels observational (Principle 8, §D.5): a template widens value *input* to agents
   that act on it, never to the observational panels that judge it.
2. **Nested agent positions** — an `agent` prompt inside a `parallel` branch, a `pipeline` stage, a
   `fan_out` body, or a loop body. These are rejected by the adjudicated scope decision (§C intro,
   F.29): template prompts are admissible only in a **top-level or `map`-lane** agent, so the value
   edges of the dataflow graph stay lexically obvious and the render `lane` stays `{nil, %{index: e}}`.

**Both families MUST be enforced by an ACTIVE guard (normative), not left to `to_text/1`.** Each
rejecting position's `parse/2` clause (for family 1) and each of the four nested folds (for family 2 —
`agent_branches`, `pipeline_stages`, `agent_lane`, `body_node`) MUST match a `{:sigil_P, meta, _}`
argument in the prompt/subject/candidate/value position and emit a caller-located `Finding` at the
sigil's `meta`. *Why an explicit guard even though the base gates already reject `~P`:* the base
literal/`is_binary` gates **already** reject a `~P` tuple, but with a **generic** message — `verify`'s
`verify_subject` (`compiler.ex:753`), `judge`'s `judge_candidates` (`L854`), `synthesize`'s inputs
(`L278`), and `return` (`L164`) all gate on `Macro.quoted_literal?` first, and a `{:sigil_P, meta,
[...]}` is a **call** tuple, not a literal, so it is rejected outright with "… must be a literal";
`log`/`phase`/`agent` require `is_binary` in the clause head (`L143`–`L159`), so a sigil tuple falls to
the invalid-arguments clause (`L320`/`L288`). **No base position stringifies `~P` through `to_text/1`'s
`inspect(other)` fall-through** — that fall-through is never reached with a sigil tuple in any base
position. The active guard therefore exists to emit a **precise** diagnostic (*"templates are not
admissible here"* / *"…not in a `parallel` branch"*) in place of the base clauses' generic "must be a
literal", **not** to prevent a "silent junk" failure mode that does not actually occur. Keep the guard
as belt-and-suspenders for the message; do not justify it with a stringification hazard a reviewer will
find does not hold.

```counter-example
let :x = agent("draft")
verify(~P"Is <%= @x %> sound?", voters: 3)   # family 1 — a template subject on a panel — REJECTED (panels are literal-only)
```

```counter-example
let :x = agent("draft")
parallel([agent(~P"Improve <%= @x %>")])     # family 2 — a template prompt in a `parallel` branch — REJECTED (top-level / map-lane agents only, F.29)
```

**C.2.4 Execution algorithm.** `RunAgent` (`SPEC §6.4`) is unchanged except that the prompt
handed to `CallProvider` is rendered when it is a template:

```
EffectivePrompt(node, run_id, lane):
  - If node.prompt is a binary: Return node.prompt.                        ; literal — unchanged
  - Return RenderTemplate(node.prompt, run_id, node.bindings, lane).       ; §B.6; lane is nil at top level, %{index: e} in a map lane
```

`EffectivePrompt` takes an explicit `lane` argument — `nil` for a top-level agent, `%{index: e}`
for the agent of a `map` lane `e` (§C.4.4). A top-level `agent` never runs in a `map` lane (a lane
runs through `BuildAgent`/`RunLane`, not `RunAgent`), so **`RunAgent`/`CommitAttempt` (`SPEC §6.4`)
call `CallProvider(provider, EffectivePrompt(node, run_id, nil), node.schema, key)`** in place of
`CallProvider(…, node.prompt, …)`; and the map-lane path `BuildAgent`/`RunLane`, extended with a
`lane` parameter (§C.4.4), calls **`EffectivePrompt(node, run_id, lane)`** so a lane's `@element`
render is a deterministic function of the journaled `over` list and the lane index. Everything
else — idempotency resolution, retry-then-fail, incremental commit — is `SPEC §6.4` verbatim.
Passing a rendered template as `prompt` is admitted by the amended provider port **§6.4.1′**
(§A.4): the string handed to `CallProvider` is a fully-materialized `String.t()` —
**materialized by a pure journal fold before the call**, then journaled verbatim in
`agent_committed.prompt` **at commit** (with the provider `result`, `SPEC §6.4`), and **never
re-rendered on replay** (DF-P3). There is no prompt-only pre-call event (§C.2.5). Turn
independence is preserved and `CallProvider` still receives no conversation state or live
reference. **The value committed to the `prompt` payload of every prompt-bearing agent event is the
materialized `EffectivePrompt` *string*, not the inert `%Template{}` struct that `node.prompt`
holds:** for a template-prompt agent the commit path stores `EffectivePrompt(node, run_id, lane)`
in place of the base "store `node.prompt` verbatim" rule (dataflow-ground §1) in **both**
`agent_committed.prompt` **and** each `agent_attempt_rejected.prompt` (`SPEC §7.2`) it writes on a
fail-closed retry — this is the amended **§6.4-commit′ / §7.2′ / §7.2-rejected′ / §7.3′** clause
(§A.4(6)). (`agent_failed` has no `prompt` key, `SPEC §7.2`, so it is untouched.) `EffectivePrompt`
is byte-identical across a node's attempts (its producers committed before this node ran, §B.5.5,
and are immutable), so a rejected attempt and the eventual commit journal the **same** prompt
string. Consequently the `SPEC §7.3` `agents` projection's `prompt` field carries the rendered
binary, never the inert struct, and both replay (DF-P3) and audit read a real, already-rendered
prompt string rather than an inert `%Template{}`.

- **Determinism.** `EffectivePrompt` is `RenderTemplate` (§B.6), a pure fold over the
  immutable journal; two implementations render byte-identical prompts for binary bindings
  (and identical-within-the-Elixir-embedding prompts otherwise — §B.7 T3, §D.2).
- **Exactly-once.** The key is unchanged and value-free; the rendered prompt never perturbs
  it. A resumed agent that already committed replays its journaled prompt verbatim
  (`agent_committed.prompt`) and is **never** re-rendered (`SPEC §6.4` replay branch). An
  uncommitted agent re-renders from the same journaled producer result → identical bytes
  (§D.2).
- **Replay-safety.** The producer's `agent_committed` is committed **before** the consumer
  runs (define-before-use, §B.5.5; top-level sequential order, `SPEC §6.11`), so `BoundValue`
  always finds it (§D.4).

**C.2.5 Journal events.** **None new.** The rendered prompt is captured in the consuming
agent's existing `agent_committed.prompt` (`SPEC §7.2`), which is already observable output.
This is the key economy: injection reuses the existing agent event wholesale.

**C.2.6 Conformance.**

- **DF-P1.** An `agent` prompt MUST be either a literal string (unchanged) or an inert
  `%Template{}` over in-scope bindings, rendered per the amended provider port **§6.4.1′**
  (§A.4); interpolation and computed prompts remain rejected. A `%Template{}` prompt is admissible
  **only** when the `agent` is **top-level or a `map` lane**; an implementation MUST actively reject
  (caller-located) a `%Template{}` prompt on an `agent` nested in a `parallel` branch, a `pipeline`
  stage, a `fan_out` body, or a loop body (Rule C.2.4, §C-intro scope decision, F.29).
- **DF-P2.** The rendered prompt MUST be a deterministic `RenderTemplate` fold over the journal,
  materialized before the call and journaled verbatim **at commit** in the `prompt` payload of
  every prompt-bearing agent event (there is no prompt-only pre-call event); it MUST NOT enter the
  idempotency key. The value committed to **`agent_committed.prompt` AND to each
  `agent_attempt_rejected.prompt`** (`SPEC §7.2`) MUST be the **materialized `EffectivePrompt`
  string** (§C.2.4), **not** the inert `%Template{}` held in `node.prompt`; a conforming commit path
  MUST override the base "store `node.prompt` verbatim" rule (dataflow-ground §1) per the amended
  **§6.4-commit′ / §7.2′ / §7.2-rejected′ / §7.3′** clause (§A.4(6)) for a template-prompt agent, on
  both events (`agent_failed` has no `prompt` key and is untouched). Because `EffectivePrompt` is
  byte-identical across a node's attempts (§B.5.5), a rejected attempt and the eventual commit
  journal the same prompt string, so the `SPEC §7.3` `agents` projection, replay (DF-P3), and audit
  all read a rendered prompt string on every prompt-bearing event.
- **DF-P3.** A resumed, already-committed agent MUST replay its journaled prompt and MUST NOT
  re-render.

---

### C.3 Logic-less templates  ·  Verdict: ADOPT (subsumed by §B)

Fully specified in **§B**. The `%Template{}` struct (§B.3), its compile-time lowering (§B.4),
its validation (§B.5), and `RenderTemplate` (§B.6) are the whole idiom. No additional node
struct, address, or event: a template is inert data embedded in a consuming node (§C.2, §C.7),
with no address (§B.3), exactly like `%BudgetSlices{}`. Its conformance is §B.7 (T1–T4).

---

### C.4 `map` — node-per-element over a bounded collection  ·  Verdict: DEFER

**Purpose.** Run an agent (or a short agent lane) **once per element** of a bound collection,
each lane rendering its own element. This is the bounded fan-out over data. It is the **only**
new construct with a runtime-decided width, and it is bounded by a compile-time cap
(§A.3.3, §D.3).

**C.4.1 Surface grammar.**

```
MapStmt : `map` ElementName `,` MapOpts `do` AgentLane `end`
ElementName : BindingRefAtom       ; the atom-literal token `:name` (§C.1.1 BindingRefAtom) — the per-element binding name; NO separate `:` terminal (that would denote `map ::name`)
MapOpts : MapOpt (`,` MapOpt)*     ; an UNORDERED keyword list — keys read by Keyword.fetch (SPEC §5.10.4)
MapOpt :
  - `over:` BindingRefAtom         ; REQUIRED — the bound collection; `over:` is the keyword-list KEY token, BindingRefAtom is the atom-literal value `:name` (NO stray `:` between them — that would denote `over: ::name`)
  - `max:` IntegerLiteral          ; REQUIRED — positive-integer literal structural cap
  - `max_concurrency:` IntegerLiteral   ; OPTIONAL
AgentLane : AgentStmt          ; EXACTLY ONE agent per lane (Tier-1); injects @ElementName (and any enclosing binding)
```

`MapOpts` is a keyword list validated by **subset/membership**, not by position: the required
keys `over:` and `max:` MUST both be present and the optional key `max_concurrency:` MAY be, in
**any order** (`SPEC §5.10.4`, matching every other combinator's option grammar). Duplicate keys
are handled per `SPEC §5.10.4`. Thus `map :x, max: 10, over: :items do … end` and
`map :x, over: :items, max: 10 do … end` are equivalent.

```elixir
let :findings = agent("List the code's problems as a JSON array of {issue, fix} objects.",
  schema: %{"type" => "array"})
let :patches = (map :finding, over: :findings, max: 20 do   # parens REQUIRED: block-bearing producer (§C.1.2)
  agent(~P"""
  Fix exactly this one finding, returning a patch:

  <%= @finding %>
  """)
end)
# `@patches` now names the ORDERED LIST of the lanes' patches (DF-M4) — a `gather`/`emit`, or
# another `map`'s `over:`, can fold it.
```

- `over: :findings` names a **`let`-bound collection** — either a producer whose journaled result
  is a list **or** another `map`'s binding (its ordered lane-result List, §C.1.1/DF-M4), resolved
  at runtime through `ResolveRef` (§C.4.4).
- `max:` is a **REQUIRED positive-integer literal** — the structural cap.
- `max_concurrency:` is optional (`SPEC §3.3` semantics).
- Inside the body, `@finding` (the `ElementName`) is bound to the current lane's element, and the
  lane's `agent` prompt MUST reference it (Rule C.4.6) — a lane that ignores its element is
  rejected. The `ElementName` MUST NOT collide with an enclosing binding (Rule C.4.5).
- The lane is **exactly one `agent`** in Tier 1 (`AgentLane : AgentStmt`). A multi-stage lane is
  deliberately **not** admitted, for two reasons: (a) `let` is forbidden in a `map` body (Rule
  C.1.4/C.4.3), so a second stage could reference **no** first-stage output — the stages would be
  mutually blind; and (b) a `map` binds **only** its lanes' terminal results (DF-M4), so any
  non-terminal stage's output would itself "flow nowhere," re-creating inside the lane the exact
  wall (§A.1) this proposal dissolves. A single-stage lane is therefore the only Tier-1-consistent
  shape; **multi-stage map lanes are deferred to Tier 2** (§E). Consequently each lane's terminal
  result is simply its single agent at `address ++ [e, 0]`, and the map's bound value is the
  ordered List of those (`BoundList`, DF-M4).

**C.4.2 Inert node struct + addressing + idempotency.**

```
%Workflow.Node.Map{
  address      :: address(),
  element_name :: atom(),
  over         :: BindingRef,        ; compile-time BindingRef of the bound collection — {:node, addr} (a list-valued producer) OR {:map, addr} (another map's ordered lane-result List, §C.1.1/DF-M4); resolved via ResolveRef, never BoundValue directly (§C.4.4)
  max          :: pos_integer(),     ; the structural cap
  body         :: [Agent.t()],       ; a ONE-element lane (single agent; placeholder address, re-addressed per lane)
  max_concurrency :: pos_integer() | nil
}
```

- **Addressing.** Like `fan_out` (`SPEC §4.4`, §6.10), the body is stored with a placeholder
  address and **re-addressed per lane at runtime**: the single lane agent for element `e` is at
  `address ++ [e, 0]` (the `pipeline`/`fan_out` two-index layout, `SPEC §4.2`, with the second
  index fixed at stage `0` because a Tier-1 lane is single-stage — §C.4.1). The width `e ∈
  0..W-1` is runtime-decided (below).
- **Idempotency.** Each lane keys `(run_id, address ++ [e, 0], iteration=0, attempt)` — a
  distinct stable address per element (`SPEC §6.5`). The element **value** is **not** in the key;
  it is rendered into the lane's prompt (journaled in `agent_committed.prompt`) but the key stays
  value-free (Principle 2). This is exactly the dataflow-ground §4 requirement: each mapped lane
  at a distinct stable sub-address, and "the value it binds must NOT enter the key."
- **Element binding.** When the `map` clause `node/4` builds this `%Map{}` (under the threaded
  `binding_env`, §C intro), it parses its single lane `agent` under the **element-extended** env
  `Map.put(binding_env, element_name, {:element, over})` — a **disjoint** extension (an `ElementName`
  colliding with an enclosing binding is rejected, Rule C.4.5, so no shadowing ever occurs) — so the
  lane agent's own `node/4` resolves `@element` against that extended env and populates its `bindings`
  there, at lane-construction time (§C.2.2 construction step). This is precisely the one binding a
  top-level `build/5` fold can **never** supply — `element_name` is in scope only inside the map body —
  which is why the per-form entry, not `build/5`, must carry `binding_env` (§C intro, F.25). At runtime
  `ResolveRef({:element, over}, run_id, %{index: e})` = `Index(BoundValue(over), e)` (§C shared
  resolution), so `@finding` in lane `e` renders the `e`-th element of the journaled collection — a
  deterministic project-of-a-fold. The lane's prompt MUST reference this `ElementName` (Rule C.4.6).

**C.4.3 Validation rules (smallest counter-examples).**

**Rule C.4.1 — `over:` names an in-scope, list-valued binding.** `over:` MUST name a binding in
`BindingEnv` at this statement. It MAY be a `{:node}` producer (an `agent`/`synthesize`/`gather`
whose journaled result is a list) **or** a `{:map}` (another `map`'s ordered lane-result List,
§C.1.1/DF-M4). The collection is resolved at runtime through `ResolveRef` (§C shared resolution,
called by `DecideMapWidth`, §C.4.4) — a `{:node}` over via `BoundValue`, a `{:map}` over via
`BoundList` — **never** through `BoundValue` directly (that is the defect DF-M5 closes: a `{:map}`
address carries no `agent_committed`, so `BoundValue` would raise `BindingUnresolved`). List-ness is
not compile-time-decidable (a `schema` is advisory, a schemaless producer is shapeless), so a
resolved collection that is not a list fails closed at runtime (`MapOverNotAList`, §C.4.4, DF-M5).
`over:` is a **REQUIRED** key (§C.4.1 `MapOpt`): a `map` with no `over:` is rejected exactly as a
`map` with no `max:` (Rule C.4.2), so the required-key set `{over:, max:}` is fully witnessed by a
counter-example for **each** missing key (matching the `SPEC §5.10.4` exact-key-set discipline).

```counter-example
map :x, over: :ghost, max: 10 do
  agent(~P"do <%= @x %>")     # `over: :ghost` names no preceding `let`/`map` — REJECTED
end
```

```counter-example
map :x, max: 10 do            # `over:` is a REQUIRED key — missing — REJECTED
  agent(~P"do <%= @x %>")
end
```

**Rule C.4.2 — `max:` REQUIRED, positive-integer literal.** This is the bounded-termination
gate (§A.3.3). A missing, non-literal, or `<= 0` `max:` is rejected — an **unbounded map is
not expressible**.

```counter-example
map :x, over: :items do        # no `max:` — an unbounded map is forbidden — REJECTED
  agent(~P"do <%= @x %>")
end
```

```counter-example
map :x, over: :items, max: length(items) do   # `max:` must be a literal integer, never computed
  agent(~P"do <%= @x %>")
end
```

**Rule C.4.3 — Body is exactly one agent.** A Tier-1 map lane is a single `agent` (§C.4.1):
`AgentLane : AgentStmt`. No `map`/loop/panel/`return`/`collect`/`let`/`log` in a map body (no
nesting of regions, no intra-lane dataflow, in Tier 1), and no second agent stage.

```counter-example
map :x, over: :items, max: 10 do
  log("x")                    # a map lane must be exactly one `agent` turn — REJECTED
end
```

```counter-example
map :x, over: :items, max: 10 do
  agent(~P"draft <%= @x %>")
  agent("critique the draft")   # a second lane stage — REJECTED in Tier 1 (single-stage lanes only, §C.4.1)
end
```

**Rule C.4.4 — `map` is top-level-only.** Not in the loop body vocabulary (`SPEC §5.7.6`),
mirroring `let` (Rule C.1.4). Bindings resolve at `iteration = 0`.

```counter-example
while_budget reserve: 8 do
  map :x, over: :items, max: 10 do agent(~P"<%= @x %>") end   # not in body vocabulary — REJECTED
end
```

**Rule C.4.5 — A `map` ElementName MUST NOT shadow an in-scope binding.** The `ElementName` enters
the map body's `BindingEnv` (§C.4.2). To carry Rule C.1.3's "unique name per scope" discipline
across the nested map-body scope, an `ElementName` that collides with **any** binding in scope at
the `map` statement is rejected (caller-located). This makes element resolution unambiguous — no
author (and no implementer) must reason about element-vs-enclosing shadowing, and the body's
`BindingEnv` extension is always **disjoint**. (The permissive alternative — allow the collision
and pin "element wins" as an ordered-map overwrite — was declined for author clarity and symmetry
with C.1.3; see F.17.)

```counter-example
let :x = agent("draft")
map :x, over: :ys, max: 3 do          # element name `:x` shadows the in-scope binding `:x` — REJECTED
  agent(~P"<%= @x %>")
end
```

**Rule C.4.6 — A `map` lane MUST use its element.** The lane `agent`'s prompt MUST be a
`%Template{}` (§B.3) whose `assigns` include the `ElementName`. A literal-string lane prompt, or a
template that references only enclosing bindings and never `@ElementName`, renders a **byte-identical
prompt in every lane** — the element flows nowhere, re-creating §A.1's "a fan_out lane is a
byte-identical replica" wall inside the lane (the same no-dangling reason §F.10 mandates
single-stage lanes). Such a lane is rejected (caller-located). An author who genuinely wants N
identical turns wants `fan_out` (`SPEC §3.3`), not `map`.

```counter-example
map :x, over: :ys, max: 3 do
  agent("summarize the input")   # lane prompt ignores its element `@x` — every lane identical — REJECTED
end
```

**C.4.4 Execution algorithm.**

```
RunMap(node, run_id, provider, prior, ctx):
  - Let {width, seq} be DecideMapWidth(node, run_id, prior, ctx.seq).
  - Let {branches} be the ordered List [ {Rebase(node.body, node.address ++ [e]), %{index: e}}
      for each {e} from 0 to {width} - 1 inclusive ]; if {width} is 0, {branches} is [].
      ; each element is a PAIR {lane_body, lane}: lane_body is the rebased lane body; lane is the inert %{index: e} data (never a closure) that carries the lane index e into the worker.
  - Let {cap} be node.max_concurrency or max(width, 1).
  - Let {results} be RunConcurrently(branches, cap, fn {lane_body, lane} ->
      RunLane(lane_body, run_id, provider, prior, lane) end).  ; base RunConcurrently (SPEC §6.9) is UNCHANGED and 1-arity: it applies fun to each element (here a PAIR) in input order; the 1-arity worker destructures {lane_body, lane}. lane = %{index: e} then threads RunLane→BuildAgent→EffectivePrompt (§6.9′) so the single lane agent renders @element
  - Let {r} be CommitLanes(results, run_id, seq).              ; SPEC §6.9, element order
  - If {r} is {:ok, seq'}:
    - Return {:cont, ctx with seq = CommitMarker(map_completed, node, prior, seq')}.
  - If {r} is {:halt, seq', reason}: Return {:halt, ctx with seq = seq', reason}.

DecideMapWidth(node, run_id, prior, seq):
  - If a `map_started` for node.address is in {prior}:                     ; replay verbatim
    - Return {its payload.width, seq}.
  - Let {collection} be ResolveRef(node.over, run_id, nil).                ; §C shared resolution — {:node}→BoundValue, {:map}→BoundList; NEVER BoundValue directly (DF-M5). lane is nil: `map` is top-level (Rule C.4.4), so `over:` is a top-level `{:node}`/`{:map}` binding, and neither resolver reads the lane.
  - If {collection} is not a list: Raise MapOverNotAList(node.address).    ; fail closed (REQUIRED — DF-M5)
  - Let {observed} be length({collection}).
  - Let {width} be min({observed}, node.max).                              ; the structural cap
  - Let {seq'} be Commit Event.map_started(node.address, node.over, observed, width, node.max) at {seq}, then seq + 1.   ; over = node.over VERBATIM (a BindingRef tuple, §C.4.5), never a bare address
  - Return {width, seq'}.
```

- **Lane provenance (how the index reaches the worker — normative, pinned).** Base
  `RunConcurrently(inputs, cap, fun)` (`SPEC §6.9`, §6.9 verbatim) applies `fun` as a **1-arity**
  worker to each element of `inputs` in input order; every base caller
  (`parallel`/`pipeline`/`fan_out`/`vote`/`score`) passes a 1-arity `fn input -> …`. `RunMap`
  **does not perturb** that shipped algorithm: it makes `branches` an ordered **List of pairs**
  `{lane_body, lane}` (one per lane, `lane = %{index: e}`) and passes the still-**1-arity** worker
  `fn {lane_body, lane} -> RunLane(lane_body, run_id, provider, prior, lane) end`, which
  destructures the pair. The lane's provenance into `EffectivePrompt` is therefore fully defined:
  it originates in the `branches` pair `RunMap` builds, is carried verbatim by base
  `RunConcurrently` as the worker's single argument, destructured in the worker head, and threaded
  `RunLane → BuildAgent → EffectivePrompt` (§6.9′). Input-order commit (`SPEC §6.9`) already fixes
  the observable order (DF-M2), so this is a completeness pin with **zero** behavior change and
  **zero** change to base `RunConcurrently`. (An Elixir implementation MAY realize this idiomatically
  as `Task.async_stream` over the pre-zipped `[{lane_body, lane}]` List — e.g. built with
  `Stream.with_index` — provided input-order commit is preserved; that is observably equivalent,
  `SPEC §8`.)
- **Lane threading (the map-specific execution detail).** A `map` lane is the **only** lane
  whose prompt depends on a runtime quantity — the lane index `e` — so the index MUST reach the
  render. `SPEC §6.9`'s lane runners `RunLane(stages, run_id, provider, prior)` and
  `BuildAgent(node, run_id, provider, prior)` are extended to **§6.9′** with one trailing
  argument, `lane`: `RunLane(stages, run_id, provider, prior, lane)` and
  `BuildAgent(node, run_id, provider, prior, lane)`. `RunLane` passes its `lane` unchanged to
  every `BuildAgent` it calls; `BuildAgent`, wherever it renders a prompt for `CallProvider`,
  calls `EffectivePrompt(node, run_id, lane)` (§C.2.4) with that `lane` — so lane `e`'s agent
  renders `@element = ResolveRef({:element, over}, run_id, %{index: e}) = Index(BoundValue(over),
  e)` (§C shared resolution), a deterministic project-of-a-fold. This extension is **conservative
  for every base-SPEC caller**: `parallel`/`pipeline`/`fan_out` (`SPEC §6.9`–§6.10) pass
  `lane = nil`, and `EffectivePrompt(node, run_id, nil)` renders literal prompts byte-for-byte as
  before (their per-lane data is baked into compile-time addresses, `SPEC §4.4`), so no shipped
  behavior changes. Only a `map` lane passes a non-`nil` `lane`. The `lane` is plain inert data
  (`%{index: e}`, a map — never a closure), so threading it preserves closure-freedom (§D.1)
  entirely.
- **Bounded termination (§D.3).** `width = min(observed, max) <= max`, a compile-time
  constant, so the region has **at most `max` lanes**, each a finite agent lane. Even a
  producer that returns a 10,000-element list yields at most `max` lanes; elements past `max`
  are **not** processed. This is the identical guarantee `max_iterations` gives loops
  (`SPEC §1.3` Principle 5): a structural cap bounds the fan-out regardless of runtime data.
- **Determinism / replay-safety.** `width` is journaled in `map_started.width` and **replayed
  verbatim** on resume (the `fan_out_started.width` precedent, dataflow-ground §4), so resume
  never recomputes the width against a since-changed value — though, unlike `fan_out` (whose
  width tracks the live ledger), a map's `over` collection is an **immutable** journaled
  result, so re-derivation would give the same answer anyway; journaling it keeps the fold
  uniform and auditable. Each lane's element is a deterministic `Index(BoundValue(over), e)`.
- **Exactly-once.** Lanes commit via `CommitLanes` (`SPEC §6.9`) in element order, through
  resume-aware `BuildAgent`, so a resumed map re-commits **nothing** already journaled and
  continues at the first un-journaled lane stage (`SPEC §6.9`, C4).
- **Fail-closed.** A non-list `over` is a run-time raise (a run crash, like `fan_out` on an
  unbounded run, `SPEC §6.10`); a schema-backed lane agent that fails validation fails the
  region exactly as any concurrent region (`SPEC §6.1`).

**C.4.5 Journal events.** **Two new** (additive, `SPEC §7.1`):

| `type` | Payload keys |
|---|---|
| `:map_started` | `address, over, observed_length, width, max` |
| `:map_completed` | `address` |

`map_started` records the width decision (replayed on resume) and the observed collection
length (audit: how many elements the producer emitted vs. how many the cap admitted). **On replay
the entire `map_started` payload — including `observed_length` — is read back verbatim and never
recomputed:** `DecideMapWidth` (§C.4.4) returns the journaled `width` from the existing event and
does **not** re-fold `over`, so `observed_length` sits on the **same replay-verbatim footing as
`width`**. An implementer MUST NOT re-derive `observed_length` from `length(ResolveRef(over))` on
resume — it is an audit field, not observable in the terminal result, and re-deriving it would risk
a mismatch were `over` ever widened to a mutable source. Both are
positional markers keyed by `(type, address)` and committed through `CommitMarker`
(`SPEC §6.3`) — at most once per address, so a resumed region reproduces the crash-free
journal (C4). `map_started.over` is the collection's **`BindingRef`** — **`node.over` verbatim**,
a `{:node, addr}` or `{:map, addr}` tuple (§C.4.2, inert and serializable) — **not** a bare
address; it is recorded for traceability (an implementation MUST store the whole `BindingRef`
tuple, so two implementations do not diverge by one storing `[i,0]` and the other
`{:map,[i,0]}`). Lane agents commit ordinary `agent_committed`/`agent_attempt_rejected`/
`agent_failed` events at `address ++ [e, 0]`. A `let`-bound map's value (DF-M4) is the ordered
List of those lanes' `agent_committed.result`s, folded by `BoundList` (§C shared resolution) from
these **existing** events plus `map_started.width` — **no** third event is added.

**C.4.6 Conformance.**

- **DF-M1.** A `map`'s `max:` MUST be a positive-integer literal; an unbounded map MUST be
  unexpressible. The region MUST run at most `max` lanes; `width = min(observed_length, max)`.
- **DF-M2.** The width decision MUST be journaled in `map_started.width` and replayed verbatim
  on resume; each lane's element MUST be `Index(BoundValue(over), e)`, a deterministic fold. The
  runtime lane index `e` MUST be threaded to the lane agent's render: the lane runners MUST carry
  the lane (`RunLane`/`BuildAgent` extended to §6.9′ with a `lane` argument, §C.4.4) and MUST call
  `EffectivePrompt(node, run_id, %{index: e})` for lane `e`, so lane `e` renders the `e`-th element
  and no other. The lane's provenance MUST be the one pinned in §C.4.4: `RunMap`'s `branches` is an
  ordered List of pairs `{lane_body, %{index: e}}` and the worker passed to base `RunConcurrently`
  (`SPEC §6.9`, **unchanged**, 1-arity) is `fn {lane_body, lane} -> RunLane(…, lane) end`; an
  implementation MUST NOT redefine base `RunConcurrently` to a 2-arity worker to carry the index. A
  base-SPEC lane (`parallel`/`pipeline`/`fan_out`) MUST pass `lane = nil` and MUST render
  byte-for-byte as before.
- **DF-M3.** Each lane MUST be a single agent keyed on `(run_id, address ++ [e, 0], iteration,
  attempt)`; the element value MUST NOT enter any key. A non-list `over` MUST fail closed. A
  multi-stage lane MUST be rejected in Tier 1 (§C.4.1). The lane's `agent` prompt MUST be a
  `%Template{}` whose `assigns` include the `ElementName` (Rule C.4.6), and the `ElementName` MUST
  NOT shadow an in-scope binding (Rule C.4.5); both `over:` and `max:` MUST be present (required
  keys, Rules C.4.1/C.4.2).
- **DF-M4.** A `let`-bound `map` MUST resolve to the **ordered List** of its lanes' terminal
  `agent_committed.result` values, folded (`BoundList`, §C shared resolution) in **strict
  ascending lane order** `0..W-1` where `W` is the journaled `map_started.width`; element order is
  observable and MUST equal ascending lane index. A width-0 map MUST bind `[]`. An **unbound**
  `map` is fire-and-forget and its lane outputs are unreferenceable. DF-M4 is a resolution rule
  only: it MUST add **no** journal event (the two events of §C.4.5 are unchanged).
- **DF-M5.** `over:` MAY name **any** list-valued binding — a `{:node}` producer whose journaled
  result is a list **or** a `{:map}` (its ordered lane-result List, DF-M4, enabling `map`-over-`map`).
  `DecideMapWidth` (§C.4.4) MUST resolve the collection through `ResolveRef` (§C shared resolution) —
  `{:node}`→`BoundValue`, `{:map}`→`BoundList` — and MUST NOT resolve it through `BoundValue`
  directly (a `{:map}` address carries no `agent_committed`, so a direct `BoundValue` would raise
  `BindingUnresolved` on a validated tree, contradicting §D.4). Because list-ness is knowable **only**
  at runtime (a `schema` is advisory to the provider and a schemaless producer has no declared shape),
  the `MapOverNotAList` fail-closed raise (§C.4.4) is **REQUIRED** and MUST NOT be dropped on the
  assumption that a `{"type":"array"}` schema makes it unreachable.

---

### C.5 `gather` — fold a bound collection into one value with a NODE  ·  Verdict: DEFER

**Purpose.** Turn a bound collection (or several bindings) into **one** value by running **one
agent** over the whole collection — the fold-with-a-node form. It is `synthesize`
(`SPEC §3.6`) generalized from **literal** inputs to **journaled** inputs.

**C.5.1 Surface grammar.**

```
GatherStmt : `gather` `(` Prompt `)`        ; Prompt : StringLiteral | Template (§C.2.1) — mirrors AgentStmt
```

`gather` reuses **`AgentStmt`'s exact `Prompt` nonterminal** (§C.2.1, `StringLiteral | Template`),
so — like an `agent` — its argument may be either a `~P` template (the common, useful case, whose
assigns render the bound collection(s)) or a plain string literal. A literal-string `gather` is
therefore **grammatical**, matching Rule C.5.1's prose that it is legal-but-pointless (a
`synthesize` with no inputs); the grammar and the validation accept the **same** strings (the §F.8
grammar/validation-agreement discipline, applied to `gather`).

Used most often as a `let` producer so the fold's result is itself bindable:

```elixir
let :patches = (map :fix, over: :findings, max: 20 do   # parens REQUIRED: block-bearing producer (§C.1.2)
  agent(~P"""
  Produce a patch for:
  <%= @fix %>
  """)
end)
let :report = gather(~P"""
Combine these patches into a single reviewed patch set:

<%= @patches %>
""")
```

`gather` is an agent turn whose prompt is a template over bindings; its output is one
`agent_committed` result. Note the fold consumes **`@patches`** — the `map`'s **bound output**
(the ordered List of the lanes' patches, DF-M4) — **not** the original `@findings` input; binding
the `map` (§C.1.1, DF-M4) is exactly what lets `gather` see the fan-out's results rather than
re-folding its inputs. (The above renders the whole `@patches` List via `RenderText`'s `inspect/1`
for a non-binary list — `SPEC §4.4`; authors who need per-element formatting use `map` to
pre-render each element to a binary, then `gather` the joined List.)

**C.5.2 Inert node struct + addressing + idempotency.** `gather` reduces at compile time to a
**schemaless `%Agent{}`** exactly as `synthesize` does (`SPEC §6.3` dispatch, dataflow-ground
§1): `%Agent{address: node.address, prompt: <the %Template{} or the literal binary>, bindings:
<resolved, or %{} for a literal prompt>, schema: nil, retries: 0}`. Addressing and idempotency are therefore an ordinary agent's
(`SPEC §6.5`); no new node struct is strictly required (an implementation MAY keep a thin
`%Gather{}` that rewrites to `%Agent{}` at parse time, like `synthesize`).

**C.5.3 Validation rules.**

**Rule C.5.1 — Prompt is a template (or literal); assigns resolve.** Same name-resolution as
§C.2 (Rules B.5.4/B.5.5). A `gather` with a literal string and no assigns is legal but
pointless (it is just `synthesize` with no inputs).

```counter-example
gather(~P"Summarize <%= @missing %>")   # unbound assign — REJECTED
```

**Rule C.5.2 — No schema/retries options in Tier 1.** `gather` is schemaless (`retries: 0`),
like `synthesize`. (A schema-bound gather is a straightforward later extension; deferred.)

**Rule C.5.3 — `gather` is top-level-only (Tier-1 restriction).** A `gather` inside a loop body
or a `map` body is rejected, mirroring `let` (Rule C.1.4) and `map` (Rule C.4.4): it renders a
template over bindings that resolve at `iteration = 0` (`BoundValue`), so it is not in the closed
loop-body vocabulary (`SPEC §5.7.6`). This makes the iteration-0 binding assumption explicit
rather than merely implied by the body vocabulary.

```counter-example
while_budget reserve: 8 do
  gather(~P"Combine <%= @items %>")   # `gather` is not in the loop body vocabulary — REJECTED
end
```

**C.5.4 Execution algorithm.** Identical to a schemaless agent (`SPEC §6.4`) with a rendered
prompt (§C.2.4 `EffectivePrompt`). Determinism, exactly-once, and replay-safety are §C.2's,
verbatim. It runs exactly one turn — trivially terminating.

**C.5.5 Journal events.** **None new** — one ordinary `agent_committed` at the gather's
address (the reduced `%Agent{}`).

**C.5.6 Conformance.**

- **DF-G1.** `gather` MUST reduce to one schemaless agent turn over a rendered template; its
  result MUST be an ordinary `agent_committed`, bindable by `let`.
- **DF-G2.** Every fold of a collection into one value in Tier 1 MUST be a node (`gather`) or
  the existing accumulator machinery — never a lambda or an in-language reducer.

---

### C.6 `pipeline-with-dataflow` — thread stage N's output into stage N+1 (by composition)  ·  Verdict: ADOPT (by composition)

**Purpose.** Thread each stage's output into the next stage's prompt. **No new combinator is
needed**: this idiom is `let` (§C.1) + prompt injection (§C.2) + top-level sequencing
(`SPEC §6.11`).

**C.6.1 Surface (composition, not new grammar).**

```elixir
workflow "threaded" do
  let :outline  = agent("Draft a tight outline for the essay.")
  let :sections = agent(~P"""
  Expand each item of this outline into a paragraph:

  <%= @outline %>
  """)
  let :draft    = agent(~P"""
  Assemble these sections into a coherent essay:

  <%= @sections %>
  """)
  emit(~P"<%= @draft %>")     ; §C.7 — no newline, so an inline ~P is fine here
end
```

Each `let` binds a stage's journaled output; the next stage injects it. Top-level statements
run sequentially in source order (`SPEC §6.11`) and define-before-use (§B.5.5) guarantees each
producer commits before its consumer renders (§D.4). This is a *strict sequential* thread; it
is exactly the data-flow the current `pipeline` combinator refuses to provide (`SPEC §10.4`
G).

**C.6.2 Why not extend the `pipeline` combinator.** The existing `pipeline` runs **N item
lanes in parallel with no barrier** (`SPEC §3.4`). Threading stage output within a lane is
coherent, but threading **across items** (does lane 2 see lane 1's stage output?) opens
ordering and per-item-binding questions that are not needed to solve the "outputs flow
nowhere" wall. The `let`-chain covers sequential threading at top level with zero new
mechanism. Extending `pipeline` itself is **DEFERRED** (§E).

**C.6.3 Validation / execution / events / conformance.** All inherited: `let` (§C.1), prompt
injection (§C.2). No new struct, address, event, or rule. **Conformance: DF-C1 —** an
implementation that ships `let` + prompt injection MUST make the `let`-chain above work with
no additional feature; sequential threading is a consequence, not a combinator.

---

### C.7 `emit` — render the terminal result from bound values  ·  Verdict: ADOPT

**Purpose.** Produce the run's terminal value by **rendering a template over bound values**,
rather than by returning a compile-time literal (`return`, `SPEC §3.1`). This is the "render a
final document" idiom.

**C.7.1 Surface grammar.**

```
EmitStmt : `emit` `(` Template `)`
```

```elixir
emit(~P"""
# Review Report

## Findings
<%= @findings %>

## Recommended patch set
<%= @report %>
""")
```

**C.7.2 Inert node struct + addressing + idempotency.**

```
%Workflow.Node.Emit{
  address  :: address(),
  template :: %Template{},
  bindings :: %{atom() => BindingRef}
}
```

- **Addressing.** A top-level `emit` at position `i` has address `[i]`.
- **Idempotency.** `emit` performs **no paid effect** (it is a pure render, no provider call),
  so it needs no idempotency key. Its rendered value flows into the terminal `run_completed`
  event.

**C.7.3 Validation rules.**

**Rule C.7.1 — Assigns resolve (name resolution + define-before-use).** As §B.5.4/§B.5.5.

```counter-example
workflow "x" do
  emit(~P"Result: <%= @answer %>")   # no preceding `let :answer` — REJECTED
  return(:ok)                        ; (a workflow still needs a terminal value — see C.7.6)
end
```

**Rule C.7.2 — A workflow's terminal value comes from a `return` or an `emit`.** `SPEC §5.10.2`
(a workflow MUST contain a `return`) is **widened**: a workflow MUST contain at least one
`return` **or** at least one `emit`. Both set the terminal value; the **last executed** wins
(`SPEC §6.3` `return` semantics — `emit` shares them, §C.7.4).

```counter-example
workflow "x" do
  let :d = agent("draft")     # neither `return` nor `emit` — no terminal value — REJECTED
end
```

**Rule C.7.3 — `emit` is top-level-only (Tier-1 restriction).** An `emit` inside a loop body or
a `map` body is rejected, mirroring `let` (Rule C.1.4), `map` (Rule C.4.4), and `gather` (Rule
C.5.3): it renders a template over bindings that resolve at `iteration = 0`, and like `return`
it sets the run's terminal value, which is a top-level concern. It is not in the closed loop-body
vocabulary (`SPEC §5.7.6`).

```counter-example
while_budget reserve: 8 do
  emit(~P"Result: <%= @answer %>")   # `emit` is not in the loop body vocabulary — REJECTED
end
```

**Rule C.7.4 — `emit`'s argument MUST be a `~P` Template (active reject of any other form).** Unlike
`gather` (§C.5.1), which reuses `agent`'s `Prompt : StringLiteral | Template` nonterminal, `emit`
admits **only** a `Template` (§C.7.1 grammar). The rejection of any other argument MUST be an **active
guard**, not implicit: `parse/2`'s `emit` clause MUST match `{:emit, meta, [{:sigil_P, _, _}]}` and
reject any other argument — a `StringLiteral`, an interpolated string, or any non-sigil form — with a
caller-located `Finding` at `meta`. *Why the explicit guard is load-bearing (stated honestly):* the
real hazard is an **accept-vs-reject divergence on a binary argument**, not a "silent garbage" one. A
literal `emit("done")` hands `to_text/1` a **binary**, which `to_text/1` cleanly wraps as a single
`{:text, "done"}` segment and **accepts** — so without the active guard one implementer rejects
`emit("done")` per the Template-only grammar (§C.7.1) while another accepts it as a literal terminal: a
two-implementers divergence on a day-one ADOPT construct. (A non-binary, non-sigil argument — e.g.
`emit(:foo)` or `emit(1 + 1)` — would additionally reach `to_text/1`'s `inspect(other)` fall-through
and stringify, but the binary accept-vs-reject case is the one the guard is really needed for; the
guard turns the grammar's Template-only restriction into an enforced validation reject and emits a
precise diagnostic in place of a cleanly-but-wrongly-accepted terminal.) This is the identical
F.24(2)/Rule C.2.4 active-guard discipline, applied to `emit`. *Adjudication (pl-design non-blocking 3, a cross-lens conflict):* keep `emit` Template-only
+ active reject rather than widen `emit` to `Prompt` the way F.15 widened `gather`. `emit` of a pure
literal is exactly `return` (§C.7.2/DF-E2), which already exists — admitting a literal `emit` would
mint a second surface for a construct the vocabulary already holds and blur the `emit`≡render /
`return`≡literal split — whereas a literal `gather` is a genuinely distinct (if pointless)
`synthesize`-with-no-inputs. The asymmetry with F.15 is therefore principled, not an inconsistency.

```counter-example
emit("done")     # a literal-string emit — REJECTED (that is `return`); write `return("done")` or `emit(~P"done")`
```

**C.7.4 Execution algorithm.**

```
RunEmit(node, run_id, ctx):
  - Let {value} be RenderTemplate(node.template, run_id, node.bindings, nil).   ; §B.6; `emit` is top-level (§C.7.3), never in a map lane, so lane is nil
  - Return {:cont, ctx with return = {value}}.       ; sets the terminal value; commits no event; does NOT halt
```

- `emit` mirrors `return` (`SPEC §6.3`): it sets `ctx.return` and does **not** halt, so a
  later `emit`/`return` overwrites it (last-executed wins). Authors place the terminal
  `emit`/`return` **last**.
- **Determinism / replay-safety.** `RenderTemplate` is a pure journal fold (§B.6, §D.2). The
  rendered string flows into `run_completed.value` (`SPEC §7.2`), which is journaled — so the
  terminal value is a **deterministic function of journaled data** (`SPEC §1.3` Principle 3).
  On resume of an incomplete run, `emit` re-renders from the immutable journal → identical
  bytes; on resume of a **completed** run, `ExecuteRun` short-circuits and never re-renders
  (`SPEC §6.2`). Replay-safe (§D.4).
- **Termination.** `emit` runs once; no iteration.

**C.7.5 Journal events.** **None new.** The rendered value is captured in the existing
terminal `run_completed.value` (`SPEC §7.2`), exactly as a `return` value is. (An optional
`emit_rendered{address, value}` marker is **RECOMMENDED-not-required** for observability;
`run_completed.value` is the authoritative record either way.)

**C.7.6 Conformance.**

- **DF-E1.** `emit` MUST set the terminal value to a deterministic `RenderTemplate` fold over
  the journal; the value MUST be journaled in `run_completed.value`.
- **DF-E2.** A workflow MUST contain at least one `return` or `emit`; the last-executed one
  supplies the terminal value.
- **DF-E3.** `emit` MUST commit no paid effect and MUST NOT halt execution (last-wins, like
  `return`).
- **DF-E4.** `emit`'s argument MUST be a `~P` `Template` (§C.7.1); `parse/2` MUST match `{:emit, meta,
  [{:sigil_P, _, _}]}` and actively reject any non-template argument (e.g. a `StringLiteral`) with a
  caller-located `Finding` at `meta` (Rule C.7.4) — never stringify it via `to_text/1`.

---

### C.8 The two DO-NOT-CROSS idioms, specified as REJECTIONS

The governing rule names two candidate idioms that **cross the Tier-1/Tier-2 line**. They are
specified here precisely enough to be *implementable as excluded* — a conforming
implementation must reject them, and this section pins the smallest counter-example and the
principled reason, so no team accidentally admits them.

#### C.8.1 `select` / `when` — bounded literal branch (REJECT)

**What it would be.** Choose among literal branches by a closed predicate over a bound value:
`select @verdict do; true -> agent("ship"); false -> agent("revise"); end`.

**Why it is rejected.** This is **control flow**, and the thesis is *data flow, not control
flow* (§A.2). It violates `SPEC §1.3` Principle 8 and `SPEC §6.10` ("**The language has no
conditional or branching combinator**"): a `select` chooses **which subtree runs** based on a
runtime value. Even journaled and replay-safe, the mere **presence** of a value-dependent
branching node is the categorical shift from Tier 1 (deterministic by *absence* of control
vocabulary, `SPEC §1.3` Principle 2, C2) to Tier 2. It is distinct from the existing
value→control edges (`while_budget until:`, `until_dry` dryness), which are (a) **size-only**
folds, never content, and (b) affect only **loop stop**, never **which** node runs.

**Smallest counter-example (MUST be rejected).**

```counter-example
let :v = verify("claim", voters: 3)     # (already rejected: panels aren't bindable, C.1.2)
select @v do                            # a branching combinator — NOT in the vocabulary — REJECTED
  true  -> agent("ship it")
  false -> agent("revise it")
end
```

**The Tier-1 alternative (where branching belongs).** Render the value into **one** agent's
prompt and let the **agent** branch internally — semantic branching belongs in the model's
reasoning, not the workflow graph:

```elixir
let :review = agent("Review the claim and state whether it holds.")
agent(~P"""
Here is a prior review:

<%= @review %>

If the review found the claim sound, ship it as-is; otherwise, revise it to address every
concern. Return the final artifact either way.
""")
```

**Conformance: DF-X1.** An implementation MUST NOT provide any combinator that selects which
node/subtree runs based on a runtime value. Value-dependent **control** flow remains
unexpressible (C2, Principle 8).

#### C.8.2 `reduce` with a closed in-language reducer (REJECT for Tier 1)

**What it would be.** Fold a bound collection into one value with a **closed operator** rather
than a node: `reduce(:n, over: :items, with: :count)`, `reduce(:joined, over: :lines, with:
:concat)`.

**Why it is rejected (for now).** A closed reducer set (`:count`, `:concat`, `:first`,
`:last`, `:unique`) is deterministic and closure-free, so it does **not** break the hard
invariants — but it drifts toward **in-language computation** (`:count` + a comparison is
arithmetic-adjacent; the slope from `:count` to `:sum` to general arithmetic is the exact
`DO NOT CROSS` "arithmetic-in-prompts / general computation" boundary, `SPEC §1.2`). The
**node** form (`gather`, §C.5) already folds N things into one value by delegating the fold to
an **agent**, and the existing accumulator machinery already exposes `count()` to loop
predicates (`SPEC §6.8`). Tier 1 therefore has no unmet need a closed reducer uniquely
serves. **REJECT** until a concrete corpus wall shows `gather` + accumulators are insufficient;
if that wall appears, admit the **smallest** closed set (likely just `:concat` of binaries)
and nothing arithmetic.

**Smallest counter-example (MUST be rejected in Tier 1).**

```counter-example
reduce(:n, over: :items, with: :count)   # an in-language reducer — REJECTED (use gather or count() in a predicate)
```

**Conformance: DF-X2.** An implementation MUST NOT provide an in-language collection reducer
in Tier 1; collection folds are nodes (`gather`) or accumulators only.

---

## D. Cross-cutting proofs

### D.1 Closure-freedom of the whole extended tree

Every node struct this proposal adds holds only escapable data: `%Template{}` is a list of
`{:text, binary} | {:assign, atom}` tuples plus an atom list (§B.3); `%Let{}` holds an atom
and a child node; `%Map{}` holds atoms, a positive integer, a `BindingRef` (a `{:node,
address}` or `{:map, address}` tuple of atoms/integers), and a single-agent body list; `%Emit{}`
holds a `%Template{}` and a `%{atom => BindingRef}` map. `bindings` values are addresses — lists
of non-negative integers (`SPEC §4.2`), i.e. compile-time constants. **No field can hold a
function.** The `~P` lowering (`Template.lower/3`, the **binary scanner** run **by `parse/2`** at
compile time — §B.4) emits the `%Template{}` **struct** (with binary `{:text, …}` segments),
never a `quote`/`fn` — and calls no `EEx.Engine`/`Code.string_to_quoted`, so no closure or quoted
form can enter through a hole body (the deliberate drop from EEx, §B.1). Therefore the extended
`%Tree{}` remains `Macro.escape`-able
into a compile-time constant with **zero closures** (`SPEC §1.3` Principle 7, C3), and
`SPEC §5.1.1` (no `fn`) is untouched. ∎

### D.2 Determinism & replay-safety of every flowed value

Every value that flows into a prompt or terminal result is produced by `RenderTemplate` (§B.6)
= a fold of `{:text}`/`{:assign}` segments where each assign is resolved by `ResolveAssign` →
`ResolveRef` → `BoundValue`/`Index` (§C shared resolution). Each of these:

- reads **only** the immutable journal (`Journal.Fold`, `SPEC §6.2`) and the compile-time
  `bindings`/`lane` — **no** clock, randomness, environment, or process state (`SPEC §1.3`
  Principles 2, 3);
- is **total and deterministic**: `BoundValue` matches a single `(address, iteration=0)`
  `agent_committed` (unique by exactly-once, `SPEC §6.5`); `Index` is bounds-guarded by the
  `map` width (§C.4); `RenderText` is `SPEC §4.4` verbatim (binary pass-through / `inspect/1`,
  with `SPEC §4.4`'s host-scoped byte-normativity clause applying identically here).

Hence two conforming implementations render, from the same journal (§B.7 T3): **byte-identical**
prompts and terminal values for **binary** bound values (cross-host normative); and **identical
within the Elixir embedding** for non-binary bound values (where `inspect/1` rendering — map-key
ordering, atom colons, escaping — is byte-normative only for the Elixir embedding, `SPEC §4.4`,
cited one bullet above). In particular, `Kernel.inspect/1` on a string-keyed provider map guarantees
**no** canonical key order across Elixir versions, so the within-embedding guarantee itself holds only
for a **fixed host `inspect/1`** (same Elixir version, equal maps from equal JSON decode); two Elixir
versions MAY render different bytes for the same bound map — this is new relative to the shipped
literal-only story, whose inspected values are all compile-time-fixed. Authors who need cross-host
byte-stability MUST bind **binary** values, or pre-render each element to a binary via `map` before
`gather`/`emit` (the normative §B.6 and DF/T3 hedge). On resume, an already-committed consumer replays its journaled
`agent_committed.prompt`/`run_completed.value` and is **never** re-rendered (`SPEC §6.2`,
§6.4); an uncommitted consumer re-renders from the **same** journaled producer result → the
same bytes. Every flowed value is thus a deterministic function of already-journaled data —
`SPEC §1.3` Principle 3, strengthened C9′ (§A.4). ∎

### D.3 Termination bound for every new fan-out

The only new construct with runtime-decided multiplicity is `map` (§C.4). Its width is
`min(observed_length, max)` where `max` is a **REQUIRED compile-time positive-integer literal**
(Rule C.4.2), so `width <= max` **unconditionally**, regardless of the producer's output.
Each lane is a **single** `agent` (Rule C.4.3, §C.4.1; no nested regions, loops, or extra stages).
Therefore a `map` region performs at most `max` agent turns and always halts —
the identical structural-cap guarantee `max_iterations` gives loops (`SPEC §1.3` Principle 5,
C7). `let`, prompt injection, `gather`, and `emit` add **no** iteration (each runs a fixed
number of turns: one, zero, one, zero respectively). The extended tree therefore still
provably terminates; C7 gains exactly one more structural cap (`map.max`) and loses nothing.
∎

### D.4 Resume reuses bound values from the journal

A consumer renders `@name` by folding the producer's `agent_committed` (`BoundValue`). Two
facts guarantee that event is present whenever the consumer runs:

1. **Define-before-use** (Rule B.5.5): a reference resolves only to a binding whose producer
   **lexically precedes** the consumer in the same or an enclosing scope.
2. **Sequential top-level order** (`SPEC §6.11`) + `let`/`map`/`emit` being **top-level-only**
   (Rules C.1.4, C.4.4): a preceding top-level producer commits its events **before** the
   consumer's node executes — an `agent`/`synthesize`/`gather` its `agent_committed`, and a `map`
   its `map_started` **plus** every lane's `agent_committed`. (Inside a `map` lane, the `over`
   producer is a top-level `let` that precedes the whole `map`, so it too is already committed.)

Consequently **every** resolver finds the events it folds: `BoundValue` finds a `{:node}` over's
producing `agent_committed`; `BoundList`/`MapWidth` find a `{:map}` over's `map_started.width` and
each lane's `agent_committed`. Critically, `DecideMapWidth` resolves `over:` through `ResolveRef`
(§C.4.4, DF-M5), **never** through `BoundValue` directly, so a `map`-over-`map` chain
(`let :b = (map …); map :j, over: :b, max: … do … end`) resolves by the **same** fold and never
raises. `BindingUnresolved` is therefore genuinely **unreachable for a validated tree** — for a
`{:node}` over, a `{:map}` over, and a `map`-over-`map` `over:` alike; the earlier draft's
`BoundValue`-only `over` resolution (which crashed on a `{:map}` over) is closed by DF-M5. On resume this is even stronger: the producer's event is
already in `prior` (the folded journal, `SPEC §6.2`), so the value is reconstructed by the
same fold with no recomputation of any effect — exactly the mechanism accumulators and
idempotency resolution already use (`SPEC §6.6.1`, §6.4; dataflow-ground §5 "accumulators are
the proof that a durable value edge CAN be a pure fold"). No bound value is ever carried in
process state; resume needs none. ∎

### D.5 Panels stay observational; no value→control edge is added

Nothing in this proposal lets a value alter **which** node runs or **how many** times (except
`map`'s bounded, capped width, which is data-driven fan-out, not a branch). Panels remain
unbindable (Rule C.1.2) and observational (`SPEC §1.3` Principle 8): a `verify`/`judge`
outcome still flows nowhere, and `select`/`when` are rejected (§C.8.1). The proposal relaxes
**value flow** only, exactly as dataflow-ground §5.3 demands ("Letting a value flow is
orthogonal to letting *control* flow … an extension should be explicit about which it
relaxes"). We relax value flow; we do not touch control flow. ∎

---

## E. Recommendation — per-idiom verdict & build order

Standing guidance: **ship `refine` (`SPEC §9`) first**, and add a dataflow idiom only when the
authored-workflow corpus keeps hitting the "outputs flow nowhere" wall. The verdicts below
honor that: the *core* dataflow slice is small and high-leverage; the heavier idioms are
gated behind demonstrated need; two idioms are rejected outright.

| Idiom | Verdict | Rationale |
|---|---|---|
| **Template layer** (§B) | **ADOPT** (foundation) | Nothing flows without it; it is pure infrastructure (an inert struct + a compile-time **binary scanner** + a render that already exists in `SPEC §4.4`). Zero runtime risk, closure-free by construction (§D.1), and "no embedded Elixir" is structural (no `EEx`/`Code.string_to_quoted`, §B.4). |
| **`let`** (§C.1) | **ADOPT** | The keystone. Every other value edge composes from it. Adds no effect, no event, no key — a bound value is just a fold over the producer's existing `agent_committed`. |
| **prompt injection** (§C.2) | **ADOPT** | The edge authors are actually asking for ("improve this draft"). Reuses the existing agent event and key wholesale; the rendered prompt lands in the already-observable `agent_committed.prompt`. |
| **`emit`** (§C.7) | **ADOPT** | Cheap, high-value, pure render, no paid effect. Turns "flow N results into one document" into a first-class terminal. |
| **pipeline-with-dataflow** (§C.6) | **ADOPT by composition** | Falls out of `let` + injection + sequencing — **no new combinator**. Extending the `pipeline` *combinator* itself is **DEFERRED** (cross-item threading is unneeded and semantically fraught). |
| **`gather`** (node form, §C.5) | **DEFER** | Valuable but not day-one: it is `synthesize` over journaled inputs. Ship once folding several bound outputs into one write-up recurs and `synthesize`-with-literals proves insufficient. Light to add (reduces to one agent). |
| **`map`** (§C.4) | **DEFER** | The heaviest idiom: runtime-decided width, per-lane re-addressing, the structural `max:` cap, a new concurrent region, and two new events. It is a **bindable producer** (`let :xs = (map …)` binds the ordered List of lane results, DF-M4) with **single-agent lanes** in Tier 1 (multi-stage lanes → Tier 2, §C.4.1). Ship only when per-element fan-out over a bound collection is a demonstrated, recurring wall. Fully specified here so it is ready when that wall appears. |
| **`reduce`** (closed reducer, §C.8.2) | **REJECT (Tier 1)** | Drifts toward in-language computation; `gather` + accumulators already cover real needs. Revisit only on a concrete wall, and then admit the smallest possible closed set (`:concat` of binaries), never arithmetic. |
| **`select` / `when`** (§C.8.1) | **REJECT** | It is **control flow**, not data flow — violates "no conditional/branching combinator" (Principle 8) and the whole thesis (§A.2). Semantic branching belongs **inside** an agent's reasoning, rendered one value into one prompt (§C.8.1). |

### Build order

1. **`refine`** (`SPEC §9`) — the already-committed next step; unblocks nothing here but is the
   standing priority.
2. **Dataflow core** — Template layer (§B) + `let` (§C.1) + prompt injection (§C.2) + `emit`
   (§C.7), shipped as **one coherent slice**. This is the minimum that dissolves the "outputs
   flow nowhere" wall, and it unlocks pipeline-with-dataflow (§C.6) by composition **for free**.
   It amends Principle 6 → 6′, `SPEC §6.4.1` → §6.4.1′, C9 → C9′, and the closed-vocabulary cluster
   → 17-way (Principle 1′/§2.4′/C1′, §A.4(8′)) (§A.4) and adds **zero** new journal events (every
   flowed value rides existing `agent_committed.prompt` / `run_completed.value`).
   **Test-suite guidance (implementation note, non-normative).** This slice is the first construct to
   fold a **runtime-decoded, string-keyed provider map** through `Kernel.inspect/1` at execution time
   (shipped `SPEC §4.4` only ever inspected compile-time literals). Because `inspect/1` guarantees no
   canonical map-key order across Elixir versions (§B.6/§D.2 hedge), the ADOPT slice's tests MUST pin a
   **binary-valued** binding path when asserting byte-exact journaled prompts/terminals, and MUST NOT
   assert byte-stability on an **inspected-map** path — otherwise the suite itself silently depends on a
   non-normative ordering. Assert map-bearing renders by structural/normalized comparison, never byte
   equality.
3. **`gather`** (§C.5) — add when folding multiple bound outputs into one turn recurs.
4. **`map`** (§C.4) — add when per-element fan-out over a bound collection recurs; it is the
   one slice that adds a new region and new events (`map_started`/`map_completed`), so it ships
   last and behind demonstrated need.
5. **Never (absent a hard wall):** `reduce` (closed reducer), `select`/`when`.

### One-line stance

**Add data flow, not control flow: flow only values the journal already holds, only through
the deterministic render `SPEC §4.4` already defines — widened from literals to journaled
values under an exhaustive, compile-time-checked whitelist.** This is a *strengthening* of
"no value binding" (Principle 6 → 6′): it replaces a blunt ban that still leaked data with a
scalpel that pins exactly which values flow and exactly how they render, preserving
closure-freedom, determinism, replay-safety, and bounded termination in full.

---

## F. Design decisions & tradeoffs (adversarial-panel changelog)

This section records the resolutions taken after the two-expert adversarial panel (elixir-beam
idiom + pl-design theory) reviewed the proposal. **F.1–F.6** resolve the *first* panel pass;
**F.7–F.10** resolve the *second* pass, which rejected the EEx-tokenizer-based lowering and the
open `map` output edge; **F.11–F.13** resolve the *third* pass, which rejected the uppercase-`~P`
escape mis-statement and the dangling `map`-over-`map` `over:` edge; **F.14–F.17** resolve the
*fourth* pass, which rejected the unpinned `let`/`=`/do-block surface→AST mapping, the
gather grammar/validation contradiction, and the under-enumerated §A.4 amendment set; **F.18–F.21**
resolve the *fifth* pass, which rejected the `agent_attempt_rejected.prompt` struct-vs-string
divergence (the §A.4 amendment set was still not exhaustive) and closed the map lane-index
threading gap plus two presentational grammar/payload warts; **F.22–F.24** closed the in-grammar
sigil-delimiter divergence, the `RunConcurrently` lane-provenance hop, and the remaining fifth-pass
non-blocking warts; **F.25–F.27** resolve the *sixth* pass, which rejected the compile-time
`BindingEnv` threading locus (it could populate no `bindings` field nor reach a `map` lane's
`@element`) and the under-enumerated §A.4 set (still missing the shipped `SPEC §1.2` Non-goal that
bans value binding); **F.28–F.29** resolve the *seventh* pass, which rejected the still-unreconciled
closed-vocabulary count (`SPEC §1.3` Principle 1's "exactly 13 combinators" and its four sibling
count-clauses were silently overridden — the ninth exhaustiveness miss) and the unpinned per-form
`node/4` 4th-argument decision at the compiler's five nested `node/3` call sites (which left nested
template agents' binding-resolution undefined). Each blocking objection was
resolved without weakening any non-negotiable invariant; where the two lenses could conflict, the
adjudication and the rejected alternative are stated. Where a second-pass resolution supersedes a
first-pass one (the EEx→scanner switch retires F.3's and F.5(1)'s EEx framing), the earlier entry
is annotated as **superseded by F.7**.

> **NORMATIVE STATUS OF §F (read first).** §F is **non-normative rationale and history**. The sole
> normative surface of this document is **§A–§E**; a conforming implementation is defined entirely by
> §A–§E and needs nothing here. §F is a six-plus-pass adversarial archaeology and therefore contains
> **superseded pins** — earlier requirements that a later pass retracted (e.g. F.24(3)'s "BindingEnv
> threaded only at `build/5`" was retracted by F.25; F.16's `EffectivePrompt(…, ctx)` signature was
> superseded by F.19's `lane`; F.3/F.5(1)'s EEx framing was retired by F.7; F.5(6)/Rule-C.2.4's
> then-"three positions" whitelist was narrowed by F.29 to the four top-level/map-lane positions). A
> reader MUST NOT lift a requirement from a §F entry: **where a §F pin conflicts with §A–§E, §A–§E
> governs**, and any §F entry marked *superseded by* / *retracted by* / *narrowed by* is dead. §F
> entries are cited from §A–§E only to point at the *rationale* for a decision, never to *supply* a
> requirement. (A future editorial pass MAY move §F to a separate history file; it is kept inline here
> only because several §A–§E rationale citations still resolve to its anchors.)

**F.1 — `~P` is surface syntax lowered by `parse/2`, not a self-expanding sigil macro (§B intro,
§B.1, §B.2 note, §B.4, §B.5, §B.7 T1).** *Objection (elixir-beam, Blocking 1):* the original §B
specified `~P` as a `defmacro sigil_P` whose engine "runs during macro expansion" and raises at
its own `caller_env`. That is mechanically impossible here: `workflow/2` hands the **unexpanded**
do-block to `Workflow.Compiler.parse/2`, which never `Macro.expand`s the block, so a standalone
`sigil_P` body would never fire — the mechanism is dead code, and routing template-shape errors
through a sigil-macro `raise` would bifurcate validation into two loci, violating the invariant
that **all** validation lives in the single, directly-testable `parse/2`. *Resolution (adopted):*
keep `~P` and the inert `%Template{}` **exactly as designed** but delete the macro mechanism.
**No `sigil_P` is defined or imported;** `parse/2` recognizes the `{:sigil_P, meta, [{:<<>>, _,
[raw]}, _mods]}` AST node structurally and lowers it with the plain function `Template.lower/3`,
invoked exactly as `verify_prompt/2`/`score_prompt/2`/`to_text/1` are today. All template
validation — shape and name-resolution — now originates in `parse/2`. *Rejected alternative:* a
whole-block `Macro.expand` step to make a sigil macro fire; rejected because it would destroy the
"plain, directly-testable, single validation locus" property the invariant protects. This is the
elixir-beam counter-proposal adopted verbatim; it does not touch the grammar or the struct, so it
composes cleanly with F.2–F.4.

**F.2 — Maximal-munch template grammar with lookahead (§B.2, Rule B.5.6).** *Objection
(pl-design, Blocking 2):* `TextChar :: SourceCharacter but not the sequence <%=` is ill-formed —
`but not` excludes strings, but a single `SourceCharacter` can never *match* the three-character
`<%=`, so the exclusion is vacuous and `<%= @draft %>` is derivable both as an `AssignHole` and as
a run of `TextChar`s, leaving the grammar ambiguous. *Resolution (adopted):* restructured §B.2 as
a maximal-munch lexical grammar — `TextChar :: SourceCharacter [lookahead != AssignHoleStart]`
with `AssignHoleStart :: <%=` — plus a normative disambiguation clause ("`<%=` MUST begin an
`AssignHole`, never `TextChar`s") and a new decidable rejection, Rule B.5.6 (an `<%=` not
completed as a hole is a caller-located `Finding`, counter-example `~P"literal <%= tag"`). Literal
`<%=`-in-text becomes an explicit inexpressibility, not an ambiguity. No invariant interaction.
*(Generalized by F.8: the lookahead guard is now `EExTagOpen :: <%` (every tag opener), not just
`<%=`, so statement/comment/literal-escape tags are recognized-then-rejected rather than derivable
as text; Rule B.5.6 correspondingly rejects an unterminated `<%…` tag, not only an unterminated
`<%=`.)*

**F.3 — §B.2 grammar and §B.4 algorithm pinned to agree on hole whitespace (§B.2, §B.4).**
*(EEx framing superseded by F.7 — the reference lowering is now a hand-rolled scanner that trims
`TemplateWS` itself, so the grammar/algorithm agreement no longer depends on `EEx.tokenize`'s
whitespace behavior. The `TemplateWS :: WhiteSpace | LineTerminator` widening and the "§B.2 is
normative; the lowering conforms to it" framing both stand.)* *Objection (pl-design, Blocking 3):*
§B.2 fixed `HWhitespace :: Space | Tab` (line terminators
excluded), but §B.4 delegates to `EEx.tokenize/2`, which accepts newlines inside `<%= … %>`, so a
heredoc hole `~P"""<%=\n@draft\n%>"""` is accepted by the algorithm and rejected by the
grammar — the reference implementation cannot conform to its own grammar. *Adjudication:* this is
the one spot where the idiomatic-convenience lens ("just reuse EEx's tokenizer wholesale") and the
PL-purity lens could pull apart. Both experts converged on the **convenient** reconciliation, and
so do I: **widen §B.2 to match EEx** (`TemplateWS :: WhiteSpace | LineTerminator`, reusing `SPEC
§2.1`'s lexemes) rather than hand-roll a stricter subset the reference tokenizer violates. §B.2 is
declared the **normative** definition of an admissible template; §B.4 `Template.lower/3` is **one
conforming lowering**; any tokenizer MUST accept exactly the §B.2 language — no more, no less. The
rejected alternative — narrowing the hole to horizontal whitespace and forcing a bespoke
grammar-faithful tokenizer — was declined because it keeps the reference EEx path non-conformant
for no purity gain (a hole spanning lines is not a computation). Grammar and algorithm now cannot
diverge.

**F.4 — `SPEC §6.4.1` added to the amendment set as §6.4.1′ (§A.4, §C.2.4, DF-P1).** *Objection
(pl-design, Blocking 4):* §C.2.4 passes a rendered template as `CallProvider`'s `prompt`, but the
still-normative `SPEC §6.4.1` fixes `prompt :: String.t()` as "this node's literal prompt —
**never a splice of any other node's output**", and §A.4 amended Principle 6 and C9 but **not**
§6.4.1 — a silent contradiction with shipped `SPEC.md`. *Resolution (adopted):* §6.4.1 is added to
the §A.4 amendment set with an explicit replacement clause **§6.4.1′**, widening `prompt` to
"EITHER this node's literal prompt OR the deterministic `RenderTemplate` of an inert `%Template{}`
over already-journaled bindings; never an arbitrary interpolation, closure, computed value, or
live splice." Turn independence is preserved because the injected prompt is fully materialized to
a `String.t()` by a pure journal fold and journaled verbatim in `agent_committed.prompt` **before**
the call, so `CallProvider` still receives no conversation state. §C.2.4 and DF-P1 now cite
§6.4.1′. No invariant weakens: the only admissible non-literal prompt remains a pinned render over
journaled data.

**F.5 — Non-blocking refinements adopted.** (1) *(Superseded by F.7.)* The "custom `EEx.Engine`"
framing (§B.1) was first reframed to "reuse EEx's **tokenizer** function only" — but the second
panel showed even the tokenizer must go (F.7); §B.1/§B.4 now use a hand-rolled binary scanner that
calls **no** EEx and **no** `Code.string_to_quoted`, so "no embedded Elixir" is structural, not a
post-tokenize narrowing. (2) §B.2's note now states
normatively that **no `sigil_P` runtime definition exists** and that **uppercase `~P` is chosen
because uppercase sigils do not interpolate `#{}`**, guaranteeing the template content is a single
raw literal binary (the property that makes the whole template a compile-time literal). (3) §C.4.1
`MapOpts` was restated as an **unordered required-key set** (`over:` + `max:` required,
`max_concurrency:` optional, any order, duplicate-key handling deferred to `SPEC §5.10.4`),
matching every other combinator's option grammar. (4) §D.2's "byte-identical" conclusion was
**scoped**: byte-identical for binary bound values (cross-host normative), identical within the
Elixir embedding for non-binary values, with authors needing cross-host stability required to bind
binary values. (5) §C.5 (`gather`) and §C.7 (`emit`) each gained an explicit **top-level-only**
rule with a counter-example (Rules C.5.3, C.7.3), making the iteration-0 binding assumption stated
rather than inferred, symmetric with `let` (C.1.4) and `map` (C.4.4). (6) §C.2 gained Rule C.2.4,
a normative **closed whitelist of template positions** — a `%Template{}` is admissible only as an
`agent` prompt, a `gather` template, or an `emit` template; a `~P` in a `verify`/`judge` subject,
a `return` value, or a `phase`/`log` argument is rejected, keeping panels observational. *(This
three-position whitelist is **narrowed by F.29** to **four** positions — a **top-level** or
**`map`-lane** `agent` prompt, a **top-level** `gather`, a **top-level** `emit` — and its rejection
list gains the four nested agent positions; see the live Rule C.2.4 in §C.2.3.)*

**F.6 — Where the lenses could still conflict, and the pick.** The elixir-beam lens accepts the
compiler's **dual diagnostic channel** (a `Finding` for arg-shape, a forbidden-form `raise` for
morally-forbidden forms like `fn`), while the pl-design lens might prefer that **all** template-
shape violations `raise`. *Adjudication:* adopt the dual channel (§B.4) — forbidden **expression**
forms (arithmetic/call in a hole, control statements, blocks: Rules B.5.1–B.5.3) take the
forbidden-form `raise` path, exactly as a stray `fn` does; a **malformed hole shape** (Rule B.5.6)
and **name-resolution** failures (B.5.4/B.5.5) yield a `Finding`. This satisfies the elixir-beam
hard requirement (every diagnostic **originates in `parse/2`** via the existing
`Finding`/`__CALLER__` machinery, never a separate sigil macro) while honoring the pl-design
intent (the truly-forbidden forms are rejected with the same severity as `fn`). The `max:` cap
(Rule C.4.2) is kept a **compile-time positive-integer literal** — the pl-design red line — and was
**not** relaxed to a bound-derived or computed cap for ergonomics, because that literal is the sole
guarantor of bounded termination (§D.3). The `select`/`when` rejection (§C.8.1) and the closed
`<%= @name %>`-only template whitelist are likewise left un-loosened.

---

*Second-pass resolutions (F.7–F.10).*

**F.7 — The reference lowering is a hand-rolled binary scanner; EEx is dropped entirely (§B intro,
§B.1, §B.4, §B.6, §B.7 T1/T2, §D.1).** *Objection (elixir-beam, Blocking 1):* §B.4 was written
against a fictional `EEx.tokenize/2` contract. The real contract returns `{:text, charlist, meta}`
(content is a **charlist**), `{:expr, ~c"=", raw_source_charlist, meta}` (the hole body is **raw
source as a charlist, not an AST**), and `{:start_expr, marker, charlist, meta}`/`{:end_expr, [],
charlist, meta}` for statements/blocks. Consequently §B.4's central branch
`If {token} is {:expr, "=", expr_ast}: If {expr_ast} is {:@, …}` could **never fire** (the token
carries a charlist, not an `{:@,…}` AST — matching it needs an unspecified `Code.string_to_quoted`
step); its `{:expr, "", _}` control branch could never match (the real form is `:start_expr`/
`:end_expr` with marker `[]`); and §B.6's `out <> chars` would do `binary <> charlist` and
**raise**, so `RenderText` was **not total** — the algorithm failed the document's own
"implementable from this document alone; two teams cannot diverge" bar. *Adjudication (both lenses
converge):* **drop EEx entirely and lower with a direct binary scanner over the raw sigil binary**
(§B.4). The scanner walks `raw`: it flushes each pending text run as a **binary** slice, treats
`<%` as a tag opener, scans to the next `%>`, and for a `<%=` hole trims `TemplateWS` and requires
the body to match `~r/\A@([A-Za-z][A-Za-z0-9_]*)\z/`, rejecting anything else. This is ~15 lines,
**total by construction** (text segments are always binaries, so §B.6 `out <> chars` is
`binary <> binary`), version-stable (no dependence on EEx's unstable internal token tuples), and
**never** calls `EEx.tokenize`, `EEx.Engine`, or `Code.string_to_quoted` — so "no embedded Elixir"
is a **structural** property of the recognizer, not an after-the-fact validation, and there is no
`Code.string_to_quoted` seam through which arbitrary Elixir could re-enter a hole body. *Rejected
alternative:* keep `EEx.tokenize` and correct §B.4 to the real contract (`List.to_string` every
text charlist; `Code.string_to_quoted!` each hole body then match `{:@, …}`; reject `:start_expr`/
`:end_expr`/`:middle_expr`; rewrite the false "accepts exactly §B.2" note to "accepts a superset;
the fold narrows it"). Declined because (a) it re-parses each hole body with
`Code.string_to_quoted` — the exact embedded-Elixir seam the design exists to close; (b) it leans
on undocumented-for-compat token tuples that have changed shape across Elixir versions; and (c) it
makes grammar/algorithm agreement an *aspirational note* (a superset narrowed by the fold) rather
than **true by construction**. The "rip a proven template architecture" mandate is satisfied by
ripping the **ideas** — the assigns-dependency set (`%Template{}.assigns`, §B.3) and compile-time
validation (§B.5) — **not** by literally calling EEx. This resolves the elixir-beam blocker and, as
that lens noted, is strictly better for the pl-design goal: the scanner accepts **exactly** §B.2
(no superset to narrow), so §B.4's conformance note now reads truthfully.

**F.8 — Every `<%…` opener is a grammar-recognized tag routed to a located rejection; none falls
through to text or a silent drop (§B.2, §B.4, Rules B.5.2/B.5.7/B.5.8).** *Objection (pl-design,
Blocking 2):* §B.2 forbade only the three-character `<%=` from `TextChar`, so a statement tag
`<% if @ok do %>`, a comment `<%# … %>`, and a literal-escape `<%% … %>` — containing no `<%=`
substring — were derivable as ordinary `TextRun` (i.e. §B.2 said they were **valid text** that
renders verbatim), while §B.4/Rules B.5.2–B.5.3 **rejected** them, and §B.4 additionally had no
branch for comment/escape tokens (a **third**, silent-drop behavior). The identical source was thus
"valid text" under the grammar, "rejected" under validation, and "silently dropped" under the
algorithm — a hard two-implementers failure, and smuggled non-determinism at the lexer boundary.
*Resolution (adopted, the pl-design counter-proposal):* make the tag opener first-class. §B.2 now
has `EExTagOpen :: <%` and `TextChar :: SourceCharacter [lookahead != EExTagOpen]`, so **no** `<%…`
sequence is derivable as text; `AssignHole` is the one admissible tag, and `StatementTag`,
`CommentTag`, `LiteralEscapeTag` are grammar-**recognized** productions that §B.5 **rejects** with a
caller-located diagnostic (Rules B.5.2, B.5.7, B.5.8). The scanner (§B.4) gives every `<%` opener an
explicit branch and a terminal classification — statement/block → forbidden-form `raise`, comment/
literal-escape/unterminated → `Finding` — so **no** EEx-token kind is ever silently dropped and no
input falls off the end. Grammar (§B.2), validation (§B.5), and the reference scanner (§B.4) now
accept and reject the **same** strings — for statements, comments, and literal-escapes, not just
whitespace — so F.3's "cannot diverge" actually holds. *Channel adjudication:* per the elixir-beam
counter-proposal, statement/block tags (which carry embedded control code) take the forbidden-form
`raise`, exactly like a stray `fn`; comments and literal-escapes (mere unsupported **shape**, no
parsed expression) yield a `Finding`. Both channels **anchor at the `~P` sigil node's `meta`**, so
one bad template reports exactly one source line (resolving non-blocking concern 3). The pl-design
"just add rejected-tag productions" and the elixir-beam "dual channel" requirements are both met:
grammar bloat is pure rejection (no runtime behavior), and every diagnostic still originates in
`parse/2`.

**F.9 — `map` is a bindable Producer yielding the ordered List of its lanes' terminal results
(§C.1.1, §C shared resolution, §C.4, §C.5 example, DF-M4).** *Objection (pl-design, Blocking 3):*
`map` committed N per-lane `agent_committed` results that **no** construct could reference —
`Producer` omitted `MapStmt` (so `let :xs = map …` was ungrammatical), and map lanes could not
`collect` — so `map` re-created the exact "outputs flow nowhere" wall (§A.1) this proposal exists to
dissolve. The §C.5 example proved the gap: after mapping `:findings` into patches, it folded
`<%= @findings %>` (the **original input**), silently discarding the patches. A producer with an
unreferenceable output type is a dataflow graph with a dangling out-edge. *Resolution (adopted):*
close the edge. (1) `MapStmt` is added to `Producer` (§C.1.1). (2) A `let`-bound `map` at address
`A` of journaled width `W` resolves (via the new `{:map, A}` `BindingRef` and `BoundList`, §C shared
resolution) to the List `[result(A ++ [0,0]), …, result(A ++ [W-1,0])]`, folded from each lane's
terminal `agent_committed.result` in **strict ascending lane order 0..W-1** — element order is
observable and equals lane index, pinned exactly as `CommitLanes` pins commit order. (3) A width-0
map binds `[]`. (4) The §C.5 example is fixed to `let :patches = (map … end)` then
`gather(~P"… <%= @patches %>")` (the producer parens are mandated by F.14). (5) A new conformance clause **DF-M4** states the rule and that an
**unbound** `map` is fire-and-forget (its lane outputs unreferenceable). This keeps everything a
pure journal fold: `BoundList` reuses the **existing** `agent_committed` fold machinery plus the
**existing** `map_started.width`, so — as the elixir-beam lens asked — DF-M4 adds **no** new event
and §C.4.5's "two new events" count is unchanged. *Rejected alternative:* leaving `map` unbindable
and telling authors to post-process the journal outside the workflow — rejected because it is the
very wall §A.1 names and would let one implementer invent an ad-hoc binding while another leaves the
outputs unreachable (a two-implementers failure).

**F.10 — Second-pass non-blocking refinements adopted.** (1) *Single-stage map lanes (concern 4).*
`AgentLane` is narrowed from `AgentStmt+` to `AgentStmt` (§C.4.1, Rule C.4.3): a multi-stage lane
has **no** intra-lane dataflow (`let` is forbidden in a map body, so stage s+1 cannot see stage s),
and — now that a `map` binds only its lanes' **terminal** results (DF-M4) — any non-terminal stage's
output would itself "flow nowhere," re-creating §A.1's wall inside the lane. A single-stage lane is
therefore the only Tier-1-consistent shape; **multi-stage lanes are deferred to Tier 2**. This
adopts concern 4's first option (restrict) over its second (merely document), because restricting is
the choice that preserves the proposal's own no-dangling-outputs thesis, and it makes DF-M4's
terminal-result definition unambiguous (each lane is one agent at `[e, 0]`). (2) *Single-fold
resolution (concern 2).* §C shared resolution gains an observably-equivalent note: an implementation
MAY fold the journal **once** and resolve all of a node's bindings (and a map's whole lane List)
against that one projection — mirroring `Accumulator.of/1` — keeping the mechanism O(journal) rather
than O(assigns × journal), without changing any observable result. (3) *Diagnostic anchor (concern
3).* §B.4 now states both diagnostic channels anchor at the sigil node's `meta`, so one bad template
reports one line. (4) *`prompt`-journaling wording (concern 5).* §6.4.1′, §C.2.4, DF-P2, and this
changelog's F.4 no longer say the rendered prompt is "journaled verbatim **before** the call"
(which read as a nonexistent prompt-only pre-call event, contra §C.2.5); they now say it is
**materialized by a pure journal fold before the call** and **journaled verbatim at commit** with
the provider `result`, never re-rendered on replay (DF-P3). (5) *Diagnostic completeness (concern
6).* the scanner has an explicit terminal branch for every `<%` opener and for end-of-input, so no
token kind is silently skipped and no input falls off the end (formal-notation's "an algorithm with
an input that falls off the end is a spec hole" is satisfied by construction).

---

*Third-pass resolutions (F.11–F.13).*

**F.11 — Uppercase `~P` processes NO escape sequences; every multi-line template is a heredoc
(§B.2, §B.3, §C.2.1, §C.4.1, §C.5, §C.6).** *Objection (elixir-beam, Blocking 1):* the design's
load-bearing choice of the **uppercase** `~P` sigil has a second, unstated consequence the spec got
factually wrong. An uppercase sigil not only skips `#{…}` interpolation (correctly noted, §B.2) but
also performs **no escape-sequence processing**: `quote(do: ~P"Improve:\n\n<%= @draft %>")` yields
the raw binary `"Improve:\\n\\n<%= @draft %>"` — **literal backslash-n**, not newlines. Because §B.4
slices `raw` verbatim into `{:text, binary}` and §B.6 passes text through unchanged, every **inline**
canonical example (§C.2.1, §C.4.1, §C.5, §C.6, all `~P"…\n\n<%= @x %>"`) would render a prompt
containing literal `\n\n`, silently sending broken prompts to the model — and directly contradicting
§B.3's own worked segment `{:text, "Improve this:\n"}` (a **real** newline, which only a heredoc or a
literal line break produces). §B.2's clause "escaping … rules are Elixir's" was flatly false for an
uppercase sigil. *Adjudication (both lenses; idiom-minimality is decisive):* adopt the **heredoc
fix** — the elixir-beam PRIMARY counter-proposal. (1) §B.2 now states normatively that `~P` is an
uppercase sigil and therefore performs **no** escape processing — its content is the verbatim source
binary, with only the closing-delimiter escape applying (exactly like `~S`); the misleading
"escaping … rules are Elixir's" clause is deleted. (2) **Every** multi-line example (§C.2.1, §C.4.1,
§C.5, §C.6) is converted to the heredoc form `~P"""…"""`, whose line breaks are real line terminators
in `raw`. (3) §B.3 is reconciled: the real-newline `{:text, "Improve this:\n"}` is stated to arise
from a heredoc/literal-newline template, and an explicit counter-illustration shows inline
`~P"Improve this:\n<%= @draft %>"` lowering to `{:text, "Improve this:\\n"}` (literal backslash-n),
so no implementer is misled. This keeps `Template.lower/3` a **pure verbatim slicer** — no invariant
touched, no new mechanism. *Rejected alternative (elixir-beam's own fallback, and the direction a
completeness-first lens might take):* have the §B.4 scanner un-escape a fixed, closed set
(`\n`→LF, `\t`→TAB, `\\`→`\`) on text segments so inline `\n` works as written. Declined because it
adds a **new enumerated-escape surface** that must itself be specified with counter-example rigor
(which escapes? what of a stray `\x`?) and introduces a fresh two-implementers divergence risk — a
mechanism-and-surface cost — for zero expressive gain over a heredoc, which already yields real
newlines with no new spec surface. Both remedies are invariant-safe (total, deterministic,
closure-free); the tie breaks on **mechanism minimality**, so the heredoc fix wins. (Neither prior
panel caught this because both reasoned about the sigil's no-interpolation property in isolation
without checking the coupled no-escape consequence against the live AST — the examples were never
executed. Non-blocking concern 1 is folded in: §C.2.2 now states that inside a `~P` template `#{…}`
is inert literal text, never interpolation and never rejected. Non-blocking concern 2 is folded in:
§B.3 now states assign names are template syntax scanned from the binary, never Elixir variables or
module attributes, so macro hygiene does not apply.)

**F.12 — `map`-over-`map` is closed by routing `over:` through `ResolveRef`; grammar, validation,
execution, and §D.4 now agree (§C.4.1, §C.4.2, §C.4.4 DecideMapWidth, §C.4.6 DF-M5, §D.4).**
*Objection (pl-design, Blocking 2):* the map→map path had a dangling, divergent out-edge. §C.1.1
makes `MapStmt` a Producer, so `let :b = map …` binds `:b → {:map, addr}`, and Rule C.4.1 admitted
any in-scope binding as `over:`. But `DecideMapWidth` resolved the collection with
`BoundValue(run_id, node.over.address)` — bypassing the polymorphic `ResolveRef`. `BoundValue`
matches a single `agent_committed` at `(address, iteration=0)`; a `{:map}` binding has **no** such
event (its address carries only `map_started`/`map_completed`; its lanes live at `addr ++ [e,0]`).
So a chained map parsed, name-resolved, and passed every validation rule, then crashed at runtime
with `BindingUnresolved(b_addr)` — a three-way contradiction: (a) two-implementers divergence (one
wires `DecideMapWidth` through `ResolveRef` and it works; another follows the text literally and
crashes); (b) a completeness hole (the grammar/validation accept a form execution cannot evaluate,
unmarked by any counter-example); (c) an internal contradiction with §D.4, which proves
`BindingUnresolved` unreachable for a validated tree even as this case raised it. The asymmetry
proving it an oversight: **every** other resolution site (assign injection in `agent`/`gather`/
`emit`) goes through `ResolveAssign`→`ResolveRef` (which handles `{:map}` via `BoundList`); only
`over:` reached past `ResolveRef` to `BoundValue`. *Adjudication:* adopt the **PRIMARY** counter-
proposal — close the edge and keep the natural `map`∘`map` pattern first-class. `DecideMapWidth`'s
collection step is changed from `BoundValue(run_id, node.over.address)` to
`ResolveRef(node.over, run_id, nil)`, so a `{:node}` over resolves via `BoundValue` and a `{:map}`
over via `BoundList` to its ordered lane-result List (the `is not a list → MapOverNotAList`
fail-closed guard is retained). A new conformance clause **DF-M5** states the rule; Rule C.4.1 and
the §C.4.2 `over` annotation are updated to admit `{:node}` **or** `{:map}` and to mandate
`ResolveRef`; §D.4 is rewritten so `BindingUnresolved` is genuinely unreachable for `{:node}`,
`{:map}`, and `map`-over-`map` alike. Grammar, validation, execution, and the §D.4 proof now agree.
*Why PRIMARY over the FALLBACK (compile-time reject a `{:map}` `over:` and defer chained map to
Tier 2):* both close the divergence and neither weakens an invariant (determinism, closure-freedom,
and the `max:` structural bound are untouched either way — a consuming map's `width = min(len, max)`
stays capped whether the list came from a `{:node}` or a `{:map}`). The tie-breaker per the
governing mandate is **agent-authorability**: PRIMARY makes `map`∘`map` (map a collection, then map
again over the results) a natural, first-class pattern that reuses `BoundList` **wholesale with zero
new machinery**, and it removes the very special-case (`over:` alone bypassing `ResolveRef`) that
caused the bug — restoring the symmetry that every value edge resolves through one path. The FALLBACK
would reject an invariant-safe, useful pattern for **no** invariant gain, and would leave `map`
bindable-for-`gather`/`emit` yet not mappable-over — an asymmetry more confusing than the width it
saves. PL-purity conceded both are acceptable and required only that the three-way inconsistency be
eliminated; PRIMARY does so while maximizing the authorability axis, so it is adopted.

**F.13 — Third-pass non-blocking refinements adopted.** (1) *`#{…}` inert in templates (concern 1).*
§C.2.2 now states that inside a `~P` template `#{…}` is not interpolation and not rejected — an
uppercase sigil renders it as inert literal text flowing verbatim into the prompt — distinguishing
it from the rejected literal-string interpolation `"…#{…}…"`. (2) *Macro-hygiene non-issue (concern
2).* §B.3 now states explicitly that assign names are template syntax scanned from the raw binary,
never Elixir variables or module attributes, so macro hygiene does not apply and no implementer
should reach for `var!`/`Module.get_attribute`. (3) *Rendered string, not struct, is journaled
(concern 3).* §C.2.4 and DF-P2 now state that `agent_committed.prompt` stores the **materialized
`EffectivePrompt` string**, not the inert `%Template{}` in `node.prompt` — the template-prompt commit
path overrides dataflow-ground §1's "store `node.prompt` verbatim" so replay (DF-P3) and audit read a
real prompt string. (4) *Non-list `over` fail-closed is REQUIRED (concern 4).* DF-M5 marks the
`MapOverNotAList` raise MUST-NOT-drop: list-ness is knowable only at runtime (a `schema` is advisory,
a schemaless producer is shapeless), so an implementer MUST NOT assume a `{"type":"array"}` schema
makes the guard unreachable.

---

*Fourth-pass resolutions (F.14–F.17).*

**F.14 — The `let` surface→AST mapping is pinned; block-bearing producers MUST be parenthesized
(§C.1.1, §C.1.2, Rule C.1.5, DF-L4; examples §C.4.1, §C.5.1, §D.4).** *Objection (elixir-beam,
Blocking 1):* the document pinned the `~P` sigil AST precisely (§B.4) yet was silent-and-misleading
on `let` — the one construct that introduces `=` to a DSL whose every other statement is a bare
call. Verified against real Elixir: because `let` is a paren-less call and `=` is low-precedence,
(a) even `let :d = agent("x")` surfaces as the **one-arg** `{:let, meta, [{:=, _, [name,
producer]}]}` (a match wrapping the producer), which the surface grammar `let : BindingName =
Producer` never revealed — so an implementer building a naive two-arg `node({:let, _, [name,
producer]}, …)` clause writes a clause that **never matches**; and (b) `let :patches = map :f,
over: :xs, max: 3 do agent("y") end` parses as the **two-arg** `{:let, meta, [{:=, _, [:patches,
{:map, _, [:f, [over: :xs, max: 3]]}]}, [do: agent]]}` — the `do…end` block **hijacked onto
`let`**, leaving the `map` **bodyless** — while §C.1.2/§C.4.2/DF-M4 all assume the `%Map{}` carries
its lane `body`. An implementer who (reasonably) matched `{:let, _, [{:=, _, [name, {:map, mm, [_,
_, [do: body]]}]}]}` (expecting the body on the map, mirroring the working unbound `map … do … end`
which DOES keep its body) gets a clause that never fires; the correct reading of the paren-free form
requires special-cased do-block-reattachment surgery. *Adjudication (both lenses converge; adopt the
elixir-beam PRIMARY counter-proposal verbatim):* **mandate parentheses around any block-bearing
producer and pin the `let` AST normatively.** §C.1.2 now states: (1) `let` surfaces as the uniform
one-arg `{:let, meta, [{:=, _, [name_ast, producer_ast]}]}` for **every** producer kind, with the
canonical `let :draft = agent("Write a draft.")` quoted exactly (as §B.4 does for the sigil); (2)
`name_ast` MUST be an atom literal left of `=`; (3) `parse/2` matches the one-arg shape then
dispatches `producer_ast` through the ordinary `node/3` path, so agent/synthesize/gather/map reuse
their existing clauses unchanged — no reattachment surgery; (4) a block-bearing producer (`map`)
MUST be parenthesized (`let :xs = (map … do … end)`), and a bare `let :x = map … do … end` is a
caller-located compile error (new Rule C.1.5 / DF-L4) detected by its two-arg `{:let, _, [_, [do:
_]]}` shape, with a hint to add parens. `Producer`'s `MapStmt` alternative is rewritten `` `(`
MapStmt `)` ``; the two `let :… = (map … end)` examples (§C.4.1, §C.5.1) and the §D.4 prose gain the
parens. *Why the paren form over the reattachment-surgery fallback:* the elixir-beam alternative
(pin the 2-arg shape and normatively require `parse/2` to splice `[do: body]` back onto the map's
args) works but is exactly the do-block surgery the parenthesized form avoids — a fragile special
case that the paren form removes entirely by making the AST **uniform** across producer kinds. As
elixir-beam noted, the paren fix pins the AST **without touching any semantic property** —
determinism, closure-freedom, replay-safety, and the `map.max` structural bound are byte-for-byte
unchanged whether the producer is parenthesized or not — so there is no lens conflict: the
reconciliation is free (pin the AST, keep the parens, lose nothing). *Rejected readability
objection:* a surface-elegance view might resist mandatory parens around `map` producers; declined
because the paren is one character-pair on the rare block-bearing producer and it is the sole thing
that makes the surface→AST mapping correct — mechanism correctness outranks the cosmetic cost of two
parens (CLAUDE-invariant: mechanism fidelity is non-negotiable).

**F.15 — `gather` reuses `AgentStmt`'s `Prompt` nonterminal; grammar and validation now accept the
same strings (§C.5.1, §C.5.2).** *Objection (pl-design, Blocking 2):* the production `GatherStmt :
gather ( Template )` derived **only** a `~P` sigil, but Rule C.5.1's prose said "a gather with a
literal string and no assigns is legal but pointless," and §C.1.1's `Producer` listed `GatherStmt`
for `let :r = gather(…)` — so `gather("done")` was **rejected** as ungrammatical by the production
yet **accepted** by the validation prose: the exact grammar/validation split §F.8 was meant to
eliminate, reintroduced for `gather`. Team A implements the grammar and rejects the literal form;
team B implements the prose and accepts it — a two-implementers divergence. *Adjudication (adopt the
pl-design PREFERRED counter-proposal):* change the production to `GatherStmt : gather ( Prompt )`,
reusing **§C.2.1's existing `Prompt : StringLiteral | Template`** — so `gather` mirrors `agent`
exactly, a literal-string gather is grammatical, and the prose is consistent. §C.5.2's reduction is
updated so the reduced `%Agent{}` may hold either the `%Template{}` or the literal binary (with
`bindings: %{}` for a literal). *Why `Prompt`-reuse over the delete-the-sentence alternative* (keep
`gather ( Template )` and replace the "literal … is legal" sentence with an explicit rejection +
counter-example): `gather` is `synthesize`-generalized, and a literal fold is harmless (it is just
`synthesize` with no inputs), so admitting it costs nothing and reusing the already-defined `Prompt`
nonterminal keeps `gather` and `agent` symmetric — the smaller, more uniform surface. Both experts
accept this (elixir-beam's preference for a tight `~P`-only `gather` is honored in spirit — a `~P`
template is still the useful case and every worked example uses one — while the grammar no longer
contradicts the prose).

**F.16 — The §A.4 amendment set is enumerated exhaustively; the template-prompt commit path and its
projection are added as §6.4-commit′ / §7.2′ / §7.3′ (§A.4, §C.2.4, DF-P2/DF-P3).**
**[Superseded in part by F.18: the fourth pass's "six/exhaustive" enumeration was still incomplete —
it missed `agent_attempt_rejected.prompt`; the live count is now **seven** and the commit rule reaches
every prompt-bearing agent event. The `EffectivePrompt(…, ctx)` signature token below is superseded by
the `lane` signature of F.19. The rest of this entry stands as the fourth-pass record.]** *Objection
(pl-design, Blocking 3):* §A.4 claimed the proposal amends "**three** normative clauses" (§1.3 P6,
§6.4.1, §8 C9), but §C.2.4/DF-P2 **also** override `SPEC §6.4`'s commit rule so a template-prompt
agent stores the materialized `EffectivePrompt` **string** instead of `node.prompt` — silently
altering two further shipped normative surfaces the amendment set never named: (a) `SPEC §7.2`
`agent_committed.prompt` payload semantics, and (b) `SPEC §7.3`'s `agents` read-projection
(`%{address, prompt, result, usage, idempotency_key}`), which is **observable output** consumed by
the §7.5 envelope and the status UI. A conforming §7.3 implementation would surface the inert
`%Template{}` struct under `prompt` where DF-P2 requires a rendered binary — so the reconciliation
did not actually hold; it contradicted §7.2/§7.3 while claiming completeness. *Adjudication (adopt
the pl-design counter-proposal — a pure completeness obligation neither lens waives):* §A.4 now
opens by enumerating **six** value-injection amendments as an explicit list (P6′, C9′, §6.4.1′,
§6.4-commit′, §7.2′, §7.3′) — replacing the false "three" count — and adds a new normative clause
**§6.4-commit′ / §7.2′ / §7.3′** stating: for a template-prompt agent the commit path MUST store
`EffectivePrompt(node, run_id, ctx) :: String.t()` in `agent_committed.prompt` in place of
`node.prompt`, so the §7.3 `agents` projection carries the rendered binary, **never** the inert
`%Template{}` struct. The separately-scoped `SPEC §5.10.2` terminal-value widening (by `emit`) is
explicitly cross-referenced (§C.7.2/DF-E2) so the enumeration omits nothing. *Why this and not a
weaker note:* §7.3 is shipped observable output, so the amendment set MUST be exhaustive or the
document repeats the very reconciliation-failure the lens hunts; the fix is cheap (enumerate the
clauses, pin the stored value's type) and changes **no** agreed behavior — DF-P2 already required
the rendered string, this only makes the shipped surfaces it touches explicit. As both lenses noted,
storing the rendered string is obviously correct (it mirrors how the writer already journals
`synthesize`'s composed prompt); the objection was completeness, not behavior, and completeness is
now satisfied.

**F.17 — Fourth-pass non-blocking refinements adopted.** (1) *Uppercase-`~P` delimiter-escape wart
(concern 1).* §B.2's claim that "the one transformation … is escaping the closing delimiter (`\"`)"
is deleted: verified in real Elixir, `\"` inside an uppercase sigil collapses but emits a
**deprecation warning** (and may become a hard error), so the spec no longer recommends it. §B.2 now
states an uppercase `~P` does **no** escape processing (`~P"a\\b"` is four bytes) and that a literal
delimiter character is embedded via an alternate delimiter (`~P[…]`/`~P/…/`/`~P|…|`) or a heredoc —
never a backslash-escape. The load-bearing claim (no `\n`/`\t`/`\\` processing) is unchanged; only
the defective `\"` exemplar is removed. (2) *`String.to_atom` on `let`/`map`/element names (concern
2).* §C (BindingEnv) gains a note that `let`/`map` binding names and `map` `ElementName`s become
atoms via the same author-source-only compile-time path as `phase` names and template assign names —
bounded, no atom-exhaustion — so a reviewer of the Elixir port does not flag `String.to_atom` at
these sites. No code change; a completeness note. (3) *Top-level grammar integration (concern 3).*
§C now pins `LetStmt`/`MapStmt`/`GatherStmt`/`EmitStmt` as new alternatives of `SPEC §3`'s top-level
`Statement` nonterminal, admissible **only** at top level (not loop-body or map-body statement sets)
— the goal-symbol closure the 8-part bar requires, previously inferable from validation prose but
un-pinned in the grammar. (4) *`map` ElementName shadowing (concern 4).* new **Rule C.4.5** rejects
an `ElementName` that shadows any in-scope binding, with a counter-example; §C.4.2's element-binding
extension is restated as **disjoint**. *Adjudication:* adopt **reject** over the permissive
"element-wins ordered-map overwrite" option — for author clarity and symmetry with Rule C.1.3's
unique-name-per-scope discipline; the permissive option was declined because a silent shadow across
the nested map scope is exactly the kind of edge two authors would reason about differently. (5)
*Missing-`over:` counter-example (concern 5).* Rule C.4.1 now carries the smallest missing-`over:`
counter-example (`map :x, max: 10 do … end`) and states `over:` is a REQUIRED key, so the required-
key set `{over:, max:}` is fully witnessed (matching the `SPEC §5.10.4` exact-key-set discipline
already cited for `max:`). (6) *`map` lane that ignores its element (concern 6).* new **Rule C.4.6**
requires the lane `agent`'s prompt to be a `%Template{}` whose `assigns` include the `ElementName`;
a literal-prompt lane, or one referencing only enclosing bindings, is rejected. *Adjudication:*
adopt the stricter **reject** option over "merely note it is degenerate" — a lane that ignores its
element makes every lane a byte-identical replica, re-creating §A.1's wall inside the lane for the
identical reason §F.10 mandated single-stage lanes; rejecting it preserves the proposal's own
no-dangling-outputs thesis (an author wanting N identical turns wants `fan_out`, not `map`). Both
adjudications (4 and 6) pick the invariant-consistent restriction over documentation, matching the
F.10 precedent.

**F.18 — The §A.4 amendment set now reaches `agent_attempt_rejected.prompt`; the enumeration is
"seven," and the commit path stores the rendered string on EVERY prompt-bearing agent event
(§A.4(6), §6.4-commit′/§7.2′/§7.2-rejected′/§7.3′, §C.2.4, DF-P2).** *Objection (pl-design,
Blocking 1):* F.16 declared the amendment set exhaustive at **six** and broadened the commit rule
for **only** `agent_committed.prompt` and the §7.3 projection — but `SPEC §7.2` defines a **second**
prompt-bearing journaled event, `agent_attempt_rejected` (`address, iteration, attempt, prompt,
output, reason, usage`), written by the fail-closed retry path (`SPEC §6.4` CommitAttempt) for a
template-prompt agent WITH a schema and `retries > 0` — a shape Rule C.2.3 admits and the day-one
ADOPT slice uses. Under the still-normative base "store `node.prompt` verbatim" rule, that event's
`prompt` payload is the inert `%Template{}` **struct** while the same node's eventual
`agent_committed.prompt` is a rendered **string** — the exact struct-vs-string divergence on a
single node's own events that F.16 was created to eliminate, and a two-implementers divergence
(store the struct vs. the rendered string) on a shipped observable surface (`SPEC §7.2`,
`agent_attempt_rejected.prompt`). So the "six/exhaustive" claim was self-contradictory. *Adjudication
(adopt the pl-design counter-proposal — a pure completeness/consistency obligation both lenses
accept):* §A.4 now enumerates **seven** amendments, adding `SPEC §7.2 agent_attempt_rejected.prompt
→ §7.2-rejected′` as the seventh item, and §6.4-commit′ is broadened from "stores `EffectivePrompt`
in `agent_committed.prompt`" to "stores the materialized `EffectivePrompt` string in the `prompt`
payload of **EVERY** prompt-bearing agent event it writes — both `agent_committed.prompt` AND
`agent_attempt_rejected.prompt`." This is well-defined because `EffectivePrompt` is provably stable
across attempts: the template's producers commit before the consumer runs (define-before-use,
§B.5.5) and are immutable, so every attempt — rejected or committed — renders a byte-identical
string, and DF-P3's "never re-render an already-committed agent" is unaffected. `agent_failed`
carries no `prompt` key (`SPEC §7.2`), so it needs no amendment; only `agent_committed` and
`agent_attempt_rejected` do. *Why this and not a weaker note:* the objection is completeness, not
behavior — storing the rendered string is the obviously-correct value on both events, and it mirrors
the elixir-beam lens's own "journal a real prompt string, never a struct" intent; leaving the
rejected-attempt event on the base rule would repeat the very exhaustiveness failure the lens hunts.
No invariant moves: the key stays value-free (Principle 2), the render stays a deterministic journal
fold (§D.2), replay-safety is unchanged (DF-P3). The prior `EffectivePrompt` signature token in F.16
(`… , ctx`) is superseded by the `lane` signature of F.19; F.16 otherwise stands.

**F.19 — Map lane-index threading closed: `RunLane`/`BuildAgent` carry a `lane`, `EffectivePrompt`
takes `lane` (§C.4.4 RunMap + Lane-threading bullet, §C.2.4 EffectivePrompt, DF-M2).** *Objection
(elixir-beam concern 1, raised by the pl-design cross-note to be blocking on completeness grounds):*
`RunMap` bound `lane` in the `RunConcurrently` fn head (`fn (lane_body, lane) -> …`) but never
delivered it — it called `RunLane(lane_body, run_id, provider, prior)` with no `lane`, and the
`SPEC §6.9` `RunLane`/`BuildAgent` chain had no `lane`/`ctx` parameter, while `EffectivePrompt`
read a `ctx.lane` that no map-lane caller ever set. A `map` lane is the **only** lane whose prompt
depends on a runtime quantity (`@element = Index(BoundValue(over), e)`), so without a threading path
two implementers could not converge on which element each lane renders — the same asymmetry-oversight
class F.12 caught for `over:`/`ResolveRef`, and one the proposal's own §D.2 proof and DF-M2 silently
assumed away. *Adjudication (adopt the elixir-beam counter-proposal — a pure execution-algorithm fix
that touches no compile-time property, and where the two lenses do NOT actually conflict):*
`EffectivePrompt` now takes an explicit `lane` (not `ctx`); `RunLane`/`BuildAgent` are extended to
**§6.9′** with a trailing `lane` argument that `RunLane` threads to each `BuildAgent` and
`BuildAgent` threads to `EffectivePrompt`; `RunMap` passes `%{index: e}` for lane `e`. The extension
is **conservative for every base-SPEC caller**: `parallel`/`pipeline`/`fan_out` pass `lane = nil`
and render byte-for-byte as before (their per-lane data is baked into compile-time addresses), so no
shipped behavior changes; only a `map` lane passes a non-`nil` lane. *Why no lens-conflict:* the
elixir-beam lens guards closure-freedom, and the threaded `lane` is plain inert data (`%{index: e}`,
a map — never a closure), so inertness (§D.1) is fully preserved; the pl-design lens needed only the
completeness path, which is now specified end-to-end (RunMap → RunLane → BuildAgent →
EffectivePrompt → RenderTemplate). DF-M2 now normatively requires the threading. *(Correction,
fifth pass:* F.19 left the **`RunConcurrently` hop** that actually carries `lane` from `RunMap` into
the worker unpinned — the `fn (lane_body, lane) -> …` head had no defined source against base
1-arity `RunConcurrently`. That gap is closed by **F.23**, which pins `RunMap`'s `branches` as an
ordered List of `{lane_body, lane}` pairs and keeps base `RunConcurrently` 1-arity and unchanged.)

**F.20 — Binding/element atom-literal surface productions de-conflated with a lexical
`BindingRefAtom` (§C.1.1 LetStmt, §C.4.1 MapStmt/MapOpt).** *Objection (pl-design concern 3):* the
surface productions `LetStmt : `let` `:` BindingName` (with `BindingName : Atom`), `MapStmt : `map`
`:` ElementName`, and `MapOpt : `over:` `:` BindingName` each conflated a **lexical** atom token
with a stray **syntactic** `:` terminal — at the token level they denote `let ::draft`,
`map ::finding`, `over: ::findings`, i.e. a double colon, the exact lexical/syntactic conflation
formal-notation.md flags as most common. The §C.1.2 AST pinning rescued real divergence, so this was
presentational, but the document holds itself to "two implementers cannot diverge from the GRAMMAR
alone" (§B.4, F.14). *Adjudication (adopt the pl-design lexical-production fix over leaning on the
prose/AST-pinning caveat — reconciling the two lenses):* a lexical production
`BindingRefAtom :: `:` AtomName` (double-colon = lexical; the `:` and name are one token with no
whitespace between) is defined once in §C.1.1 and reused by §C.4.1; the three productions now read
`let BindingRefAtom = …`, `map ElementName …` with `ElementName : BindingRefAtom`, and
`over: BindingRefAtom`, dropping the stray syntactic `:` so the grammar accepts **exactly** what the
examples and the pinned AST require. The elixir-beam lens's "the AST pins it, so the prose is mere
illustration" position was not adopted for the grammar text itself, because the self-imposed
grammar-alone bar (§B.4/F.14) makes the malformed production an inconsistency worth the one-line
lexical fix; the AST pinning (§C.1.2) is retained unchanged as the belt to the grammar's braces.

**F.21 — `map_started.over` pinned to the `BindingRef` tuple (§C.4.5, DecideMapWidth).** *Objection
(pl-design concern 4):* §C.4.5 pinned the journaled `map_started.over` payload but its prose called
`over` "the collection's ADDRESS," while §C.4.4 sets it from `node.over`, a `BindingRef`
(`{:node, addr}` | `{:map, addr}`) — not a bare address. As a normative journaled payload key this
type ambiguity could diverge two implementations (one storing `[i,0]`, one `{:map,[i,0]}`).
*Adjudication (adopt the pl-design counter-proposal):* `map_started.over` is pinned to **`node.over`
verbatim** — the whole `BindingRef` tuple (inert and serializable) — and the prose is corrected from
"the collection's address" to "the collection's `BindingRef` (`node.over`)"; `DecideMapWidth`'s event
constructor is written `Event.map_started(node.address, node.over, …)` so the stored value is
unambiguous. No behavior changes (the payload was always derived from `node.over`); the fix removes a
payload-type divergence on a shipped journal surface.

**F.22 — Sigil delimiter removed from the §B.2 Template production; the normative lexical input is
the `raw` binary (§B.2 grammar + delimiter note, §B.4, T2).** *Objection (pl-design, Blocking 1):*
§B.2 pinned the delimiter **inside** the normative production — `Template :: ~P StringDelimiter
Segment* StringDelimiter` with `StringDelimiter :: "` | `"""` — admitting only quote and heredoc
delimiters, yet the same section's prose and F.17(1) both endorse alternate sigil delimiters
(`~P[…]`/`~P/…/`/`~P|…|`), and the §B.4 reference recognizer matches the **delimiter-agnostic** AST
node `{:sigil_P, meta, [{:<<>>, _, [raw]}, _mods]}` and scans `raw` — so it accepts `~P[Fix <%= @x
%>]`, which the §B.2 grammar cannot derive. The recognizer was a strict **superset** of the grammar
it is declared (T2/§B.4) to implement exactly: a grammar-literal team rejects `~P[Fix <%= @x %>]`, an
AST-matching team accepts it — the F.7/F.8 grammar-vs-recognizer divergence class, reintroduced at
the delimiter. *Adjudication (adopt the pl-design PREFERRED counter-proposal — the `raw`-based
rewrite):* the delimiter is removed from the Template production, which is now `Template :: Segment*`
— **the grammar OF the `raw` binary** the `~P` sigil delivers — plus a normative note that the sigil
delimiter (`"`, `"""`, `[]`, `//`, `||`, `()`, `{}`, `<>`, `''`, …) is **Elixir's sigil-lexer
concern and out of scope for §B.2**; the template's lexical input is the verbatim `raw` binary. This
puts §B.2 and the §B.4 recognizer in **exact agreement by construction** — both operate on `raw`,
never on the delimiter — matching the prose/F.17 endorsement of alternate delimiters. *Why the
`raw`-rewrite and not enumerating every delimiter pair in `StringDelimiter`:* the enumeration form
also closes the divergence but re-pins a delimiter set in-grammar for a **non-Elixir host** that may
have no such lexer; the `raw`-rewrite keeps a non-Elixir host free (it supplies `raw` by whatever
means) while matching §B.4 exactly, which is precisely what F.7 demanded (grammar and recognizer
identical by construction). *Cross-lens:* the elixir-beam lens welcomed leaning on Elixir's native
sigil lexer and confirmed the `raw`-rewrite keeps a non-Elixir host free, so the two lenses agree; no
conflict to adjudicate here. Also (elixir-beam non-blocking 1) new **Rule B.5.9** pins that a `~P`
sigil MUST carry **empty** modifiers (a non-empty `mods` charlist — `~P"…"x` — is a caller-located
`Finding` at `meta`), closing the last unpinned slot of the recognizer's accept-set; the empty
template `~P""` was empirically confirmed fine (quotes to `{:<<>>, [], [""]}`, both scanner and
recognizer accept), so no grammar/recognizer/scanner three-way inconsistency exists there.

**F.23 — `map` lane-index provenance pinned: `RunMap`'s `branches` is a List of `{lane_body, lane}`
pairs; base `RunConcurrently` stays 1-arity and UNCHANGED (§C.4.4 RunMap + Lane-provenance bullet,
DF-M2).** *Objection (pl-design, Blocking 2):* `RunMap` called `RunConcurrently(branches, cap, fn
(lane_body, lane) -> …)` — a **2-arity** worker — but base `RunConcurrently(inputs, cap, fun)`
(SPEC.md:1997–2009, verified) applies `fun` as a **1-arity** worker, and every base caller passes
`fn branch -> …`. The proposal extended `RunLane`/`BuildAgent`/`EffectivePrompt` to §6.9′ with a
`lane` argument (F.19) but never extended or redefined `RunConcurrently`, and never pinned whether
`branches` is a list of bodies or of `{body, lane}` pairs — so the `lane` bound in the worker head
had **no defined source**. F.19's claim to have specified the chain "end-to-end (RunMap → RunLane →
BuildAgent → EffectivePrompt → RenderTemplate)" **skipped the RunConcurrently hop** that actually
threads the index; an implementer following the text literally could not make `RunMap` typecheck
against the defined `RunConcurrently`. *Adjudication (adopt the pl-design PREFERRED counter-proposal
— pin `branches` as pairs, leave base `RunConcurrently` untouched):* `RunMap`'s `branches` is now the
ordered List `[ {Rebase(node.body, node.address ++ [e]), %{index: e}} for e in 0..width-1 ]`, and the
worker is the still-**1-arity** `fn {lane_body, lane} -> RunLane(lane_body, run_id, provider, prior,
lane) end`, which destructures the pair. Base `RunConcurrently` (SPEC §6.9) is **not perturbed** — it
applies the 1-arity worker to each element (here a pair) in input order. §C.4.4 gained a normative
**Lane-provenance** bullet and DF-M2 now cites the pinned form, so the lane's provenance into
`EffectivePrompt` is defined end-to-end including the RunConcurrently hop. *Why this and NOT the
elixir-beam alternative (extend `RunConcurrently` to §6.9′ as a `Task.async_stream` +
`Stream.with_index` 2-arity index-passing worker):* this is the one place the two lenses could
collide — idiomatic-Elixir convenience (elixir-beam: a native 2-arity index-passing stream) vs.
PL-purity (pl-design: do not perturb a shipped algorithm). Both are invariant-safe (the `lane` is
inert `%{index: e}` data, closure-freedom §D.1 preserved). I picked the **pairing form** because it
leaves the load-bearing, shipped, five-caller base `RunConcurrently` **byte-identical and
monomorphic** (always a 1-arity `fun` over a list, whatever the element shape), whereas the 2-arity
extension introduces an arity **overload** ("`fun` MAY be 1- or 2-arity") into a shared base
algorithm — exactly the kind of implicit branching two implementers reason about differently, and a
regression to a surface the experts did **not** ask to change. The elixir-beam preference is honored
non-normatively: §C.4.4 notes an Elixir implementation MAY realize the pairing idiomatically via
`Task.async_stream` over the pre-zipped `[{lane_body, lane}]` List (built with `Stream.with_index`),
which is observably equivalent (`SPEC §8`). Observable order was already fixed by input-order commit
(DF-M2), so this is a completeness pin with **zero** behavior change.

**F.24 — Fifth-pass non-blocking refinements adopted (Rule C.2.4 active guard, BindingEnv locus,
`map_started.observed_length` replay-verbatim).** (2) *`~P` in non-template positions rejected by an
ACTIVE guard, not accidentally (elixir-beam non-blocking 2).* Rule C.2.4 now pins that each
non-template position's `parse/2` clause MUST match `{:sigil_P, meta, _}` and emit a caller-located
`Finding` — the rejection MUST NOT be left to `to_text/1`, whose `inspect(other)` fall-through would
silently stringify the AST tuple into a garbage prompt rather than raise. Without the explicit guard
a faithful implementer of the base clauses would admit `~P` everywhere as inspected junk. (3)
*BindingEnv threading locus (elixir-beam non-blocking 3).* **[Superseded by F.25.** This fifth-pass
pin — "threaded by the `build/5` statement-dispatch fold; the per-form entry carries only the
`Macro.Env`" — was self-contradictory: a node's `bindings` field is built **inside** the per-form
entry (which under this pin saw no `BindingEnv`), and a `map` lane's `@element` is bound only in the
map-body scope the top-level fold never reaches, so it could populate no `bindings` field and resolve
no lane `@element`. F.25 retracts it and threads `binding_env` through the **widened per-form entry**
instead (F.19-style uniform arity widening).**]** The fifth pass originally pinned that the
compile-time `BindingEnv` is threaded by the **statement-dispatch fold** (`build/5`) because the real
`node/3` signature `(form, address, env)` carries only the `Macro.Env`; that locus is replaced by the
F.25 widened-entry locus (§C intro). (5) *`observed_length`
replay-verbatim (pl-design non-blocking 5).* §C.4.5 now states the entire `map_started` payload —
including the audit-only `observed_length` — is read back verbatim on replay and never recomputed;
`DecideMapWidth` does not re-fold `over`, putting `observed_length` on the same replay-verbatim
footing as `width`, so an implementer does not re-derive it and risk a mismatch if `over` were later
widened to a mutable source. (4) *Binding-name char class (pl-design non-blocking 4).* Rule C.1.1 now
requires a binding/`map`-element name to match `AtomName` and REJECTS a trailing `?`/`!` (`:ok?`,
`:done!`), with the smallest counter-example. *Adjudication:* adopt the **restriction** over widening
`AtomName` to `[?!]?`, because `AssignName` (the `@name` template-reference surface, §B.2) has no
trailing `?`/`!` either — widening only the binding name would mint a bound name no `~P` template
could reference (`<%= @ok? %>` is underivable), an asymmetry two authors would resolve differently;
one character class for both surfaces keeps every bound name template-referenceable and the rule
decidable. (Non-blocking 1 — the `~P` empty-modifier rule — is recorded under F.22 with the delimiter
fix it accompanies.)

---

*Sixth-pass resolutions (F.25–F.27).*

**F.25 — The compile-time `BindingEnv` is threaded through the widened per-form entry, not the
`build/5` fold; the F.24(3) locus pin is retracted (§C intro, §C.2.2, §C.4.2, F.24(3)).** *Objection
(elixir-beam, Blocking 1):* the fifth-pass pin (F.24(3)) fixed, normatively, that the `BindingEnv` is
threaded **only** at the `build/5` statement-dispatch fold and that the per-form entry `node/3`
"carries **no** `BindingEnv` … the name-resolution fold reads its scope from that threaded
`BindingEnv`." Verified against `lib/workflow/compiler.ex`: `node/3` and `body_node/3` do have the
`(form, address, env)` `Macro.Env`-only signature **and the node struct is constructed inside
`node/3`** (`build/5` only post-inspects the returned node for the `%Phase{}`/`seen` check). The pin is
therefore self-contradictory at two sites the document holds to its grammar-alone bar: (a)
**`%Agent{}.bindings`** (§C.2.2) is "resolved at compile time" to `%{atom => BindingRef}`, which must
be filled where the `%Agent{}` is built — inside the entry — yet under the pin the entry sees no
`BindingEnv`, so it can populate **no** `bindings`; and (b) a **`map` lane's `@element`** (Rule C.4.6
REQUIRES it) is bound `element_name → {:element, over}` **only** in the map-body scope, and the lane
agent is parsed inside the `map`'s entry clause, not as a top-level statement `build/5` folds over — so
the top-level `BindingEnv` provably never contains `:element` and `build/5`-level resolution cannot
reach the lane's `@element`. Two implementers diverge: one widens the entry to carry the `BindingEnv`
and it works; one follows the pinned text literally and can resolve neither. This is the unclosed
**compile-time twin** of the runtime lane-threading asymmetry F.19/F.23 closed (and the
`over:`/`ResolveRef` asymmetry F.12 closed). *Adjudication (adopt the elixir-beam PRIMARY
counter-proposal — widen the per-form entry; reject the separate-pass alternative):* retract the
F.24(3) pin and thread `binding_env` as a real explicit accumulator **through the per-form entry
itself** — `node(form, address, env, binding_env)` and its body/map-lane equivalents — exactly the
uniform trailing-argument widening F.19 applied to `RunLane`/`BuildAgent` on the runtime side.
`build/5` passes `binding_env` into each entry call and **extends** it after each `let`/`map` returns
(define-before-use, B.5.5); each prompt-bearing clause (`agent`/`gather`/`emit`) resolves its
`template.assigns` against `binding_env` **at construction**, populating `bindings` and raising the
caller-located B.5.4/B.5.5 findings at the consuming form (§C.2.2 construction step); the `map` clause
parses its lane agent under `Map.put(binding_env, element_name, {:element, over})` (§C.4.2) so
`@element` resolves in the extended scope. *Why the widened entry (Option A) over a separate
`resolve_bindings(tree, binding_env)` pass over the inert tree (Option B):* the pl-design cross-note
flagged that a PL-purity lens might prefer Option B — to keep the per-form entry **monomorphic** — on
the F.23 "do not perturb a shipped algorithm" instinct. I decline Option B for two reasons. **(1) F.23
does not govern here.** F.23 refused an arity **overload** (a base algorithm's `fun` MAY be 1- **or**
2-arity — an *implicit branch* inside `RunConcurrently`, a base shared by five callers). Widening the
per-form entry is **not** an overload: every clause gains the **same** trailing parameter and most
ignore it, exactly as `parallel`/`pipeline`/`fan_out` ignore F.19's `lane`. A uniform monomorphic arity
widening of a per-form/per-lane entry is **F.19-class (accepted)**, not F.23-class (refused) — so
closing the compile-time twin with the same move F.19 used on the runtime twin is the *consistent*
choice, not a perturbation. **(2) Caller-location.** B.5.4/B.5.5 findings MUST be caller-located
(`SPEC §5.0`). Option A raises them at construction with the form AST + `Macro.Env` in hand — identical
to every shipped `Finding.at(env, form, …)`. Option B walks the **inert** tree, which carries no
`meta`, so it would have to either add source-location to every node struct (a struct-shape
perturbation larger than one entry parameter) or re-thread the original form ASTs beside the tree
(defeating its own "walk the inert tree" premise). Both options are invariant-safe — the `BindingEnv`
is inert compile-time data (atoms + addresses), so closure-freedom (§D.1), determinism (§D.2), bounded
termination (§D.3), and replay-safety (§D.4) are untouched either way — so the tie breaks on
precedent-consistency and caller-location, both favoring Option A. *(Non-blocking 2 folded in: §C.2.2
now names the explicit `bindings`-construction step and confirms the resulting `%{atom => BindingRef}`
map — atoms + addresses only — is `Macro.escape`-able, so the whole `%Tree{}` still escapes to a
compile-time constant per the `workflow/2` shell.)*

**F.26 — `SPEC §1.2` added to the §A.4 amendment set as the eighth item; §1.2′ surgically narrows only
the "General computation" bullet (§A.4, §A.4(7) §1.2′, DF-L1).** *Objection (pl-design, Blocking 2):*
§A.4 claimed its **seven**-clause amendment set is exhaustive — "no further shipped clause is silently
overridden" — but `SPEC §1.2` Non-goals (SPEC.md:43–48) is a distinct normative section headed "MUST
NOT be expressible" whose General-computation bullet states flatly "There is no value-binding
construct," and `let` (§C.1) IS a value-binding construct whose DF-L1 clause overrides it. §A.4 amended
§1.3 P6 → 6′ and §8 C9 → C9′ (the two *principle/conformance* restatements of no-binding) but **not**
§1.2 (the *Non-goal* restatement), so a stranger reading SPEC.md §1.2 + this extension hits a direct,
unreconciled contradiction ("there is no value-binding construct" vs. "add `let`") — a two-implementers
and stranger failure, and the identical exhaustiveness-failure class the prior passes kept re-finding
(three → six → seven items; the count was still short by the single most prominent clause, a top-level
Non-goal). The surgical subtlety the lens flagged: §1.2's bullet **bundles** "bind variables" with
"branch on agent output" and "perform arithmetic," which the proposal preserves — so a blanket
amendment would wrongly reopen the latter two. *Adjudication (adopt the pl-design counter-proposal):*
§A.4 now enumerates **eight** amendments, adding `SPEC §1.2` → **§1.2′** as item 8 and correcting the
running count ("seven" → "eight") and the exhaustiveness sentence to cite §1.2 → §1.2′. §1.2′ (§A.4(7))
edits **only** the General-computation bullet — "A workflow cannot compute values at runtime, branch on
agent output, or perform arithmetic. The **only** value-binding construct is `let` (§C.1) … value-
dependent **control** flow remains unexpressible (Principle 8, §C.8.1)" — leaving the arithmetic and
branch-on-output bans of the same bullet, and the Non-determinism / Side-effects / Runtime-linting
Non-goals, fully intact. DF-L1 (§C.1.6) now cites §1.2′, exactly as DF-P1 cites §6.4.1′. *Why a
strengthening, not a weakening (mirroring §A.4(3)):* §1.2 previously banned **all** binding as a blunt
proxy for "no capture / compute / branch"; §1.2′ states the real property directly — bind only
journaled values, render only deterministically — and keeps every other ban of the bundle, so nothing
an author could not express becomes expressible except the one narrow, checked `let` edge. *No lens
conflict:* this is pure completeness both lenses want; the only care needed — carve out **only** the
binding clause, not the bundled arithmetic/branch bans — is honored by the surgical single-bullet edit.

**F.27 — Sixth-pass non-blocking refinements adopted.** (1) *`~P` empty-modifier check stated as
`mods == []` (elixir-beam non-blocking 1).* §B.4, Rule B.5.9, and §B.7 T1 now state the no-modifier
check as `mods == []` (equivalently the empty charlist `~c""`, since `~c"" === []`), removing the
implementer double-take over whether `Code.string_to_quoted` returns `[]` or `~c""` for a no-modifier
sigil (it returns `[]`). (2) *`%Agent{}`/`%Gather{}`/`%Emit{}` `bindings` construction step named
(elixir-beam non-blocking 2).* §C.2.2 now names the explicit step that materializes `bindings` — fold
each atom in `template.assigns` to `binding_env[atom]`, `%{}` for a literal prompt — and confirms the
resulting `%{atom => BindingRef}` map (atoms + addresses only) is `Macro.escape`-able, so the whole
`%Tree{}` still escapes to a compile-time constant. (Folded into F.25's threading fix, which supplies
the `binding_env` the step reads.) (3) *`emit` literal-string argument actively rejected (pl-design
non-blocking 3, a cross-lens conflict).* new **Rule C.7.4 / DF-E4** pins that `emit`'s argument MUST be
a `~P` `Template`; `parse/2` MUST match `{:emit, meta, [{:sigil_P, _, _}]}` and reject any other
argument (e.g. `emit("done")`) with a caller-located `Finding` at `meta`, never leave it to
`to_text/1`'s `inspect` fall-through. *Adjudication:* the elixir-beam lens could see rejecting a plain
string as needless ceremony ("a constant is a fine terminal"); the pl-design lens demands grammar and
validation accept the **same** strings with an active guard (the F.15/F.24(2)/Rule C.2.4 discipline). I
side with the active reject and keep `emit` **Template-only** — declining to widen `emit` to `Prompt`
the way F.15 widened `gather` — because `emit` of a pure literal is exactly `return`, which already
exists: admitting a literal `emit` would mint a second surface for an existing construct and blur the
`emit`≡render / `return`≡literal split, whereas a literal `gather` is a genuinely distinct (if
pointless) `synthesize`-with-no-inputs. The asymmetry with F.15 is therefore principled, not an
inconsistency. (4) *`inspect/1` map-key-ordering hedge stated normatively (pl-design non-blocking 4, a
cross-lens conflict).* §B.6 and §D.2 now carry a normative note that `Kernel.inspect/1` on a **runtime
string-keyed provider map** (new in this proposal — shipped `SPEC §4.4` only ever inspected
compile-time literals) guarantees no canonical key order across Elixir versions, so even the
within-Elixir-embedding byte-normativity holds only for a fixed host `inspect/1` (same version, equal
maps from equal JSON decode); authors needing a byte-stable journaled prompt/terminal MUST bind
**binary** values or pre-render each element to a binary via `map` before `gather`/`emit`.
*Adjudication:* the elixir-beam lens treats `Kernel.inspect/1` on a provider map as "obviously fine and
idiomatic"; the pl-design lens flags the cross-version key-order gap. Both accept the **binary-binding
hedge**; the reconciliation is to state it **normatively** (not in passing prose), which §B.6/§D.2 now
do — this is the one place the extension's determinism story is strictly weaker than the shipped
literal-only story it inherits, and it is now as loud as the closure-freedom guarantees.

---

*Seventh-pass resolutions (F.28–F.29).*

**F.28 — The closed-vocabulary count 13 → 17 is the NINTH §A.4 amendment; the "exhaustive by
inspection" list is replaced by a mechanical closure rule (§A.4 preamble, §A.4(4) fix, §A.4(8′),
§10.2′).** *Objection (pl-design, Blocking 2):* §C adds four new top-level combinator names — `let`,
`map`, `gather`, `emit` — as new alternatives of `SPEC §3`'s `Statement` nonterminal, silently
overriding the shipped **closed-vocabulary cluster** that fixes the count at **13**: `SPEC §1.3`
Principle 1 ("exactly **13** top-level combinators"), `SPEC §2.4` ("exactly these **13** … names"),
`SPEC §8` C1 ("outside the **13-way** vocabulary"), `SPEC` Rule 5.1.3 ("name … not in the vocabulary is
rejected"), and the `SPEC §10.2` at-a-glance table. **None** of the five was in the eight-item §A.4 set,
and §A.4(4) **affirmatively** asserted "Every other conformance clause (C1–C8) is untouched" — but C1
**is** touched (its 13-way count must become 17-way). Rejection tests: **two-implementers** — Team A
implements shipped C1/Rule 5.1.3 and rejects `let :d = agent("draft")` as an unknown bare call; Team B
implements §C and accepts it — divergence on the day-one ADOPT slice. **Stranger** — Principle 1
("exactly 13; new capability is added by adding a combinator to the closed set") + §C ("here are four
more") is an unreconciled contradiction while §A.4's exhaustiveness sentence promises none. This is the
ninth item of the identical exhaustiveness-failure class chased from three → six → seven → eight items
(F.16/F.18/F.24/F.26), and the single most prominent one (the FIRST design principle). *Adjudication
(adopt the pl-design counter-proposal in full):* §A.4 now enumerates **nine** amendments, adding the
closed-vocabulary cluster → **17-way** as item 9 (§A.4(8′)): **Principle 1′** ("exactly **17** top-level
combinators — the shipped 13 plus `let`, `map`, `gather`, `emit`; `collect` stays body-only"),
**§2.4′** (name set 13 → 17), **C1′** ("outside the **17-way** vocabulary"), Rule 5.1.3's vocabulary set
widened to include the four names (so they are **not** unknown bare calls — each has a `parse/2`
clause), and **§10.2′** (four new table rows). §A.4(4)'s false sentence is corrected to "Every other
conformance clause is untouched **except C1, whose 13-way count becomes 17-way (C1′)**; C2–C8 are
untouched," and the running count is corrected ("eight" → "nine"). *Why a STRENGTHENING, not a
weakening:* Principle 1 itself names the sanctioned extension path — "new capability is added by adding
a combinator to the closed set, never by allowing arbitrary Elixir" — so widening the **closed** set
from 13 to 17 **named** combinators is exactly that path; the set stays closed (Rule 5.1.3 still rejects
every name outside it) and arbitrary Elixir stays rejected. *No lens conflict:* pure completeness both
lenses want (elixir-beam has no idiom objection to widening a named closed set; pl-design's ninth
amendment is the design's own extension mechanism). *Methodology fix (pl-design non-blocking 3):*
because enumeration-by-inspection under-counted on five successive passes, §A.4 now states a **mechanical
closure rule** — amend every shipped clause that (a) states a combinator count, (b) restates the
no-value-binding ban, or (c) fixes the prompt/commit/projection payload type — backed by a **grep
checklist** over `SPEC.md`'s load-bearing literals ("13", "no value binding", "literal prompt",
"node.prompt"), so a stranger re-derives the exact set instead of trusting a list that has been wrong
every prior pass.

**F.29 — The per-form `node/4` 4th-argument decision is pinned at ALL FIVE base call sites, and `~P`
templates are restricted to top-level/map-lane agents by an active guard (§C intro threading locus +
scope decision, Rule C.2.4 narrowed, §C.2.1 grammar note, DF-P1).** *Objection (elixir-beam, Blocking
1):* the proposal widens the compiler's `node/3` to `node(form, address, env, binding_env)` but
specified the 4th-argument threading at **only** the top-level `build/5` site (`compiler.ex:122`).
`node/3` has **five** call sites — `build/5` (`L122`), `agent_branches` for `parallel` (`L471`),
`pipeline_stages` (`L538`), `agent_lane` for `fan_out` (`L979`), and `body_node → node` for loop bodies
(`L661`) — and the arity change forces a 4th argument at every one, decided at only one. Meanwhile Rule
C.2.4 admitted "an `agent` prompt" **without** qualifying "top-level", and §C.2.1 extended `AgentStmt`'s
`Prompt` nonterminal **globally**, so `parallel([agent(~P"<%= @d %>")])`, `fan_out … do agent(~P"<%= @d
%>") end`, and `while_budget … do agent(~P"<%= @d %>") end` were all grammatically valid,
whitelist-admitted template agents whose binding-resolution was **undefined**: one implementer threads
the enclosing `binding_env` into the nested folds (accepts `@d`), another passes the empty env (rejects
`@d` as unbound — for a name bound at top level). The author's evident model — `EffectivePrompt`'s
`lane` is only `nil` (top-level) or `%{index: e}` (map lane), L1195 — presumed nested template agents
never occur, but no rule enforced it. *Adjudication — adopt the PREFERRED (restrictive) counter-proposal
over the permissive one:* a `~P` template is admissible **only** in a top-level `agent` prompt, a
`map`-lane `agent` prompt, a top-level `gather`, or a top-level `emit`; a template in a `parallel`
branch, a `pipeline` stage, a `fan_out` body, or a loop-body agent is **actively rejected**
caller-located. §C intro now tabulates the 4th-argument decision at **all six** `node/…` call sites
(the five base sites + the new `map` lane): `build/5` passes the in-scope `binding_env`; `agent_branches`
/ `pipeline_stages` / `agent_lane` / `body_node` each pass the **empty** env and carry an **active
`{:sigil_P, meta, _}` guard** (per Rule C.2.4/C.7.4 discipline) so the rejection is intentional with a
precise diagnostic, not an accident of empty-env name-resolution failure; the `map` lane passes the
element-extended env. Rule C.2.4 is narrowed from "three data positions / an `agent` prompt" to the
four top-level-or-map-lane positions, with the four nested agent positions added to its reject list;
§C.2.1 gains a grammar-admits/validation-narrows note; DF-P1 gains the nested-rejection clause. *Why the
restrictive resolution and NOT the permissive one (the explicit cross-lens adjudication):* the
elixir-beam lens leaned restrictive (less machinery — the four nested folds pass the empty env and never
thread a `binding_env`; matches the author's `lane ∈ {nil, map-index}` L1195 model) and asked the
pl-design lens to weigh the scope question. The pl-design lens concurs: restricting templates to
top-level + map-lane keeps the dataflow graph's value edges **lexically obvious** and preserves the
`lane ∈ {nil, map-index}` invariant, whereas admitting them in loop/parallel/fan_out bodies widens where
a value can flow and reintroduces **define-before-use-across-a-barrier** reasoning. The **permissive
alternative** (thread each fold's received `binding_env` unchanged into its sub-`node/4` calls, admitting
nested template agents via the "a top-level binding lexically precedes the whole region and commits at
iteration 0" argument) was **rejected**: it buys compositional uniformity at the cost of a wider value-
edge surface and a third `lane` case, for a capability no ADOPT use-case needs. Both experts agreed the
4th argument had to be pinned at **all five** base sites regardless of which scope was chosen; the
restrictive pick makes four of them a uniform empty-env-plus-active-guard, the simplest closure. No
invariant weakens: closure-freedom, determinism, bounded termination, and replay-safety are untouched,
and the value-edge surface is **narrower** than the permissive alternative would have made it.
