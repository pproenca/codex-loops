# Codex Loops Runtime

## Architecture

The Elixir runtime is a supervised, journal-backed workflow runner. Workflow
scripts compile into inert trees. A per-run writer process walks the tree,
invokes the selected provider, commits ordered journal events to SQLite, and
exits. Read surfaces are run projections folded from the journal.

```text
Codex -> Streamable HTTP POST /mcp -> scheduler context -> supervised run writer
                                                   -> mock turn, or one shared Codex app-server
                                                   -> append-only SQLite journal
                                                   -> API / Phoenix LiveView projections
```

One Elixir/OTP release owns every long-lived product surface: the Streamable
HTTP MCP route, scheduler API, LiveView, shared Codex app-server Port,
`DynamicSupervisor`, `Registry`, run writers, journal owner, and Phoenix PubSub.
MCP tool dispatch enters the scheduler context directly. There is no Rust
runtime, stdio bridge, loopback HTTP adapter, or MCP-owned process lifecycle.

The installed release runs as a per-user login service. Codex connections are
ordinary HTTP clients and can come and go without starting or stopping the
scheduler. The Codex app-server is a separate protocol process owned by one
supervised Elixir process and starts lazily on the first live provider turn.

## Streamable HTTP MCP

Codex registers `http://127.0.0.1:47125/mcp` and talks directly to Phoenix.
Each `POST /mcp` body is bounded to 1 MiB. Protocol `2025-03-26` accepts either
one JSON-RPC message or a non-empty JSON-RPC batch; batch responses omit
notification and client-response entries and remain a JSON array. A batch made
only of notifications and client responses returns `202` with an empty body.
Protocols `2025-06-18` and `2025-11-25` accept one message per POST. `GET` and
`DELETE` return `405`: the implementation is stateless and intentionally has
no SSE stream or `Mcp-Session-Id`.

The endpoint implements `initialize`, `ping`, `tools/list`, and `tools/call` for
MCP protocol versions `2025-03-26`, `2025-06-18`, and `2025-11-25`. After
initialization it validates `MCP-Protocol-Version`; a missing header uses the
Streamable HTTP compatibility default `2025-03-26`. One shared request guard
protects MCP, API, and LiveView: `Host` must be loopback, while `Origin` may be
absent for non-browser clients but must be loopback when present.

## Realtime And Durable Surfaces

SQLite is authoritative for every read surface, including LiveView. Immediately
before a provider attempt, the writer synchronously appends `agent_started`.
As the Codex provider normalizes JSONL into activity entries, the same writer
synchronously appends each `agent_activity`. Only after an append succeeds does
it publish `{:journal_committed, run_id, seq}`. PubSub is therefore a refresh
signal, not a second progress bus, and a connected or reconnecting LiveView
always renders a journal fold.

Agent settlement stays writer-owned: `agent_committed`,
`agent_attempt_rejected`, and `agent_failed` close an attempt. Activity remains
telemetry and does not decide validation, retry, budget, or terminal state. Its
durability before notification means a slow or disconnected UI loses no state,
and no subscriber is responsible for making activity durable.

The scheduler API and MCP tools are polling snapshot or inspection surfaces:

- `GET /api/runs/:id` and `workflow_status` return the current run projection.
- `GET /api/runs/:id/events` returns safe journal event summaries under
  `journalEvents` and legacy `events`.
- `workflow_inspect` returns the run projection, ordered `rawRefs`, and
  `journalEvents`; it does not expose raw Codex JSONL by default.
- `workflow_open_ui` returns the LiveView URL and is the MCP path for realtime
  watching.

Raw refs are pointers to durable journal events. `eventCount` counts persisted
journal events. PubSub notifications do not add projection entries.

## Runtime Bundle

The production artifact is one immutable target-specific directory. The
Elixir/Phoenix scheduler remains a Mix release named `agent_loops`, including
ERTS, compiled BEAM code, dependency `priv/` directories, and native artifacts
such as `exqlite`'s SQLite NIF.

