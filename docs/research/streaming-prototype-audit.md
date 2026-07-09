# Streaming Prototype Audit

Issue: #88, part of #82

## Question

What does commit `8eecbda` prove, and what should be kept, revised, split, or discarded now that the intended realtime architecture is mapped?

Commit audited: `8eecbda Stream provider activity through journal subscribers`

## Sources

- Commit diff for `8eecbda`
- Current code introduced or changed by that commit:
  - `.codex/workflows/staff_level_elixir_adversarial_scan.exs`
  - `config/runtime.exs`
  - `docs/operations.md`
  - `docs/runtime.md`
  - `lib/workflow/application.ex`
  - `lib/workflow/containment.ex`
  - `lib/workflow/journal.ex`
  - `lib/workflow/provider/codex.ex`
  - `lib/workflow/run/stream.ex`
  - `lib/workflow/run/writer.ex`
  - `lib/workflow/status.ex`
  - `lib/workflow/web/run_live.ex`
  - `test/workflow/codex_provider_test.exs`
  - `test/workflow/run_test.exs`
- Prior Wayfinder notes:
  - `docs/research/codex-exec-jsonl-output-schema-contract.md`
  - `docs/research/provider-containment-streaming-boundaries.md`
  - `docs/research/run-writer-journal-realtime-subscriber-responsibilities.md`
  - `docs/research/realtime-durable-run-event-vocabulary.md`
  - `docs/research/liveview-api-mcp-projection-impact.md`

## Verdict

The prototype is valuable evidence, not a production-ready architecture.

It proves that Codex Loops can publish provider activity before agent settlement, persist that activity through a journal subscriber, and show it immediately in LiveView while keeping final agent settlement in the writer. That is exactly the right direction.

It should not be accepted as-is. The production implementation should keep the core shape but revise the provider fold, progress-message projection, subscriber supervision, provider-call coverage, vocabulary, and UI/API/MCP contract.

## What The Prototype Proves

1. `Workflow.Run.Stream` is a useful small boundary for realtime run progress.
   It centralizes PubSub topic naming and keeps callers from scattering direct `Phoenix.PubSub.broadcast/3` calls for provider progress.

2. Activity can be persisted by a subscriber.
   `Workflow.Run.ActivityPersistenceSubscriber` subscribes to the global stream
   and persists `agent_activity` through `Workflow.Journal` idempotently by
   `{address, iteration, attempt, activity_index}`. This demonstrates the
   desired shape: journal persistence is outside the provider's port-draining
   callback.

3. The writer can remain the settlement authority.
   `Workflow.Run.Writer` still commits `agent_committed`, `agent_attempt_rejected`, and `agent_failed` in its own path. Activity is merged into final settlement, but activity does not decide retry, ledger, idempotency, or terminal state.

4. LiveView can show in-flight activity.
   `Workflow.Web.RunLive` receives `{:run_stream_event, ...}` and updates before the agent commits, while `{:journal_committed, ...}` remains a refresh signal.

5. Activity identity works.
   The ETS-backed `activity_tracker/4` assigns an `activity_index`, and `Status` merges streamed and settled activity by that index. The existing tests prove duplicate activity replay can be idempotent while repeated entries with different indexes remain distinct.

6. Containment can observe complete stdout lines without knowing Codex JSON.
   `Workflow.Containment` offers a generic `:on_line` callback and stays mostly protocol-neutral.

## Keep

- Keep `Workflow.Run.Stream` as the internal progress-message bus.
- Keep provider-normalized activity entries as the UI/projection vocabulary.
- Keep journal subscriber persistence for `agent_activity`, because reconnects need durable activity replay.
- Keep final settlement events in the writer critical path.
- Keep `activity_index` as the attempt-scoped ordering and dedupe key.
- Keep LiveView subscription under `connected?(socket)`.
- Keep `/api/runs/:id` and MCP status as snapshot surfaces.
- Keep `/api/runs/:id/events` as durable journal summaries, not raw Codex JSONL.

## Revise

### 1. Make the Codex provider one streaming fold

Current prototype:

- `Workflow.Provider.Codex` observes each JSONL line through `line_observer/1`.
- After the OS process exits, it splits and decodes the entire stdout again in `parse_turn/2`.

This proves the callback path, but production should fold each Codex event once as it arrives. That fold should produce:

- activity entries for realtime progress,
- latest final `agent_message`,
- usage from `turn.completed`,
- failure on `turn.failed` or stream-level `error`,
- provider result when the process exits cleanly.

Practical route: introduce a small Codex stream accumulator in `Workflow.Provider.Codex` and have containment feed complete lines into it. The buffered `run_agent/4` return can be built from the same accumulator that emitted realtime activity.

### 2. Do not give transient progress messages journal semantics in LiveView

Current prototype:

- `RunLive.assign_stream_event/3` calls `Status.apply_event/2`.
- `Status.apply_event/2` appends raw refs, appends tool activity, updates refines, and increments `event_count`.

That is correct for journal events, but a `run_stream_event` is only a progress message until `Workflow.Journal` persists it. In a connected LiveView, this can briefly create raw refs with nil sequence numbers and an event count that includes unpersisted progress.

Production should separate these paths:

- keep `Status.apply_event/2` for journal events only,
- add a progress-specific projection helper that applies an activity entry to the visible agent without appending journal raw refs or incrementing durable `event_count`,
- let the later `journal_committed` refresh replace the transient projection with the durable fold.

### 3. Stream every provider call that should be user-visible

Current prototype:

- Top-level agent attempts use `activity_tracker/4` and stream activity.
- Several refine/gate/reviewer role paths use `local_activity_tracker/0`, so Codex output from those turns is collected and committed only after settlement.

If the product promise is that the entire Codex CLI output is realtime, then every Codex-backed provider call needs a stream-capable tracker, with correct role/address/attempt identity. If some internal roles should remain quiet, the product contract should say so explicitly.

### 4. Subscriber supervision is explicit

Production splits activity persistence into
`Workflow.Run.ActivityPersistenceSubscriber`, a supervised subscriber with
tested restart/resubscribe behavior. `Workflow.Journal` stays the SQLite owner
and final serializer rather than owning PubSub subscription lifecycle.

### 5. Tighten the activity taxonomy

Current prototype streams:

- lifecycle entries for `thread.started` and `turn.started`,
- reasoning and tool entries,
- assistant output entries from completed `agent_message`.

That is useful, but production should pin which Codex events become activity entries and how much content they carry. In the current Codex CLI contract, assistant token deltas are not exposed through `codex exec --json`; production should not imply token-by-token streaming by looking for undocumented `delta` fields.

Assistant output as a final activity entry is reasonable, but it duplicates the final result. If kept, it should be bounded, labelled as completed assistant output, and tested for schema-backed turns so the UI does not accidentally expose giant JSON or sensitive raw protocol content.

### 6. MCP inspect uses journalEvents

`workflow_inspect` calls `/api/runs/:id/events`. `ProjectionEnvelope.conform/1`
strips the legacy `"events"` field and returns the public projection,
`journalEvents` summaries, and ordered `rawRefs`.

Do not expose raw Codex JSONL through MCP inspect by default.

### 7. Rename UI event copy to activity copy

The prototype LiveView copy said "Latest event" for content that was usually an activity entry. Production copy should say "Latest activity" and reserve "journal event" language for durable sequence/type/address summaries.

## Split Out

These commit changes are useful or harmless, but not part of the streaming architecture decision:

- `config/runtime.exs` changing the release host default to `127.0.0.1`.
- Operations/runtime docs about loopback binding and Sobelow gate policy.
- `Makefile` making `browser-e2e` depend on setup.

Keep or reject those in separate operational tickets. They should not be bundled with production streaming.

## Discard From Production Streaming

`.codex/workflows/staff_level_elixir_adversarial_scan.exs` should not be treated as production architecture. It is a dogfood workflow with local absolute paths, and schema-backed prompts must avoid generic schema-shape boilerplate because `--output-schema` owns structural output shape.

It can be replaced later with a portable example workflow that keeps semantic instructions in the prompt and leaves JSON shape to the schema flag.

## Production Implementation Route

1. Provider fold: make `Workflow.Provider.Codex` parse JSONL once, stream activity as lines arrive, and settle from the same accumulator.
2. Activity bus: keep `Workflow.Run.Stream`, but clarify it emits progress messages carrying normalized activity, not public journal events.
3. Writer coverage: replace `local_activity_tracker/0` on user-visible Codex provider paths with a stream-aware tracker, or explicitly mark those paths as non-realtime.
4. Subscriber durability: keep activity persistence in the supervised subscriber with tested restart/resubscribe behavior.
5. Projection split: keep `Status.apply_event/2` journal-only and add a progress projection helper for LiveView.
6. UI vocabulary: rename latest event to latest activity and keep activity lists bounded unless a real LiveView stream feed is added.
7. API/MCP contract: pin `/events` as journal summaries and MCP inspect's `journalEvents` field.
8. Prompt/schema cleanup: remove schema-shape boilerplate from generated/authored schema-backed workflow prompts while preserving semantic instructions.

## Test And Proof Gates

- Codex provider unit/integration test: one JSONL line path produces both realtime activity and the final result without decoding stdout twice.
- Containment test: line observation remains protocol-neutral and does not block stdout draining with journal writes.
- Writer test: every intended Codex provider call path emits activity with stable `{run_id, address, iteration, attempt, activity_index}`.
- Activity persistence subscriber test: duplicate activity messages de-dupe; repeated entries with different indexes persist; subscriber restart/resubscribe behavior is pinned.
- Status/projection test: progress messages do not increment durable `eventCount` or create raw refs until journal persistence.
- LiveView test: connected view shows activity before settlement, then reconnect reconstructs the same activity from the journal.
- API test: `/api/runs/:id/events` exposes only safe journal summaries, including persisted `agent_activity` when present.
- MCP test: `workflow_status` remains snapshot-only; `workflow_inspect` follows the `journalEvents` plus rawRefs contract.
- Proof docs: update `make proof`, `make proof-mcp`, and manual smoke docs to say the UI is realtime and API/MCP are polling snapshots.

## Cleared Fog

- The prototype should be kept as a spike and mined for code, not shipped unchanged.
- The central architecture is valid: progress message bus first, journal subscriber second, writer settlement remains authoritative.
- The production work is mostly boundary tightening, not a wholesale rewrite.
- The remaining implementation decisions are now concrete enough for agent-ready tickets.
