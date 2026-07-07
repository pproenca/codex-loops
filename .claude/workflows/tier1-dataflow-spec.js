export const meta = {
  name: 'tier1-dataflow-spec',
  description: 'Propose the Tier-1 dataflow extension spec for the codex-loops workflow DSL (add data flow, NOT control flow), then harden it: one Opus proposer authors an implementable spec extension; two Opus adversaries (an Elixir/BEAM idiom expert and a programming-language-design expert) attack it in parallel and counter-propose on disagreement; the proposer reconciles and revises until both experts approve.',
  phases: [
    { title: 'Ground', detail: 'extract how values currently flow (journaled outputs, template pre-expansion, why "no value binding" holds today)', model: 'opus' },
    { title: 'Propose', detail: 'author the Tier-1 dataflow spec extension to the language-spec-author bar', model: 'opus' },
    { title: 'Converge', detail: 'elixir-beam + pl-design adversaries review; proposer reconciles + revises until both approve', model: 'opus' },
    { title: 'Finalize', detail: 'record the converged proposal, recommendations, and residual dissent', model: 'opus' },
  ],
}

const SKILL = '/Users/pedroproenca/Documents/Projects/codex-loops/.claude/skills'
const LSA = `${SKILL}/language-spec-author`
const EMP = `${SKILL}/elixir-meta-programming`
const WORKSHOP = '.spec-workshop'
const OUT = 'SPEC-DATAFLOW-PROPOSAL.md'

// ---- Shared context: the problem, the invariants, the design method ------------------

const SPEC_METHOD = `
You are authoring/reviewing a formal, IMPLEMENTABLE language-spec EXTENSION using the language-spec-author method.
READ FIRST (on disk): ${LSA}/references/spec-anatomy.md, ${LSA}/references/formal-notation.md, ${LSA}/SKILL.md.
Every proposed idiom MUST be specified to the same 8-part bar the existing SPEC.md holds its combinators to:
  surface grammar (formal notation) · inert semantic-model node struct · compile-time VALIDATION rules each with a
  smallest COUNTER-EXAMPLE · a function-style EXECUTION algorithm · journal events · an RFC-2119 conformance clause.
The bar: a developer with ZERO access to us could implement the extension from this document alone, and two independent
teams could not diverge. Apply the three rejection tests (stranger / edge-case / two-implementers) to every statement.`

const INVARIANTS = `
NON-NEGOTIABLE runtime/design invariants (read ${EMP}/references/*.md for the Elixir mechanics). The proposal MUST NOT weaken any:
- Workflow bodies compile to an INERT %Tree{} of node structs — ZERO closures. The \`workflow\` macro is a thin shell over the
  plain function Workflow.Compiler.parse/2, where ALL validation lives (compile-time, caller-located findings). A runtime linter is NOT allowed.
- Determinism is enforced by ABSENCE of vocabulary nodes + compiler rejection (no :rand / wall-clock nodes exist), never at runtime.
- The journal is the SINGLE source of truth; status/inspect/LiveView are pure folds. NO process state.
- Effects are exactly-once via (run_id, node-path, iteration) idempotency keys; resume reuses committed effects.
- Every fan-out / loop is BOUNDED and provably terminates (structural max cap; budget/dryness are early-stop only).
- Replay-safety: any prompt/value the runtime uses must be a deterministic function of already-journaled data.`

