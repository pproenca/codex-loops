export const meta = {
  name: 'elixir-runtime-build-v3-opus',
  description: 'Implement the codex-loops Elixir/combinator-DSL rewrite slice-by-slice in dependency order, gated by mix verification and adversarial design-constraint review, committing per green slice and halting at the first wall.',
  phases: [
    { title: 'Foundation', detail: '#1 walking skeleton + scaffold' },
    { title: 'Core', detail: '#2-#6 validation, schema-agent, budget, exactly-once, fan-out' },
    { title: 'Dynamism', detail: '#7-#8 loops + quality combinators' },
    { title: 'Surface', detail: '#9-#12 schema DSL, provider, LiveView, CLI' },
  ],
}

// The decisions an autonomous Elixir agent reverses by default — the whole reason this project exists.
// Reused in every implement AND review prompt. Violating any of these = the slice is WRONG even if mix is green.
const GLOBAL_CONSTRAINTS = `
NON-NEGOTIABLE DESIGN CONSTRAINTS (a slice that violates ANY of these is REJECTED even if it compiles and tests pass):
1. The workflow body is parsed into INERT DATA STRUCTS at compile time, NEVER captured as \`fn -> block end\`. There must be ZERO anonymous functions / closures anywhere in the compiled workflow tree. (The idiomatic Elixir \`fn -> unquote(block) end\` DSL pattern is FORBIDDEN here — it destroys total-validation, serialization, and resume.)
2. The workflow macro is a THIN SHELL. All parsing/validation logic lives in a plain function \`Workflow.Compiler.parse/2\` (quoted AST + %Macro.Env{} -> {:ok, %Tree{}} | {:error, finding}), unit-tested directly against \`quote do ... end\` input with no macro expansion.
3. \`Compiler.parse\` RAISES on any form outside the closed combinator vocabulary. Determinism is enforced by ABSENCE of vocabulary nodes + compiler rejection, never by a runtime linter. There is no node for :rand or wall-clock, so a workflow cannot express them.
4. The journal is the SINGLE SOURCE OF TRUTH. All read surfaces (status, inspect, LiveView) are PURE FOLDS over the journal. No independent/process/GenServer state is ever rendered or trusted as authoritative. LiveView renders JOURNALED state only.
5. Exactly-once paid effects: idempotency key is (run_id, node-path, iteration). On resume, committed effects are reused from the journal (never re-run). One live writer per run via a process registry + Process.monitor (NOT heartbeat/pid polling).
6. Event log is versioned and ADDITIVE (journal@N). Node addresses are stable. Never freeze a schema that a later slice must extend.
7. Idiomatic BEAM: let-it-crash under supervision, no defensive nil-checking, no GenServer-as-universal-tool, bounded fan-out, Stream where Enum would be eager. Follow staff-level-elixir / adversarial-elixir judgment.
`

const IMPL_SCHEMA = {
  type: 'object',
  required: ['status', 'summary', 'mix_result'],
  properties: {
    status: { type: 'string', enum: ['green', 'blocked'] },
    summary: { type: 'string', description: 'what was built' },
    files_changed: { type: 'array', items: { type: 'string' } },
    mix_result: { type: 'string', description: 'verbatim tail of `mix compile` + `mix test` output proving green, or the blocking error' },
    notes: { type: 'string', description: 'residual risks / follow-ups' },
  },
}

const REVIEW_SCHEMA = {
  type: 'object',
  required: ['pass', 'violations'],
  properties: {
    pass: { type: 'boolean', description: 'true only if NO non-negotiable constraint is violated and the slice genuinely does what the issue asked' },
    violations: {
      type: 'array',
      items: {
        type: 'object',
        required: ['constraint', 'evidence', 'fix'],
        properties: {
          constraint: { type: 'string' },
          evidence: { type: 'string', description: 'file:line + what is wrong' },
          fix: { type: 'string' },
        },
      },
    },
  },
}

