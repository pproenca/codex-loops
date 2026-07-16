# Reactor execution refactor

> **Status: ready for execution.** This is the implementation and verification
> plan for replacing Codex Loops' generic in-memory workflow scheduling with
> Reactor while retaining Codex Loops' durable scheduler semantics.

Date: 2026-07-16

Baseline: `64e8037` (`Replace Rust control plane with single OTP service`)

## Outcome

Codex Loops remains one packaged Elixir/Phoenix OTP release and one direct
Streamable HTTP MCP endpoint. Reactor becomes a private, programmatically built
execution substrate inside each supervised run. It may own dependency planning,
ready-step selection, bounded asynchronous step execution, joins, and result
propagation. It does not become the product language, durable store, scheduler
service, provider owner, or MCP lifecycle manager.

The completed refactor must leave this ownership split:

```text
Codex -> Streamable HTTP /mcp -> Workflow.Scheduler -> Workflow.Run.Writer
                                                        |
                                                        +-- journal/lease/effect boundary
                                                        |
                                                        +-- Reactor plan and runtime
                                                              |
                                                              +-- workflow step adapters
                                                                    |
                                                                    +-- shared Codex app-server
```

The install contract remains one action: the archive's `./install` installs the
immutable release and skill, reconciles the user service, health-checks it, and
registers `http://127.0.0.1:47125/mcp`. The refactor must not introduce another
runtime, launcher process, MCP bridge, daemon, or Rust component.

## Decision

Adopt Reactor core as an internal library using `Reactor.Builder`. Do not expose
Reactor's DSL to workflow authors and do not compile user files as Elixir code.
The existing parser/compiler continues to turn exactly one inert top-level
`workflow` declaration into `%Workflow.Tree{}`.

Use Reactor only where it removes generic orchestration machinery:

- dependency graph construction and ready-step selection;
- bounded parallel execution and joins;
- pipeline lane dependency scheduling;
- fanout execution after Codex Loops has durably resolved its width;
- propagation of successful step results to dependent steps.

Keep Codex Loops implementations where they encode product semantics Reactor
does not provide:

- SQLite journal, event schema, pure read-model folds, ledger, and idempotency;
- the per-run Registry lease, supervised run owner, and active-run capacity;
- the paid-provider start/settlement boundary and `outcome_unknown` policy;
- stable workflow addresses and journaled loop/fanout/refine decisions;
- provider adapters and the one shared Codex app-server connection;
- MCP, Phoenix API/LiveView, installation, user-service, and release ownership.

Do not add `reactor_file`, `reactor_process`, `reactor_req`, or another Reactor
extension during this migration. They do not replace a retained product
boundary and would widen the dependency and failure surface.

## Non-negotiable invariants

Every slice must preserve these properties. A test that proves one of them must
not be weakened, deleted, or rewritten to assert Reactor internals.

1. **The journal is authoritative.** Restart and resume reconstruct all durable
   state by folding SQLite events. Reactor state, process state, PubSub messages,
   and telemetry are never authoritative.
2. **No Reactor persistence.** Never serialize `%Reactor{}`, executor queues,
   closures, references, PIDs, or task state. A resumed run rebuilds a fresh plan
   from the journaled `%Workflow.Tree{}` and the current compatible executor.
3. **At-most-once paid effects.** Persist `agent_started` before invoking a
   provider. If no durable settlement exists after that marker, resume records
   and returns `outcome_unknown`; it never redelivers the attempt.
4. **Retry meaning does not change.** Provider failures are terminal. Only a
   schema/adapter rejection after a settled paid result may retry, and authored
   retries remain capped at five. Reactor retries, compensation, and undo are
   disabled for every effectful workflow step.
5. **Stable identities survive.** `%Workflow.Node{}` addresses plus loop
   iteration and attempt remain the persistence and idempotency identity. A
   Reactor step name is ephemeral and must not appear in a durable event or API.
