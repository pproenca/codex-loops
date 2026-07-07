export const meta = {
  name: 'workflow-dsl-spec',
  description: 'Author SPEC.md — the full, implementable specification of the codex-loops workflow DSL — anchored to the real compiler, structured on the language-spec-author 8-part anatomy, hardened by an adversarial panel (spec-completeness + implementation-fidelity + invariants + teachability + structural-lint) that revises until all lenses agree. Carries the Proposed `refine` combinator AND the Proposed Tier-1 dataflow extension (Template/let/injection/emit + Principle 6→6′), each grounded in SPEC-DATAFLOW-PROPOSAL.md and specified as not-yet-implemented until its tracer-bullet slices land in lib/.',
  phases: [
    { title: 'Ground truth', detail: 'extract the real vocabulary/semantics from lib/' },
    { title: 'Draft', detail: 'assemble the initial SPEC.md from dossier + skills' },
    { title: 'Converge', detail: 'adversarial panel revises until unanimous' },
    { title: 'Finalize', detail: 'lint, cold-read, commit' },
  ],
}

const SKILL = '/Users/pedroproenca/Documents/Projects/codex-loops/.claude/skills'
const LSA = `${SKILL}/language-spec-author`
const EMP = `${SKILL}/elixir-meta-programming`
const WORKSHOP = '.spec-workshop'

// The completeness bar + method, embedded so every agent shares it (and pointed at the files to read in full).
const SPEC_METHOD = `
You are authoring/reviewing a formal, implementable language spec using the language-spec-author method.
READ FIRST (they are on disk): ${LSA}/references/spec-anatomy.md, ${LSA}/references/formal-notation.md, ${LSA}/references/interview-playbook.md.
The 8-part anatomy the spec MUST cover (mark any part deliberately N/A, never silently omit):
  1 Purpose & design principles (the tie-breakers)  2 Lexical grammar  3 Syntactic grammar (\`::\` lexical vs \`:\` syntactic)
  4 Semantic model (the inert %Tree{}/%Node{} shapes)  5 Static semantics = compile-time VALIDATION rules, each with a COUNTER-EXAMPLE
  6 Dynamic semantics = EXECUTION as function-style algorithms + the ERROR MODEL (abort/propagate/partial — pin it)
  7 Output & error format (journal events, result shape, exit codes)  8 Conformance (RFC 2119 MUST/SHOULD/MAY + observably-equivalent clause).
The bar: a developer with ZERO access to us could build a conforming implementation from SPEC.md alone.
Apply the THREE REJECTION TESTS to every statement: (a) stranger test — could a stranger implement it without asking us?
(b) edge-case test — empty/duplicate/missing/max/malformed/conflicting? (c) two-implementers test — could two teams diverge?
`

const META_RULES = `
The DSL is an Elixir compile-time DSL (read ${EMP}/references/*.md). Non-negotiable facts the spec must reflect accurately:
- Workflow bodies compile to an INERT %Tree{} of node structs — ZERO closures. The \`workflow\` macro is a thin shell over the
  plain function Workflow.Compiler.parse/2, where ALL validation lives (compile-time, caller-located findings).
- Determinism is enforced by ABSENCE of vocabulary nodes + compiler rejection, never a runtime linter.
- The journal is the single source of truth; status/inspect/LiveView are pure folds. Effects are exactly-once via
  (run_id, node-path, iteration) idempotency keys. Loops are bounded and provably terminate.
`