// The exact thesis to specify — passed verbatim so the proposal is continuous with the design, not re-derived.
const THESIS = `
THE PROBLEM TO SOLVE — Tier-1 dataflow idioms.
Context: the DSL is Tier 1 (declarative, deterministic, replay-safe, agent-authorable). Its current ceiling is the \`refine\`
combinator (already spec'd as SPEC.md §9). Authors keep hitting an "outputs flow nowhere" wall: an agent/judge/synthesize
produces a value, but the CURRENT language forbids feeding that value into a later prompt (SPEC.md §1.3 & §10.4 enshrine
"no value binding; prompts are static literals, no interpolation"; §6/§10 note there is no in-vocabulary judge->synthesize data flow).

THESIS: add DATA FLOW, NOT CONTROL FLOW. Candidate idioms to specify:
  1. let binding            — name a journaled node output so later nodes can reference it (binds VALUES already in the journal)
  2. prompt injection       — a prompt references a bound value via a deterministic render (NOT arbitrary #{} interpolation)
  3. logic-less templates    — an inert %Template{} (assigns-only, no embedded Elixir) rendered by a deterministic RenderText
  4. map (node-per-element)  — expand a node once per element of a bound collection (bounded fan-out, one journaled sub-node each)
  5. gather / reduce         — fold a bound collection into one value with a NODE or a CLOSED predicate (never a lambda)
  6. bounded select / when   — choose among literal branches by a CLOSED predicate over a bound value (a case, not a general if)
  7. pipeline-with-dataflow  — thread stage N's bound output into stage N+1's prompt
  8. terminal emit           — render a final document/result from bound values

GOVERNING RULE (the spine of the whole proposal):
  - Flow ONLY journaled values, and ONLY through DETERMINISTIC renders.
  - Transform collections ONLY with nodes or CLOSED predicates — NEVER lambdas.
  - BOUND every fan-out and loop.
DO NOT CROSS (these turn Tier 1 into Tier 2 and MUST be rejected): arbitrary lambdas, arithmetic-in-prompts, a general \`if\`,
  unbounded iteration, in-place external mutation, value-dependent CONTROL flow that isn't a bounded literal select.

TEMPLATE LAYER (critical): rip EEx/HEEx's ARCHITECTURE — compile-time validation, assigns-dependency tracking, the
custom EEx.Engine pattern — but NOT its SEMANTICS (no arbitrary embedded Elixir, no compile-to-closure). The template MUST
compile to an inert %Template{} struct rendered by a deterministic RenderText over journaled assigns.

Reconciliation the proposal MUST address head-on: this CHANGES the shipped "static-literal prompts / no value binding"
invariant. The proposal must show the new rule ("journaled-values-only, deterministic-render-only") is a principled
STRENGTHENING, and that determinism/replay-safety/closure-freedom/bounded-termination are all still guaranteed. For every
idiom, give an explicit ADOPT / DEFER / REJECT recommendation with rationale and a build-order note (the standing guidance is:
ship \`refine\` first; add a dataflow idiom only when the authored-workflow corpus keeps hitting the "outputs flow nowhere" wall).`

// ---- Structured verdict for the two adversaries -------------------------------------

const REVIEW_SCHEMA = {
  type: 'object',
  required: ['expert', 'verdict', 'blocking', 'concerns', 'cross_expert_note'],
  properties: {
    expert: { type: 'string', description: 'elixir-beam | pl-design' },
    verdict: { type: 'string', enum: ['approve', 'revise'], description: 'approve ONLY if there are zero blocking objections from this lens' },
    blocking: {
      type: 'array',
      description: 'defects that MUST be fixed before this expert can approve; empty iff verdict=approve',
      items: {
        type: 'object',
        required: ['idiom', 'issue', 'counter_proposal'],
        properties: {
          idiom: { type: 'string', description: 'which idiom / section the defect is in' },
          issue: { type: 'string', description: 'the defect + exactly which invariant, idiom, or rejection test it fails' },
          counter_proposal: { type: 'string', description: 'REQUIRED — a concrete alternative design, not just "remove it". When you disagree you must propose.' },
        },
      },
    },
    concerns: {
      type: 'array',
      description: 'non-blocking improvements',
      items: {
        type: 'object',
        required: ['idiom', 'suggestion'],
        properties: { idiom: { type: 'string' }, suggestion: { type: 'string' } },
      },
    },
    cross_expert_note: { type: 'string', description: 'where THIS lens anticipates conflict with the other expert (idiomatic-convenience vs PL-purity), so the proposer can reconcile' },
  },
}

// ---- Phase 0: ground truth on current value-flow mechanics --------------------------
phase('Ground')
log('Extracting how values currently flow (journaled outputs, template pre-expansion, the "no value binding" invariant)')