6. **No minted atoms.** Programmatic step references must use terms accepted by
   Reactor without converting workflow names, labels, bindings, paths, or other
   external values to atoms. If a Reactor API requires an atom, use a fixed
   compile-time atom and carry the stable address as ordinary data.
7. **Event ordering remains observable-compatible.** Bracket-start events
   precede their children, branch settlements commit in the existing stable
   lane/input order, and bracket-complete events follow all settlements.
   Concurrent start/activity events may interleave as they do today, but each
   attempt's marker/activity/settlement causality and journal sequence remain
   gap-free.
8. **Commit before notify.** Every LiveView/PubSub refresh is emitted only after
   the corresponding durable commit. PubSub remains a lossy refresh hint.
9. **Bounds remain exact.** At most eight active runs, eight concurrent tasks per
   run, fanout width 64, loop iterations 1000, and agent retries five. Reactor's
   own defaults must never relax these limits.
10. **Crash classification remains exact.** Expected workflow/provider failures
    become the existing typed terminal results. Unexpected exceptions/exits are
    journaled as `run_failed` and re-raised so supervision and callers see the
    bug. Reactor error wrapping must not turn programmer defects into expected
    domain failures.
11. **Timeouts remain effect-aware.** Keep the existing provider and reviewer
    timeout contracts. Do not use a Reactor run timeout as proof that an external
    provider effect did or did not happen; cooperative executor cancellation is
    not a transactional settlement boundary.
12. **Failure leaves no orphans.** A run-owner crash, cancellation, or terminal
    branch failure terminates all executor tasks owned by that run. It must not
    leak provider work, hold the Registry lease, or continue appending events.
13. **Existing data remains readable.** Runs created before cutover must keep the
    same status, inspect, ledger, resume, and LiveView projections. No event
    schema migration is justified by changing the in-memory executor.
14. **The external surface is unchanged.** Workflow syntax, MCP tool schemas,
    HTTP/API responses, install action, service lifecycle, and release layout
    remain compatible unless a separate versioned product decision changes them.

## Target code boundary

Create a small execution boundary rather than moving `Workflow.Run.Writer` into
a new service-object hierarchy:

- `Workflow.Run.Writer` keeps the per-run process lifecycle, Registry lease,
  crash journaling, terminal notification, and ordered commit authority. It is
  the Reactor coordinator/caller, just as it is the current tree-walk caller.
- `Workflow.Execution` is a functional facade that builds and runs an ephemeral
  plan from a tree, prior events, and run options.
- `Workflow.Execution.Plan` translates inert workflow nodes into Reactor builder
  calls and attaches stable address metadata. Translation is pure and directly
  unit-testable.
- Custom `Reactor.Step` modules are limited to real semantic boundaries such as
  a paid agent attempt, a durable dynamic decision, an ordered barrier, or a
  composite loop/refine state machine. Do not create one wrapper module per
  existing function merely to add layers.
- Journal/event/provider functions remain ordinary modules and structs. Do not
  add single-implementation behaviours or dependency-injection containers for
  Reactor.

The exact module split may change when code is extracted, but there must be one
public internal execution facade and one long-term engine. The final tree must
not retain parallel legacy and Reactor executors.

### Commit protocol

The ordered durable boundary is part of the design, not an implementation detail:

1. The run writer calls Reactor synchronously under its existing crash wrapper.
   Reactor's coordinator is therefore part of the run owner's execution, while
   asynchronous steps remain library-owned children that must terminate when
   the caller dies. A separate top-level `async_nolink` executor is forbidden.
2. A paid step appends `agent_started` through `Workflow.Journal` and waits for
   the durable acknowledgement before calling the provider. Activity uses the
   same journal API. An append timeout/error stops the step before the provider
   call; if the marker committed despite an ambiguous caller failure, recovery
   safely classifies it as `outcome_unknown`.
3. Concurrent steps may append only immediate causal events: `agent_started`
   and that attempt's `agent_activity`. They return typed branch outcomes and
   pending settlement event batches as ordinary data.
