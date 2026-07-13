# Run Writer, Journal, And Realtime Responsibilities

Wayfinder asset for issue #85, part of #82.

**Status: resolved.** This note replaces the former subscriber-style persistence
proposal with the shipped single-writer, append-before-notify contract.

## Ownership

| Concern | Owner |
| --- | --- |
| Workflow traversal and provider-effect ordering | Per-run writer |
| Durable sequence allocation and SQLite append | Journal write owner |
| `agent_started`, `agent_activity`, and settlement append calls | Per-run writer |
| Codex JSONL normalization | Codex provider |
| Post-commit `{:journal_committed, run_id, seq}` refresh signal | Writer through Phoenix PubSub |
| Run-state reconstruction | Pure journal folds |
| Live presentation | LiveView over the folded projection |

The writer calls the journal synchronously for every activity entry and publishes
only after the append succeeds. There is no independently authoritative progress
feed, and the PubSub signal carries no event snapshot. `Workflow.Run.Stream` owns
subscription/topic convenience only.

## Attempt Safety

The writer appends `agent_started`, including the full attempt identity, before
launching the provider. A committed, rejected, or failed settlement closes the
attempt. If the writer dies between those events, the provider may already have run
or charged; resume records `outcome_unknown` and never redelivers that attempt. This
is an honest at-most-once effect contract, not an exactly-once claim.

Activity is durable telemetry. It may appear before settlement and remains visible
after reconnect, but it never proves the provider outcome and never controls retry,
resume, accounting, or terminal state.

## Ordering And Failure

- SQLite `seq` is allocated at append time; concurrent starts and activity appear in
  arrival order.
- `activity_index` orders activity within one attempt.
- Stable projection sorting prevents concurrent arrival order from changing the API
  shape of agent lists.
- A failed append prevents notification and must fail loudly.
- A missed PubSub notification cannot lose durable state.

Canonical behavior is specified in [`SPEC.md`](../../SPEC.md) and summarized in
[`docs/runtime.md`](../runtime.md).
