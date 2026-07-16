# Reactor execution refactor

Status: implemented; deterministic, packaged, adversarial, and live gates must
all pass before release.

This document is the implementation and verification record for adopting
Reactor inside Codex Loops. Reactor is a private in-memory scheduling library.
It adds dependency-owned processes inside the existing BEAM, but no second OS
process, user service, executable, MCP transport, durable store, or
workflow-authoring surface.

## Product boundary

The shipped product remains one Elixir/Phoenix OTP release and one optional
skill-only plugin. The archive still has one `./install` reconciliation action:
it installs the immutable release and skill, provisions the user service,
health-checks it, and registers `http://127.0.0.1:47125/mcp` directly in Codex.

```text
Codex -- Streamable HTTP --> Phoenix /mcp --> Scheduler --> Run writer
                                                        |
                                                        +-- ephemeral Reactor DAG
                                                        +-- SQLite journal
                                                        +-- shared Codex app-server
```

There is no Rust runtime, stdio bridge, second app server, launchd-only MCP
client, or Reactor-owned daemon.

## Decision

Use Reactor 1.0 core only for the generic bounded concurrency that it can safely
replace:

- parallel branches;
- pipeline lanes;
- fixed and dynamic fanout lanes;
- verify voters;
- judge candidate lanes;
- refine reviewer panels.

Keep scheduler product semantics in Codex Loops:

- the per-run writer and Registry lease;
- ordered SQLite commits and post-commit PubSub;
- provider start/activity/settlement and at-most-once recovery;
- schema retry policy;
- loop decisions and iteration limits;
- dynamic fanout-width decisions;
- refine rounds, gates, projections, and reviewer failure semantics;
- status, inspect, resume, API, MCP, and LiveView projections.

This removes both `Task.Supervisor.async_stream_nolink` workflow schedulers.
Reactor does not wrap or duplicate a legacy executor; it is the only generic
concurrent-region scheduler.

## Why the scope is deliberately flat

The locked Reactor release is safe here only through its public flat-builder
surface: `Reactor.Builder.new/1`, `add_step!/5`, `return!/2`,
`Reactor.Argument.from_value/2`, `from_result/2`, and `Reactor.run/4`.

The implementation does not use Reactor composition, recursion, dynamic map
steps, halt/resume persistence, compensation, undo, or run timeouts. The audit
found that those mechanisms either do not match durable scheduler semantics or
have unsafe lifecycle/API behaviour in Reactor 1.0.2. `%Reactor{}` values are
ephemeral and are never journaled or exposed.

Every concurrent frontier builds one flat DAG plus a supervised FIFO admission
process. The admission process is required because Reactor 1.0.2 does not
guarantee ready-vertex order; without it, cap-one paid work could execute later
inputs before an earlier failure. A per-run atomic fatal latch is set inside the
actual branch worker before its fatal typed result returns. The FIFO checks that
latch before every admission, so cross-lane mailbox ordering cannot refill work
after a fatal branch has settled.

- worker names are tuples such as `{:workflow_worker, 3}`;
- ordered-join names are tuples such as `{:workflow_collect, 3}`;
- argument names are the fixed internal atoms `:item`, `:prior`, and `:results`;
- every step has `max_retries: 0` and `ref: :step_name`;
- the plan contains at most eight asynchronous worker steps; each worker pulls
  the next indexed input only after its prior item settles;
- synchronous collect/order steps join worker outputs and restore input order;
- dynamic fanout remains limited to 64 inputs, while previously valid wider
  static parallel/pipeline frontiers remain accepted;
- `Reactor.run/4` receives the existing per-run cap, at most eight.

Expected workflow/provider failures are successful typed step values. The
writer receives them in input order and applies the existing durable settlement
rules. Unexpected exceptions are re-raised with their original stacktrace.
For Codex refine roles, the journaled reviewer timeout is forwarded into the
app-server request, which owns the absolute paid-turn deadline and cancellation.
The generic supervised task has no competing deadline: admission and streamed
activity include bounded synchronous journal calls whose aggregate cannot be
safely represented by a fixed margin. Writer death and execution cancellation
still brutally terminate the task, while the app-server monitors that caller and
cancels its request.

## Process ownership and cancellation

Reactor's own asynchronous steps are globally supervised and are not linked to
the `Reactor.run/4` caller. Codex Loops therefore does not execute provider work
directly in those wrappers.

```text
run writer
  `-- linked per-run Task.Supervisor
        |-- cancellation token + FIFO admission + report broker
        |-- Reactor runner
        `-- current branch workers + guardians

Reactor OTP application
  `-- Reactor.TaskSupervisor: worker wrappers (at most eight per plan)