4. Expected branch/provider/schema failures are successful Reactor step values
   such as `%Workflow.Execution.BranchOutcome{}`. This guarantees the ordered
   join still runs. They are not returned as Reactor errors.
5. A single `async?: false` ordered-join step depends on every branch, consumes
   their typed outcomes in stable lane/input order, and appends settlement
   batches plus the completion/failure bracket through `Workflow.Journal`.
   `Workflow.Journal` remains the only sequence allocator; Reactor tasks never
   append final branch settlements independently. Slice 1 must prove with the
   locked Reactor release that this synchronous step executes in the run
   coordinator. If not, use one explicit per-run ordered-barrier process or stop;
   never call back into a writer blocked inside `Reactor.run`.
6. An unexpected Reactor task exception/exit is returned to the writer as an
   executor fault. The writer unwraps and re-raises it through its existing crash
   wrapper, which checks for an unsettled marker, appends the correct
   `run_failed` reason, and exits with the original fault/stacktrace.
7. All process protocols remain behind named client functions. Reactor error
   wrappers and internal message tuples do not escape `Workflow.Execution`.

Slice 2 must prototype this protocol with two parallel branches, activity,
schema rejection/retry, an expected branch failure, and an owner/task crash
before any workflow family is migrated. Failure to preserve both causal markers
and stable settlement order is a stop condition.

## Dependency policy

Add the current Reactor 1.0 core line to `mix.exs` and lock the resolved version.
At implementation time, confirm the current stable release and use the narrowest
compatible requirement that accepts security/patch fixes without crossing a
minor compatibility boundary.

Before merging the dependency:

- inspect its OTP application and supervision requirements;
- inventory all transitive production dependencies and licenses;
- update `THIRD_PARTY_NOTICES.md` and release/package metadata as required;
- run `mix deps.audit` and `mix hex.audit`;
- measure release archive size and cold-start/health latency before and after;
- confirm all four supported release targets build;
- depend only on public Reactor APIs.

Reactor's dependency application is outside the Codex Loops root supervisor, so
slice 1 must add an explicit local readiness boundary. The proposed shape is a
small `Workflow.Execution.Runtime` process ordered before
`Workflow.RuntimeSupervisor` under the root `:rest_for_one` tree. It owns no
workflow state. It probes Reactor through a bounded public no-op execution,
reports `execution: :available | :unavailable` through the existing health
checks map, rejects new runs while unavailable, and monitors the locked
release's required execution infrastructure. Loss of that infrastructure must
make health return the existing unavailable response, cause active executor
tasks to report failure to their run writers, and allow future runs only after
the public probe succeeds again. If this cannot be implemented without relying
on unstable Reactor internals, the dependency fails the slice-1 go/no-go gate.

Every programmatically added effectful step must set retries explicitly to zero.
Do not inherit `Reactor.Builder.Step` retry defaults. Do not define `compensate/4`
or `undo/4` for paid effects. Set the Reactor run concurrency option explicitly
to the Codex Loops per-run cap instead of accepting library defaults.

## Migration slices

Each slice is independently reviewable. Do not advance when its deterministic
gate is red. Preserve the legacy executor only as a temporary comparison and
rollback mechanism through slice 6.

### 0. Freeze the behavioral baseline

Goal: capture the contract before adding Reactor.

Implementation:

- Run and record `make ci` at the baseline commit.
- Add deterministic golden traces for representative sequential, parallel,
  pipeline, generic fanout, loop, verify, judge, synthesize, and refine runs.
- Normalize only genuinely volatile values such as temporary paths, wall-clock
  timestamps, and generated run IDs. Require exact ordered equality for bracket,
  settlement, decision, and ledger events. For concurrent start/activity events,
  retain exact addresses and gap-free global sequence but assert only the
  per-attempt causal partial order and activity indexes, never a cross-branch
  address-to-sequence order chosen by one scheduler interleaving.
- Add a reusable crash-injection provider/harness for each side of the paid
  effect boundary and each concurrent join.
- Preserve a legacy v1 journal fixture containing a completed run, a resumable
  run, a terminal failed run, and an unsettled `agent_started` attempt.