```sh
make dev-bundle
make dist
```

The bundle layout is fixed:

```text
bin/codex-loops
libexec/scheduler/
share/skills/codex-loops/
share/codex-loops/runtime.json
```

`bin/codex-loops` is a release overlay, not a separate runtime. It exposes
installation reconciliation and explicit service operations. `./install`
copies and activates the immutable version, then uses that overlay to bind
Codex, install the skill, provision and start the login service, health-check
the release, and register the `/mcp` URL.

macOS uses `~/Library/LaunchAgents/com.pproenca.codex-loops.plist`; Linux uses
`~/.config/systemd/user/codex-loops.service`. The service manager owns the
release's foreground process. Direct operations are:

```sh
codex-loops serve
codex-loops stop
codex-loops restart
codex-loops status --json
codex-loops doctor --json
```

`serve` enables and starts the service and waits for exact scheduler health.
`stop` and `restart` operate through the host service manager. `status` reports
both the installed service definition and scheduler health.

For development and proof processes, run the packaged release directly by
enabling the endpoint at runtime:

```sh
CODEX_LOOPS_SERVER=1 \
CODEX_LOOPS_HOST=127.0.0.1 \
CODEX_LOOPS_PORT=47125 \
CODEX_LOOPS_JOURNAL_PATH=/tmp/codex-loops-runs.sqlite \
CODEX_LOOPS_CODEX_BIN="$(command -v codex)" \
CODEX_LOOPS_BINDING_PATH="$HOME/.codex/workflows/codex-binding.json" \
_build/prod/rel/agent_loops/bin/agent_loops start
```

Those last two variables are mandatory for a direct release start and must be
absolute. `CODEX_LOOPS_BINDING_PATH` points at the binding created by the
one-action installer. Normal operations use `codex-loops serve`, whose managed
service definition supplies both values.

`CODEX_LOOPS_HOST` defaults to `127.0.0.1` because the packaged scheduler is a
local, path-first product surface. Runtime configuration rejects wildcard and
non-loopback addresses; only `localhost`, IPv4 `127.0.0.0/8`, and IPv6 `::1`
are valid. The installed service sets `CODEX_LOOPS_PORT=47125`; a release
started directly defaults to `PORT`, then `4000`, when that variable is absent.

The bundle stage inside `make ci` starts the packaged release, checks
`/api/health`, validates a workflow through
`/api/workflows/validate`, starts a mock run through `/api/runs`, reads the
polling status snapshot and journal summaries through `/api/runs/<id>` and
`/api/runs/<id>/events`, and verifies the `/runs/<id>` LiveView route is
reachable. Service and installer proofs exercise the release overlay and
one-action reconciliation separately.

The MCP stage inside `make ci` sends Streamable HTTP requests directly to
`/mcp` and proves initialization, tool discovery, validation, mock execution,
conformance variants, status, inspection, resume, and UI opening. It also
asserts that client disconnects have no effect on the service. User-service
lifecycle has its own proof surface.

The health projection checks the OTP application, journal owner, and PubSub.
`Workflow.Web.Endpoint` is intentionally not repeated as a component check:
receiving `/api/health` already proves that the endpoint is serving requests.

## Journal Model

Runs are stored in SQLite at `~/.codex/workflows/runs_1.sqlite` by default, or
at `CODEX_LOOPS_JOURNAL_PATH` when set. Events are keyed by `{run_id, seq}` and
folded to reconstruct status, summaries, and resume decisions.

The supervised journal process owns one serialized write connection. Status,
inspection, and LiveView folds open short-lived read-only SQLite connections,
so concurrent readers do not queue through the journal process's mailbox. Event
blobs are size-bounded and decoded with OTP's safe term option.

## Provider Effects And Resume

Provider attempts are at-most-once. The writer commits `agent_started`,
including the attempt identity, before submitting work to the provider. A matching
`agent_committed`, `agent_attempt_rejected`, or `agent_failed` settles that
attempt. Completed and rejected attempts replay from the journal on resume.