// Topological order over the DAG. Each slice's blockers precede it. Sequential — they share the tree and build on each other.
// model: fable for design/metaprogramming/taste-critical & subtle-concurrency; sonnet for mechanical infra.
const SLICES = [
  { n: 1,  phase: 'Foundation', model: 'opus',  title: 'Walking skeleton: schemaless one-agent workflow end-to-end (mock), journaled + scaffold' },
  { n: 2,  phase: 'Core',       model: 'opus',  title: 'Compile-time validation: rustc-style caller-located findings + forbidden-form catalog' },
  { n: 3,  phase: 'Core',       model: 'opus', title: 'Schema-backed agent + fail-closed structured-output retry' },
  { n: 4,  phase: 'Core',       model: 'opus', title: 'Budget ledger: usage accounting + remaining/total fold' },
  { n: 5,  phase: 'Core',       model: 'opus',  title: 'Exactly-once effect boundary + resume + single-writer run lease' },
  { n: 6,  phase: 'Core',       model: 'opus', title: 'Static fan-out combinators: parallel and pipeline' },
  { n: 7,  phase: 'Dynamism',   model: 'opus',  title: 'Dynamic loop combinators: while_budget, until_dry, collect + predicate sub-vocabulary' },
  { n: 8,  phase: 'Dynamism',   model: 'opus',  title: 'Quality combinators: verify, judge, synthesize, fan_out width:' },
  { n: 9,  phase: 'Surface',    model: 'opus',  title: 'Schema sub-DSL: RubyLLM-style declarative builders' },
  { n: 10, phase: 'Surface',    model: 'opus', title: 'Real provider: Codex app-server / SDK adapter behind the provider port' },
  { n: 11, phase: 'Surface',    model: 'opus', title: 'Live read surface: Phoenix LiveView pure projection over the journal' },
  { n: 12, phase: 'Surface',    model: 'opus', title: 'CLI surface + JSON discipline + exit-code contract' },
]

const LENSES = [
  { key: 'constraints', prompt: 'Verify the diff against the NON-NEGOTIABLE DESIGN CONSTRAINTS above. Hunt specifically for: any anonymous function / closure inside the compiled workflow tree; logic living inside a quote block instead of Compiler.parse; any read surface trusting process state instead of folding the journal; any non-deterministic node that slipped in. Grep the actual source. Report every real violation with file:line evidence.' },
  { key: 'runs-and-idiom', prompt: 'Verify the slice ACTUALLY does what its issue asked (run `mix test` yourself and read the tests — are they testing real external behavior or trivially passing?). Separately, judge BEAM idiom per staff-level-elixir/adversarial-elixir: rescue-instead-of-crash, GenServer-as-object, unbounded/linked Task fan-out, eager Enum, N+1. Report real violations with file:line.' },
]

const implPrompt = (s) => `You are implementing ONE vertical slice of a greenfield Elixir rewrite, on the current git branch, in this working directory. The full spec is GitHub issue #${s.n} — run \`gh issue view ${s.n}\` to read its body (What to build / Design constraints / Acceptance criteria) and honor it exactly.

${GLOBAL_CONSTRAINTS}

Prior slices are already implemented and committed in this tree — build on them, do not recreate them. For slice #1 you must also scaffold the mix project (supervision tree, deps, CI-ready test setup).

Do the work end-to-end:
- Write idiomatic Elixir following the constraints above and the sibling skills (staff-level-elixir, elixir-meta-programming, adversarial-elixir).
- Write real tests that exercise EXTERNAL BEHAVIOR at the highest seam (Workflow.Compiler.parse/2 for DSL correctness; interpreter-over-inert-tree + a call-counting mock provider for run semantics). No implementation-detail tests.
- Run \`mix compile --warnings-as-errors\` and \`mix test\` yourself and iterate until BOTH are green. Do NOT report green unless you have actually run them and seen them pass — paste the real tail of the output into mix_result.
- Do NOT commit; the pipeline commits after review passes.

Return the structured result. status='green' ONLY if mix compile (no warnings) and mix test both pass for real.`