- Record current dev-bundle archive size and scheduler health startup time.

Proof:

```sh
make ci
```

Rollback: test-only fixtures and measurements can be reverted without runtime
impact.

### 1. Add Reactor and prove the translation seam

Goal: determine that Reactor can represent Codex Loops' static execution graph
without changing runtime behavior.

Implementation:

- Add Reactor core and dependency notices.
- Add a pure tree-to-plan prototype behind `Workflow.Execution.Plan`.
- Cover phase/log/emit/return, agent dependencies, parallel joins, and pipeline
  lane dependencies with plan-structure tests.
- Prove that tuple/integer step references work without dynamic atoms. If they
  do not, retain fixed internal names and address metadata; do not mint atoms.
- Pass immutable run context through Reactor inputs/options. Do not put mutable
  journal cursors or authoritative state in the plan.
- Explicitly configure step async behavior, retries, and the run concurrency
  cap in tests.
- Enumerate the locked Reactor release's application children and failure
  behavior. Implement the execution readiness boundary described above and add
  its status to `Workflow.Scheduler.health/0` without changing the health API
  response shape.
- Create one opaque Reactor `concurrency_key` per run and pass it, with
  `max_concurrency: 8`, to the top-level run and every nested run. Instrument a
  nested prototype to prove the public pool is shared and removed after owner
  death. If the locked public API cannot enforce one shared pool, flatten nested
  plans or stop; do not implement an unbounded second scheduler.
- Inject loss of Reactor's required task supervisor/concurrency tracker while
  idle, during a mock run, and after `agent_started`. Health must fail closed,
  no executor work may be orphaned, the in-flight attempt must become
  `outcome_unknown`, and a recovered runtime must accept a future run.

Go/no-go gate:

- The plan is built entirely through public APIs.
- It introduces no new durable representation.
- It can express the static graph without duplicating a second dependency graph
  inside Codex Loops.
- Release size/startup regression is understood and accepted.
- Its public shared concurrency mechanism and dependency-runtime recovery pass
  the injected-failure tests.

If any gate fails, remove Reactor and stop. Do not build a compatibility
framework around a library that cannot own the generic graph work.

### 2. Extract the durable shell without changing behavior

Goal: make the boundary between product semantics and generic execution explicit
before changing engines.

Implementation:

- Keep `Workflow.Run.Writer` as the temporary run owner and durable shell.
- Keep it as the synchronous Reactor coordinator. Paid steps and ordered joins
  append through the Journal API and never call back into the blocked writer.
- Extract pure context reconstruction, journal settlement checks, event commit,
  provider-attempt execution, and public result normalization from the 2,800+
  line writer into cohesive existing-domain modules.
- Move the current tree walk behind a temporary `Workflow.Execution.Legacy`
  implementation used only during migration.
- Do not create a public engine option. A private application/test switch may
  select legacy or Reactor for conformance tests.
- Run characterization tests after each extraction before changing scheduling.
- Prove the commit protocol's parallel failure, schema retry, activity ordering,
  append failure/ambiguity, executor crash, and writer crash cases before slice
  3, including that all Reactor-owned tasks terminate when the writer dies.

Rollback: revert individual extractions. No event or public API changes are
allowed in this slice.

### 3. Add mock-only differential conformance

Goal: compare engines without duplicating a real paid effect.

Implementation:

- Run the same compiled tree through legacy and Reactor engines in isolated
  journals with deterministic providers.
- Compare canonical event traces, final status, result bindings, ledger, inspect
  payload, and failure value. Canonical comparison means exact equality for
  stable bracket/settlement/decision/ledger events; gap-free global sequence;
  and partial-order assertions for concurrent start/activity events. For each
  attempt require `agent_started` before activity/settlement and monotonically
  increasing activity indexes, without treating cross-branch timing as public.
- Use controlled barriers so concurrent tests assert the existing ordering
  contract rather than scheduler timing.
