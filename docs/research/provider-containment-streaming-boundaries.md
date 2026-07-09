# Provider And Containment Streaming Boundaries

Wayfinder asset for [Map provider and containment streaming boundaries](https://github.com/pproenca/codex-loops/issues/84).

## Question

Where should realtime process-output streaming be owned between `Workflow.Provider.Codex` and `Workflow.Containment`?

This ticket maps the boundary only. It does not implement the streaming architecture.

## Sources

- Official Elixir `Port` docs: `https://hexdocs.pm/elixir/Port.html`
- Official Elixir `Stream` docs: `https://hexdocs.pm/elixir/Stream.html`
- Codex CLI contract from `docs/research/codex-exec-jsonl-output-schema-contract.md`
- Current code:
  - `lib/workflow/containment.ex`
  - `lib/workflow/provider/codex.ex`
  - `lib/workflow/run/writer.ex`
  - `lib/workflow/run/stream.ex`
  - `lib/workflow/journal.ex`
  - `lib/workflow/event.ex`
  - `test/workflow/containment_test.exs`
  - `test/workflow/codex_provider_test.exs`
  - `test/workflow/run_test.exs`

## Decision

`Workflow.Containment` should own the OS-process transport boundary. It starts one external process, delivers stdin, drains stdout and stderr, tracks exit status and timeout, splits raw stdout into complete lines for observation, and returns an OS-level success or failure. It should remain wire-format ignorant: no Codex event names, no JSON decoding, no schema handling, no provider activity vocabulary, and no final assistant-message selection.

`Workflow.Provider.Codex` should own the Codex protocol boundary. It builds `codex exec --json`, writes and passes the `--output-schema` file for schema-backed turns, decodes stdout JSONL, maps Codex thread events into provider activity, detects `turn.failed` and stream-level `error`, folds the latest completed `agent_message` into the final result, extracts usage from `turn.completed`, and returns the existing provider contract to the writer.

The realtime path should be stream-first in the provider, not journal-first in containment. Containment may expose a generic `on_stdout_line`/`on_stdout_chunk` callback because line observation is a transport concern, but that callback must stay lightweight and protocol-neutral. The provider consumes those lines and emits normalized activity into a realtime bus. Durable journal persistence should be a subscriber to that bus, not a synchronous write inside the port-draining loop.

## Non-Elixir Explanation

Elixir `Stream` is not the same thing as product realtime streaming.

`Stream` means "a lazy enumerable recipe." A stream does no work until something consumes it with `Enum` or `Stream.run`. It is useful for large files, lazy transforms, and early exit. It is not automatically a UI feed and it is not automatically concurrent.

Realtime Codex streaming means "the OS process sends stdout messages while it is still running, and the app publishes useful events as those messages arrive." In Elixir, that starts with a `Port`: a port is how an Erlang/Elixir process starts and communicates with an external OS process by receiving messages. A `Stream.resource/3` could be an implementation technique for wrapping a port as an enumerable, but the architecture should not confuse "lazy enumeration" with "realtime PubSub output."

## Ownership Matrix

| Concern | Owner | Notes |
| --- | --- | --- |
| External process lifecycle | `Workflow.Containment` | Open the port, feed stdin, handle close/exit, timeout, and stderr capture. |
| Command construction | `Workflow.Provider.Codex` | Provider knows `codex exec --json`, `--output-schema`, provider-specific env, and CLI capability assumptions. |
| Stdin bytes | Provider prepares, containment transports | Provider decides prompt bytes. Containment only writes/delivers them. |
| Stdout chunk draining | `Workflow.Containment` | Drain port messages promptly so the child process is not blocked by full pipes. |
| Generic line splitting | `Workflow.Containment` | Newline framing is transport-level enough for a JSONL process. The emitted value is still just a binary line. |
| JSONL decoding | `Workflow.Provider.Codex` | JSON is Codex protocol, not containment. Decode each line as it arrives. |
| Codex event semantics | `Workflow.Provider.Codex` | Thread lifecycle, tool calls, reasoning, final assistant message, usage, and failure events belong here. |
| Realtime normalized activity | Provider produces, realtime bus publishes | Provider maps raw Codex events to Codex Loops activity entries. The bus publishes before durable persistence. |
| Durable activity append | Activity persistence subscriber, not containment | `Workflow.Run.ActivityPersistenceSubscriber` can persist activity out of band through `Workflow.Journal`. It should not be in the port-draining critical path. |
| Final provider result | `Workflow.Provider.Codex` | Fold the same JSONL event stream into result, usage, activity, or provider failure. |
| Schema validation and retry | `Workflow.Run.Writer` | The CLI constrains shape with `--output-schema`, but local fail-closed validation remains the writer's gate. |

## Current Code Reading

`Workflow.Containment.run_turn/2` already mostly matches the transport role: it takes `{path, args}`, writes stdin to a temp file, opens a port, drains stdout, redirects stderr to a temp file, handles non-zero exits and timeout, and offers an `:on_line` observer. That observer is generic, but it is synchronous in the same receive loop that drains the port. If a future callback performs slow journal writes, network calls, or blocking PubSub work, it can delay stdout draining and create backpressure against the child process.

`Workflow.Provider.Codex.run_agent/4` already owns the Codex protocol: it resolves the Codex CLI command, adds `--output-schema`, calls containment, decodes JSONL, detects failures, picks the final `agent_message`, extracts usage, and maps activity. The prototype added `line_observer/1` so provider activity can be emitted while the process is running, but the final result is still parsed after process exit from the full accumulated stdout. The long-term provider shape should fold lines once as they arrive and use that same fold for both realtime activity and the final result.

`Workflow.Run.Writer` currently passes an `activity_sink` into every provider call. The sink records activity in an ETS table and emits `agent_activity` via `Workflow.Run.Stream`. That is the right direction for decoupling provider progress from final settlement, but it is still invoked synchronously by the provider callback. The callback must stay lightweight, and ticket #85 should decide whether the writer should keep owning this sink or whether a dedicated subscriber process owns journal persistence.

`Workflow.Run.ActivityPersistenceSubscriber` subscribes to `Workflow.Run.Stream`
and persists `agent_activity` out of band through `Workflow.Journal`. That keeps
the PubSub subscription out of containment and out of the writer's settlement
critical path while preserving SQLite serialization inside the journal owner.

## Backpressure And Failure Rules

Containment must prioritize draining the port. Slow downstream consumers should not prevent stdout from being read. Therefore, containment callbacks should be best-effort, fast handoffs, or message sends into supervised processes. They should not synchronously append to SQLite.

If containment sees timeout or non-zero exit, it reports an OS-level error. It should include useful stdout/stderr diagnostics but should not reinterpret them as Codex protocol failures.

If the provider decodes `turn.failed`, a stream-level `error`, malformed JSONL, or missing final output, it reports or raises a provider-level failure according to the existing provider contract. Earlier activity events do not make a failed turn successful.

## Architecture Implications For Later Tickets

- Keep containment protocol-neutral. Do not move Codex JSON, activity mapping, or schema behavior into `Workflow.Containment`.
- Make the Codex provider stream-first: one fold over incoming JSONL should produce realtime activity and the final provider result.
- Keep local schema validation in `Workflow.Run.Writer`; `--output-schema` removes prompt schema boilerplate but does not remove deterministic retry/fail-closed policy.
- Treat `Stream` as an optional implementation detail, not as the architectural source of realtime behavior.
- Revisit `Port.open({:spawn, shell_command(...)})` separately. The Elixir docs generally prefer `:spawn_executable` plus `args`, but the current shell wrapper is also doing stdin/stderr redirection. If this changes, keep the change inside containment.
- Defer durable/realtime event vocabulary, journal subscriber mechanics, and UI/API projection semantics to #85, #86, and #87.

## Wayfinder Result

The boundary is clear enough to unblock the next tickets: containment owns raw process I/O, provider owns Codex JSONL semantics and final folding, and journal persistence must subscribe to provider activity rather than sit inside the port-draining path.
