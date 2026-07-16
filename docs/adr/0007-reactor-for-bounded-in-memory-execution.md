# ADR 0007: Reactor for bounded in-memory execution

Status: Accepted

## Context

Codex Loops had two bespoke `Task.Supervisor.async_stream_nolink` schedulers for
generic workflow fanout and refine reviewer panels. The scheduler still needs
its own durable journal, writer lease, provider effect protocol, loops, and
refine state machine; those are product semantics rather than generic DAG
execution.

Reactor provides bounded graph scheduling and dependency joins, but its runtime
state is in memory and its asynchronous lane tasks are not owned by the
`Reactor.run/4` caller. Reactor 1.0.2 also has APIs and halt semantics that are
not suitable for durable paid-effect recovery.

## Decision

Use Reactor 1.0.2 as a private, ephemeral scheduler for flat bounded concurrent
frontiers only. Build plans programmatically with the audited public builder
subset. Disable Reactor retries and do not implement compensation or undo.

The per-run writer remains the journal and settlement authority. Each frontier
gets one linked, anonymous `Task.Supervisor` containing the Reactor runner,
cancellation token, FIFO admission process, report broker, branch workers, and
guardians. Stopping that scope is a synchronous paid-work cancellation barrier.
The broker prevents late globally-supervised Reactor wrapper reports from
leaking into the writer mailbox. A guardian also terminates branch work when the
writer, Reactor wrapper, or cancellation token dies.

Each run monitors Reactor's task-supervisor root, every task partition, and the
concurrency tracker while executing. The FIFO feeds at most eight Reactor
worker steps, preserving prior input-order dispatch and fail-fast paid-effect
behavior despite Reactor's arbitrary ready-vertex order. Each actual branch
worker sets a per-run atomic fatal latch before returning a fatal typed result;
the FIFO checks it before every admission, avoiding any dependence on message
arrival order between Reactor lanes.

Codex refine roles receive the journaled reviewer timeout as their app-server's
absolute paid-turn deadline. Their generic supervised task has no competing
deadline because admission and streamed activity include bounded journal calls
whose aggregate is not a safe fixed margin. Writer death and execution
cancellation remain hard task boundaries, and the app-server monitors the task
and cancels its request. Other providers keep the exact reviewer task timeout.

Do not persist Reactor state, expose Reactor in workflow syntax or APIs, use its
DSL, or add another runtime/service process.

## Consequences

- Reactor replaces both generic async-stream schedulers.
- Workflow ordering, retry, timeout, resume, and at-most-once semantics remain
  owned and tested by Codex Loops.
- Dynamic fanout remains limited to 64; static parallel/pipeline widths retain
  compatibility while the Reactor graph itself stays bounded by eight workers.
- Loop and refine domain state machines remain ordinary Elixir code.
- Scheduler health now includes Reactor execution readiness.
- The release gains Reactor and its MIT-licensed transitive dependencies, but
  installation and MCP lifecycle are unchanged.
- Readiness and in-flight loss detection intentionally observe the registered
  task-supervisor/concurrency-tracker names, task partitions, and tracker ETS
  table in exactly pinned Reactor 1.0.2. Every Reactor update must rerun
  infrastructure replacement, owner-death, cap, and packaged-health proofs
  before changing the dependency pin and lock.