const repairPrompt = (s, violations) => `Adversarial review REJECTED your implementation of issue #${s.n}. Fix every violation below, keep mix compile (warnings-as-errors) and mix test green, do not regress. Violations:\n${violations.map((v, i) => `${i + 1}. [${v.constraint}] ${v.evidence}\n   Fix: ${v.fix}`).join('\n')}\n\n${GLOBAL_CONSTRAINTS}\nRe-run mix and return the structured result with real output.`

const reviewPrompt = (s, lens) => `Adversarially review the UNCOMMITTED working-tree changes implementing GitHub issue #${s.n} ("${s.title}"). Run \`git diff HEAD\` and \`gh issue view ${s.n}\` first. Assume the implementation is wrong until proven otherwise.\n\n${GLOBAL_CONSTRAINTS}\n\nYOUR LENS: ${lens.prompt}\n\nReturn pass=false if you find ANY real violation. Be concrete; no nitpicks about style that don't touch the constraints or acceptance criteria.`

const results = []
for (const s of SLICES) {
  phase(s.phase)
  log(`Slice #${s.n} — implementing on ${s.model}`)

  let impl = await agent(implPrompt(s), { label: `impl:#${s.n}`, phase: s.phase, model: s.model, effort: 'high', schema: IMPL_SCHEMA })
  if (!impl || impl.status !== 'green') {
    results.push({ n: s.n, title: s.title, outcome: 'HALTED-build', detail: impl?.mix_result || 'agent died', notes: impl?.notes })
    log(`Slice #${s.n} could not reach green build — halting pipeline.`)
    break
  }

  // Adversarial gate: parallel lenses, read-only, run as soon as impl is green.
  const reviews = await parallel(LENSES.map((lens) => () =>
    agent(reviewPrompt(s, lens), { label: `review:#${s.n}:${lens.key}`, phase: s.phase, model: 'opus', effort: 'high', schema: REVIEW_SCHEMA })
  ))
  const violations = reviews.filter(Boolean).flatMap((r) => r.violations || [])

  if (violations.length) {
    log(`Slice #${s.n} — ${violations.length} constraint violation(s); repairing.`)
    impl = await agent(repairPrompt(s, violations), { label: `repair:#${s.n}`, phase: s.phase, model: s.model, effort: 'high', schema: IMPL_SCHEMA })
    if (!impl || impl.status !== 'green') {
      results.push({ n: s.n, title: s.title, outcome: 'HALTED-review', detail: `unresolved violations: ${JSON.stringify(violations)}`, mix: impl?.mix_result })
      log(`Slice #${s.n} repair failed — halting pipeline.`)
      break
    }
  }

  // Checkpoint: commit the green, review-passed slice.
  const commit = await agent(
    `Commit ONLY the changes implementing GitHub issue #${s.n} on the current branch. Run \`git add -A\` then \`git commit\` with a message: first line "slice #${s.n}: ${s.title}", body summarizing what was built and noting "Closes #${s.n}". Do not push. Confirm with \`git log --oneline -1\` and return that line.`,
    { label: `commit:#${s.n}`, phase: s.phase, model: 'sonnet', effort: 'low' }
  )
  results.push({ n: s.n, title: s.title, outcome: 'DONE', commit: (commit || '').slice(0, 200), impl: impl.summary })
  log(`Slice #${s.n} committed. (${results.filter((r) => r.outcome === 'DONE').length}/${SLICES.length} done)`)
}

return {
  branch: 'elixir-runtime-rewrite',
  completed: results.filter((r) => r.outcome === 'DONE').map((r) => `#${r.n}`),
  halted_at: results.find((r) => r.outcome.startsWith('HALTED')) || null,
  results,
}