const ground = await agent(
  `Extract GROUND TRUTH from this repository to anchor a "Tier-1 dataflow" spec extension. The existing SPEC.md (repo root) is the
authoritative description of the IMPLEMENTED language — read it, especially §1.3 (design principles / "no value binding"),
§4.3-§4.4 (node structs + compile-time template pre-expansion), §4.5 (schema modules), §6.4/§6.6/§6.10 (agent turn, collect,
judge/synthesize execution), and §10.4 (the "outputs flow nowhere" worked cases). Cross-check against lib/workflow/*.ex where a
mechanism matters (node.ex, tree.ex, compiler.ex, run/writer.ex, idempotency.ex, event.ex, catalog/*.ex).

Report, precisely and verifiably (exact struct fields, node paths, event names, arities):
 1. Exactly what a schema-backed agent()/judge/synthesize output IS once produced — where and how it is journaled, and its addressable identity.
 2. How template pre-expansion works TODAY (§4.4) — the closest existing thing to "render a prompt from structured pieces" — and why it stays closure-free.
 3. The exact wording + location of every place the language forbids value binding / prompt interpolation / value-dependent flow.
 4. Node addressing + the (run_id, node-path, iteration) idempotency key — what a NEW bound-value reference or a map/gather node would have to key on to stay exactly-once and replay-safe.
 5. Any existing partial dataflow (e.g. collect/accumulator folds in §6.6) that a dataflow extension would generalize or must stay consistent with.
Write your findings to ${WORKSHOP}/dataflow-ground.md (create the dir if needed) and return the structured summary.`,
  {
    label: 'ground:value-flow', phase: 'Ground', model: 'opus', effort: 'high',
    schema: {
      type: 'object',
      required: ['facts', 'source_files'],
      properties: {
        facts: { type: 'string', description: 'the extracted ground truth, precise, with exact names/fields/paths' },
        source_files: { type: 'array', items: { type: 'string' } },
      },
    },
  }
)

// ---- Phase 1: the proposal ----------------------------------------------------------
phase('Propose')
log('Authoring the Tier-1 dataflow spec extension')

await agent(
  `${SPEC_METHOD}${INVARIANTS}${THESIS}

Ground truth on the current value-flow mechanics is in ${WORKSHOP}/dataflow-ground.md and the authoritative SPEC.md is at the repo
root — READ BOTH FIRST. Then AUTHOR the proposal file ${OUT} at the repository root: a self-contained, implementable spec extension
for the Tier-1 dataflow idioms, idiomatic to this Elixir compile-time DSL and continuous with SPEC.md's structure/notation.

Structure the document as:
  A. Purpose & the governing rule (data flow not control flow; journaled-values-only through deterministic renders; the
     reconciliation with the shipped "no value binding / static-literal prompts" invariant — argue it is a principled STRENGTHENING).
  B. The template layer FIRST (it underpins prompt injection & emit): the inert %Template{} struct, the assigns model, the
     custom-EEx.Engine-style COMPILE-TIME lowering + assigns-dependency tracking you rip from EEx/HEEx, and the deterministic
     RenderText algorithm — with an explicit statement of what embedded-Elixir/closure semantics you deliberately DROP.
  C. Each idiom (let, prompt injection, map, gather/reduce, bounded select/when, pipeline-with-dataflow, emit) to the FULL 8-part
     bar: surface grammar in formal notation · inert node struct + how it extends node addressing and the idempotency key ·
     validation rules EACH with a smallest counter-example (esp. the "DO NOT CROSS" rejections: lambda, arithmetic-in-prompt,
     general if, unbounded map/loop, external mutation) · a function-style execution algorithm proving determinism, exactly-once,
     replay-safety, and bounded termination · journal events · an RFC-2119 conformance clause.
  D. Cross-cutting proofs: closure-freedom of the whole extended tree; determinism/replay-safety of every flowed value;
     termination bound for every new map/fan-out; how resume reuses bound values from the journal.
  E. Recommendation: per-idiom ADOPT / DEFER / REJECT with rationale, and a build order (relative to shipping refine first).

Write ${OUT}. Return a one-paragraph summary of the design stance you took and any idiom you already recommend DEFER/REJECT.`,
  { label: 'propose:dataflow', phase: 'Propose', model: 'opus', effort: 'high' }
)

