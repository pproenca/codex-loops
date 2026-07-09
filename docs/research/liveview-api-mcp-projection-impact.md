# LiveView, API, MCP, and projection impact for realtime Codex streaming

Issue: #87, part of #82

## Question

Which user-facing and integration-facing surfaces must change once Codex provider output streams in realtime?

## Sources

- `lib/workflow/web/run_live.ex`
- `lib/workflow/web/scheduler_run_controller.ex`
- `lib/workflow/scheduler.ex`
- `lib/workflow/scheduler/run_projection.ex`
- `lib/workflow/scheduler/run_events_projection.ex`
- `lib/workflow/status.ex`
- `lib/workflow/run/stream.ex`
- `lib/workflow/journal.ex`
- `lib/workflow/run/writer.ex`
- `lib/workflow/mcp/anubis_server/workflow_status.ex`
- `lib/workflow/mcp/anubis_server/workflow_inspect.ex`
- `lib/workflow/mcp/anubis_server/tool_helpers.ex`
- `lib/workflow/mcp/projection_envelope.ex`
- `lib/workflow/mcp/scheduler_client.ex`
- `test/workflow/web/run_live_test.exs`
- `test/workflow/web/scheduler_api_test.exs`
- `test/workflow/mcp_anubis_validate_test.exs`
- `test/workflow/mcp_projection_envelope_test.exs`
- `test/workflow/status_projection_test.exs`
- `test/workflow/run_test.exs`
- Phoenix LiveView docs: `connected?/1`, `stream/4`, `stream_insert/4`
- Phoenix contexts docs

## Decision

Keep exactly one realtime product surface: the Phoenix LiveView run page. Keep the scheduler API and MCP tools as snapshot and inspection surfaces backed by the durable journal fold.

The realtime pipeline should remain:

1. Codex provider normalizes Codex JSONL into activity entries.
2. Writer/provider shell emits lightweight progress messages through `Workflow.Run.Stream`.
3. Connected LiveView processes receive progress messages and update immediately.
4. `Workflow.Run.ActivityPersistenceSubscriber` subscribes to the same stream and persists `agent_activity` out of band through `Workflow.Journal`.
5. Durable API, MCP, resume, accounting, and reconnect behavior read from `Workflow.Status` and scheduler projections folded from the journal.

This matches the implemented direction: `Run.Stream` is the realtime
progress-message bus, `ActivityPersistenceSubscriber` persists `agent_activity`,
and `RunLive` treats `{:journal_committed, ...}` as a refresh signal while
applying `{:run_stream_event, ...}` directly for immediate UI feedback.

## Surface map

| Surface | Needs realtime? | Needs durable replay? | Contract |
| --- | --- | --- | --- |
| Phoenix LiveView `/runs/:id` | Yes | Yes | Connected users should see normalized activity entries before the agent settles. Initial mount, reconnect, and refresh must rebuild from the scheduler snapshot and journal fold. |
| `Workflow.Run.Stream` | Yes | No | Internal progress-message bus. It carries normalized activity entries, not the public journal contract. |
| `Workflow.Run.ActivityPersistenceSubscriber` | No user-facing realtime | Yes | Explicit subscriber that persists `agent_activity` idempotently through `Workflow.Journal`. It must not be in the port-draining critical path. |
| `GET /api/runs/:id` | No | Yes | Snapshot projection from `Workflow.Status` and `RunProjection`. Polling can observe persisted activity, but the endpoint is not a live stream. |
| `GET /api/runs/:id/events` | No | Yes | Ordered journal event summaries only. The additive `"journalEvents"` field, and legacy `"events"` field, mean journal event projections, not raw Codex events or PubSub progress messages. |
| MCP `workflow_status` | No | Yes | Concise snapshot over `GET /api/runs/:id`. It should not promise streaming. Polling can observe journal-persisted activity. |
| MCP `workflow_inspect` | No | Yes | Detailed inspection over `GET /api/runs/:id/events`; the MCP envelope strips legacy `"events"` and returns the public projection plus `journalEvents` and ordered `rawRefs`. |
| MCP `workflow_open_ui` | Indirectly | Yes | Opens the LiveView URL. The UI is the realtime experience; the MCP tool itself remains a URL-returning snapshot command. |
| `Workflow.Status` | No | Yes | Pure fold. It may fold persisted `agent_activity`, but it must not depend on transient stream delivery. |
| `RunProjection` | No | Yes | Stable read model shared by API, MCP, and LiveView snapshots. It should expose activity entries as activity, not as Codex events. |
| `RunEventsProjection` | No | Yes | Stable journal-summary read model. Do not turn it into a realtime feed. |

## Phoenix UI impact

The current shape is broadly right:

- `RunLive.mount/3` calls `RunStream.subscribe(run_id)` only under `connected?(socket)`, then assigns a scheduler snapshot.
- This matches LiveView lifecycle docs: `mount/3` runs for the initial static render and again after the client connects, so side effects and subscriptions belong in the connected branch.
- `handle_info({:run_stream_event, ...})` applies the event to the current `Status` for immediate display.
- `handle_info({:journal_committed, ...})` refreshes from the scheduler snapshot, making replay and reconnect authoritative.

