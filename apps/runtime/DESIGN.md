# codex-loops v2 — Event-Sourced Minimal Core (FINAL)

Ground-up rewrite of `apps/runtime`. The journal becomes an append-only event log and the *only* persistent artifact; every read surface (status, inspect, list, resume, serve) is a pure fold over it. The engine is a pure reducer plus a thin effect shell; all IO (file appends, SDK calls, vm bridge) lives at the edges. Target: 13 src files, ~3,000 lines, exactly one installed runtime dependency. Version bumps to **0.2.0**.

This document is the winning "event-sourced minimal core" proposal with four judge-mandated grafts integrated and all contradictions resolved (see §11). It is the single source of truth for the implementation fleet.

---

## 0. Lens, philosophy, and what survives

**Lens: event-sourced minimal core.** One write path (`Journal.append`), one read path (`fold(events) -> RunState`), one projection family (`RunState -> snapshot | summary | list entry | SSE payload`). Nothing is ever rewritten in place; nothing derived is ever persisted.

**Public contract preserved verbatim** (per `plugins/codex-loops/SPEC.md`):
- All 11 commands and aliases: `draft validate test run workflow resume inspect status list serve help` (`run` ≡ `workflow`).
- Flags: `--args --journal --provider mock|sdk --mock --budget small|standard|deep --approved --background --status-server --status-host --status-port --json --quiet --no-input --event-limit --journal-root --limit --host --port --model --model-policy --codex-base-url --codex-path-override --codex-config --skip-git-repo-check --echo-prompts --deterministic-timestamps --run-id --background-worker --goal --name --output --workflow-permission-key` plus the 14 kebab-cased limit flags generated from `LIMIT_INPUTS` (`--max-agents --max-concurrent --schema-retry-limit --max-work-items-per-agent --max-inventory-items-returned --max-prompt-bytes-per-agent --max-mutation-files-per-agent --max-mutation-files-per-run --max-parallel-items --max-pipeline-items --max-tool-calls-per-agent --max-tool-calls-per-run --task-budget --min-remaining-tokens-for-agent`; `taskBudget` keeps the legacy `turnBudget` programmatic alias).
- DSL globals: `args`, `budget{total,spent(),remaining()}`, `agent`, `pipeline`, `parallel`, `workflow`, `phase`, `log`, console shims; meta-first pure-literal scripts; plain JS only.
- Exit codes 0/1/2/4/6/8/130. JSON envelopes always carry `command`. `async_launched` background handle shape `{command, status:"async_launched", workflowName, pid, runId, journalPath, scriptPath, statusUrl?, statusServerPid?}`.
- Resume cache key descriptor `runId+phaseTitle+label+promptHash+schemaHash+optionsHash` with the exact v1 hash composition (sha256, stableStringify with recursively sorted keys, 32-hex prefix; optionsHash = options minus schema plus selectedModel/selectedEffort/agentDefinitionHash).
- Fail-closed provider-schema structured output with `schemaRetryLimit` (default 2) and the exact `RETRY_SUFFIX` protocol resuming the same thread.
- Mock provider determinism rules (threadId `mock-<nodeId>`, tokens `max(1,ceil(len/4))`, toolCalls 0, durationMs 0, synthesis order enum[0] → [] → true → 1 → `${label}-mock` → required-keys object).
- isolation→sandboxMode mapping (`read-only`→`read-only`, `workspace-write`|`worktree`→`workspace-write`, `full-access`→`danger-full-access`, else omitted). Effort domain exactly `medium|high|xhigh`.
- `@openai/codex-sdk` as the only live execution path; `codexPathOverride` may pick the binary, never a different SDK. Local-only scope, `remote.supported:false`.
- `runtimeContract` surfaced in every snapshot. Programmatic exports exactly `workflow` + `testWorkflow`. Default journal path `.agent-loops-runs/latest.json` and journal root `.agent-loops-runs` remain the documented defaults (see §1.6 — latest.json becomes a pointer file). Package keeps name `agent-loops`, bin `agent-loops -> dist/cli.js`, ESM, Node >= 24.
- Pinned user-facing error strings preserved verbatim: FIRST_META / pure-literal / forbidden-API list ("cannot import modules, access fs, access process, or spawn shell commands"), "parallel() expects an array of functions, not promises", "pipeline() expects an array as the first argument", "workflow() nesting is limited to one child level", DATE_ERROR / RANDOM_ERROR texts, "failed structured output validation: ...", "Thread.runStreamed() is required", "Malformed workflow snapshot", the plain-JavaScript rejection suffix, and the registry message beginning `agent({agentType}): agent type '<x>' not found. Available agents:` (the literal `{agentType}` prefix is kept as intentional call-form notation since tests/skill text pin it).

**Deliberately broken/changed** (internal surfaces, not SPEC):
- Journal **file format**: the `workflow-snapshot/v1` mutable JSON + write-only JSONL sidecar are replaced by a single append-only JSONL event log (`agent-loops/journal@2`). v1 journals get **read-only dual-read** for `inspect`/`status`/`list` (grafted, §1.7); `resume` and `serve` reject them with a clear exit-2 message: `legacy v1 snapshot journal; finish or re-run with agent-loops >= 0.2`.
- Default journal flow: per-run `.agent-loops-runs/<name>-<runId8>.jsonl` files, with `.agent-loops-runs/latest.json` maintained as a `{"$pointer": ...}` file so bare `status`/`resume`/`inspect`/`serve` keep meaning "the latest run" (grafted, §1.6).
- Snapshot v2 no longer embeds script text (scriptPath + scriptSha256 only). Inline-script execution is dropped (SPEC already declares it out of scope; path-first only). Status enum: `queued|running|done|failed|killed` (`paused` is dropped — nothing ever emitted it).
- `--approval-mode` (no-op illusion), the dead `deterministic-apply` module, the dead SDK client options, the shipped `config/` dir, and the hand-maintained `public-api.d.ts` are removed.

---

## 1. Data model

### 1.1 The journal: one append-only JSONL file

`--journal <path>` names a single file. Each line is one event:

```
{"seq":1,"t":"run_opened","ts":"2026-06-10T12:00:00.000Z", ...payload}
```

Envelope rules:
- `seq`: strictly increasing integer from 1. Fold rejects out-of-order seq (corruption signal, surfaced as a typed error, not silent mis-projection).
- `t`: event type string (catalog below). `ts`: ISO-8601; **omitted entirely** when `deterministicTimestamps` (byte-identical reruns possible in tests).
- `w`: child-workflow scope tag (`"<childName>#<k>"`), omitted for the root run. Child workflows share the parent journal per contract.
- Payload fields are flat and closed (shipped `schema/journal-event.schema.json`, `additionalProperties:false` per variant).

A torn final line (crash mid-append) is silently dropped by the reader with a `truncatedTail:true` note in projections. Every line is self-contained JSON; no event references byte offsets.

### 1.2 Event catalog

| type | payload | emitted when |
|---|---|---|
| `run_opened` | `schema:"agent-loops/journal@2"`, runId, workflowName, scriptPath, scriptSha256, args, provider, budgetPlan, limits, runtimeContract | exactly once, first line, by `prepare` (parent process even for `--background`) |
| `runner_attached` | pid, startedAt?, mode:`fresh\|resume`, cliVersion | each process that takes the writer lock |
| `runner_heartbeat` | pid | every 30 s while running (grafted; suppressed under deterministicTimestamps; never fsynced) |
| `runner_detached` | reason:`"stale-takeover"` | a resumer breaking a dead holder's lock |
| `phase_entered` | phase (index), title | `phase()` |
| `log_emitted` | message | `log()` / console.* |
| `agent_scheduled` | node (32-hex id), label, phase, phaseTitle, attempt, promptHash, schemaHash, optionsHash, promptPreview(≤180), model?, effort, routeReason, agentType?, agentDefinitionSha?, isolation?, risk? | `agent()` after policy/identity resolution, before provider call |
| `agent_started` | node, attempt, threadId? | provider stream begins |
| `agent_progress` | node, attempt, tokens?, toolCalls?, lastToolName?, lastToolSummary? (all **cumulative**) | throttled: ≥500 ms between events per node, plus always on tool-name change |
| `agent_retried` | node, attempt, reason:`schema-invalid\|output-unparseable`, errors[] | structured-output retry loop |
| `agent_completed` | node, attempt, threadId?, result, tokens, toolCalls, durationMs, source:`provider-schema\|text\|mock` | per-attempt figures; fold sums across attempts |
| `agent_failed` | node, attempt, error{name,kind,message}, tokens?, toolCalls?, durationMs? | non-retryable failure or retry exhaustion |
| `agent_replayed` | node, attempt | resume cache hit; carries **no** result — fold reuses the prior `agent_completed` |
| `child_started` / `child_finished` | w, name / w, status, result? | `workflow()` boundaries |
| `script_changed` | scriptSha256 (notice) | resume detects an edited script |
| `run_finished` | status:`done\|failed\|killed`, result? \| error?, totalTokens, totalToolCalls, durationMs | terminal; exactly one per process attempt that terminates the run |

There is **no stream-delta event type**. Raw SDK stream events never touch disk; they feed the in-process progress callback which (a) updates live budget accounting and (b) is downsampled into `agent_progress`. This deletes the O(events²) write amplification and the unbounded `workflowProgress` array.

### 1.3 The fold: `RunState` and projections

`engine.ts` exports a pure reducer:

```ts
fold(events: JournalEvent[]): RunState
apply(state: RunState, event: JournalEvent): RunState   // fold = events.reduce(apply, INITIAL)
```

`RunState` (in-memory only, never serialized): runId, workflowName, scriptPath, scriptSha256, args, runtimeContract, budgetPlan, limits, `status` (`running` iff a `runner_attached` has seq > seq of last `run_finished`; `queued` if `run_opened` with no attach), `runner` (pid/startedAt of last attach + lastHeartbeatTs; cleared by `run_finished`), `phases[] {index,title,status,nodeIds[]}`, `nodes Map<nodeId,NodeState>` (label, phase, attempt, state `queued|running|done|failed|killed`, tokens/toolCalls summed across attempts, threadId, error?, resultRef→seq of its `agent_completed`), logs[], totals (agentCount/totalTokens/totalToolCalls — always recomputed by the fold, never stored), result/error, lastSeq, truncatedTail?, legacy?.

Projections (pure, in engine.ts):
- `toSnapshot(state, journalPath): WorkflowSnapshot` — `schemaVersion:"workflow-snapshot/v2"`. **One** canonical progress representation: `phases[]` with embedded node summaries (the v1 triple `phases`/`progress.phases`/`workflowProgress` is gone). No embedded script text. `runtimeContract` echoed from `run_opened`.
- `toSummary(state, tailEvents, eventLimit): WorkflowStatusSummary` — nodeCounts `{queued,running,done,failed,killed}`, stale/staleReason, `lastEvents` = the literal last N journal events.
- `toListEntry(...)` for `list`.

**Stale detection (grafted heartbeats):** `status==='running'` AND (no runner record → `running journal has no live runner ownership record`; pid fails `process.kill(pid,0)` with non-EPERM → `runner pid N is not alive` — both v1 reason strings preserved; OR pid probes alive but the newest of `runner_attached.ts`/`runner_heartbeat.ts` is older than 90 s → new reason `runner heartbeat is stale`). The heartbeat-age check is skipped when events carry no `ts` (deterministicTimestamps) and for cross-machine reads it is the only signal — fixing both the PID-reuse false-alive and container-inspection gaps at near-zero cost.

### 1.4 Node identity and the resume cache (contract preserved, bug fixed)

```
nodeId      = sha256(stableStringify(pick(descriptor, CACHE_KEY_FIELDS))).slice(0,32)
CACHE_KEY_FIELDS = ['runId','phaseTitle','label','promptHash','schemaHash','optionsHash'] as const
RESUME_CACHE_KEY = CACHE_KEY_FIELDS.join('+')   // structurally cannot drift from the hasher (grafted)
optionsHash = sha256(stableStringify({ ...agentOptions minus schema, selectedModel, selectedEffort, agentDefinitionHash }))
```