- Cover success, expected provider failure, schema rejection/retry exhaustion,
  unexpected exception, timeout, and cancellation.
- Never shadow a Codex/live run: two engines would create two paid effects and
  invalidate the at-most-once contract.

Required workflow families:

| Family | Required cases |
| --- | --- |
| Linear | empty/phase/log, return, emit, one and multiple agents |
| Parallel | widths 1/2/8, authored cap 1/2/8, one branch failure, crash at join |
| Pipeline | zero/one/many items, independent lane progress, stage failure |
| Fanout | fixed/dynamic width, widths 0/1/64, attempted 65, `on_zero` modes |
| Loop | zero/one/1000 iterations, exhausted cap, all predicates, nested fanout |
| Quality | verify thresholds, judge modes, synthesize, partial role failure |
| Refine | converge, did-not-converge, reviewer timeout/crash, cold-read/repair |
| Resume | settled reuse, unknown outcome, replayed width/decision, old journal |

Rollback: remove the Reactor engine and private switch. The golden fixtures stay
useful.

### 4. Cut static and bounded concurrent regions over to Reactor

Goal: let Reactor own the generic graph, concurrency, and joins.

Implementation:

- Migrate linear nodes first, then parallel and pipeline, then generic fanout.
- For dynamic fanout, resolve and persist width once before constructing/running
  lanes. Resume consumes the journaled width and never recomputes historical
  budget/path inputs.
- Preserve the current causal event contract: bracket start, attempt start,
  activity, stable ordered settlements, then bracket completion.
- Keep the paid agent step responsible for `agent_started -> provider -> typed
  pending settlement`; the ordered join/writer protocol owns durable branch
  settlement. Reactor sees the typed domain outcome, not a domain failure raised
  as an executor error.
- Map expected domain failures deliberately. Re-raise unexpected step failures
  after `run_failed` is committed.
- Verify executor task ownership and shutdown when a sibling fails or the run
  owner exits.
- Remove the replaced `Task.Supervisor.async_stream_nolink` workflow topology
  helpers as soon as each family passes. Retain `Workflow.TaskSupervisor` only
  while a non-topology use remains proven by search/tests.

Rollback: switch the private engine default back to legacy. Because event shape
and persisted trees are unchanged, Reactor-created runs remain readable and
resumable by the legacy engine during this slice.

### 5. Migrate loops and quality combinators

Goal: move all remaining execution families behind the Reactor facade without
pretending Reactor supplies their domain semantics.

Implementation:

- Represent a loop/refine round as a custom composite step or nested Reactor run
  built from the already-compiled subtree.
- Keep loop continuation, deduplication, budget, dry-run streak, gate decisions,
  and terminal projections in Codex Loops domain functions.
- Persist each dynamic decision before scheduling the next round. Resume folds
  it and reconstructs only unfinished work.
- Enforce the product's 1000-iteration cap directly. Do not substitute Reactor's
  internal iteration/retry limits.
- Run verify/judge/synthesize/refine panels with bounded Reactor concurrency,
  preserving ordered role settlement, role-specific failures, reviewer timeout,
  and usage accounting.
- Ensure a nested executor cannot multiply concurrency beyond eight for the run;
  the writer-created Reactor `concurrency_key` and `max_concurrency: 8` must be
  passed to every nested plan. Instrument actual simultaneously running
  workflow/provider work for nested loop/refine/fanout combinations, prove the
  peak never exceeds eight, prove pool state disappears after owner death, and
  retain the app-server-wide eight-turn admission bound.

Rollback: use the private legacy engine for all families. No journal conversion
is needed.

### 6. Default cutover and old-journal compatibility

Goal: make Reactor the only production engine while preserving rollback.

Implementation:

- Run the complete differential suite and switch the internal default.
- Start and resume the baseline v1 journal fixtures with the new engine.
- Upgrade a copied real development journal and verify status/inspect/LiveView
  projections before allowing writes; never test against the user's only copy.