// The refine idiom we designed and grilled — passed in so the Proposed section is continuous with the design, not re-derived.
const REFINE_DESIGN = `
PROPOSED combinator \`refine\` (design-stage — NOT yet in the compiler; label the whole section "Proposed / not-yet-implemented").
Purpose: iterative adversarial refinement — a producer agent's work is checked by a parallel panel of reviewers who return
structured findings; a fixer revises using those findings; repeat until the panel reaches consensus or a round bound is hit.
Grammar (surface, verify/judge-style positional subject + kw opts):
  refine <producer :: agent(literal)>, reviewers: [<lens atoms>+] | <pos-int>, revise_with: <fixer :: agent(literal)>,
         until: :unanimous | :majority, max_rounds: <pos-int literal> [, on_stall: :fail | :accept]
Validation rules (each with the smallest counter-example):
  V1 producer must be an agent() form           (ctr: refine "a claim", ...  — that's verify)
  V2 revise_with: required, an agent() form      (ctr: omit it — a refine with no fixer is just verify)
  V3 reviewers: non-empty lens list or pos int   (ctr: reviewers: [])
  V4 until: in {:unanimous, :majority}           (ctr: until: :vibes)
  V5 :majority needs >= 3 reviewers              (ctr: reviewers: [:a,:b], until: :majority  — collapses to unanimous)
  V6 max_rounds: pos-int literal <= iteration cap (ctr: max_rounds: 0)
  V7 prompts are literal strings, no interpolation (ctr: agent("fix #{x}"))
Semantic model: %Refine{producer, reviewers (pre-expanded %Agent{} templates, one per lens), fixer, threshold, max_rounds, on_stall}.
  Reviewer schema = {verdict: boolean, findings: [{id, issue, fix}]}. Addressing: refine_addr ++ [round, role, voter_i];
  idempotency key iteration = round (the reserved slot finally carries a nonzero value).
Execution:
  ExecuteRefine: artifact <- RunProducer (round 0). For r in 0..max_rounds-1:
    verdicts <- RunReviewers(artifact, r) PARALLEL, schema-bound, journaled; if Consensus(verdicts, threshold) -> {:converged, artifact};
    if r == max_rounds-1 -> STALL (on_stall :fail raises RefineStalled [default]; :accept returns {:stalled, artifact} journaled converged:false);
    else findings <- OpenFindings(verdicts); artifact <- RunFixer(artifact, findings, r+1).
  Consensus: :unanimous = all verdicts true; :majority = count(true) > n/2 (strict; majority of 2 = 2).
  OpenFindings = findings from THIS round's failing reviewers, flattened, deduped by id, ordered by (reviewer_index, finding.id) —
    a total order so the fixer prompt is a deterministic function of journaled data (replay-safe).
  Reviewer malformed output -> hard fail-closed (no retry). Producer/fixer malformed -> existing agent retry-then-fail.
Output: events refine_round_started{r}, refine_produced / refine_revised{r}, refine_verdict{voter,verdict,findings},
  terminal refine_converged{r} | refine_stalled{rounds}. A stalled :fail surfaces a distinct :did-not-converge exit (not exit-8).
Conformance: reviewers MAY run in any order/parallel since Consensus and OpenFindings are order-independent; scheduling MUST NOT
  affect the verdict or the fixer's composed prompt.
`

// The Tier-1 DATAFLOW extension (adversarially converged; verdicts baked into the proposal). Passed in so the dataflow
// Proposed section is continuous with that design. The FULL normative source is on disk — agents read it, never paraphrase.
const DATAFLOW_PROPOSAL = 'SPEC-DATAFLOW-PROPOSAL.md'   // repo root — 8-part-bar spec with per-idiom verdicts
const DATAFLOW_DESIGN = `
PROPOSED Tier-1 DATAFLOW extension (design-stage; the ADOPT set is targeted for implementation as tracer-bullet slices).
FULL normative source ON DISK: ${DATAFLOW_PROPOSAL} (and the extracted dossier ${WORKSHOP}/dataflow.md). The draft/reviser MUST
read both and ground EVERY dataflow statement in them — do NOT re-derive from memory. The proposal is written to the same 8-part
bar as SPEC.md and carries the per-idiom verdicts + the Principle 6→6′ reconciliation verbatim.
Thesis: add DATA FLOW, not control flow — flow only journaled values through the deterministic RenderText SPEC §4.4 already
defines, widened from compile-time literals to already-journaled values under an exhaustive compile-time whitelist.
ADOPT — specify to the FULL 8-part bar as one coherent "dataflow core" section:
  - Template layer: an inert %Template{} compiled by a hand-rolled binary scanner (NOT a macro; ONLY <%= @assign %> holes),
    rendered by the deterministic, closure-free RenderText.
  - let: bind a name to a lexically-preceding producer's JOURNALED output (agent/synthesize); name→address at compile time,
    value via a pure journal fold; creates no new value/effect/event/idempotency key.
  - prompt injection: a TOP-LEVEL agent's prompt MAY be a %Template{} over in-scope bindings; the materialized EffectivePrompt is
    journaled (retry-stable) in agent_committed.prompt AND agent_attempt_rejected.prompt; Rule C.2.4 REJECTS template prompts in
    parallel/pipeline/fan_out/loop bodies.
  - emit: render the terminal from bound values into run_completed.value; a workflow MAY end with return OR emit.
  - pipeline-with-dataflow: by COMPOSITION of let + injection — NO new combinator.
DEFER — specify but mark deferred: gather (fold bound outputs via a node); map (node-per-element, bounded max:, single-agent
  lanes, the only piece adding new events map_started/map_completed).
REJECT — document as out-of-Tier-1 with rationale: reduce (closed reducer); select/when (control flow — violates the thesis).
RECONCILIATION the section MUST carry: this is a STRENGTHENING of "no value binding" — Principle 6 → 6′ (journaled-values-only,
  deterministic-render-only), plus the amended clauses (§1.2′, C9′, §6.4.1′, the §6.4 commit path + §7.2/§7.3 payload semantics,
  and the closed-vocabulary count 13→17). Present these as PROPOSED amendments; do NOT rewrite SPEC.md's implemented §1–§8
  normative body — add non-destructive FORWARD-REFERENCES only (e.g. Principle 6 notes the proposed 6′).
TRACKING (landed-vs-proposed): this extension is being built as slices — Slice 0 prefactor (binding_env + RenderText seam),
  Slice 1 (let+template+emit), Slice 2 (injection), Slice 3 (docs+SPEC fold). The dataflow dossier reports which constructs are
  ALREADY in lib/. Any idiom the dossier marks LANDED moves OUT of the Proposed section into the implemented body and is held to
  code fidelity like the rest of the vocabulary; only not-yet-landed idioms stay in the Proposed §.
`