Both the hash input and the published `runtimeContract.resume.cacheKey` descriptor derive from the **same** `CACHE_KEY_FIELDS` array in engine.ts, and `contract.test.ts` pins golden hash vectors (literal 32-hex nodeIds for fixed inputs). Changing identity is a deliberate, reviewed act.

**Deterministic default labels — content-occurrence scheme (final resolution of the parallel-resume cache bug).** AsyncLocalStorage structural call paths are **dropped** (two judges identified the mechanism gap: `parallel()` runs as a context-realm closure and all guest calls funnel through one JSON hostcall, so host-side ALS cannot observe branch structure). Instead:

- `contentHash = sha256(stableStringify({phaseTitle, promptHash, schemaHash, optionsHashSansLabel})).slice(0,8)`
- default label = `auto:<contentHash>.<occ>` where `occ` = the count of already-scheduled nodes in this run sharing that contentHash (computed from RunState at schedule time; no global timing-dependent counter).

Properties: distinct-content fan-out (the actual reported bug) gets fully order-independent labels — each branch's label is a pure function of its content. Byte-identical sibling calls get occurrence numbers by arrival order, but such nodes are interchangeable by construction (identical prompt/schema/options), so the k-th arrival replaying the k-th completed node is sound; the residual edge — downstream consumers of *distinct results* from identical-content siblings may see them in swapped positions on resume — is documented, with explicit `label` recommended for identical-content fan-out. Explicit `label` always overrides. The cache key formula and descriptor are untouched — only the default label *value* changes. No scope-stack or ALS machinery exists anywhere.

### 1.5 Journal IO discipline (`journal.ts`)

- **Single live writer.** Writer takes `<journal>.lock` (O_EXCL, contains pid). A resumer finding a lock whose pid is dead appends `runner_detached{reason:"stale-takeover"}` after breaking it. `serve`/`status`/`inspect`/`list` never lock (read-only).
- **Appends** go through one held FileHandle with an in-process promise chain (strict serialization → no interleaved writes, monotone seq). `fdatasync` after `run_opened`, `agent_completed`, `agent_failed`, `run_finished`; heartbeats/logs/progress ride OS flushing (a crash loses only cosmetic tail events; the fold tolerates it). **`agent()` resolves to the script only after its `agent_completed` append + fdatasync completes** — a crash can never lose work the script already observed (grafted durability guarantee).
- **Terminal latch at the writer** (grafted): once this writer has appended a `run_finished`, further appends are dropped with a stderr diagnostic — the v1 double-`workflow_killed` bug becomes structurally impossible; the run loop keeps a belt-and-braces latch too.
- **Reads**: `readAll(path)` (stream lines, drop torn tail), `head(path)` (first line only — `run_opened`), `tail(path, bytes)` (last events for `list`/`status`), `subscribe(path, onEvents)` (fs.watch + 1 s poll fallback, incremental from last byte offset; used by `serve` and test helpers).

### 1.6 Default paths and the latest.json pointer (grafted)

