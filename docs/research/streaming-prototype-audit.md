# Streaming Prototype Audit

Issue #88, part of #82. Commit audited: `8eecbda`.

**Status: superseded.** The audited prototype established that Codex activity could
be observed before settlement, but its subscriber-first persistence and socket-local
projection were rejected for production.

## What Was Retained

- Containment observes complete stdout lines without understanding Codex JSON.
- The Codex provider decodes each JSONL line once through an immutable accumulator.
- Activity entries have an attempt-local `activity_index`.
- Attempt settlement remains owned by the run writer.
- API and MCP status remain snapshots; inspection exposes safe journal summaries,
  not raw Codex JSONL.
- LiveView is the realtime watching surface.

## What Replaced The Prototype

- The writer synchronously appends `agent_started` before the provider effect.
- The writer synchronously appends every normalized `agent_activity` before sending
  a post-commit PubSub notification.
- LiveView refolds the journal on notification and keeps no separate progress state.
- Reconnect, API, MCP, and LiveView therefore agree without subscriber lag, missed
  message recovery, or value-based activity deduplication.
- An unsettled start is never redelivered; resume records `outcome_unknown`.

The resolved design is documented in [`docs/runtime.md`](../runtime.md). This file
is retained only to preserve the research trail for the audited commit.