const DOSSIER_SCHEMA = {
  type: 'object',
  required: ['area', 'facts', 'source_files'],
  properties: {
    area: { type: 'string' },
    facts: { type: 'string', description: 'the extracted ground truth, precise, with exact names/arities/shapes' },
    source_files: { type: 'array', items: { type: 'string' } },
  },
}

const REVIEW_SCHEMA = {
  type: 'object',
  required: ['lens', 'pass', 'defects'],
  properties: {
    lens: { type: 'string' },
    pass: { type: 'boolean', description: 'true ONLY if this lens finds zero defects in the current SPEC.md' },
    defects: {
      type: 'array',
      items: {
        type: 'object',
        required: ['part', 'issue', 'fix'],
        properties: {
          part: { type: 'string', description: 'which anatomy part / section' },
          issue: { type: 'string', description: 'the defect + which rejection test or code fact it fails' },
          fix: { type: 'string', description: 'the concrete change that would resolve it' },
        },
      },
    },
  },
}

// ---- Phase 0: ground truth (parallel read-only readers write dossiers to disk) ----
phase('Ground truth')
log('Extracting the real DSL vocabulary + semantics from lib/')

const READERS = [
  { area: 'vocabulary', files: 'lib/workflow/compiler.ex, lib/workflow.ex', ask: 'the exact closed combinator vocabulary, each combinator\'s accepted argument shapes/options, and the thin-macro->parse/2 split' },
  { area: 'nodes-tree', files: 'lib/workflow/node.ex, lib/workflow/tree.ex', ask: 'every node struct, its fields, the tree shape, node addressing, and how templates (verify voters / judge scorers / fan_out) are pre-expanded' },
  { area: 'validation', files: 'lib/workflow/compiler.ex, lib/workflow/compiler/finding.ex, test/workflow/compiler_test.exs', ask: 'every compile-time validation rule the compiler enforces and its located-finding message — with the smallest failing input for each' },
  { area: 'execution', files: 'lib/workflow/run/writer.ex, lib/workflow/run.ex, lib/workflow/idempotency.ex, lib/workflow/predicate.ex, lib/workflow/ledger.ex', ask: 'the interpreter execution algorithm per node type, the loop/budget/dryness termination semantics, exactly-once keys, resume, and the error model' },
  { area: 'output', files: 'lib/workflow/journal.ex, lib/workflow/event.ex, lib/workflow/status.ex, lib/workflow/cli.ex', ask: 'the journal event schema/versions, the status fold, the result/output shape, and the exit-code + JSON contract' },
  { area: 'usage', files: 'lib/workflow/catalog/*.ex, test/workflow/*run*.exs', ask: 'the canonical authored-workflow examples and how each combinator is actually written by an author' },
  { area: 'dataflow', files: `${DATAFLOW_PROPOSAL} (read in full), plus grep lib/ for any LANDED dataflow constructs (a %Template{} / Node.Emit struct, a ~P sigil, a \`let\` form, binding_env threading in compiler.ex, a widened RenderText)`, ask: 'the Proposed Tier-1 dataflow extension exactly as SPEC-DATAFLOW-PROPOSAL.md specifies it — the ADOPT idioms (Template layer, let, prompt injection, emit) with their surface grammar / inert node struct / validation rules+counter-examples / execution algorithm / journal shape, the DEFER (gather, map) and REJECT (reduce, select) verdicts, the Principle 6→6′ reconciliation and the EXACT set of amended clauses (§1.2′, C9′, §6.4.1′, §6.4-commit′/§7.2′/§7.3′, closed-vocabulary 13→17) — AND a precise landed-vs-proposal INVENTORY: for each idiom, state whether it is ALREADY implemented in lib/ (cite the module/struct) or still proposal-only. This inventory decides which idioms the draft folds into the implemented body vs keeps in the Proposed section.' },
]