// ---- Phase 2: adversarial convergence (2 experts) -----------------------------------
phase('Converge')

const EXPERTS = [
  {
    key: 'elixir-beam',
    charter: `${INVARIANTS}
You are a STAFF-LEVEL ELIXIR / BEAM + metaprogramming expert. READ ${EMP}/references/*.md and ${EMP}/SKILL.md before judging.
Attack the proposal on IDIOM and MECHANISM:
 - Is every construct genuinely a COMPILE-TIME, closure-free lowering to an inert struct, accumulated via module attributes and
   validated inside the plain Workflow.Compiler.parse/2 (NOT inside a quote block, NOT at runtime)? Point to any spot where a
   closure, runtime eval, node:vm, or arbitrary embedded Elixir sneaks in.
 - The %Template{} layer: does it correctly RIP EEx/HEEx's architecture (custom EEx.Engine, compile-time assigns-dependency
   tracking, compile-time validation) while DROPPING its compile-to-closure / arbitrary-embedded-Elixir semantics? Is the
   RenderText deterministic and total? Is Macro.escape / hygiene handled; are bound names resolved without var! fighting?
 - let / map / gather / select: do they fit accumulate-attributes + thin-macro-over-parse/2, or do they smuggle ceremony an
   alien (OO/imperative) model would? Would a staff Elixir engineer build it THIS way?
 - Any place the design reaches for a lambda/predicate where a closed vocabulary node belongs.
When you object, you MUST supply a concrete counter_proposal (the idiomatic construction you'd build instead).`,
  },
  {
    key: 'pl-design',
    charter: `${SPEC_METHOD}
You are a PROGRAMMING-LANGUAGE-DESIGN expert applying the language-spec-author bar. Attack the proposal on LANGUAGE THEORY:
 - Grammar: well-formed, unambiguous, precedence/associativity pinned? Semantic model complete and closed?
 - The governing line "data flow NOT control flow": hunt for smuggled control flow — a general if, an unbounded map/loop, a
   value-dependent branch that isn't a bounded LITERAL select, a lambda, arithmetic-in-prompt. Each is a blocking defect.
 - Determinism & replay-safety: is EVERY flowed value provably a journaled value rendered deterministically? Pin every ordering
   (map element order, gather/reduce fold order, select tie-break). An unpinned order is a defect.
 - Bounded termination: does every new map/fan-out/loop carry a structural finite bound with a counter-example for the unbounded case?
 - Consistency: does the reconciliation with the shipped "no value binding / static-literal prompts" invariant actually hold, or
   does it silently contradict SPEC.md? Is each idiom specified to the full 8-part bar with counter-examples + conformance?
When you object, you MUST supply a concrete counter_proposal (the tighter rule/grammar/algorithm you'd adopt instead).`,
  },
]

// No round cap: the panel loops until BOTH experts approve. The runtime's global
// agent-lifetime backstop is the only ultimate ceiling; there is no early exit on rounds.
let round = 0
let approved = false
let lastReviews = []