- Verify terminal runs are no-ops and an unmatched start marker fails closed.
- Exercise Scheduler, MCP, HTTP API, LiveView, service restart, and app-server
  reconnect paths against Reactor-backed runs.
- Keep the legacy module for one short cutover slice only, guarded from normal
  production selection and covered by a rollback test.

Rollback: ship the immediately previous release or flip the internal engine to
legacy. The unchanged event schema makes this a code rollback, not a data
rollback.

### 7. Delete the duplicate executor

Goal: finish the refactor instead of permanently carrying two engines.

Implementation:

- Delete `Workflow.Execution.Legacy`, the engine switch, bespoke graph-ready
  selection, async-stream topology helpers, and lane scheduling now owned by
  Reactor.
- Shrink `Workflow.Run.Writer` to lifecycle/lease/crash handling and execution
  invocation. Retained orchestration code must correspond to a named product
  invariant, not a generic DAG primitive.
- Remove `Workflow.TaskSupervisor` if repository search and failure tests prove
  no remaining owner needs it.
- Remove dead options, structs, aliases, and tests that inspect the old
  implementation. Keep all behavioral/golden tests.
- Add an ADR recording Reactor as the in-memory execution substrate and link it
  from the canonical docs.
- Update runtime, authoring, operations, architecture, dependency, and release
  documentation.

Completion check:

- There is one production executor.
- No workflow topology is implemented twice.
- Reactor-specific terms stay below `Workflow.Execution` and do not leak into
  workflow syntax, journal events, MCP, API, or UI.
- The change removes the bespoke generic scheduling machinery it set out to
  replace. If Reactor merely wraps it, the refactor is incomplete.

Rollback: revert this deletion slice only until the next public release. Do not
reintroduce the legacy engine after a release has been proven and published
without a new incident-driven plan.

### 8. Production and live verification

Goal: prove the built, installed product rather than only the Mix development
tree.

Run all gates below from the final commit. A deterministic pass without a live
pass is not enough to declare the refactor production-ready.

#### Deterministic gate

```sh
make ci
```

This must continue to cover formatting, compile warnings, Credo, Sobelow,
dependency/security audits, full tests, Dialyzer, browser E2E, plugin package,
distribution/install proof, release/API/service proof, and direct Streamable
HTTP MCP conformance.

Additionally inspect the produced release:

```sh
make dist
```

Use the required signing key in release conditions. Verify the archive contains
one OTP release, one CLI/install action, and the skill, with no Rust or second
MCP runtime. Compare archive size and health startup time with slice 0.

#### Automated live MCP gate

Run the existing packaged-release proof with the cheapest configured Codex
model that supports the app-server protocol:

```sh
CODEX_LOOPS_CODEX_MODEL=<cheapest-supported-model> make proof-mcp-live
```

Record the exact model, Codex CLI version, package version, commit, timestamp,
run ID, terminal status, usage, and journal path before cleanup in a redacted
proof artifact. The proof must validate and start through `/mcp`, observe real
activity, complete, inspect the journal-backed projection, resolve the UI URL,
keep the service alive until explicit shutdown, and then prove shutdown.

Add `make proof-reactor-live` for the refactor. It must use an isolated packaged
release and temporary journal/binding like `proof-mcp-live`, but exercise in one
small workflow:

- a sequential real agent step;
- two real parallel branches joined before continuation;
- one result consumed by a dependent step or terminal binding;
- status and inspect polling while work is active and after completion;
- release restart after settlement, followed by status/inspect and a no-op
  resume that performs no additional paid turn.

Keep this proof intentionally small and use the cheapest compatible model. Do
not deliberately kill an in-flight live paid turn: the deterministic
crash-injection suite is the safe proof of `outcome_unknown`.

#### Installed Codex canary

From the final distribution, run the single `./install` reconciliation action
in a clean canary user environment and verify:

1. the service is healthy at `127.0.0.1:47125`;
2. Codex has exactly one MCP registration pointing directly at `/mcp`;
3. `workflow_validate`, mock `workflow_start`, `workflow_status`,
   `workflow_inspect`, and `workflow_open_ui` work through Codex;
