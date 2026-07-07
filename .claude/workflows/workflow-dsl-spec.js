export const meta = {
  name: 'workflow-dsl-spec',
  description: 'SURGICALLY insert (and harden) a Proposed "§10 — Tier-1 dataflow" section into the EXISTING, already-hardened SPEC.md — never rewriting §1–§9. Maps the current doc, lifts the ADOPT/DEFER/REJECT content faithfully from the adversarially-converged SPEC-DATAFLOW-PROPOSAL.md, renumbers the authoring guide, and adds non-destructive forward-references (Principle 6→6′ etc.). An adversarial panel (completeness + fidelity + invariants + teachability + structural-lint + a non-destructiveness diff-guard against HEAD) revises the DELTA ONLY until unanimous. Leaves the change uncommitted for human review — no auto-commit. As dataflow slices land in lib/, a landed idiom moves from the Proposed §10 into the implemented body.',
  phases: [
    { title: 'Ground truth', detail: 'map the existing SPEC.md structure + extract the dataflow proposal' },
    { title: 'Draft', detail: 'SURGICALLY insert §10 dataflow into the existing SPEC.md — never rewrite §1–§9' },
    { title: 'Converge', detail: 'panel reviews the DELTA (+ a non-destructiveness diff-guard) until unanimous' },
    { title: 'Finalize', detail: 'lint, diff-guard, cold-read the new §10; report the diff (NO auto-commit)' },
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
log('SPEC.md already exists — mapping its structure + extracting the dataflow proposal for a SURGICAL insert (NOT a rewrite)')

// Surgical mode: SPEC.md §1–§9 is ALREADY authored, hardened, and committed. We are ADDING a §10 dataflow section, not
// re-deriving the language. So the readers only (a) map the existing doc so the insert renumbers/cross-references correctly,
// and (b) extract the dataflow proposal. The implemented-vocabulary body is taken from the existing SPEC.md verbatim.
const READERS = [
  { area: 'spec-structure', files: 'SPEC.md (the EXISTING committed spec at repo root), and ' + `${LSA}/scripts/check-spec.sh`, ask: 'a precise structural map of the CURRENT SPEC.md: the full section/heading outline with line ranges; exactly where §9 (Proposed refine) ends and the next section begins; the current number + title of the authoring-guide section and every internal cross-reference that a new §10 insertion would force to renumber; the Appendix B grammar-summary structure; and the exact shipped clauses a Proposed dataflow section must add non-destructive FORWARD-REFERENCES to (Principle 6, §1.2 General-computation Non-goal, §6.4.1 provider port, §7.2/§7.3 prompt payload, §8 conformance C1/C9, the §2.4 / §10.2 closed-vocabulary list). Quote each anchor line verbatim so the insert can target it exactly. This is a MAP, not a critique — do not propose rewrites.' },
  { area: 'dataflow', files: `${DATAFLOW_PROPOSAL} (read in full), plus grep lib/ for any LANDED dataflow constructs (a %Template{} / Node.Emit struct, a ~P sigil, a \`let\` form, binding_env threading in compiler.ex, a widened RenderText)`, ask: 'the Proposed Tier-1 dataflow extension exactly as SPEC-DATAFLOW-PROPOSAL.md specifies it — the ADOPT idioms (Template layer, let, prompt injection, emit) with their surface grammar / inert node struct / validation rules+counter-examples / execution algorithm / journal shape, the DEFER (gather, map) and REJECT (reduce, select) verdicts, the Principle 6→6′ reconciliation and the EXACT set of amended clauses (§1.2′, C9′, §6.4.1′, §6.4-commit′/§7.2′/§7.3′, closed-vocabulary 13→17) — AND a precise landed-vs-proposal INVENTORY: for each idiom, state whether it is ALREADY implemented in lib/ (cite the module/struct) or still proposal-only. This inventory decides which idioms the draft folds into the implemented body vs keeps in the Proposed section.' },
]

const dossiers = (await parallel(READERS.map((r) => () =>
  agent(
    `Extract GROUND TRUTH for the "${r.area}" area, to anchor a SURGICAL insertion of a Proposed §10 dataflow section into the EXISTING SPEC.md.
Read ${r.files} (and grep as needed). Report ${r.ask}. Be exhaustive and PRECISE — exact headings, line ranges, section numbers, struct fields, event names, and verbatim anchor lines.
Then WRITE your findings to ${WORKSHOP}/${r.area}.md (create the dir if needed) as clean markdown, and return the structured summary.`,
    { label: `read:${r.area}`, phase: 'Ground truth', model: 'opus', effort: 'high', schema: DOSSIER_SCHEMA }
  )
))).filter(Boolean)

// ---- Phase 1: surgical insert (NOT a rewrite) ----
phase('Draft')
log(`Structure mapped for ${dossiers.length} areas; SURGICALLY inserting §10 dataflow into the existing SPEC.md`)

await agent(
  `${SPEC_METHOD}${META_RULES}
SURGICAL EDIT — DO NOT REWRITE SPEC.md. SPEC.md at the repo root is an ALREADY-AUTHORED, adversarially-hardened, committed spec (§1–§9
plus an authoring guide). Your ONLY job is to ADD a new Proposed "§10 — Tier-1 dataflow extension" and make the minimum non-destructive
edits that insertion forces. You MUST preserve every existing section BYTE-FOR-BYTE except: (a) the new §10 you insert, (b) the section
NUMBER of the current authoring-guide section (it shifts from §10 to §11) and any in-doc cross-reference to it, and (c) a small set of
one-line non-destructive FORWARD-REFERENCE notes into shipped clauses (see below). NOTHING ELSE in §1–§9 or the authoring guide's prose
may change — do not reword, reorder, "improve", re-derive, or re-lint the existing body. This is an Edit/insert task, never a Write of the whole file.

Read (do NOT skip): the CURRENT SPEC.md in full; the structure map at ${WORKSHOP}/spec-structure.md (it gives you the exact anchor lines
and the cross-references to renumber); the dataflow dossier at ${WORKSHOP}/dataflow.md; and ${DATAFLOW_PROPOSAL} (the authoritative,
already-converged source for the §10 content — lift its ADOPT normative content faithfully, re-expressed in THIS SPEC.md's notation/voice).

Do exactly this, with targeted edits:
1. INSERT "## 10. Proposed extensions — Tier-1 dataflow (NOT YET IMPLEMENTED)" immediately AFTER §9 (Proposed refine) and BEFORE the
   authoring-guide section. Spec the ADOPT idioms (Template layer, \`let\`, prompt injection, \`emit\`, pipeline-with-dataflow) to the full
   8-part bar, mark the DEFER idioms (\`gather\`, \`map\`) deferred, and record the REJECT idioms (\`reduce\`, \`select\`/\`when\`) with rationale,
   all grounded in ${DATAFLOW_PROPOSAL}. Use this design as the scaffold:
${DATAFLOW_DESIGN}
2. RENUMBER the existing authoring-guide section from §10 to §11 (and its subsections), and update every internal reference to it. Do not touch its content.
3. ADD non-destructive one-line forward-reference notes (blockquote or parenthetical, clearly marked "Proposed §10") into these shipped clauses
   WITHOUT altering their existing normative text: Principle 6 (→ proposed 6′), §1.2 General-computation Non-goal, §6.4.1 provider port,
   §7.2/§7.3 prompt payload, §8 conformance (C1/C9), and the §2.4 / §10.2-now-§11.2 closed-vocabulary list. Each note POINTS AT §10; it does
   not restate or rewrite the clause.
4. LANDED EXCEPTION: if the dataflow dossier reports an ADOPT idiom as ALREADY implemented in lib/, fold THAT idiom into the implemented body
   as normative (code-verified) text instead of the Proposed §10, and make the corresponding amendment normative rather than a forward-reference.
   (With nothing landed yet, everything stays Proposed in §10.)

After editing, run \`git --no-pager diff --stat HEAD -- SPEC.md\` and confirm the change is ADDITIVE (insertions dominate; deletions limited to
the §10→§11 renumber and the added forward-ref anchor lines). Return: a one-paragraph summary of the inserted §10, the list of clauses you added
forward-refs to, and the diff --stat line. If you find yourself rewriting more than the four items above, STOP and report why instead.`,
  { label: 'insert:dataflow-section', phase: 'Draft', model: 'opus', effort: 'high' }
)

// ---- Phase 2: adversarial convergence until unanimous ----
phase('Converge')

const LENSES = [
  { key: 'completeness', model: 'opus', prompt: `${SPEC_METHOD}\nLENS: SPEC COMPLETENESS. Apply the three rejection tests to EVERY section. A defect is any statement a stranger couldn't implement, any rule missing its counter-example, any happy-path-only algorithm, any unpinned error-model decision, any place two implementers could diverge. Read the spec-anatomy done-bars and hold each part to them.` },
  { key: 'fidelity', model: 'opus', prompt: `${META_RULES}\nLENS: IMPLEMENTATION FIDELITY. For every normative claim about the IMPLEMENTED vocabulary, verify it against the REAL source (grep lib/workflow/*.ex and ${WORKSHOP}/*.md). A defect is any spec statement the code contradicts, any combinator option/arg shape that is wrong, any node field/event name that doesn't exist. The \`refine\` Proposed section AND any dataflow idiom the dataflow dossier (${WORKSHOP}/dataflow.md) reports as NOT-yet-landed are EXEMPT from "must match code" (design-stage), but must still be internally consistent and FAITHFUL to ${DATAFLOW_PROPOSAL} (a claim that contradicts the proposal is a defect). Any dataflow idiom the dossier reports as ALREADY landed in lib/ is NOT exempt: it must match the real source, and if the draft left it in the Proposed section instead of the implemented body that misplacement is a defect. If code and spec disagree, the CODE is right — the spec is the defect.` },
  { key: 'invariants', model: 'opus', prompt: `${META_RULES}\nLENS: INVARIANTS. A defect is any place the spec states or implies something that violates: inert closure-free tree, determinism-by-absence, journal-as-sole-truth (no process state), exactly-once effects, bounded/terminating loops, validate-in-parse-at-compile-time. Also flag any execution algorithm whose determinism or replay-safety is not actually guaranteed by what the spec says. NOTE the Tier-1 dataflow section DELIBERATELY amends "no value binding" to Principle 6′ (journaled-values-only, deterministic-render-only); do NOT flag that amendment itself as an invariant violation, but DO verify 6′ genuinely preserves the listed invariants — flag any dataflow construct whose closure-freedom, determinism-by-absence, journal-as-sole-truth, exactly-once, or bounded termination is not actually guaranteed by what the spec says (e.g. an unpinned inspect-map render order, a template hole that could admit non-journaled data, a bound value read before its producer commits, an unbounded map).` },
  { key: 'teachability', model: 'opus', prompt: `${SPEC_METHOD}\nLENS: TEACHABILITY. This SPEC.md must let an agent author a NEW correct workflow with no access to the code. TEST IT: from SPEC.md alone, write a fresh workflow that exercises a non-trivial use-case (e.g. a review-gated pipeline, the proposed refine, or a dataflow flow that binds an output with \`let\`, injects it into a downstream agent's \`~P\` prompt, and renders a terminal with \`emit\`). Would it compile under the rules as written? Every ambiguity that forced you to guess, every combinator you couldn't use correctly from the doc, is a defect.` },
  { key: 'structural', model: 'opus', prompt: `LENS: STRUCTURAL LINT. Run ${LSA}/scripts/check-spec.sh on SPEC.md (bash). Report every FAIL/WARN as a defect (missing section, unresolved TODO/placeholder, missing grammar notation, absent RFC 2119 keywords, missing counter-examples). Also check cross-reference closure: every algorithm/type/term the NEW §10 uses must be defined somewhere in the doc — a dangling reference is a defect. Do NOT report pre-existing check-spec.sh findings that also fire on the committed HEAD version (those predate this change); only NEW findings the §10 insertion introduced.` },
  { key: 'nondestructive', model: 'opus', prompt: `LENS: NON-DESTRUCTIVENESS (the safety guard). Run \`git --no-pager diff HEAD -- SPEC.md\` (bash). This change MUST be ADDITIVE. The ONLY permitted modifications to pre-existing content are: (a) the inserted §10 dataflow section, (b) renumbering the authoring-guide section §10→§11 and updating references to it, and (c) the small set of clearly-marked one-line "Proposed §10" forward-reference notes appended to shipped clauses (Principle 6, §1.2, §6.4.1, §7.2/§7.3, §8, the closed-vocabulary list). ANY OTHER deletion, rewording, reordering, or "improvement" of the existing §1–§9 or authoring-guide prose is a BLOCKING defect — report each such hunk with its diff context and demand it be reverted to the HEAD text. A wholesale rewrite (large deletion counts, the body shrinking) is the top defect this lens exists to catch. Also flag if the diff shows the file was truncated or a section went missing.` },
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
      `${l.prompt}\n\nSCOPE — this run only ADDED a Proposed §10 dataflow section to an already-hardened SPEC.md. Treat §1–§9 and the authoring guide as FROZEN and authoritative: do NOT propose edits to them, and do NOT re-litigate pre-existing wording. Confine your defects to (i) the NEW §10 content, (ii) the renumbering/forward-reference edits, and (iii) any place the §10 insertion INTRODUCED an inconsistency with the frozen body. (The non-destructiveness lens is the exception — it audits the whole diff.)\n\nAdversarially review the CURRENT SPEC.md at the repository root (read it fresh; read ${WORKSHOP}/ and the committed HEAD version as your lens requires). Assume the delta is defective until proven otherwise. Return pass=false with concrete, located defects if you find ANY in scope; pass=true only if this lens is fully satisfied.`,
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

  // Reviser: SURGICAL — resolves defects in the delta only; §1–§9 and the authoring guide stay frozen.
  await agent(
    `${SPEC_METHOD}${META_RULES}
The adversarial panel found defects in the §10 dataflow insertion. Resolve EVERY defect below with TARGETED edits. This remains a surgical
change: §1–§9 and the authoring-guide prose are FROZEN — the only content you may edit is the new §10, the §10→§11 renumber, and the marked
forward-reference notes. If a non-destructiveness defect says an existing hunk was altered, REVERT that hunk to its committed HEAD text
(\`git --no-pager show HEAD:SPEC.md\` is the source of truth). Keep every NOT-yet-landed dataflow idiom labeled Proposed; keep any LANDED idiom
(per ${WORKSHOP}/dataflow.md) in the implemented body held to code fidelity.
Defects (${openDefects.length}):
${openDefects.map((d, i) => `${i + 1}. [${d.lens} · ${d.part}] ${d.issue}\n   Fix: ${d.fix}`).join('\n')}
Edit SPEC.md with targeted edits and return a one-line summary of the revisions.`,
    { label: `revise#${round}`, phase: 'Converge', model: 'opus', effort: 'high' }
  )
}

// ---- Phase 3: finalize (lint + diff-guard + cold-read of §10; NO auto-commit) ----
phase('Finalize')

// Cold-read: a stranger implementer reads ONLY the new §10 for questions they'd have to ask.
const coldRead = await agent(
  `${SPEC_METHOD}\nYou are a developer with ZERO prior context, handed the NEW "§10 — Tier-1 dataflow" section of SPEC.md to implement (the rest of the
spec is already accepted). Read §10 end to end (and the shipped clauses it forward-references). List every question you would have to ask the authors
to build the ADOPT idioms from §10 alone — each is a defect. Return pass=true only if §10's ADOPT idioms are implementable with no further questions.`,
  { label: 'cold-read:section-10', phase: 'Finalize', model: 'opus', effort: 'high', schema: REVIEW_SCHEMA }
)

if (coldRead && !coldRead.pass && (coldRead.defects || []).length) {
  log(`Cold-read surfaced ${coldRead.defects.length} question(s) on §10; final surgical revision`)
  await agent(
    `Resolve these final cold-read defects with TARGETED edits to §10 only (§1–§9 and the authoring guide stay frozen), then confirm:\n${coldRead.defects.map((d, i) => `${i + 1}. [${d.part}] ${d.issue}\n   Fix: ${d.fix}`).join('\n')}`,
    { label: 'revise:cold-read', phase: 'Finalize', model: 'opus', effort: 'high' }
  )
}

// Verify + report the diff. DO NOT COMMIT — the diff is left in the working tree for human review.
const report = await agent(
  `Finalize the SPEC.md §10 insertion for HUMAN REVIEW — do NOT commit anything. Steps:
1. Run \`bash ${LSA}/scripts/check-spec.sh SPEC.md\` and capture its verdict.
2. Run \`git --no-pager diff --stat HEAD -- SPEC.md\` and \`git --no-pager diff HEAD -- SPEC.md | head -c 4000\`.
3. VERIFY the change is additive+surgical: the pre-existing §1–§9 and authoring-guide text is unchanged except the §10 insertion, the §10→§11
   renumber, and the marked forward-reference notes. If ANY other pre-existing hunk changed, say so loudly as a REGRESSION.
4. Ensure ${WORKSHOP}/ is gitignored (append to .gitignore if missing) — do not stage or commit it.
Return: the check-spec.sh verdict, the diff --stat line, an explicit surgical/additive PASS or REGRESSION verdict, and a one-paragraph description
of what §10 adds. Leave SPEC.md modified-but-uncommitted.`,
  { label: 'verify:diff-no-commit', phase: 'Finalize', model: 'opus', effort: 'low' }
)

return {
  mode: 'surgical-insert',
  committed: false,
  converged,
  rounds: round,
  final_open_defects: converged ? [] : openDefects,
  cold_read_clean: !!(coldRead && coldRead.pass),
  finalize_report: (report || '').slice(0, 1200),
}
