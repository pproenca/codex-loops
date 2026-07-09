# Run Writer, Journal, And Realtime Subscriber Responsibilities

Wayfinder asset for [Map run writer, journal, and realtime subscriber responsibilities](https://github.com/pproenca/codex-loops/issues/85).

## Question

What responsibilities must stay in the run writer's critical path, and what realtime activity can move to subscriber-style delivery without weakening durability, ordering, idempotency, or resume semantics?

This ticket maps the boundary only. It does not implement code changes.

## Sources

- Official Elixir `Task.Supervisor` docs: `https://hexdocs.pm/elixir/Task.Supervisor.html`
- Official Elixir process anti-patterns: `https://hexdocs.pm/elixir/process-anti-patterns.html`
- Official Phoenix PubSub docs: `https://hexdocs.pm/phoenix_pubsub/Phoenix.PubSub.html`
- Prior Wayfinder notes:
  - `docs/research/codex-exec-jsonl-output-schema-contract.md`
  - `docs/research/provider-containment-streaming-boundaries.md`
- Current code:
  - `lib/workflow/application.ex`
  - `lib/workflow/run/writer.ex`
  - `lib/workflow/journal.ex`
  - `lib/workflow/run/stream.ex`
  - `lib/workflow/event.ex`
  - `lib/workflow/status.ex`
  - `lib/workflow/idempotency.ex`
  - `lib/workflow/web/run_live.ex`
  - `test/workflow/run_test.exs`
  - `test/workflow/status_projection_test.exs`
  - `test/workflow/web/run_live_test.exs`

## Decision

The run writer must remain the single authoritative execution and settlement process for a run. It owns the per-run write lease, walks the workflow tree, decides control flow, invokes providers, validates schema-backed output, handles retry/fail-closed semantics, and synchronously appends every event required to replay, resume, or settle the run.

Realtime provider activity may move to subscriber-style delivery because it is progress telemetry, not the paid-turn settlement. `agent_activity` can be broadcast while the provider is still running and optionally persisted by a journal subscriber, but no execution decision may depend on whether that subscriber received, inserted, or ordered the telemetry before the final settlement event.

The durable source of truth for paid effects remains the writer-committed terminal attempt event: `agent_committed`, `agent_attempt_rejected`, or `agent_failed`. If a turn streamed activity but never journals one of those events, resume must treat it as unsettled according to the existing idempotency rules.

## Non-Elixir Explanation

Think of the writer as the courtroom clerk for the workflow: it records the facts that determine what legally happened. A realtime stream is more like a live commentator: useful, immediate, and visible, but not the authority that decides whether the run completed, retried, or failed.

In Elixir terms, `Phoenix.PubSub` is a message fan-out mechanism: processes subscribe to topics, and broadcasts deliver messages to those subscribers. That is perfect for live UI progress. It is not, by itself, a durable log or a consensus point. If nobody is subscribed, or a subscriber crashes, the workflow should not silently change its execution semantics.

## Must Stay In The Writer Critical Path

These are authoritative facts. The writer may delegate storage to `Workflow.Journal`, but it must synchronously commit them before making the next dependent execution decision:

| Event family | Why it is authoritative |
| --- | --- |
| `run_started`, `run_completed`, `run_failed` | Establishes run lifecycle, terminal state, budget target, and script path for resume/read APIs. |
| `phase_entered`, `log_emitted` | Workflow-authored visible structure that the read model reconstructs. |
| `agent_committed` | The paid provider turn succeeded; result and usage become replayable and must not be re-run on resume. |
| `agent_attempt_rejected` | A paid attempt failed local validation; retry resumes at the next attempt instead of double-spending. |
| `agent_failed` | The paid turn reached a terminal expected failure. |
| `parallel_*`, `pipeline_*`, `fanout_*`, `fan_out_*` | Structural brackets and fan-out width decisions; resume must not recompute widths from changed ledger state. |
| `iteration_started`, `loop_decision`, `loop_completed`, `loop_exhausted` | Loop control-flow history; resume must replay historical decisions. |
| `accumulate` | Declared reductions; folds rebuild accumulators without double-counting. |
| `verify_*`, `judge_*` | Panel shape and folded outcomes; branch votes/scores remain ordinary agent settlements. |
| `refine_*`, including role/gate failures | Refine role descriptors, rounds, decisions, terminal/non-converged outcomes, and failure summaries used by read models and later bindings. |

The writer can still use supervised tasks for concurrent branches and panels, but those tasks should build events off-thread and return them to the writer. The writer remains the only process that commits authoritative run facts in run order.

## Can Move To Subscriber-Style Delivery

`agent_activity` is the main candidate. It represents provider progress such as lifecycle notices, tool calls, reasoning summaries, assistant output, warnings, or other normalized Codex JSONL items observed before a turn settles.

`agent_activity` should be treated as realtime telemetry with a stable attempt-scoped identity:

```text
run_id + address + iteration + attempt + activity_index
```

That identity lets subscribers de-duplicate repeated activity and lets `Workflow.Status` merge a later settled event's activity list with activity that arrived earlier. UI ordering inside a turn should use `activity_index`, not journal sequence, because subscriber persistence is allowed to race with authoritative writer commits.

If Codex Loops wants mid-run reconnects to show streamed activity, the journal may persist `agent_activity` as a subscriber. That makes it persisted telemetry, not an execution fact. The final settlement event should still contain the turn's finalized activity list so a missed subscriber message does not erase the activity from the completed run.

Raw Codex JSONL should not become a writer-critical durable event by default. It can be diagnostic telemetry or an optional future artifact, but the provider should normalize it at the boundary before it reaches the run model.

## Journal And PubSub Responsibilities

`Workflow.Run.Stream` should own topic naming and the small public API for realtime run events. It should not know provider protocol details or workflow control flow.

`Workflow.Journal` should own the SQLite connection and serialized append operations. For authoritative events, it is called synchronously by the writer. For realtime activity, it may subscribe to `Workflow.Run.Stream` and append telemetry at the next available journal sequence.

`Workflow.Status` should stay a pure fold. It can fold `agent_activity`, but the fold must not make `agent_activity` affect idempotency, retry, budget ledger, or terminal run state.

`Workflow.Web.RunLive` should treat `journal_committed` as a refresh signal and realtime stream events as temporary local projection updates. On mount or refresh, it should reconstruct from scheduler/journal state rather than trusting socket memory as authoritative.

## Ordering Rules

Authoritative event order is the writer's execution order.

Realtime activity order is scoped to the provider attempt and should be represented by `activity_index`. Once journal persistence is subscriber-style, SQLite `seq` is not a reliable proxy for "the provider emitted this before that settlement." It is only the order in which the journal persisted messages it received.

If the product later needs a single merged timeline across durable facts and realtime telemetry, that should be a separate projection rule, not an implicit guarantee of journal insertion order.

## Failure Modes That Need Explicit Design

- Authoritative journal append fails: the writer must not continue as if the event committed. This is a durability failure. The run should fail/crash loudly; if possible, `run_failed` records the crash, but if the journal itself is unavailable there may be no durable terminal fact.
- Provider succeeds but writer crashes before `agent_committed`: there is no durable settlement. Resume cannot infer success from realtime activity. The implementation should keep the window small and rely on provider idempotency keys where available, but activity telemetry must not be treated as proof of success.
- Activity subscriber misses a message: live subscribers may have seen it, but the journal may not. Final settled activity on `agent_committed`/`agent_attempt_rejected`/`agent_failed` should preserve the completed turn's activity where possible.
- Activity subscriber lags behind the writer: UI should merge by attempt identity and `activity_index`, not by journal `seq`.
- Activity subscriber crashes: it should be supervised and restarted, but the writer/provider should not be linked to that failure. The official `Task.Supervisor` guidance is the same principle for side-effect work: isolate failures from the caller when the caller is not awaiting that work.
- PubSub broadcast fails or has no subscribers: the workflow execution must not change. Broadcasts are delivery signals, not durable facts.
- Activity volume is large: do not broadcast giant raw payloads by default. BEAM process messages copy data between processes, so realtime messages should carry the normalized minimum needed for the UI/projection.
- Duplicate activity delivery: de-duplicate by the stable attempt-scoped identity above. The current prototype already tests idempotency by `activity_index`.
- Duplicate subscriptions: Phoenix PubSub allows duplicate subscriptions for the same PID/topic pair, which deliver duplicate events. Long-lived subscribers should subscribe once per topic.

## Current Prototype Assessment

The prototype has useful direction:

- `Workflow.Run.Stream` creates a small PubSub wrapper for realtime run events.
- `Workflow.Journal` subscribes to the stream and persists `agent_activity` outside the provider call path.
- `Workflow.Run.Writer` keeps final provider settlement in its own commit path.
- `Workflow.Status` merges streamed and settled activity by activity index.
- `Workflow.Web.RunLive` can apply stream events immediately and re-fold from committed state on journal signals/refresh.

But it should still be treated as a spike until later tickets settle vocabulary and UI/API semantics:

- `agent_activity` is currently both a PubSub message and a persisted journal event. The architecture needs to name whether it is durable telemetry, ephemeral progress, or both.
- The writer's `activity_sink` still does synchronous ETS insertion and PubSub emission in the provider callback. That is acceptable only if the callback remains a small handoff and never performs SQLite or slow network work.
- Journal sequence now includes subscriber-persisted activity. That is fine for a foldable read model, but not as a guarantee of provider emission order relative to settlement events.
- `Workflow.Journal` combines authoritative append APIs and subscriber handling in one process. That is reasonable because it owns SQLite serialization, but callers should continue to interact through named functions and `Workflow.Run.Stream`, not scattered process messages.

## Wayfinder Result

The writer must keep all authoritative run facts in its synchronous path. Realtime `agent_activity` can be delivered and optionally persisted by subscribers as non-authoritative telemetry, keyed by run/agent/attempt/activity index. The next tickets can now focus on the exact realtime-versus-durable event vocabulary and the LiveView/API projection contract.