while (!approved) {
  round++
  log(`Convergence round ${round}: elixir-beam + pl-design adversaries reviewing ${OUT}`)

  const reviews = (await parallel(EXPERTS.map((e) => () =>
    agent(
      `${e.charter}

Adversarially review the CURRENT ${OUT} at the repository root (read it FRESH; also read the authoritative SPEC.md and
${WORKSHOP}/dataflow-ground.md, and grep lib/workflow/ as your lens requires). Assume the proposal is defective until proven
otherwise. Return verdict="revise" with concrete, LOCATED blocking objections if you find ANY from your lens — and remember every
objection MUST carry a concrete counter_proposal. Return verdict="approve" ONLY if your lens is fully satisfied with zero blocking defects.`,
      { label: `review:${e.key}#${round}`, phase: 'Converge', model: 'opus', effort: 'high', schema: REVIEW_SCHEMA }
    )
  ))).filter(Boolean)

  lastReviews = reviews
  const blocking = reviews.flatMap((r) => (r.blocking || []).map((b) => ({ expert: r.expert, ...b })))
  const approvals = reviews.filter((r) => r.verdict === 'approve').map((r) => r.expert)
  log(`Round ${round}: ${approvals.length}/${EXPERTS.length} experts approve; ${blocking.length} blocking objection(s)`)

  if (blocking.length === 0 && approvals.length === EXPERTS.length) {
    approved = true
    break
  }

  // Reconcile + revise. The proposer must resolve conflicts BETWEEN the two experts, not just append fixes.
  const concerns = reviews.flatMap((r) => (r.concerns || []).map((c) => ({ expert: r.expert, ...c })))
  const crossNotes = reviews.map((r) => `[${r.expert}] ${r.cross_expert_note}`).filter(Boolean)

  await agent(
    `${SPEC_METHOD}${INVARIANTS}
The two-expert adversarial panel (elixir-beam idiom + pl-design theory) REJECTED the current ${OUT}. Revise the file IN PLACE to
resolve EVERY blocking objection without regressing what the experts did not object to and without weakening any invariant.

Where the two experts CONFLICT (idiomatic-Elixir convenience vs PL-purity), you MUST adjudicate explicitly: pick the resolution
that best preserves determinism / closure-freedom / bounded-termination / agent-authorability, state which counter-proposal you
adopted and WHY the other was not, and record it in a "Design decisions & tradeoffs" changelog section at the end of ${OUT}.
If an objection reveals an idiom cannot be made Tier-1-safe, RECOMMEND REJECT (move it to Tier 2) rather than bend an invariant.

BLOCKING objections (${blocking.length}) — each with the expert's counter-proposal:
${blocking.map((b, i) => `${i + 1}. [${b.expert} · ${b.idiom}] ${b.issue}\n   Counter-proposal: ${b.counter_proposal}`).join('\n')}

Cross-expert conflict notes:
${crossNotes.map((n) => `- ${n}`).join('\n')}

Non-blocking concerns (address where cheap):
${concerns.map((c, i) => `${i + 1}. [${c.expert} · ${c.idiom}] ${c.suggestion}`).join('\n')}

Edit ${OUT} and return a one-line summary of the revisions + any conflict you adjudicated.`,
    { label: `reconcile#${round}`, phase: 'Converge', model: 'opus', effort: 'high' }
  )
}

// ---- Phase 3: finalize --------------------------------------------------------------
phase('Finalize')

const summary = await agent(
  `The Tier-1 dataflow proposal at ${OUT} has completed ${round} round(s) of adversarial review and is ${approved ? 'APPROVED by both experts' : 'NOT yet approved (round budget exhausted)'}.
Read the final ${OUT}. Produce a crisp executive summary for the repository owner covering:
 1. The per-idiom verdict table (idiom -> ADOPT / DEFER / REJECT) exactly as the final proposal recommends.
 2. The single governing rule the experts converged on, in one sentence.
 3. Any invariant tension and how it was reconciled (the "no value binding" -> "journaled-values-only" strengthening).
 4. ${approved ? 'Confirm zero residual blocking objections.' : 'The residual blocking objections that remain unresolved.'}
 5. The recommended build order relative to shipping refine (§9) first.
Also ensure ${WORKSHOP}/ is gitignored (it is a scratch dir; do NOT commit it). Do NOT commit ${OUT} — it is a decision artifact for the owner to review.
Return the executive summary as markdown.`,
  { label: 'finalize:summary', phase: 'Finalize', model: 'opus', effort: 'high' }
)

return {
  approved,
  rounds: round,
  proposal_file: OUT,
  residual_blocking: approved ? [] : lastReviews.flatMap((r) => (r.blocking || []).map((b) => `[${r.expert} · ${b.idiom}] ${b.issue}`)),
  executive_summary: summary,
}