4. one cheapest-model live workflow works through the same installed binding;
5. closing/reopening Codex does not own or duplicate the scheduler service;
6. rerunning `./install` is idempotent and leaves one healthy service;
7. service restart preserves journal projections and completed-run no-op resume;
8. uninstall/rollback instructions affect only Codex Loops-owned state.

This canary is the user-visible proof of the one-action install contract. Save
run IDs and redacted command output; do not commit credentials, Codex home data,
or raw model content.

#### Actual Codex MCP-client gate

Add a mandatory `make proof-codex-client-live` target. Unlike
`proof-mcp-live`, which is intentionally a direct HTTP conformance client, this
proof must demonstrate that a real Codex client discovers and invokes the MCP
registration installed by the one action.

Run it in a clean authenticated canary account/VM against a pinned supported
Codex CLI version. The script must:

1. unpack the final archive and run only `./install`;
2. query Codex's MCP configuration and assert exactly one `codex-loops`
   registration with the expected direct `/mcp` URL;
3. run Codex non-interactively with structured/JSON output and require captured
   MCP tool-call records for validate, start, status, inspect, and open-UI;
4. use mock for the lifecycle sequence and the cheapest compatible model for
   one minimal live workflow;
5. terminate that Codex client process and prove the scheduler remains healthy;
6. start a fresh Codex client process, inspect the same run ID, and prove no
   additional provider turn occurred.

The proof fails if the transcript lacks the named MCP calls, if Codex starts a
second scheduler, or if scheduler health follows the client process lifecycle.
Store only redacted transcript assertions and metadata as proof artifacts.

#### Packaged upgrade and rollback gate

Add `make proof-upgrade-rollback`, parameterized with a baseline archive. In an
isolated service-manager/user environment it must:

1. install the baseline archive with its one action;
2. create completed, resumable, terminal-failed, and unsettled-attempt journals;
3. install the Reactor archive with its one action and assert one service and one
   MCP registration;
4. verify projections, settled no-op resume, resumable progress, and fail-closed
   `outcome_unknown` without another paid call;
5. create a completed Reactor-backed run, reinstall the baseline archive, and
   verify that unchanged v1 events still project and resume compatibly;
6. rerun the Reactor install and prove reconciliation is idempotent.

An install/upgrade must reject before mutating files or restarting the service
when any run is active. Return a stable actionable error and require the user to
rerun the same one action after work settles; do not drain indefinitely or kill
an in-flight paid turn. The proof must hold a controlled run active, assert this
rejection leaves the old service/binding untouched, settle it, and then prove a
single rerun upgrades successfully.

#### Four-target release matrix

Before the Reactor dependency merges, add CI jobs for
`aarch64-apple-darwin`, `x86_64-apple-darwin`,
`aarch64-unknown-linux-gnu`, and `x86_64-unknown-linux-gnu`. Each pull-request
job builds the release/dev bundle, runs the target-local archive/install smoke,
and uploads the runtime manifest, archive hash, size/startup measurement, and
test log as a named immutable Actions artifact. A temporary CI signing key may
exercise archive verification but must never publish those artifacts.

All four build/install jobs are merge gates for dependency and release-shape
changes. Release-tag jobs repeat the matrix with the release signing secret,
publish the signed archive/checksum/signature triples, collect them into
`DIST_DIR`, and run `make homebrew-formula`. The normal Linux `make ci` job
remains the full deterministic behavior gate rather than being silently treated
as four-target coverage.

## Failure-injection matrix

The following deterministic failures are mandatory because a happy-path live
turn cannot prove durable effect semantics:

