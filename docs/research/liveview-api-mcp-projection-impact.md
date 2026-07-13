# LiveView, API, MCP, And Projection Impact

Wayfinder asset for issue #87, part of #82.

**Status: resolved by the durable-first projection design.** Subscriber-first and
socket-local progress proposals in earlier revisions are superseded.

## Decision

The Phoenix LiveView run page is the realtime watching surface. The scheduler API
and MCP tools remain polling snapshot and durable inspection surfaces. All of them
read the same journal-backed projection.

The production path is:

1. The writer appends `agent_started` before invoking the provider.
2. The provider normalizes one Codex JSONL line at a time.
3. The writer synchronously appends each `agent_activity`.
4. After the append succeeds, the writer publishes `{:journal_committed, run_id, seq}`.
5. LiveView refolds the journal; reconnect and polling observe the same state.
6. The writer later appends an attempt settlement.

## Surface Contract

| Surface | Contract |
| --- | --- |
| Phoenix LiveView `/runs/:id` | Subscribe after connect, refold after commit notifications, and rebuild from the journal on mount or reconnect. |
| `GET /api/runs/:id` | Durable run-projection snapshot; not a stream. |
| `GET /api/runs/:id/events` | Ordered, safe journal summaries under `journalEvents` and the legacy `events` field. |
| MCP `workflow_status` | Concise polling snapshot. |
| MCP `workflow_inspect` | Projection plus `journalEvents` and ordered `rawRefs.journal`; no raw Codex JSONL. |
| MCP `workflow_open_ui` | Absolute LiveView URL for realtime watching. |

`eventCount` counts journal events. Activity order within an attempt uses
`activity_index`; agent lists use stable address, iteration, and attempt ordering.
PubSub delivery must never increment counts, create raw refs, or alter resume logic
independently of the journal.

## Failure Rules

- If an activity append fails, it is not published.
- If PubSub delivery is missed, the next poll, refresh, or reconnect still sees the
  durable activity.
- An activity entry is telemetry, not proof of provider success.
- An `agent_started` marker without settlement is terminally unknowable on resume;
  the attempt is not redelivered.

Canonical details live in [`docs/runtime.md`](../runtime.md) and
[`docs/operations.md`](../operations.md).
