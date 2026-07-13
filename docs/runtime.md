# Codex Loops Runtime

## Architecture

The Elixir runtime is a supervised, journal-backed workflow runner. Workflow
scripts compile into inert trees. A per-run writer process walks the tree,
invokes the selected provider, commits ordered journal events to SQLite, and
exits. Read surfaces are run projections folded from the journal.

```text
Codex MCP tool -> Rust HTTP adapter -> scheduler HTTP API -> supervised run writer
                                      -> mock turn, or one shared Codex app-server
                                      -> append-only SQLite journal
                                      -> scheduler API / Phoenix LiveView projections
```

The native Rust control plane owns adapter and explicit OS-process concerns:
locating its fixed runtime bundle; CLI start, supervision, and stop commands;
health-checking; and translating MCP tool calls into scheduler HTTP requests.
The MCP subcommand never performs process lifecycle work. Elixir owns
supervision inside the OTP application: the shared Codex app-server Port,
`DynamicSupervisor`, `Registry`, run writers, journal owner, Phoenix PubSub, and
Phoenix LiveView.

## Realtime And Durable Surfaces

SQLite is authoritative for every read surface, including LiveView. Immediately
before a provider attempt, the writer synchronously appends `agent_started`.
As the Codex provider normalizes JSONL into activity entries, the same writer
synchronously appends each `agent_activity`. Only after an append succeeds does
it publish `{:journal_committed, run_id, seq}`. PubSub is therefore a refresh signal,
not a second progress bus, and a connected or reconnecting LiveView always
renders a journal fold.

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
```

The native command derives the bundle root from its own executable and selects
stdio MCP with `codex-loops mcp`. MCP disconnection
does not stop the scheduler. The native per-user supervisor keeps it alive until
an explicit `codex-loops stop`, restarting unexpected scheduler exits with
bounded backoff while retaining the owner lock. `codex-loops serve --foreground`
uses the same supervision loop without daemonizing for external process-manager
integration. Supervisor metadata persists independently of each child
generation and records the effective bind, journal, and model configuration so
explicit stop remains available during backoff and restart inherits stateful
settings.

Endpoint configuration also declares ownership. Host/port configuration uses
the local native supervisor. An explicit `--server URL` or
`CODEX_LOOPS_SCHEDULER_URL` is externally owned: the native client verifies
health and API version but never autostarts, stops, restarts, or reads local
logs for that endpoint. Path-bearing remote operations remain opt-in through
`CODEX_LOOPS_SHARED_FILESYSTEM=1`; status, inspection, UI, and pathless resume
need no shared filesystem.

Run the scheduler server from the release by enabling the endpoint at runtime:

```sh
CODEX_LOOPS_SERVER=1 \
CODEX_LOOPS_HOST=127.0.0.1 \
CODEX_LOOPS_PORT=47125 \
CODEX_LOOPS_JOURNAL_PATH=/tmp/codex-loops-runs.sqlite \
_build/prod/rel/agent_loops/bin/agent_loops start
```

`CODEX_LOOPS_HOST` defaults to `127.0.0.1` because the packaged scheduler is a
local, path-first product surface. Set `CODEX_LOOPS_HOST=0.0.0.0` or another
non-loopback address only when deliberately exposing the scheduler beyond the
local machine; put that deployment behind the host's normal access controls
such as a trusted reverse proxy, tunnel, firewall, or private network boundary.
`CODEX_LOOPS_PORT` defaults to `PORT`, then `4000`.

The bundle stage inside `make ci` starts the packaged scheduler, checks
`/api/health`, validates a workflow through
`/api/workflows/validate`, starts a mock run through `/api/runs`, reads the
polling status snapshot and journal summaries through `/api/runs/<id>` and
`/api/runs/<id>/events`, and verifies the `/runs/<id>` LiveView route is
reachable. It then launches another mock run through the packaged
`codex-loops run` command and verifies that run's LiveView URL.

The MCP stage inside `make ci` starts the scheduler explicitly, executes the
bundled MCP adapter, and proves validation, mock execution, conformance
variants, status, inspection, resume, and UI opening against that runtime. It
also asserts that MCP creates no owner state and that closing MCP has no effect
on the scheduler. Native lifecycle behavior has its own proof surface.

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

Provider attempts are at-most-once. The writer commits `agent_started`, including
the attempt identity, before submitting work to the provider. A matching
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

Normal runs preserve unrestricted provider execution. The explicit
`sandbox-run` surface instead starts ephemeral app-server threads with a
workspace-write policy and an explicit detached Git worktree as `cwd`. Its
scheduler runtime, journal, home, loopback port, and MCP transcript are isolated
and retained until `sandbox-clean` removes them.

Schema-backed turns use the app-server `outputSchema` parameter; the
schema owns output shape, while prompts should carry semantic work
instructions. The writer still validates results locally and fails closed after
configured retries.

`codex-loops install --codex /absolute/path/to/codex` probes and persists the
lexical path plus exact version. The native launcher passes that path into
runtime configuration. The provider consumes normalized application
configuration and never searches PATH or reads process environment.

The app-server protocol is bounded: JSON lines are limited to 1 MiB, prompts and
aggregate per-turn notifications to 16 MiB, each turn to 10,000 notifications,
and pending admission to 64 requests. Admission waits at most five seconds; an
expired admission is conservatively `outcome_unknown` because its mailbox request
may already have been accepted. The default turn deadline is 30 minutes, and a
turn timeout interrupts and drains only that turn. At most eight live turns share
the connection across all runs.
Concurrent workflow work is also capped at eight tasks, fanout width at 64
lanes, and requested per-node limits may reduce those caps further. Agent
retries are limited to five and loop bounds to 1000 iterations. Refine reviewers
also have a finite per-reviewer deadline. Compatibility `while_budget`,
`until_dry`, and `fan_out` forms lower to the generic `loop`/`fanout` semantic
core before execution.

## Supervision

The application supervises:

- `Workflow.Journal`: SQLite write owner and boot gate.
- `Workflow.Run.Registry`: unique per-run writer lease.
- `Workflow.PubSub`: post-commit notifications.
- `Workflow.TaskSupervisor`: bounded failure-isolated workflow tasks.
- `Workflow.Provider.Codex.AppServer`: lazy owner and concurrent router for the
  single Codex app-server Port.
- `Workflow.Run.Supervisor`: dynamic supervisor for run writers.
- `Workflow.Web.Endpoint`: optional endpoint, disabled by default unless
  `CODEX_LOOPS_SERVER=1` or `true`.

These children use dependency order under `:rest_for_one`: if the journal,
registry, or PubSub foundation restarts, downstream writers and the endpoint are
restarted too. No writer can remain alive behind a replacement registry.

## Scope

Supported: local workflow scripts, explicit CLI lifecycle, HTTP-only MCP tool calls, mock tests, live
Codex runs, SQLite-backed scheduler projections, scheduler API/UI reads, and
release packaging.

Not currently shipped: draft scaffolding, hosted workflow services, and
per-agent skip controls.