```

The per-run supervisor is the synchronous cancellation boundary. Terminal
failure stops it before returning, so no paid branch worker can remain alive.
The report broker is stopped at the same boundary and late wrapper reports are
dropped instead of leaking into the writer mailbox. Each branch preserves the
existing hard timeout; its guardian also kills the branch if the writer,
Reactor wrapper, or cancellation token dies.

The writer monitors Reactor's task-supervisor root, every task partition, and
the concurrency tracker while a plan runs. Replacement of any dependency
aborts the run scope instead of continuing with stale concurrency-pool state.

`Workflow.Execution.available?/0` is a pure readiness boundary. Scheduler
health requires the Reactor task-supervisor root, every partition, concurrency
tracker process, and tracker-owned ETS table to be live and responsive. Reactor
remains an OTP dependency application; no duplicate lifecycle manager is added
to `Workflow.Application`.

## Preserved invariants

1. SQLite events are authoritative. Status and resume fold the journal.
2. Reactor state is never durable and is rebuilt for every frontier.
3. `agent_started` is durable before provider dispatch. An unmatched marker is
   never redelivered and resumes as `outcome_unknown`.
4. Provider attempts remain at-most-once. Reactor retries, undo, and
   compensation are disabled.
5. Journal sequence allocation and final settlements remain writer-owned and
   input-ordered. Start/activity events may interleave while branches run.
6. External workflow values never become atoms.
7. Limits remain: eight active runs, eight tasks per run, fanout width 64, loop
   iterations 1000, and five authored retries.
8. Per-branch timeouts kill the supervised branch. A Reactor run timeout is not
   used as evidence that an effect did not happen.
9. Writer death, Reactor wrapper death, or required Reactor infrastructure loss
   leaves no provider worker running.
10. API, MCP, LiveView, journal schema, workflow syntax, and one-action install
    remain compatible.

## Implementation slices

### Completed

- [x] Capture a green pre-refactor `make ci` baseline and release size.
- [x] Lock Reactor 1.0.2 and its production dependency graph.
- [x] Restrict plan construction to the audited public flat-builder API.
- [x] Add fixed references, zero Reactor retries, FIFO admission, an atomic
      fatal latch, ordered collection, and compatibility for static frontiers
      wider than 64.
- [x] Keep raw process protocols behind receiver-owned client functions and
      model execution outcomes as distinct structs with dispatch centralized
      in their owning module.
- [x] Add a linked per-run task scope, report broker, supervised branch workers,
      owner/wrapper guardians, per-item hard timeouts, and Reactor dependency
      monitoring.
- [x] Replace generic parallel/pipeline/fanout/verify/judge scheduling.
- [x] Replace refine reviewer scheduling while preserving timeout/crash
      demotion and ambiguous-provider fatality.
- [x] Add execution readiness to scheduler health.
- [x] Add plan, atom-safety, cap/refill, width-64, ordering, exception, timeout,
      synchronous cancellation, mailbox hygiene, owner-death, late-journal,
      queue-crash, unresponsive-partition, and tracker-replacement tests.
- [x] Preserve all existing workflow-family and resume tests unchanged.
- [x] Fix the live proof so `CODEX_LOOPS_CODEX_MODEL` reaches the packaged
      release.
- [x] Record the architecture and new dependency notices.

### Release gates

- [x] `make quality` passes.
- [x] `make dialyzer-check` passes.
- [x] `make ci` passes from the working tree.
- [x] The release/API/LiveView/direct-MCP and one-action installer proofs pass.
- [x] `CODEX_LOOPS_CODEX_MODEL=gpt-5.6-terra make proof-mcp-live`
      completes validate/start/status/inspect/resume/open-UI through packaged
      Streamable HTTP MCP using one real Codex turn.
- [x] Adversarial BEAM and Elixir reviews both pass after the final diff.
- [x] Release-size delta is recorded.
- [x] The four supported distribution targets are native build/sign/install
      jobs in the signed release matrix.
- [x] The final diff is approved for commit to `master` after all applicable
      gates.

Size evidence from the same macOS build:

- baseline release: 37,172 KiB; Reactor release: 41,816 KiB;
  delta: +4,644 KiB (+12.5%);
- baseline dev bundle: 37,192 KiB; Reactor dev bundle: 41,840 KiB;
  delta: +4,648 KiB (+12.5%);
- dev-bundle file count: 1,726 to 2,237 (+511).

The deterministic CI remains one Ubuntu job. The separate release matrix runs
native build, release boot, install, signing, archive verification, and formula
aggregation jobs for both macOS and both Linux architectures.

## Deterministic verification matrix

| Concern | Required evidence |
|---|---|
| Plan safety | tuple refs, fixed argument atoms, zero retries, no undo/compensation |
| Ordering | reverse completion still returns and settles in input order |
| Continuous cap | freeing one of two slots immediately starts the next lane |
| Production bounds | width 64 reaches a measured peak of eight, never nine |
| Domain failures | expected failure tuples reach the writer as values |
| Programmer errors | original exception and stacktrace escape the execution facade |
| Timeout | blocked branch is brutally terminated and classified by its caller |
| Writer death | every branch terminates and the journal stops changing |
| Reactor tracker loss | current execution aborts; branch terminates; readiness recovers |
| Existing semantics | all linear, loop, fanout, quality, refine, and resume tests pass |
| External surface | scheduler API, MCP, browser, release, service, and install proofs pass |

The canonical deterministic command remains:

```sh
make ci
```

The live proof is manual because it requires credentials and spends a model
turn:

```sh
CODEX_LOOPS_CODEX_MODEL=<cheap-compatible-model> make proof-mcp-live
```

## Rollback

Rollback is a normal code rollback, not a journal migration:

1. restore the two prior bounded schedulers in `Workflow.Run.Writer`;
2. remove `Workflow.Execution`, its plan/step/guardian/runtime-support modules,
   and Reactor from `mix.exs`/`mix.lock`;
3. remove the additive `execution` health check;
4. rebuild and run `make ci`.

The workflow language, event schema, SQLite rows, installer, service, and MCP
configuration do not change, so Reactor-created runs remain readable by the
pre-Reactor scheduler.
