# Claude Code 2.1.211 Ultracode And Dynamic Workflows

This note records a local reverse-engineering pass over the installed Claude
Code executable. It exists to inform Codex Loops authoring and language design;
it is not a claim that Claude's internal workflow surface is a stable public
API.

## Provenance

- Input: `/Users/pedroproenca/.local/bin/claude`
- Resolved input: `/Users/pedroproenca/.local/share/claude/versions/2.1.211`
- Reported version: `2.1.211 (Claude Code)`
- Build time embedded in the bundle: `2026-07-15T16:34:37Z`
- Git SHA embedded in the bundle: `17a4b6d7b2ee1936b95e595054c7e7d38fddafb7`
- SHA-256: `5a728a76198b6eca7f3c7cdbff43bab44b77b48c2108f7a3107d889773382629`
- Format: signed arm64 Mach-O with a Bun payload

The findings below come from printable strings and the minified JavaScript
payload in the executable. Useful source landmarks are included as decimal file
offsets so a future pass can distinguish product drift from interpretation.

## What Ultracode Means

There are two related opt-ins.

1. A human-typed prompt containing the standalone word `ultracode` opts that
   turn into the Workflow tool. The injected reminder says:

   > The user included the keyword "ultracode", opting this turn into
   > multi-agent orchestration — use the Workflow tool to fulfill the request.

2. Session ultracode is enabled by the `ultracode` setting or
   `--effort ultracode`. It means xhigh reasoning effort plus a standing
   instruction to use workflows for every substantive task. The full reminder
   optimizes for the most exhaustive correct answer, says token cost is not a
   constraint, and reserves solo execution for conversational or trivial work.

The keyword trigger runs only for a human-typed prompt, against the text before
slash-command expansion. It is enabled by default and can be disabled with the
`workflowKeywordTriggerEnabled` setting. It is suppressed when workflows are
disabled, when the caller explicitly suppresses keyword handling, or for prompt
forms that look like commands, quoted text, code, paths, or identifiers.

The recognizer is more careful than a case-insensitive substring search:

- the prompt must not start with `/`;
- the match uses word boundaries;
- matches inside paired backticks, quotes, angle brackets, braces, brackets, or
  parentheses are ignored;