| Injection point | Required result |
| --- | --- |
| Before `agent_started` | Resume may safely execute the attempt once |
| After `agent_started`, before provider call | Resume fails `outcome_unknown`; no redelivery |
| Provider accepted work, before response | Resume fails `outcome_unknown`; no redelivery |
| Provider returned, before settlement commit | Resume fails `outcome_unknown`; no redelivery |
| After settlement, before PubSub | Fold is correct; UI catches up from journal |
| During activity streaming | Activity indexes remain valid; final effect policy is unchanged |
| One concurrent branch crashes | No orphan tasks; no false completion bracket |
| One branch returns an expected failure | Stable earlier settlements remain; run fails once |
| Run owner exits | Registry lease releases; all owned tasks terminate |
| Journal restarts | Downstream dependent children rebuild in dependency order |
| App-server exits | Supervised reconnect behavior remains bounded and observable |
| Release/service restarts | Durable projection survives; no settled effect repeats |
| Reactor task/run timeout | Timeout cannot be mistaken for effect non-execution |

## Performance and overload checks

The refactor must not be accepted solely on functional equivalence. Measure:

- one active run and eight active runs;
- per-run concurrency 1, 2, and 8;
- fanout widths 1, 8, and 64;
- journal append latency while activity events stream;
- scheduler health/API latency under maximum admitted work;
- mailbox growth for the run owner, journal, PubSub, and app-server;
- task/process cleanup after success, failure, timeout, and owner crash;
- memory retained after a 64-lane result set and after repeated loops.

Inputs remain bounded by compiler/runtime limits. Do not add an externally driven
unbounded `cast`, detached task, infinite call timeout, or push-only queue to feed
Reactor.

## Review gates

Run these gates on every slice that changes execution, supervision, event
delivery, shared state, or LiveView behavior:

1. two blind `adversarial-beam` reviewers over the exact diff plus relevant
   sibling supervision/journal modules;
2. two blind `adversarial-elixir` reviewers over the exact diff plus the full
   execution boundary;
3. two blind `adversarial-phoenix-liveview` reviewers when a slice changes UI,
   PubSub routing, projections, or LiveView lifecycle.

The gates are fail-closed: both blind reviewers must return PASS. A split verdict
is contested and blocks the slice until the code or rule evidence is resolved.
Verdict-only agents do not fix the code; fixes happen in a separate pass and the
complete gate is rerun.

Reviewers must specifically look for:

- supervision strategy no longer matching dependency order after Reactor starts;
- restart amnesia caused by treating an in-memory plan as durable;
- unsupervised/detached executor or provider tasks;
- concurrency defaults bypassing the run-wide cap;
- PubSub/telemetry becoming an authoritative event path;
- Reactor retry/undo causing a second paid effect;
- expected failures swallowed by rescue or unexpected bugs normalized as data;
- an unnecessary service/manager/behaviour layer around plain functions;
- dynamic atoms or unbounded retained task results.

## Final acceptance checklist

The refactor is complete only when every item is true:

- [ ] Reactor owns the generic in-memory graph/concurrency work.
- [ ] The legacy executor and private engine switch are deleted.
- [ ] Journal schema and all external contracts remain compatible.
- [ ] Old journal fixtures fold and resume correctly.
- [ ] Paid effects remain at-most-once with fail-closed unknown outcomes.
- [ ] All product limits are explicitly enforced and tested.
- [ ] No executor/provider task survives its run owner.
- [ ] Dependency, license, release-size, and four-target build checks pass.
- [ ] `make ci` passes from the final commit.
- [ ] `make proof-mcp-live` passes on the cheapest compatible model.
- [ ] `make proof-reactor-live` passes on the packaged release.
- [ ] `make proof-codex-client-live` proves real Codex MCP discovery and calls.
- [ ] `make proof-upgrade-rollback` passes against the baseline archive.
- [ ] All four merge-gate release build/install jobs pass and retain artifacts.
- [ ] The installed Codex canary passes through the direct HTTP MCP registration.
- [ ] The one-action `./install` proof and idempotent rerun pass.
- [ ] Required adversarial BEAM/Elixir/LiveView gates pass.
- [ ] Runtime, operations, authoring, ADR, and third-party docs are current.
- [ ] No credentials or live proof payloads are committed.

Do not merge, tag, publish, or describe the refactor as production-ready before
the entire checklist is complete.