const dossiers = (await parallel(READERS.map((r) => () =>
  agent(
    `Extract GROUND TRUTH from this repository for the "${r.area}" area of the workflow DSL. Read ${r.files} (and grep as needed).
Report ${r.ask}. Be exhaustive and PRECISE — exact module/function names, arities, option keys, struct fields, event names.
This becomes the anchor for a formal spec, so every fact must be verifiable in the source; do not infer or embellish.
Then WRITE your findings to ${WORKSHOP}/${r.area}.md (create the dir if needed) as clean markdown, and return the structured summary.`,
    { label: `read:${r.area}`, phase: 'Ground truth', model: 'opus', effort: 'high', schema: DOSSIER_SCHEMA }
  )
))).filter(Boolean)

// ---- Phase 1: initial draft ----
phase('Draft')
log(`Ground truth captured for ${dossiers.length} areas; drafting SPEC.md`)

await agent(
  `${SPEC_METHOD}${META_RULES}
Author the INITIAL DRAFT of SPEC.md at the repository root — the full, implementable specification of the codex-loops workflow DSL.
Ground truth for the IMPLEMENTED language has been written to ${WORKSHOP}/*.md — read ALL of them; every normative statement about the
implemented vocabulary MUST match that ground truth (and thus the real source). Also model the doc's structure on ${LSA}/assets/templates/spec-template.md
and keep it lint-clean for ${LSA}/scripts/check-spec.sh (all 8 parts present, RFC 2119 keywords, counter-examples for validation rules).

Cover, as normative-and-verified-against-code: purpose & principles (closed vocabulary, determinism-by-absence, journal-as-truth,
fail-closed, bounded termination, no value binding, inert tree); lexical notes (it is embedded Elixir — state what that means for tokens/literals);
the syntactic grammar of the workflow block and EVERY combinator (agent, log, phase, parallel, pipeline, return, collect, while_budget,
until_dry, verify, judge, synthesize, fan_out + budget_slices) in formal notation; the semantic model (%Tree{}/%Node{} inert shapes + addressing);
the validation rules WITH counter-examples; the execution algorithms + error model; the journal-event/output/exit-code format; and conformance.

Then add clearly-delimited "Proposed extensions (not yet implemented)" sections for TWO extensions:
  (§9) the \`refine\` combinator, using this design verbatim as its basis:
${REFINE_DESIGN}
  (§10) the Tier-1 DATAFLOW extension, using this design as its basis and grounding EVERY normative statement in ${DATAFLOW_PROPOSAL}
        and ${WORKSHOP}/dataflow.md (read both):
${DATAFLOW_DESIGN}
Order them §9 refine then §10 dataflow, and renumber the authoring guide accordingly. EXCEPTION per the dataflow dossier's
landed-vs-proposal inventory: any dataflow idiom the dossier reports as ALREADY implemented in lib/ MUST be folded into the
implemented normative body (held to code fidelity) and REMOVED from the Proposed §10; if every ADOPT idiom has landed, keep §10
only for the still-unbuilt DEFER idioms (gather, map) and the REJECT record. Present the Principle 6→6′ and other amendments as
PROPOSED (forward-references only) for any idiom still in §10, and as implemented normative text for any idiom that has landed.

Finally, because this SPEC.md will ALSO teach agents to author workflows, include an "Authoring guide for agents" section: how to write a valid
workflow, the closed vocabulary at a glance, the top mistakes the compiler rejects (with the fix), and 2-3 worked use-cases end to end.
Write the file. Return a one-paragraph summary of what you wrote and any part you marked N/A.`,
  { label: 'draft:spec', phase: 'Draft', model: 'opus', effort: 'high' }
)