When the user passes no `--journal` on a run command, the writer creates `.agent-loops-runs/<name>-<runId8>.jsonl` and atomically rewrites `.agent-loops-runs/latest.json` to `{"$pointer":"<name>-<runId8>.jsonl"}` (+newline; tmp+rename). The documented default journal path **remains** `.agent-loops-runs/latest.json`: every reader (`status`/`inspect`/`resume`/`serve`/no-journal re-run) that opens a file whose document is a `$pointer` object follows it exactly one hop (target resolved relative to the pointer file's directory; nested pointer → UsageError). Explicit `--journal` paths are used as-is and do not touch the pointer. `list` scans the journal root for `*.jsonl` (plus legacy `*.json` snapshots via dual-read), skipping pointer files as entries; corrupt journals surface as error entries instead of vanishing. Result: per-run files kill latest.json clobbering while bare `status`/`resume` still mean "the latest run".

### 1.7 Legacy v1 journals (grafted dual-read)

`journal.ts` detects v1 snapshot files (JSON document containing `"schemaVersion": "workflow-snapshot/v1"`) and exposes `readLegacySnapshot(path) -> RunState` — a best-effort, read-only mapping (status, runId, workflowName, phases, node summaries, recomputed totals, logs) with `legacy:true`. `inspect`/`status`/`list` accept it (projections carry `legacy:true`); `resume` and `serve` throw `UsageError(2)` with the legacy message. No write-path migration exists.

### 1.8 runtimeContract: one factory

`commands.ts` owns the single `buildRuntimeContract()` (the v1 duplicate in runner.ts is gone). Shape preserved: activation{allowed,source,command,reason}, permission{decision,source,autoDenied,ruleText,targetSettingsSource?}, structuredOutput{mode:"provider-schema",failClosed:true,schemaRetryLimit}, scheduling{maxAgents,maxConcurrentAgents,queueExcessAgents:true,queueStateVisible:true,releaseSlotsOnTerminalState:true}, budgeting{taskBudgetTokens?,minRemainingTokensForAgent?,accountingFields:["tokens"],thresholdPolicy}, resume{journalPath,cacheKey:RESUME_CACHE_KEY,completedNodesReplayFromJournal:true} (now literally true — replay *is* from the journal), remote{supported:false,reason}. Approval stays record-only: mock→allow; `--approved`→allow; else caller-owned (source `--no-input` | `cli-noninteractive`). `--approval-mode` is deleted.

---

## 2. Execution engine

### 2.1 Architecture

```
cli.ts ──> commands.ts (prepare/execute) ──> run loop (in script-host.ts)
                                              │
            script-host.ts (vm membrane) ─ intents ─> engine.ts (pure: identity, budgets, reduce)
                                              │             │
            providers.ts (SDK/mock) <── agent calls    events│
                                              │             ▼
                                        journal.ts append (single writer)
```

The run loop is the only place effects compose: it receives *intents* from the DSL host (schedule agent, enter phase, log), consults pure engine checks (budgets, identity, cache), performs provider IO, and appends events. In-memory `RunState` is advanced by the same `apply()` used for cold folds — execution and replay share one code path, so "resume sees exactly what live saw" is true by construction.

### 2.2 Script host: the data-only vm membrane (`script-host.ts`)

The v1 escape (`log.constructor('return process')()`) existed because host functions were placed in the context. v2 places **zero host objects** in the context:

1. `vm.createContext(Object.create(null), {codeGeneration:{strings:false, wasm:false}})` — guest `eval`/`new Function` are disabled at the V8 level.
2. An *installer* script is compiled **inside the context**; it defines all globals (`agent`, `phase`, `log`, `parallel`, `pipeline`, `workflow`, `budget`, `args`, console shims, throwing `Date`/`Math.random`, undefined `Intl`/`setTimeout`/`setInterval`/`process`/`Buffer`/`require`/`crypto`/`performance`) as **context-realm closures**. Every reachable global has the context's `Function.prototype` in its chain.
3. The installer is invoked once with a single host function `hostcall(opJson: string): Promise<string>`, held only in closures — unreachable via JS reflection. All payloads cross the membrane as **JSON strings, both directions**. Host errors never cross as objects: `hostcall` resolves `{ok:false, err:{name,message,code}}` and the in-context trampoline rethrows a *context-realm* Error; control errors carry codes (`KILLED`, `BUDGET`) so the host reconstructs the right class when they propagate back out.
4. The script body (`export const meta =` rewritten to `const meta =`) is wrapped in `"use strict"; const __main = async () => { ... }` and run with a sync timeout (bounds the prologue). The completion value returns via JSON round-trip (v1 `normalizeJsonResult` semantics kept).

Threat model, stated honestly in docs: the membrane closes all known reflective escapes and `codeGeneration:false` removes the guest Function-constructor attack class, but `node:vm` is **not** a hard security boundary (unbounded sync loops, hypothetical V8 bugs). Scripts run with caller approval; the sandbox is determinism/hygiene enforcement plus defense in depth, not multi-tenant isolation. If requirements harden, move script-host into a child process with the same JSON bridge.

### 2.3 Determinism enforcement

- In-context `Date` shim is complete: constructor, `now`, `parse`, `UTC` all throw `DATE_ERROR`; `Math.random` throws `RANDOM_ERROR` (exact v1 strings). `Intl` is `undefined` (closes the wall-clock leak). `console.{log,warn,error}` → `log()`.
- **AST static gate (grafted from the losers; replaces stripped-source regex):** `validate.ts` parses the wrapped script with **acorn** (bundled devDependency, ecmaVersion 2024). Checks walk real AST nodes — `ImportDeclaration`/`ImportExpression`, `require()` calls, `process`/`Buffer` identifier references, `WithStatement`, `await using`, `node:fs`/`child_process` module specifiers, `applyFrontmatter(` (runner_only_helper), orchestration-hook presence (`agent`/`parallel`/`pipeline`/`workflow` call expressions) — so tokens inside prompt strings and comments can never false-positive. Acorn parse failure (e.g. TypeScript syntax) → `plain_javascript` finding with the exact v1 message suffix. Meta-first + pure-literal checks are AST-based too (first statement must be `export const meta = {…}`; the ObjectExpression may contain only literals/arrays/plain objects, no computed keys or `__proto__`/`constructor`/`prototype` keys); `parseWorkflowMeta` constructs the meta value directly from the AST (the 100 ms vm eval is gone). Error copy corrected to match enforcement (`name` and `description` required; `phases` optional). Findings are rustc-style: `{severity, code, message, line, column, frame, hint?}`. Codes preserved: `meta_first | forbidden_source | plain_javascript | meta_literal | runner_only_helper | missing_orchestration_hook`. The gate remains advisory layered defense; the membrane is the enforcement.
- **One enforcement point**: `validate.ts` is called by CLI prepare, by programmatic `runWorkflow` (always — the `.codex/workflows`-path-only condition is deleted), and by every child `workflow()` spawn. The runner's duplicate partial meta validator is deleted.

### 2.4 DSL semantics (unchanged where pinned)

- `parallel(thunks)`: thunk array required (exact v1 error string); per-branch failures → `null` slots, order preserved; barrier semantics.
- `pipeline(items, ...stages)`: per-item independent stage progression (no stage barrier), stage fns receive `(prev, original, index)`, item failure → `null`.
- Control errors (`WorkflowKilledError`, `WorkflowBudgetExceededError`, provider `kind:"budget"`) always propagate and fail the run; everything else inside branches degrades to `null`.
- `workflow(nameOrRef, args)`: depth ≤ 1 (exact error string), shares parent journal/limits/policy/abort signal, events tagged `w`, phase titles prefixed `workflow:<name> / ` (child nodeIds naturally namespaced via phaseTitle).
- `phase(title)`/`log(message)`: emit events; **no global dedupe** (v1's silent drop of repeated logs is gone). Resume idempotency via prefix tracking (§2.7).
- `budget`: frozen `{total, spent(), remaining()}` backed by the child process's response-updated mirror of host-observed token totals; `remaining()===Infinity` when no `taskBudgetTokens`.

### 2.5 Agent call lifecycle

`agent(prompt, opts)` (host side): resolve policy decision (`policy.ts`, first-match route table; **precedence fixed**: explicit `opts.model` > route.model > policy.defaultModel > CLI `--model`) → resolve agent definition (user dirs *before* builtins, so users can override `planner` etc.) → compose + frame prompt (`SUBAGENT_FRAMING` constants preserved verbatim) → compute hashes/contentHash/label/nodeId (§1.4) → **cache check** (done node in RunState → append `agent_replayed`, return cached result) → pure pre-checks (taskBudgetTokens/minRemainingTokensForAgent based on observed tokens, maxAgents, maxPromptBytesPerAgent, current mutation cap) → `agent_scheduled` + `agent_started` → provider/mock turn → retry loop → `agent_completed` / `agent_failed`. `parallel()` and `pipeline()` are bounded by `maxParallelItems`/`maxPipelineItems` before item work starts.

**Structured output (fail-closed, contract preserved + asymmetry fixed):** with a schema, the value must come from the provider structured-output channel (SDK `outputSchema`). Both *schema-invalid* and *non-parseable* structured output are now **retryable** (v1 made unparseable JSON fatal by accident of substring matching): up to `schemaRetryLimit` extra attempts append `RETRY_SUFFIX` and resume the **same** threadId; each retry emits `agent_retried`. Exhaustion throws `MalformedOutputError` (exit 8) with the v1 message text `failed structured output validation: ...` and the node fails.

**Observed token accounting:** provider and mock turns record aggregate token usage in journal events. The child script sees updated `budget.spent()` and `budget.remaining()` after host responses. Explicit `taskBudgetTokens` and `minRemainingTokensForAgent` refuse future `agent()` scheduling once observed spend reaches the threshold; already-started turns are not killed solely because the budget is reached.

### 2.6 Kill/abort

SIGINT/SIGTERM → AbortController → provider turns aborted → run loop marks queued/running nodes killed (events), appends exactly **one** `run_finished{status:"killed"}` (run-loop latch + writer-level latch), releases the lock, throws `WorkflowKilledError` → exit 130. Abort reason from `signal.reason`.

### 2.7 Resume algorithm

`resume --journal p` (and `workflow`/`run` pointed at an existing non-empty journal — same code path, preserving the pinned "identical re-run makes zero provider calls" invariant; the runId is recovered from `run_opened`, never re-minted):
1. `readAll` + `fold` → RunState. Reject if status `running` **and** runner judged live (pid alive and heartbeat fresh) — exit 2, v1 gate; if stale, break lock + `runner_detached` and proceed (stale runs become resumable instead of dead-ended).
2. Recover scriptPath from `run_opened` (resume) or take the provided script (workflow); re-read; if sha256 differs, proceed (content-hash nodeIds invalidate exactly the changed calls — that *is* longest-unchanged-prefix caching) and append a `script_changed` notice event.
3. Append `runner_attached{mode:"resume"}` and re-execute the script from the top.
4. **Prefix tracking:** while every `agent()` so far has been a cache hit, `phase()`/`log()` emissions matching the recorded event prefix in order are *suppressed* (not re-appended). At the first cache miss the host flips to live mode and appends everything normally. Journals stay duplicate-free without content-based dedupe; `run_opened` is never re-emitted. Under parallel interleaving prefix matching may flip to live mode early — the failure mode is duplicate cosmetic events, never lost or corrupted state (documented).
5. Cache hits append `agent_replayed`; failed nodes re-run with `attempt+1`; totals accumulate across attempts in the fold.

### 2.8 Background launch (no argv round-trip)

1. Parent runs full `prepare` (resolution, validation, runId mint), creates the journal (+pointer when defaulted), appends `run_opened` (status queued).
2. Parent spawns detached `node dist/cli.js resume --journal <p> --background-worker` with stdout/stderr redirected to `<journal>.worker.log` (worker deaths are no longer silent). The worker folds `run_opened`, attaches, and executes — validation/preparation happen exactly once, in the parent.
3. Parent immediately prints the pinned `async_launched` handle.
4. `--status-server`: parent spawns `serve --journal <p> --port <n|0>`; serve binds itself (port 0 → kernel-assigned, no probe/rebind TOCTOU) and writes `<journal>.serve.json` `{url,pid}`; parent polls that portfile ≤2 s to fill `statusUrl`. The journal keeps a single writer.

### 2.9 serve (`serve.ts`)

Read-only. One shared incremental projection per server: `journal.subscribe` feeds `apply()`; SSE clients receive the projected summary **on change** (not 1 Hz full-file re-parse), plus a 15 s heartbeat comment. `GET /status.json` → `{journalPath, status: toSummary(state, 40)}`, no-store. Any other path → self-contained HTML dashboard (single template literal; client uses one reconnect timer — fixes the v1 `onerror` interval leak). All agent events carry `node`, so dashboard event↔agent matching is uniform. Binds 127.0.0.1:0 by default. `serve --json` stays compact single-line `{"command":"serve","journalPath","url"}`.

---

## 3. Providers (`providers.ts`)

`CodexAgentClient = { runAgent(req): Promise<AgentRunResult> }` unchanged. Two implementations:

**SDK adapter:** one `new Codex({config, baseUrl, codexPathOverride, apiKey?, env?})` **per run** (not per call). Thread per node: `startThread`/`resumeThread(threadId)` with `{model, modelReasoningEffort, sandboxMode, workingDirectory, skipGitRepoCheck}`; `runStreamed(prompt, {outputSchema, signal})`. Event mapping preserved (thread.started→threadId, agent_message→text, turn.completed→usage, tokens=input+output, toolCalls from non-message item.completed). Dead typed options (approvalPolicy, networkAccess, webSearch, additionalDirectories) are **removed**; power users reach them via `--codex-config` JSON passthrough only.

**Error taxonomy replaces substring matching everywhere.** The adapter classifies at the throw site into `AgentError{kind}`: `config` (spawn/ENOENT/SDK load → fatal, exit 4), `malformed-output` (unparseable/schema-invalid structured output → retryable, exit 8 on exhaustion), `budget` (propagates, exit 6), `aborted` (→ killed, 130), `provider` (transient → `agent()` returns null per contract). No error message text is ever inspected to decide behavior.

**Mock client:** pure, deterministic, contract preserved exactly — it must keep pairing 1:1 with the subset validator in `schema.ts` (property-tested).

**Agent registry** (in `policy.ts`): builtins (inventory/discovery/planner/critic) as *fallback after* user `.codex/agents/*` (override order fixed); files parsed with `yaml` (frontmatter and .yaml/.yml/.json), alias keys kept; allowed/denied tools remain prompt-advisory and the composed section is retitled `Allowed tools (advisory):` / `Denied tools (advisory):` (SDK offers no tool allowlist today — tracked risk). The not-found message is preserved verbatim (§0).

**Model policy:** TS constant is the single source (`config/model-policy.json` deleted); `--model-policy <path>` loads external JSON validated by `validateModelPolicy`. Effort bounds/disallowed list fail closed at resolution time. Budget presets preserved as structural presets only: default `{maxAgents:1000, maxConcurrentAgents:8, maxParallelItems:4096, maxPipelineItems:4096}` with no token ceiling; small `{maxAgents:6, maxConcurrentAgents:2, maxWorkItemsPerAgent:6, maxInventoryItemsReturned:12, maxMutationFilesPerRun:12}`; standard `{maxAgents:1000, maxConcurrentAgents:8}`; deep `{maxAgents:1000, maxConcurrentAgents:8}`. Only explicit `--task-budget` / `taskBudget` sets `taskBudgetTokens`.

---

## 4. Module layout (13 src files)

| file | owns |
|---|---|
| `src/cli.ts` | `util.parseArgs` per-command spec tables, dispatch, stdout/stderr formatting incl. the stderr JSON error object, help text *generated from the table*, exit-code mapping, background/serve spawning |
| `src/commands.ts` | prepare/execute orchestration, provider selection, budget-preset precedence, the single runtimeContract factory, all `*Command` functions (CLI + programmatic), shared enum validators |
| `src/index.ts` | public entry: `workflow`, `testWorkflow` only |
| `src/journal.ts` | event envelope/types, append writer (lock, serialization, fsync policy, terminal latch), readAll/head/tail/subscribe, torn-line tolerance, `$pointer` resolution, legacy v1 detection + `readLegacySnapshot` |
| `src/engine.ts` | **pure**: `apply`/`fold`, `toSnapshot`/`toSummary`/`toListEntry`, nodeId/contentHash hashing + `stableStringify` + `CACHE_KEY_FIELDS`/`RESUME_CACHE_KEY`, budget check functions, stale logic |
| `src/script-host.ts` | vm membrane, installer script, determinism shims, DSL implementations, run loop, content-occurrence labels, schema-retry loop, concurrency semaphore, resume prefix tracking, child workflows |
| `src/validate.ts` | acorn AST gate (meta-first, pure-literal, forbidden APIs, plain-JS, hook check, runner-only ban), `parseWorkflowMeta`, rustc-style findings |
| `src/providers.ts` | `CodexAgentClient`, SDK adapter, mock client, `AgentError` taxonomy |
| `src/policy.ts` | model policy + resolution, agent-definition registry, budget presets + `LIMIT_INPUTS` (single source for flag names ↔ limit keys), prompt-framing constants |
| `src/serve.ts` | HTTP server, SSE, embedded HTML dashboard, portfile |
| `src/authoring.ts` | draft scaffold template + post-write gate/dry-run, script/name resolution, command wrappers (yaml + schema-validated), `PREFLIGHTS` registry with markdown-frontmatter-manifest (afterPath pagination implemented) |
| `src/schema.ts` | subset JSON-Schema validator (type/enum/required/properties/items/additionalProperties), definition validation |
| `src/types.ts` | shared types + typed error classes with `exitCode` |

Deleted outright: `deterministic-apply.ts` (plan-first mutation stays a *data contract* — agents return patch plans, the caller applies them; the unused `workflow_apply` event type and `frontmatter-patch-plan` runtime go with it), `config.ts`, `status.ts`/`status-server.ts`, `public-api.d.ts`, `mock-agent-client.ts`/`codex-client.ts`/`agent-registry.ts`/`model-policy.ts`/`prompts.ts`, `runner.ts`/`command-service.ts`/`workflow-authoring.ts`/`workflow-compatibility.ts`, and the `config/` directory.

---

## 5. CLI parsing and output

- **`node:util.parseArgs`** with `strict:true`, `allowPositionals:true`, and a **per-command** options table. Fixes: boolean flags can no longer swallow positionals; `--background=true` errors loudly; unknown flags are rejected *per command* (`status --goal x` → exit 2). One `COMMANDS` table drives parsing, validation, **and** `--help`; `scripts/gen-help.mjs` renders the markdown command block for the four doc sites and supports `--check` (SPEC's "help matches docs" acceptance becomes mechanical; run it in repo CI).
- Limit flags generated from `LIMIT_INPUTS` (kebab-cased), shared with programmatic input keys; `taskBudget` keeps the `turnBudget` alias. One validator per enum, exported from `commands.ts`, used by both layers.
- Output discipline preserved: stdout = exactly one final payload (`--json` envelope always has `command`; `--quiet --json` failure = **empty stdout**, diagnostics on stderr); banners/budget-plan/diagnostics on stderr; `serve --json` compact single-line.
- **Machine-parseable failure object (grafted):** whenever a `--json` invocation fails, the **last stderr line** is a single-line JSON object `{code, exitCode, message, hint?, details?}` (`code` ∈ `usage|provider-config|validation|malformed-output|killed|runtime`, mapped from the typed error class). Shipped as `schema/cli-error.schema.json`. Human prose diagnostics precede it; stdout contract untouched. AI callers stop prose-scraping.
- **draft closes the author loop (grafted):** after writing the scaffold, `draft` runs the AST gate and a mock dry-run (in-process `testWorkflow`, provider mock, deterministicTimestamps, throwaway temp journal) and prints next-step commands on stderr. `--json` envelope becomes `{command:"draft", workflowName, scriptPath, validation:{ok,findings}, nextSteps:[ "agent-loops test <name>", "agent-loops workflow <name> --approved" ]}` (workflow-draft schema updated). Docs/help describe draft honestly as a "deterministic scaffold (no LLM)"; the command name stays `draft` (contract).

## 6. Error and exit-code strategy

Typed classes in `types.ts`, each carrying `exitCode` at construction:

| class | exit | replaces |
|---|---|---|
| `UsageError` | 2 | bad flags/args/provider names, resume-while-running, legacy journal on resume/serve, nested pointer |
| `ProviderConfigError` | 4 | adapter `kind:"config"` (spawn/ENOENT/SDK) |
| `ValidationError` | 6 | compatibility findings, meta errors, budget violations (`WorkflowBudgetExceededError extends ValidationError`) |
| `MalformedOutputError` | 8 | structured-output retry exhaustion |
| `WorkflowKilledError` | 130 | abort/signals |
| anything else | 1 | runtime |

`exitCodeOf(err) = err.exitCode ?? 1`. **No substring classification exists anywhere.** Errors crossing the vm membrane serialize `{name, code, message}` and are reconstructed as the right class host-side. Pinned user-facing strings (§0) are preserved verbatim and locked in `contract.test.ts`.

## 7. Build and packaging

- esbuild (`scripts/build.mjs`): `src/cli.ts`→`dist/cli.js`, `src/index.ts`→`dist/index.js`; ESM, platform node, target node24; `external:['@openai/codex-sdk']` only — **`yaml` and `acorn` are bundled devDependencies**, so `package.json dependencies` stays exactly `{"@openai/codex-sdk": "^0.137.0"}` and `npx -y agent-loops` cold-start adds zero extra registry fetches (~270 KB of dist, noise next to the codex binary).
- Types: `tsc -p tsconfig.types.json` (`emitDeclarationOnly`, `rewriteRelativeImportExtensions:true`, declarations for `src/**` into `dist/`) replaces the hand-maintained `public-api.d.ts`.
- `package.json`: version `0.2.0`; `files: ["dist/","schema/","README.md"]` (drops deleted `config/`, plus `scripts/` and tsconfigs); scripts `{"build":"node scripts/build.mjs","test":"node scripts/build.mjs && node --test tests/*.test.ts","typecheck":"tsc --noEmit","prepack":"pnpm run build"}`; devDeps gain `yaml@^2` and `acorn@^8`. bin/exports/engines unchanged.
- `schema/` ships: `journal-event.schema.json` (new), `workflow-snapshot.schema.json` (rewritten v2 projection), `cli-error.schema.json` (new), `workflow-command.schema.json`, `workflow-draft.schema.json` (gains validation/nextSteps), `agent-result.schema.json`, `workload-plan.schema.json`, `patch-plan.schema.json` (kept as the plan-first mutation data contract). All closed. `workflow-progress-event.schema.json` and `frontmatter-patch-plan.schema.json` are **removed** with their features.
- `tsc --noEmit` typechecks `src/**` **and** `tests/**` (strict, noUncheckedIndexedAccess, exactOptionalPropertyTypes kept).

## 8. Testing strategy

Replace the 3,115-line monolith with 14 focused files under `tests/`, all `node:test` (no framework dep), **no `process.chdir` anywhere** — every helper takes explicit `cwd`, CLI subprocesses get the `cwd` spawn option, enabling concurrency.

- `tests/helpers.ts`: `makeWorkspace(t)` (mkdtemp + writers for `.codex/workflows|commands|agents`, auto-cleanup via `t.after`, child-process registry that kills leaked pids), fake codex JSONL executables (kept from v1), `waitForEvent(journalPath, type, timeout)` built on `journal.subscribe` — **event-driven waits replace every poll/sleep**.
- `engine.test.ts` (pure): fold determinism (`fold(a++b) === apply*(fold(a), b)`), totals math, stale logic incl. heartbeat-age, **golden cache-key vectors** (literal nodeId hex strings pinned), content-occurrence label assignment.
- `journal.test.ts`: append serialization, **named crash-injection matrix** (grafted): torn final line, lock contention, stale-lock reclaim, out-of-order seq corruption surfaced as typed error, writer terminal latch, pid-reuse-with-stale-heartbeat verdict; pointer-file follow + nested-pointer rejection; legacy-v1 dual-read and resume rejection.
- `dsl.test.ts`: membrane escape attempts as regressions (`log.constructor`, `Function`, `eval`, `Intl.DateTimeFormat`, `Date.parse`, `Date.UTC`), exact determinism error strings, parallel/pipeline null-slot semantics, labels stable under artificially reordered mock completions.
- `resume.test.ts`: identical rerun → zero provider calls (both via `resume` and via `workflow` against an existing journal); failed-only retry with attempt increment; **unlabeled distinct-content parallel agents replay** (regression for the v1 cache bug); identical-content sibling interchangeability; prefix suppression yields duplicate-free journals; stale takeover; `script_changed` notice.
- `providers.test.ts`: injected FakeCodex + fake binary via `--codex-path-override`; outputSchema/sandboxMode/effort mapping; cumulative mid-stream toolCall counting; error-taxonomy mapping per kind; unparseable output now retryable.
- `policy.test.ts`: route precedence (explicit model > route > policy default > CLI), effort bounds, user-overrides-builtin registry order, presets/limits.
- `validate.test.ts`: AST gate incl. prompts-containing-`import x from y`/`'fs'`/commented tokens **not** rejected, line/column/hint findings, TS-syntax rejection text.
- `authoring.test.ts`: draft scaffold + auto-gate + mock dry-run + nextSteps, resolution order, wrapper frontmatter via yaml, manifest preflight + working afterPath pagination.
- `schema.test.ts`: subset validator and validator↔mock-synthesis pairing property.
- `cli.e2e.test.ts`: spawns **`node dist/cli.js`** (the shipped artifact; `test` script builds first): envelopes, exit codes 2/4/6/8/130, `--quiet --json` discipline incl. the stderr JSON error object on every failure path, background handle (worker pid killed in `t.after`), worker.log existence, latest.json pointer flow.
- `serve.test.ts`: status.json, SSE first event arrives on change, portfile handshake.
- `contract.test.ts`: pins SPEC-level literals locally — `RESUME_CACHE_KEY` ⇄ `CACHE_KEY_FIELDS.join('+')`, golden nodeId vectors, runtimeContract consts, snapshot `workflow-snapshot/v2`, exact error strings, help text ⇄ COMMANDS table, all shipped schemas parse + are closed + removed schemas absent, `index.ts` exports exactly workflow/testWorkflow.
- `packaging.test.ts` (grafted): `pnpm pack` → install tarball in a temp dir → execute the installed bin (`agent-loops help`, `draft`+`test --provider mock`) — catches files[]/exports/externals regressions even dist-level e2e misses.

The monorepo doc-parity suite (BUSINESS_RULE_COVERAGE, plugin-prose regexes) **moves out of the package** — repo CI runs `node apps/runtime/scripts/gen-help.mjs --check` instead.

## 9. Pain-point disposition (complete)

**runner-core:** vm escape → data-only membrane + codeGeneration:false (§2.2). +1 tool-call cap → adapter-side cumulative counting (§2.5). O(events²) snapshot rewrites → append-only journal, no persisted derived state (§1.1). Timing-dependent default labels → content-occurrence labels (§1.4). Duplicate killed/started journal lines → writer terminal latch + `runner_attached` instead of re-emitted `run_opened` (§1.5, §2.6, §2.7). Substring fatal classification → typed AgentError kinds (§3). Global log dedupe → removed; prefix tracking (§2.4, §2.7). Porous determinism/Intl/Date.parse → complete in-context shims (§2.3); async-timeout limitation kept and documented.

**cli-and-commands:** parser ambiguity → parseArgs per-command tables (§5). Substring exit codes → typed classes (§6). Silent background workers / double-prepare → journal-bootstrapped worker + worker.log (§2.8). No-op approval flags → `--approval-mode` deleted; `--approved`/`--no-input` record-only (§1.8). Port TOCTOU → serve binds itself + portfile (§2.8). Global KNOWN_FLAGS → per-command specs (§5). Shared latest.json → per-run files + pointer (§1.6). Duplicated enum validators → single exported validators (§5).

**providers-and-models:** fatal/retryable asymmetry → taxonomy; unparseable retryable then exit 8 (§2.5, §3). Advisory tools → kept advisory, relabeled, risk-tracked (§3). Builtin shadowing → user-first (§3). Dead SDK options → deleted; `--codex-config` passthrough (§3). Hand-rolled YAML → bundled `yaml` (§3). Policy JSON duplicate → TS constant (§3). Model precedence → explicit > route > policy > CLI (§2.5). `{agentType}` message → preserved verbatim as pinned notation (§0).

**lifecycle-and-journal:** O(n²) IO + 1 Hz SSE re-read → event log + incremental subscribe (§1.1, §2.9). Dual runtimeContract factories → one (§1.8). 'journal' terminology lie → journal *is* the event log; `completedNodesReplayFromJournal` literally true (§1.5, §2.7). SSE poller leak → single reconnect timer (§2.9). Dead deterministic-apply → deleted; patch plans remain data contracts (§4). Loose frontmatter fence → `yaml` (§3, §4). PID-only staleness → heartbeats grafted (§1.3). list parses whole files → head + tail reads; corrupt journals surface as error entries (§1.5, §1.6).

**authoring-and-validation:** 'draft' dishonesty → name kept, docs say "deterministic scaffold (no LLM)", auto-gate + dry-run + nextSteps close the loop (§5). Raw-source token false positives + regex-not-AST → acorn AST gate with rustc-style findings (§2.3). Split enforcement → single `validate.ts` from all three paths (§2.3). Wrong meta error copy → corrected. afterPath pagination → implemented (§4). Hardcoded preflight coupling → `PREFLIGHTS` registry (§4). Hand-rolled frontmatter parser/schema drift → yaml + load-time validation against shipped schema (§4).

**tests/build:** chdir poisoning → cwd-explicit helpers. dist never tested → e2e runs dist + packaging smoke. Polling flakiness → journal-subscription waits. Process leaks → child registry + t.after kills. Monorepo doc coupling → gen-help --check at repo level. Monolith → 14 focused files. tests untypechecked → included in tsc.

**repo-context:** four duplicated command lists → gen-help --check (§5). cacheKey triplication → `CACHE_KEY_FIELDS` single source + golden vectors (§1.4). Triple progress representation → one projection (§1.3). Deleted-config-still-shipped → `files` fixed (§7). plugin.json URL typo → flagged for the plugin docs package, out of scope for the app code. Stale root README → out of scope for this rewrite (repo-level follow-up).

## 10. Migration notes (for README/docs)

- Journal format v2 notice: v1 snapshot journals are readable by `inspect`/`status`/`list` (read-only) but `resume`/`serve` reject them; in-flight v1 runs should finish on 0.1.x.
- Default journal flow change (per-run files + latest.json pointer); removed flags (`--approval-mode`, dead codex options); removed `deterministic-apply` runtime and the `workflow-progress-event`/`frontmatter-patch-plan` schemas; snapshot is now `workflow-snapshot/v2` without embedded script text; inline scripts no longer supported (path-first only).
- Plugin SKILL/SPEC/README command blocks are regenerated from `scripts/gen-help.mjs` output in the same PR, wrapped in `<!-- gen:commands -->` / `<!-- /gen:commands -->` markers so `--check` can verify all four sites.

## 11. Resolved contradictions (decision log)

1. **Default-label mechanism**: Judges 1+2 proved ALS structural paths under-specified across the JSON membrane; Judge 3 proved cache-key modification unnecessary. Final: **content-occurrence default labels** — C's order-independence idea, delivered as A's label-value-only fix. Cache key descriptor and hash composition untouched; zero scope machinery.
2. **Journal contract break vs. preservation**: the spine (JSONL-at---journal, fold-everything) stands. The ergonomic costs judges attributed to it are repaired by grafts: latest.json pointer (bare status/resume UX), v1 dual-read (inspectability), worker.log (silent workers). Legacy v1 event names are not preserved — journal@2 is a clean break with a clear rejection message on the write path.
3. **Regex vs. AST gate**: the proposal's "regex is fine for advisory" stance is overruled by all three judges' graft lists — acorn is bundled (zero install weight), kills the false-positive class, and yields line/column diagnostics. The gate remains advisory; the membrane remains the boundary.
4. **`--journal` mandatory vs. default**: overruled in favor of the v1 default (`.agent-loops-runs/latest.json`), now a pointer file. SPEC examples showing explicit `--journal` remain valid; the default is restored and documented.
5. **Stale detection**: pid-only "accepted limitation" upgraded with `runner_heartbeat` events — the event log makes it nearly free, and it fixes PID-reuse and container inspection.
6. **Everything else from the losers** (five-port hexagon, subprocess script host, zod+ajv, commander, sqlite, checkpoint+log dual artifacts, cache-key field changes) is **rejected** as spine-changing or dependency-bloating.
