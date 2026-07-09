# Realtime And Durable Run Event Vocabulary

Wayfinder asset for [Define realtime versus durable run event vocabulary](https://github.com/pproenca/codex-loops/issues/86).

## Question

What domain vocabulary should Codex Loops use for realtime provider output versus durable journal facts?

The user delegated the naming choice: pick the most intuitive vocabulary aligned with Elixir. The chosen split follows Elixir/Phoenix intuition: durable facts are journal data; realtime output is process/PubSub messaging; UI-facing provider progress is normalized activity.

## Sources

- User direction on #86: choose the most intuitive Elixir-aligned vocabulary.
- `CONTEXT.md`
- Prior Wayfinder notes:
  - `docs/research/codex-exec-jsonl-output-schema-contract.md`
  - `docs/research/provider-containment-streaming-boundaries.md`
  - `docs/research/run-writer-journal-realtime-subscriber-responsibilities.md`
- Current code:
  - `lib/workflow/event.ex`
  - `lib/workflow/status.ex`
  - `lib/workflow/run/stream.ex`
  - `lib/workflow/provider/codex.ex`
  - `lib/workflow/scheduler/run_projection.ex`
  - `lib/workflow/scheduler/run_events_projection.ex`
  - `lib/workflow/web/run_live.ex`

## Decision

Use these canonical terms:

| Term | Meaning | Current code mapping |
| --- | --- | --- |
| Journal event | Durable writer-authoritative fact about a run. | `%Workflow.Event{}` stored by `Workflow.Journal`; examples: `:run_started`, `:agent_committed`, `:loop_decision`. |
| Progress message | Transient PubSub message about work happening now. | `{:run_stream_event, run_id, event}` on `Workflow.Run.Stream`; `{:journal_committed, ...}` is also a delivery signal, not an authority by itself. |
| Activity entry | Normalized provider progress item for an agent attempt. | Maps like `%{kind: "tool", label: ..., summary: ..., status: ...}` produced by `Workflow.Provider.Codex`. |
| Agent settlement | Authoritative paid-attempt outcome. | `:agent_committed`, `:agent_attempt_rejected`, `:agent_failed`. |
| Codex event | Raw JSON object from `codex exec --json`. | Values decoded from JSONL in `Workflow.Provider.Codex`; examples: `thread.started`, `item.completed`, `turn.completed`. |
| Run projection | Read model for API/UI. | `Workflow.Status`, `Workflow.Scheduler.RunProjection`, `Workflow.Scheduler.RunEventsProjection`. |
| Raw ref | Client-safe pointer to a journal event. | `%{run_id, seq, type, address}` style references in `Status.raw_refs` and API maps. |

The most important naming rule: avoid bare "event" unless the surrounding noun disambiguates it. Say `Codex event`, `journal event`, or `progress message`.

## Why This Is The Elixir-Aligned Split

The BEAM already treats realtime delivery as messages between processes. Phoenix PubSub is a message fan-out mechanism. So the realtime side should use message vocabulary: progress message, stream message, subscriber.

The run journal stores facts that already happened. Event-sourced systems often call these events, and the existing code already has `Workflow.Event` and `Workflow.Journal`. So the durable side should keep event vocabulary, but always with the qualifier `journal`.

Provider protocol data should stay at the boundary. A raw `codex exec --json` line is a Codex event until `Workflow.Provider.Codex` normalizes it. After that it becomes an activity entry or contributes to an agent settlement.

## Vocabulary Rules

1. Use `journal event` for durable run history.
2. Use `progress message` for realtime PubSub delivery.
3. Use `activity entry` for UI/projection-ready provider progress.
4. Use `agent settlement` for `agent_committed`, `agent_attempt_rejected`, and `agent_failed`.
5. Use `Codex event` only for raw decoded JSONL from the Codex CLI.
6. Use `run projection` for folded read models, not `run state`.
7. Use `raw ref` only for a pointer to a journal event, not for raw event payloads.
8. Use `ledger` only for budget/usage accounting, not as a synonym for the journal.

## Event And Message Classes

### Durable Journal Events

These affect replay, resume, terminal state, ledger accounting, or workflow-visible history:

- Run lifecycle: `run_started`, `run_completed`, `run_failed`.
- Workflow structure: `phase_entered`, `log_emitted`.
- Agent settlements: `agent_committed`, `agent_attempt_rejected`, `agent_failed`.
- Control flow and reductions: loop, fanout, accumulate, verify, judge, and refine journal events.

### Persisted Telemetry Journal Events

`agent_activity` may be stored in the journal to support reconnects and historical inspection, but its domain meaning is still telemetry. It must not decide replay, resume, retry, terminal state, or ledger accounting.

This is intentionally a hybrid: physically journaled, semantically progress. Call it `agent_activity` or persisted activity, not an agent settlement.

### Realtime Progress Messages

Progress messages are PubSub deliveries used by LiveView and subscribers:

- Provider activity while an agent turn is still running.
- Post-commit notifications like `journal_committed`, which tell readers to refresh or apply a projection.

A progress message can carry a journal event-shaped struct for convenience, but the delivery itself is not a journal event until `Workflow.Journal` stores it.

### Codex Events

Codex events are raw provider protocol objects:

- `thread.started`
- `turn.started`
- `item.started`
- `item.updated`
- `item.completed`
- `turn.completed`
- `turn.failed`
- `error`

Codex Loops should not expose these as the primary app vocabulary. The provider should translate them into activity entries, usage, failures, and agent settlements.

## UI Vocabulary

For visible copy and API fields:

- Prefer `Activity` for normalized provider progress shown to users.
- Prefer `Latest activity` over `Latest event` when the value comes from an activity entry.
- Prefer `Recent journal events` only when listing actual journal sequence/type/address rows.
- Keep `Raw activity` for a debug/details area that shows normalized activity entries.
- Use `Raw refs` only for stable journal references in API/debug output.

## Implementation Implications

The current code can migrate incrementally:

- `Workflow.Event` can remain the implementation module for journal events; the vocabulary fix does not require a module rename.
- `Workflow.Run.Stream` should describe itself as a progress message bus, not a generic event bus.
- `agent_activity` can remain a journal event type if Codex Loops wants persisted telemetry, but docs and projections should call it activity/progress, not settlement.
- `Workflow.Provider.Codex` should use Codex event internally and activity entry externally.
- `RunEventsProjection` should be clear whether it lists journal events or UI activity. Today it lists journal events.
- LiveView copy should prefer activity wording for provider progress and event wording only for journal history.

## Wayfinder Result

The vocabulary is settled: Codex events come from the CLI, activity entries are normalized provider progress, progress messages deliver realtime updates, journal events are durable run facts, agent settlements are the authoritative paid-turn outcomes, run projections are folded read models, and raw refs are pointers to journal events.