// ---- Phase 2: adversarial convergence until unanimous ----
phase('Converge')

const LENSES = [
  { key: 'completeness', model: 'opus', prompt: `${SPEC_METHOD}\nLENS: SPEC COMPLETENESS. Apply the three rejection tests to EVERY section. A defect is any statement a stranger couldn't implement, any rule missing its counter-example, any happy-path-only algorithm, any unpinned error-model decision, any place two implementers could diverge. Read the spec-anatomy done-bars and hold each part to them.` },
  { key: 'fidelity', model: 'opus', prompt: `${META_RULES}\nLENS: IMPLEMENTATION FIDELITY. For every normative claim about the IMPLEMENTED vocabulary, verify it against the REAL source (grep lib/workflow/*.ex and ${WORKSHOP}/*.md). A defect is any spec statement the code contradicts, any combinator option/arg shape that is wrong, any node field/event name that doesn't exist. The \`refine\` Proposed section AND any dataflow idiom the dataflow dossier (${WORKSHOP}/dataflow.md) reports as NOT-yet-landed are EXEMPT from "must match code" (design-stage), but must still be internally consistent and FAITHFUL to ${DATAFLOW_PROPOSAL} (a claim that contradicts the proposal is a defect). Any dataflow idiom the dossier reports as ALREADY landed in lib/ is NOT exempt: it must match the real source, and if the draft left it in the Proposed section instead of the implemented body that misplacement is a defect. If code and spec disagree, the CODE is right — the spec is the defect.` },
  { key: 'invariants', model: 'opus', prompt: `${META_RULES}\nLENS: INVARIANTS. A defect is any place the spec states or implies something that violates: inert closure-free tree, determinism-by-absence, journal-as-sole-truth (no process state), exactly-once effects, bounded/terminating loops, validate-in-parse-at-compile-time. Also flag any execution algorithm whose determinism or replay-safety is not actually guaranteed by what the spec says. NOTE the Tier-1 dataflow section DELIBERATELY amends "no value binding" to Principle 6′ (journaled-values-only, deterministic-render-only); do NOT flag that amendment itself as an invariant violation, but DO verify 6′ genuinely preserves the listed invariants — flag any dataflow construct whose closure-freedom, determinism-by-absence, journal-as-sole-truth, exactly-once, or bounded termination is not actually guaranteed by what the spec says (e.g. an unpinned inspect-map render order, a template hole that could admit non-journaled data, a bound value read before its producer commits, an unbounded map).` },
  { key: 'teachability', model: 'opus', prompt: `${SPEC_METHOD}\nLENS: TEACHABILITY. This SPEC.md must let an agent author a NEW correct workflow with no access to the code. TEST IT: from SPEC.md alone, write a fresh workflow that exercises a non-trivial use-case (e.g. a review-gated pipeline, the proposed refine, or a dataflow flow that binds an output with \`let\`, injects it into a downstream agent's \`~P\` prompt, and renders a terminal with \`emit\`). Would it compile under the rules as written? Every ambiguity that forced you to guess, every combinator you couldn't use correctly from the doc, is a defect.` },
  { key: 'structural', model: 'opus', prompt: `LENS: STRUCTURAL LINT. Run ${LSA}/scripts/check-spec.sh on SPEC.md (bash). Report every FAIL/WARN as a defect (missing section, unresolved TODO/placeholder, missing grammar notation, absent RFC 2119 keywords, missing counter-examples). Also check cross-reference closure: every algorithm/type/term a section uses must be defined somewhere in the doc — a dangling reference is a defect.` },
]