- a match adjacent to `/`, `\`, or `-` is ignored;
- a match followed by `?` is ignored;
- a match followed by `.` and another identifier character is ignored.

Relevant bundle landmarks: workflow availability and keyword setting at
`216373397`, session ultracode at `216376845`, the recognizer at `225425632`,
and the reminders at `226149189`.

Outside session ultracode, the Workflow prompt imposes a strict opt-in rule.
The tool may be used only when the user wrote `ultracode`, directly requested a
workflow or multi-agent orchestration, invoked a skill or command that requires
Workflow, or requested a named/saved workflow. Merely benefiting from
parallelism is explicitly insufficient.

## The Authoring Model

The prompt's main architectural instruction is hybrid orchestration:

1. Scout inline first to discover the real work list.
2. Author one well-scoped workflow for the next orchestration phase.
3. Read its result before deciding whether another workflow is needed.

Large work is normally split across several workflows rather than one opaque
mega-run:

- understand: parallel readers produce a structured map;
- design: independent approaches feed a scored synthesis;
- review: diverse finders feed adversarial verification;
- research: a multi-modal sweep feeds deep reads and synthesis;
- migration: discover sites, transform isolated units, then verify.

The system prompt says the script should encode deterministic control flow—
loops, conditions, fan-out, barriers, and synthesis—while agents do the semantic
work inside that structure.

## Script Shape And Metadata

Scripts are plain JavaScript, not TypeScript. The first statement must be one
exported constant object:

```javascript
export const meta = {
  name: "find-flaky-tests",
  description: "Find flaky tests and propose fixes",
  whenToUse: "Use for repeated CI failures",
  phases: [
    { title: "Scan", detail: "grep logs for retries" },
    { title: "Verify", detail: "adversarially check candidates" },
  ],
}
```

`meta` is parsed as an AST literal, not evaluated. It permits literal values,
arrays, objects, expression-free template literals, and negative numeric
literals. It rejects spreads, sparse arrays, computed keys, methods/accessors,
template interpolation, and the keys `__proto__`, `constructor`, and
`prototype`.

Required metadata:

- `name`: non-empty string;
- `description`: non-empty string.

Optional metadata:

- `title`: non-empty string;
- `whenToUse`: string;
- `phases`: literal objects with string `title`, optional string `detail`, and
  optional string `model`.

Phase titles in metadata should exactly match runtime `phase()`/`opts.phase`
titles. A runtime-only title still creates a progress group, but it loses the
predeclared detail. The script limit is 524,288 bytes.

Relevant bundle landmarks: parser at `222640559`, metadata validator at
`222643886`, tool input schema at `222714050`.

## DSL Reference

### `agent(prompt, options?)`

Spawns one workflow subagent and returns either its final text string or a
schema-validated object.

Documented options:

```text
label?: string
phase?: string
schema?: JSON Schema object
model?: string
effort?: string | supported numeric effort
isolation?: "worktree"
agentType?: string
```

The runtime also reads `stallMs`, but the authoring prompt does not document it;
it should be treated as internal.

Important behavior:

- no schema: the final text is the literal return value, not a message to the
  human;
- with schema: a `StructuredOutput` tool is injected and the agent must call it;
- user skip, terminal API failure, or a caught lane failure becomes `null`;
- `label` controls display only;
- `phase` should be supplied inside concurrent callbacks because mutating the
  global phase from racing callbacks is ambiguous;
- omitted `model` inherits the resolved main-loop model and is the preferred
  default;
- `isolation: "worktree"` creates a temporary git worktree and preserves it when
  the agent changes files;
- the executable contains dormant remote-agent code, but this build rejects
  `isolation: "remote"` and exposes only `"worktree"` in the prompt;
- a named `agentType` must exist and pass Agent permission rules;
- workflow subagents can discover session MCP tools through ToolSearch but
  cannot recursively invoke Agent or Workflow.

The plain-text subagent system prompt is effectively:

```text
You are a subagent spawned by a workflow orchestration script.
Your final text is returned verbatim to the script.
Return literal data/text, not acknowledgements such as "Done."
If asked for JSON, return only raw JSON. Be concise.
```

The schema-backed variant instead requires exactly one successful
`StructuredOutput` call. Schema validation retries default to five. The normal
stall deadline is 180 seconds and stalled agents may be retried five times. A
specific degraded-response heuristic retries once after a 45-second backoff
when the response has no stop reason, fewer than 50 output tokens, and consumes
more than half the stall window.

### `pipeline(items, ...stages)`

The default multi-stage primitive.

```javascript
const results = await pipeline(
  items,
  (item, original, index) => agent(firstPrompt(item)),
  (previous, original, index) => agent(nextPrompt(previous, original)),
)
```

Semantics:

- each item traverses every stage independently;
- there is no cross-item barrier between stages;
- item A can enter stage 3 while item B remains in stage 1;
- every stage receives `(previousResult, originalItem, index)`;
- a `null` stage result stops the remaining stages for that item;
- a thrown stage error produces `null` for that lane and is logged;
- the returned array preserves input order.

This is explicitly preferred over `parallel()` between stages. A barrier is
justified only when the next operation needs the complete preceding result set,
such as global deduplication, an all-empty early exit, or comparison against all
other findings. Flattening, filtering, conceptual phase boundaries, or code
style are explicitly not sufficient reasons.

### `parallel(thunks)`

A barrier fan-out:

```javascript
const results = await parallel([
  () => agent("check correctness"),
  () => agent("check security"),
])
```

The input must be an array of functions, not promises. All thunks start
concurrently and the call waits for all of them. It uses `Promise.allSettled`:
one failure never rejects the whole barrier, and a failed slot becomes `null`.
Authors are repeatedly told to use `.filter(Boolean)` before consuming results.

### `phase(title)` and `log(message)`

`phase()` changes the current progress group for subsequent agent calls.
`log()` emits a narrator/progress line. Concurrent work should assign
`opts.phase` directly instead of racing on global phase state.

### `args`

`args` is the value passed to Workflow verbatim. Arrays and objects must be
passed as JSON values, not JSON-encoded strings. Named workflows use it for a
question, target path, or configuration object.

### `budget`

```text
budget.total       number | null
budget.spent()     output tokens spent this turn
budget.remaining() max(0, total - spent), or Infinity without a target
```

The pool is shared by the main loop and every workflow/child workflow in the
turn. The target is a hard ceiling. Further `agent()` calls throw once it is
spent. Every budget loop must test `budget.total`; otherwise `Infinity` can run
until the 1,000-agent emergency cap.

### `workflow(nameOrRef, args?)`

Runs a named saved workflow or `{scriptPath}` as a child and returns its result.
The child shares the parent's concurrency cap, agent counter, abort signal, and
token budget. Nesting is exactly one level: a child cannot call `workflow()`.

### Other globals

The VM exposes `console`, `setTimeout`, and `clearTimeout`, plus standard
ECMAScript built-ins. It does not expose Node.js or filesystem APIs. The script
returns its terminal value with normal JavaScript `return`; there is no separate
`emit` primitive.

## Determinism And Sandbox

The VM disables string/wasm code generation and wraps promise/iterator
boundaries. Workflow source rejects `with`, reserved internal identifiers, and
`await using`. It instruments awaited values so host promises settle safely
across the VM boundary.

Resume determinism removes ambient time and randomness:

- `Date.now()` throws;
- `Math.random()` throws;
- `Date()` and `new Date()` with no arguments throw;
- explicit `new Date(value)`, `Date.parse`, and `Date.UTC` remain available.

Timestamps must arrive through `args` or be added after the workflow returns.
Pseudo-diversity should come from deterministic prompt/index variation.

## Limits And Failure Semantics

- concurrent local agents: `min(16, max(2, CPU cores - 2))`;
- remote-agent semaphore in dormant code: 50;
- lifetime agent-call cap: 1,000;
- one `parallel`/`pipeline` call: at most 4,096 items according to the prompt;
- workflow source: 512 KiB;
- structured-output validation retries: 5 by default;
- stalled-agent retries: 5;
- default stall window: 180 seconds;
- collected workflow log lines: 1,000;
- configured size guidelines: small `<5`, medium `<15`, large `<50`; these are
  advisory, not hard caps.

`parallel` and `pipeline` convert lane exceptions into logged `null` slots.
Budget-exhausted slots also become `null` and a dropped-slot summary is logged.
Top-level script errors fail the workflow. A returned function is forbidden;
objects crossing the boundary are sanitized and cloned.

This leads to a central authoring rule: do not let absence of a result silently
mean rejection, refutation, or success. Model `confirmed`, `refuted`, and
`unverified` separately.

Relevant runtime landmarks: hooks at `222652648`, caps and subagent prompts at
`222673506`, loader/runtime assembly at `222676349`.

## Resume And Journal Semantics

Each run persists `journal.jsonl` under the session workflow transcript
directory. Completed agent results can be replayed after editing a script with
`Workflow({scriptPath, resumeFromRunId})`.

The cache key is versioned `v2` and hashes:

1. the previous agent key (creating a rolling prefix chain);
2. the rendered prompt;
3. a stable serialization of `schema`, `model`, `effort`, `isolation`, and
   `agentType`.

`label`, `phase`, and `stallMs` do not participate in the key. The rolling key
implements “longest unchanged prefix”: once one call changes or misses, later
calls run live even if their local prompt is unchanged.

Unlike Codex Loops, Claude's recovered runtime respawns a journaled `started`
call that lacks a result. That can duplicate a side effect after an uncertain
crash. Codex Loops' durable `agent_started`/`outcome_unknown` rule is stronger
and must not be replaced by Claude's cache behavior.

## Workflow Discovery And Precedence

Claude discovers JavaScript workflows from:

- the user workflow directory (effectively `~/.claude/workflows/*.js`);
- project `.claude/workflows/*.js` directories found by the project-directory
  walk;
- plugin workflow directories/files;
- bundled workflows.

Only `.js` files load. `.mjs`, `.cjs`, and `.ts` are counted as near misses and
ignored. Plugin workflow names are namespaced as `plugin-name:workflow-name`.
User/project workflows override same-named plugin and bundled workflows; plugin
workflows override bundled workflows when no user/project definition exists.

## Quality Patterns In The Workflow Prompt

The tool prompt teaches these reusable structures:

### Adversarial verification

Spawn independent skeptics with an explicit instruction to refute. A claim
survives only under a declared quorum. The suggested verifier default is
conservative: mark refuted when uncertain for research claims, or use a
three-state `CONFIRMED | PLAUSIBLE | REFUTED` ladder for recall-oriented code
review.

### Perspective-diverse verification

Give voters different failure lenses—correctness, security, performance,
reproduction—instead of cloning one generic critic. Diversity catches different
failure modes; redundancy only estimates agreement.

### Judge panel

Generate independent solutions from materially different angles, score them,
then synthesize from the winner while grafting useful ideas from runners-up.

### Loop until dry

For unknown-size discovery, repeat until `K` consecutive rounds produce no new
items. Deduplicate against every item ever seen, not only confirmed items;
otherwise rejected candidates reappear forever and the loop does not converge.

### Multi-modal sweep

Search through different modalities such as by-container, by-content,
by-entity, and by-time. Each finder remains blind to the others until a genuine
barrier combines the candidate pool.

### Completeness critic

Finish with a critic asking what modality was never run, what claim remains
unverified, and which source could not be read. Its gaps become another bounded
round of work.

### No silent caps

If the workflow samples, keeps only top-N, stops retrying, or exhausts a budget,
log exactly what was dropped. Silent truncation falsely communicates complete
coverage.

## Bundled `code-review` Workflow

The hidden bundled workflow is generated near offset `223359798`. Its actual
shape is:

```text
Scope
  -> Find barrier
  -> canonicalize and group candidates by (file, line)
  -> one verifier per location
  -> optional gap sweep at xhigh/max
  -> synthesis by candidate index
  -> host-side assembly and backfill
```

Effort scaling:

| Effort | Correctness finders | Cleanup finders | Candidate cap/finder | Sweep | Report cap |
| --- | ---: | ---: | ---: | --- | ---: |
| high | 3 | 1 combined | 6 | no | 10 |
| xhigh | 5 | 1 combined | 8 | yes, up to 8 | 15 |
| max | 5 | 1 combined | 8 | yes, up to 8 | 15 |

The five correctness prompts are unusually concrete:

1. line-by-line diff plus enclosing-function scan;
2. removed-behavior/invariant audit;
3. cross-file caller/callee tracing;
4. language/framework pitfall scan;
5. wrapper/proxy forwarding and accidental re-entry audit.

The combined cleanup finder covers reuse, simplification, efficiency, altitude
(deep fix versus fragile special case), and exact CLAUDE.md convention
violations.

Candidate schema:

```text
file, optional line, one-line summary, concrete failure_scenario
```

The failure scenario must state user-visible wrong output, error, data loss, or
concrete maintenance/performance cost—not merely an intermediate state such as
“the value is stale.”

Notable implementation details worth porting:

- user target text is framed as scope-only data and explicitly forbidden from
  changing actions or output format;
- absolute/backslash paths are canonicalized by longest suffix match against
  the changed-file list;
- grouping by location is not semantic deduplication: every candidate keeps its
  own verdict;
- verifiers must cite the relevant line and return a verdict for each indexed
  candidate;
- xhigh/max sweep agents see the known list and search only for gaps;
- synthesis returns only primary/merge indices, never rewritten finding text;
- host code validates indices and backfills unused verified findings until the
  report cap, preventing an unreliable synthesizer from silently deleting them;
- correctness outranks cleanup when the cap forces a cut.

The review verdict ladder is `CONFIRMED`, `PLAUSIBLE`, `REFUTED`. Recall mode
keeps plausible findings when the mechanism is real and the triggering runtime
state is reachable. Refutation requires code evidence that the claim is wrong,
impossible, or already guarded.

## Bundled `deep-research` Workflow

The visible bundled workflow begins near offset `223379801`:

```text
Scope into five complementary search angles
  -> pipeline each angle through Search -> shared URL dedup -> Fetch/Extract
  -> rank falsifiable claims
  -> three adversarial votes per claim
  -> synthesize confirmed claims with citations and caveats
```

Hard script constants:

- three voters per claim;
- two refutations kill a claim;
- fetch at most 15 novel sources;
- verify at most 25 ranked claims;
- source extraction returns at most five claims;
- search returns four to six results per angle.

The workflow distinguishes:

- `confirmed`: enough valid votes and fewer than two refutations;
- `refuted`: two or more explicit refutations;
- `unverified`: too few valid votes because verifier agents failed.

That third state is deliberate. An infrastructure failure is not reported as a
research conclusion. If every verifier fails, the workflow tells the caller to
retry rather than saying the claims were false.

Other reusable details:

- extracted claims must be falsifiable and include a supporting direct quote;
- sources are ranked as primary, secondary, blog, forum, or unreliable;
- claims are ranked by centrality and then source quality;
- verifiers test quote support, contradictory evidence, source strength,
  freshness, and marketing/cherry-picking risk;
- the search/fetch path is a true no-barrier pipeline;
- the verification barrier is intentional because global ranking needs the
  complete claim pool;
- progress labels derived from web content strip terminal controls, bidi and
  zero-width characters, quote lookalikes, and suspicious host text to prevent
  a hostile title from masquerading as a trusted hostname;
- synthesis failure returns the verified raw claims instead of discarding the
  run.

## Translation To Codex Loops

Claude's product surface and Codex Loops should not become identical. The
useful target is its orchestration discipline, not its JavaScript VM.

| Concern | Claude 2.1.211 | Codex Loops direction |
| --- | --- | --- |
| Program model | evaluated sandboxed JavaScript | keep inert, closed, Elixir-shaped data |
| Pipeline | runtime item and previous-result callbacks | add inert item/previous bindings before claiming equivalent dataflow |
| Parallel | barrier over thunks | current static `parallel` already matches the barrier concept |
| Dynamic fan-out | JavaScript arrays | keep bounded width expressions and explicit inert lanes |
| Verification | authored from agent/parallel primitives | keep typed `verify`/`refine`, but teach adversarial and diverse-lens prompts |
| Resume | rolling prompt/options cache; unsettled calls respawn | keep address/journal replay and `outcome_unknown` |
| Metadata | pure literal description/phase details | consider an inert metadata header without evaluating source |
| Inputs | arbitrary JSON `args` | shipped: optional literal `inputs:` schema plus immutable, validated, journaled JSON `args` through `@args` |
| Failure slots | `null` plus logs | preserve typed failed/unverified outcomes in journal and results |
| Budget | shared hard output-token pool | keep deterministic finite budgets and make dropped coverage visible |

The largest semantic gap is pipeline dataflow. Codex Loops currently expands
literal items and literal stage agents, but a stage receives neither the item
nor the previous stage result. Its examples correctly call this out. Claude's
`pipeline()` is materially stronger. New language work should provide inert,
closed bindings such as item, previous result, and index before our authoring
guide adopts Claude's callback examples.

## Immediate Rewrite Rules For Existing `.exs` Workflows

These rules fit the shipped Codex Loops language today:

1. Scout the concrete repository scope before expensive orchestration.
2. Use `pipeline` only for genuinely independent static lanes; do not imply
   item/previous-result injection that the runtime does not provide.
3. Use `parallel` or `fanout` as a barrier only when the next step truly needs
   every result.
4. Prefer explicit heterogeneous fanout lanes for different review lenses.
5. Bind the barrier output, deduplicate against all seen candidates, and inject
   the bounded evidence into a top-level synthesis agent.
6. Use `refine` or schema-backed adversarial reviewers to distinguish confirmed,
   refuted, and unverified outcomes.
7. Add a fresh gap/completeness pass for exhaustive workflows.
8. Log caps, failed lanes, unverified panels, and uncovered scope.
9. Preserve domain findings by stable ids/indices; do not ask a synthesizer to
   rewrite evidence it can instead select and merge.
10. End mutating workflows with an explicit cold read and narrow verification
    gate.

## Language Work Needed For A Closer Port

The recovered design suggests these additive, inert features:

1. Bindable barrier results: `let :panel = parallel([...])`.
2. Real pipeline values with closed references for `item`, `previous`, and
   `index`, expanded into inert templates rather than closures.
3. Dynamic map over a prior structured binding with an author-time maximum.
4. First-class lane outcome states instead of collapsing absence into a value.
5. Literal workflow metadata with description and phase detail.
6. A selection/merge terminal that takes stable candidate ids and performs
   host-side validated assembly, preventing synthesis loss.

None of these requires evaluating arbitrary JavaScript. They can compile to the
same closure-free tree and retain Codex Loops' stronger durability semantics.

Workflow inputs from the original gap list are now implemented. `args` is a
bounded JSON value validated against the optional `inputs:` contract before any
provider effect, journaled for replay, and exposed through the closed `@args`
binding. The run also records argument and tree identities so a resume cannot
silently switch arguments or execute a changed compiled plan. This is stricter
than Ultracode's rolling prompt/options resume cache and preserves the existing
at-most-once journal model.