If a writer or scheduler dies after `agent_started` but before settlement, the
provider may or may not have completed or charged. Codex Loops does not pretend
that the backend deduplicates the request and does not redeliver it. Resume
appends `run_failed` with `outcome_unknown` and terminates. Operators must inspect
the recorded attempt and start a new run deliberately if they want to try the
work again.

## Providers

- `mock`: offline provider used by `test`.
- `codex`: live provider that submits turns to one scheduler-owned, initialized
  Codex app-server, folds each correlated notification once, emits normalized
  activity entries into the journal, and settles with a result plus token usage.

Schema-backed turns use the app-server `outputSchema` parameter; the
schema owns output shape, while prompts should carry semantic work
instructions. The writer still validates results locally and fails closed after
configured retries.

`./install` selects Codex from PATH by default; `./install --codex
/absolute/path/to/codex` selects it explicitly. Installation probes and
persists the lexical path plus exact version. Immediately before the lazy
app-server starts, the release revalidates that binding. The provider never
searches PATH or silently switches commands.

For path-bearing MCP calls, an absolute `script_path` may omit
`workspace_root`. A relative `script_path` requires an explicit absolute,
existing `workspace_root`; the scheduler joins and canonicalizes them, rejects
symlink escapes, persists the canonical root in `run_started`, and restores it
for resume. Codex receives that root as the per-turn working directory.

The app-server protocol is bounded: JSON lines are limited to 1 MiB, prompts and
aggregate per-turn notifications to 16 MiB, each turn to 10,000 notifications,
and pending admission to 64 requests. Admission waits at most five seconds; an
expired admission is conservatively `outcome_unknown` because its mailbox request
may already have been accepted. The default turn deadline is 30 minutes, and a
turn timeout interrupts and drains only that turn. At most eight live turns share
the connection across all runs. Completed threads are ephemeral and explicitly
unsubscribed; because Codex retains idle unsubscribed threads for a grace period,
the owner recycles the Port after 64 releases, once unrelated live turns settle.
Only one Port exists at a time.
The scheduler admits at most eight active run writers. Within each run,
concurrent workflow work is capped at eight tasks and fanout width at 64 lanes;
requested per-node limits may reduce those caps further. Agent retries are
limited to five and loop bounds to 1000 iterations. Refine reviewers also have
a finite per-reviewer deadline. Compatibility `while_budget`,
`until_dry`, and `fan_out` forms lower to the generic `loop`/`fanout` semantic
core before execution.

## Supervision

The application supervises:

- `Workflow.Journal`: SQLite write owner and boot gate.
- `Workflow.Run.Registry`: unique per-run writer lease.
- `Workflow.PubSub`: post-commit notifications.
- `Workflow.TaskSupervisor`: bounded failure-isolated workflow tasks.
- `Workflow.RuntimeSupervisor`: a `:one_for_one` subtree containing:
  - `Workflow.Provider.Codex.AppServer`, the lazy owner and concurrent router for
    the single Codex app-server Port;
  - `Workflow.Run.Supervisor`, the dynamic supervisor for run writers; and
  - `Workflow.Web.Endpoint`, the shared HTTP application server for MCP, API,
    and LiveView. The installed service enables its listener.

The root uses dependency order under `:rest_for_one`: if the journal, registry,
PubSub, or shared task supervisor restarts, the complete runtime subtree is
rebuilt too. No writer can remain alive behind a replacement registry or task
supervisor. Inside the runtime subtree, `:one_for_one` isolates sibling failures:
an app-server crash cannot kill unrelated writers or restart the HTTP endpoint,
and an endpoint crash cannot disturb provider turns or runs.

## Scope

Supported: local workflow scripts, explicit user-service lifecycle, direct
Streamable HTTP MCP tool calls, mock tests, live Codex runs, SQLite-backed
scheduler projections, scheduler API/UI reads, and release packaging.

Not currently shipped: retained isolated scheduler environments, draft
scaffolding, hosted workflow services, and per-agent skip controls.