const MAX_ROUNDS = 5
let round = 0
let openDefects = []
let converged = false

while (round < MAX_ROUNDS) {
  round++
  log(`Convergence round ${round}: adversarial panel reviewing SPEC.md`)

  const reviews = (await parallel(LENSES.map((l) => () =>
    agent(
      `${l.prompt}\n\nAdversarially review the CURRENT SPEC.md at the repository root (read it fresh; grep the source and ${WORKSHOP}/ as your lens requires). Assume it is defective until proven otherwise. Return pass=false with concrete, located defects if you find ANY; pass=true only if this lens is fully satisfied.`,
      { label: `review:${l.key}#${round}`, phase: 'Converge', model: l.model, effort: 'high', schema: REVIEW_SCHEMA }
    )
  ))).filter(Boolean)

  openDefects = reviews.flatMap((r) => (r.defects || []).map((d) => ({ lens: r.lens, ...d })))
  const passed = reviews.filter((r) => r.pass).map((r) => r.lens)
  log(`Round ${round}: ${passed.length}/${LENSES.length} lenses agree; ${openDefects.length} open defect(s)`)

  if (openDefects.length === 0 && reviews.length === LENSES.length) {
    converged = true
    break
  }

  // Reviser: sequential, edits SPEC.md in place to resolve every defect.
  await agent(
    `${SPEC_METHOD}${META_RULES}
The adversarial panel REJECTED the current SPEC.md. Revise the file IN PLACE to resolve EVERY defect below without regressing other parts.
Preserve the ground truth in ${WORKSHOP}/*.md as authoritative for the implemented vocabulary; keep the \`refine\` section and every NOT-yet-landed dataflow idiom (per ${WORKSHOP}/dataflow.md's landed-vs-proposal inventory) labeled Proposed, while keeping any LANDED dataflow idiom in the implemented body held to code fidelity.
Defects (${openDefects.length}):
${openDefects.map((d, i) => `${i + 1}. [${d.lens} · ${d.part}] ${d.issue}\n   Fix: ${d.fix}`).join('\n')}
Edit SPEC.md and return a one-line summary of the revisions.`,
    { label: `revise#${round}`, phase: 'Converge', model: 'opus', effort: 'high' }
  )
}

// ---- Phase 3: finalize (lint + cold-read + commit) ----
phase('Finalize')

// Cold-read: a stranger implementer looks for any question they'd have to ask.
const coldRead = await agent(
  `${SPEC_METHOD}\nYou are a developer with ZERO prior context, handed SPEC.md to implement the workflow DSL from scratch. Read it end to end.
List every question you would have to ask the authors to build a conforming implementation — each such question is a defect. If you have none, say so explicitly.
Return pass=true only if you could implement the whole language (minus the clearly-Proposed refine section) with no further questions.`,
  { label: 'cold-read', phase: 'Finalize', model: 'opus', effort: 'high', schema: REVIEW_SCHEMA }
)

if (coldRead && !coldRead.pass && (coldRead.defects || []).length) {
  log(`Cold-read surfaced ${coldRead.defects.length} question(s); final revision`)
  await agent(
    `Resolve these final cold-read defects in SPEC.md in place, then confirm:\n${coldRead.defects.map((d, i) => `${i + 1}. [${d.part}] ${d.issue}\n   Fix: ${d.fix}`).join('\n')}`,
    { label: 'revise:cold-read', phase: 'Finalize', model: 'opus', effort: 'high' }
  )
}

const commit = await agent(
  `Finalize SPEC.md for commit on the current branch. Run bash ${LSA}/scripts/check-spec.sh SPEC.md and paste its verdict. Ensure ${WORKSHOP}/ is NOT committed (add it to .gitignore). Then \`git add SPEC.md .gitignore\` and \`git commit\` with first line "spec: SPEC.md — full implementable workflow DSL specification" and a body noting the adversarial-convergence provenance. Confirm with \`git log --oneline -1\` and return that line plus the check-spec.sh verdict.`,
  { label: 'commit:spec', phase: 'Finalize', model: 'opus', effort: 'low' }
)

return {
  converged,
  rounds: round,
  final_open_defects: converged ? [] : openDefects,
  cold_read_clean: !!(coldRead && coldRead.pass),
  commit: (commit || '').slice(0, 300),
}
