# Provider And Containment Streaming Boundaries

Wayfinder asset for [Map provider and containment streaming boundaries](https://github.com/pproenca/codex-loops/issues/84).

**Status: superseded by the durable-first runtime design.** This note records the
resolved boundary. Earlier subscriber-first sketches are not part of the shipped
architecture.

## Decision

`Workflow.Containment` owns bounded OS-process transport. It starts one child,
delivers stdin, drains stdout, frames complete lines, enforces the finite deadline
and byte limits, and reports transport success or failure. It remains ignorant of
Codex JSONL, activity kinds, schemas, and final-result selection.

`Workflow.Provider.Codex` owns the Codex protocol. It builds `codex exec --json`,
passes `--output-schema` for structured turns, decodes each JSONL line once, folds
the protocol into an immutable accumulator, normalizes activity, extracts usage and
the final assistant result, and reports provider failures.

`Workflow.Run.Writer` owns durability. Before the provider starts it synchronously
appends `agent_started`. Its activity sink synchronously appends each normalized
`agent_activity`; only a successful append is followed by a post-commit PubSub
notification. Settlement remains the writer's responsibility through
`agent_committed`, `agent_attempt_rejected`, or `agent_failed`.

There is no detached persistence subscriber and no second, ephemeral activity
projection. A connected UI may be notified while the provider is running, but it
always renders a journal fold. A missed notification loses no activity.

## Failure And Backpressure Rules

- Input and stdout are each limited to 16 MiB; the default provider deadline is
  30 minutes.
- Containment reports timeout, size, and child-exit failures without interpreting
  Codex semantics.
- The provider reports malformed JSONL, protocol failure, or missing final output.
- A journal append failure is a durability failure; execution must not publish or
  continue as though the entry committed.
- Activity durability may briefly backpressure stdout processing. That is the
  deliberate price of preserving append-before-notify ordering and reconnect-safe
  projections.

## Result

The production boundary is transport in containment, protocol folding in the Codex
provider, and synchronous event durability in the run writer. Canonical runtime
semantics live in [`docs/runtime.md`](../runtime.md).
