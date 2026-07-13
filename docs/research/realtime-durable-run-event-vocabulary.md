# Realtime And Durable Run Event Vocabulary

Wayfinder asset for [Define realtime versus durable run event vocabulary](https://github.com/pproenca/codex-loops/issues/86).

**Status: resolved.** The shipped design is durable-first; older proposals for a
separate ephemeral progress feed are superseded.

## Canonical Terms

| Term | Meaning |
| --- | --- |
| Journal event | A durable run fact stored by `Workflow.Journal`. |
| Commit notification | A transient `{:journal_committed, run_id, seq}` PubSub signal sent only after a successful append. It asks live readers to refold and carries no independent authority. |
| Activity entry | A normalized provider item such as lifecycle, tool, reasoning, warning, or assistant output. |
| Agent start marker | The durable `agent_started` event written before a provider effect. |
| Agent settlement | `agent_committed`, `agent_attempt_rejected`, or `agent_failed`. |
| Codex event | A raw JSON object decoded from `codex exec --json` before normalization. |
| Run projection | A read model folded from journal events. |
| Raw ref | A client-safe pointer to a journal event, not its raw payload. |

Avoid bare “event” when the noun matters: say Codex event, journal event, or
activity entry. Do not call a PubSub delivery durable, and do not call an activity
entry a settlement.

## Event Classes

- Run lifecycle, workflow structure, control decisions, paid-attempt starts and
  settlements are durable journal events.
- `agent_activity` is also a durable journal event, but its domain role is telemetry.
  It does not decide validation, retry, resume, ledger accounting, or terminal state.
- PubSub carries only post-commit notifications. `Workflow.Run.Stream` is the small
  subscription helper for those notifications; it does not carry an alternative run
  projection.
- LiveView, API, MCP status, MCP inspection, and resume all derive state from the
  journal.

## Result

The vocabulary used by current code and docs is pinned in [`CONTEXT.md`](../../CONTEXT.md).