The UI naming should change to match the glossary:

- Rename the detail panel test id/copy from `latest-event` / "Latest event" to `latest-activity` / "Latest activity". The content is an activity entry, not necessarily a journal event.
- Keep "Recent events" only for journal/log event summaries, or rename it if it is really displaying workflow log lines. Today that panel uses `status.logs`, not the journal event list.
- Keep "Raw activity" as a debug disclosure for normalized activity entries. Do not display raw Codex JSONL in the default run page.

LiveView streams are optional for the current compact UI. The page renders a bounded latest activity line and a small recent activity list. If implementation adds a continuously growing activity or journal feed, use `stream/4` and `stream_insert/4` with stable DOM ids and `limit`, because LiveView streams are designed for large client-side collections without keeping every item in socket state. The initial stream collection should still be loaded from the journal-backed snapshot, because stream limits are not enforced on the first static render.

## API impact

`GET /api/runs/:id` should remain the snapshot endpoint:

- It returns `RunProjection.to_map/1`.
- It can include running agents and activity entries if `agent_activity` has been persisted and folded.
- It must not expose raw Codex JSONL.
- Its `eventCount` means durable journal event count, not number of progress messages observed by LiveView.

`GET /api/runs/:id/events` should remain the durable journal inspection endpoint:

- It returns `RunEventsProjection.to_map/1`.
- Its `"journalEvents"` list contains `%{seq, type, address?}` summaries.
- Its legacy `"events"` list remains for compatibility and has the same safe
  summaries.
- If `agent_activity` is persisted, it may appear as a journal event type in this list.
- It should not become a server-sent stream or raw-payload dump.

Do not reuse `"events"` to mean progress messages.

## MCP impact

`workflow_status` is already a thin call to `GET /api/runs/:id`, then `ProjectionEnvelope.conform/1`. Keep it a polling snapshot. It should be documented as "current scheduler projection", not "streaming status".

`workflow_inspect` calls `GET /api/runs/:id/events`. `ProjectionEnvelope.conform/1` drops the ambiguous legacy `"events"` field and keeps the public projection fields, ordered `rawRefs`, and additive `"journalEvents"` summaries.

Do not expose raw Codex JSONL through `workflow_inspect` by default. If a raw provider diagnostic is needed, make it a separate opt-in diagnostic surface with redaction rules.

`workflow_open_ui` should remain the bridge to realtime. The MCP command returns the URL; LiveView owns the live stream.

## Projection impact

`Workflow.Status` should stay a pure fold over journal events. That keeps resume, API polling, MCP status, and reconnect behavior deterministic. Transient progress messages can update a connected LiveView immediately, but any state that matters after reconnect must be folded from the journal.

`RunProjection` should keep exposing:

- `"agents"` with per-agent `"activity"` lists.
- `"toolActivity"` with raw refs to journal entries.
- `"rawRefs"` as journal refs.
- `"eventCount"` as durable journal event count.

`RunEventsProjection` should be named and documented as journal-event projection. Its output is not the realtime stream and not the Codex event stream.

## Tests to add or update during implementation

- LiveView: rename "Latest event" assertions to "Latest activity" and keep the existing in-flight activity-before-commit behavior.
- LiveView: prove reconnect reconstructs the activity list from the journal after a streamed activity has been persisted.
- LiveView: if a growing activity feed is added, assert bounded rendering and stable DOM ids for stream items.
- API: assert `/api/runs/:id` can expose a running agent with folded `agent_activity`, and that `eventCount` equals `length(Journal.fold(id))`.
- API: assert `/api/runs/:id/events` includes only safe journal summaries, including `agent_activity` if persisted, with no raw Codex JSONL payload.
- MCP: assert `workflow_status` remains a snapshot and does not include scheduler-only fields or raw events.
- MCP: pin `workflow_inspect` with no legacy `"events"` field and with additive `"journalEvents"` summaries.
- Projection: keep `Status.fold/2` tests for idempotent activity replay by `{address, iteration, attempt, activity_index}`.
- Docs/proof: update operations/runtime docs so "events" means durable journal summaries, while "open UI" is the realtime experience.

## Architecture notes

Phoenix docs frame LiveView as the web interface into an Elixir application, not the application boundary itself. Keep `Workflow.Scheduler` as the context boundary for web/API reads. Controllers, LiveView, and MCP should call the scheduler context and should not read `Workflow.Journal` or SQLite directly.

The only exception is the internal subscriber path where `Workflow.Run.ActivityPersistenceSubscriber` listens to `Workflow.Run.Stream` and persists activity through `Workflow.Journal`. That is runtime infrastructure, not a web/API read path.

## Cleared fog

- The realtime UX belongs in LiveView, opened through `workflow_open_ui`.
- The API and MCP tools remain durable snapshot/polling contracts.
- `workflow_inspect` exposes public journal summaries under the non-ambiguous `journalEvents` name.
- LiveView streams are not required merely because Codex streams. They become the right implementation tool only for an unbounded or large UI collection.
