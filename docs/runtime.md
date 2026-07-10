# Codex Loops Runtime

## Architecture

The Elixir runtime is a supervised, journal-backed workflow runner. Workflow
scripts compile into inert trees. A per-run writer process walks the tree,
invokes the selected provider, commits ordered journal events to SQLite, and
exits. Read surfaces are run projections folded from the journal.

```text
Codex MCP tool -> scheduler HTTP API -> supervised run writer
               -> provider turn or mock turn -> append-only SQLite journal
               -> scheduler API / Phoenix LiveView projections
```

The native Rust control plane owns adapter and OS-process concerns: discovering,
starting, supervising, and stopping the local scheduler release; health-checking
it; translating MCP tool calls into scheduler HTTP requests; and returning
MCP-friendly envelopes. Elixir owns supervision inside the OTP application:
`DynamicSupervisor`, `Registry`, run writers, journal owner, Phoenix PubSub, and
Phoenix LiveView.

## Realtime And Durable Surfaces

LiveView is the realtime surface. The Codex provider normalizes Codex JSONL
events into activity entries, and the writer publishes those entries as
progress messages on `Workflow.Run.Stream` while the provider turn is still
running. A connected LiveView may render those progress messages immediately,
before the agent settles.

Progress messages are not authoritative run facts until persisted. A supervised
`Workflow.Run.ActivityPersistenceSubscriber` listens to the progress-message bus
and appends `agent_activity` journal events for reconnect and inspection. Agent
settlement stays writer-owned: `agent_committed`, `agent_attempt_rejected`, and
`agent_failed` are the events that drive replay, resume, retry, ledger, and
terminal state.

The scheduler API and MCP tools are polling snapshot or inspection surfaces:

- `GET /api/runs/:id` and `workflow_status` return the current run projection.
- `GET /api/runs/:id/events` returns safe journal event summaries under
  `journalEvents` and legacy `events`.
- `workflow_inspect` returns the run projection, ordered `rawRefs`, and
  `journalEvents`; it does not expose raw Codex JSONL by default.
- `workflow_open_ui` returns the LiveView URL and is the MCP path for realtime
  watching.

Raw refs are pointers to durable journal events. `eventCount` counts persisted
journal events only, not transient progress messages seen by a connected
LiveView.

## Packaging

The production artifact is the local Elixir/Phoenix workflow scheduler packaged
as a Mix release named `agent_loops`. It includes ERTS, compiled BEAM code,
dependency `priv/` directories, and native artifacts such as `exqlite`'s SQLite
NIF.

```sh
make release
test -x _build/prod/rel/agent_loops/bin/agent_loops
```

The release includes `bin/agent_loops` for scheduler lifecycle commands. A
separate native Rust binary is installed as `codex-loops` and
`codex-loops-mcp`; the latter name selects stdio MCP mode. MCP disconnection
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

The release stage inside `make ci` starts the packaged scheduler, checks
`/api/health`, validates a workflow through
`/api/workflows/validate`, starts a mock run through `/api/runs`, reads the
polling status snapshot and journal summaries through `/api/runs/<id>` and
`/api/runs/<id>/events`, and verifies the `/runs/<id>` LiveView route is
reachable. It then launches another mock run through the packaged
`codex-loops run` command and verifies that run's LiveView URL.

The MCP stage inside `make ci` also stages the formula layout without modifying
the source-only plugin, copies the plugin into a temporary installed root, and
proves lifecycle, validation, mock execution, conformance variants, status,
inspection, resume, and UI opening against that external runtime. The proof
asserts that the scheduler survives MCP shutdown, then stops it explicitly
through the native CLI.

## Journal Model

Runs are stored in SQLite at `~/.codex/workflows/runs_1.sqlite` by default, or
at `CODEX_LOOPS_JOURNAL_PATH` when set. Events are keyed by `{run_id, seq}` and
folded to reconstruct status, summaries, and resume decisions.

## Providers

- `mock`: offline provider used by `test`.
- `codex`: live provider that shells out to `codex exec --json
  --skip-git-repo-check`, folds each Codex event once, emits normalized activity
  entries for realtime UI, and settles with a result plus token usage.

Schema-backed turns use Codex structured output via `--output-schema`; the
schema owns output shape, while prompts should carry semantic work
instructions. The writer still validates results locally and fails closed after
configured retries.

## Supervision

The application supervises:

- `Workflow.Run.Registry`: unique per-run writer lease.
- `Workflow.PubSub`: post-commit notifications.
- `Workflow.Journal`: SQLite owner process.
- `Workflow.Run.ActivityPersistenceSubscriber`: explicit subscriber that makes
  progress activity durable.
- `Workflow.Run.Supervisor`: dynamic supervisor for run writers.
- `Workflow.Web.Endpoint`: optional endpoint, disabled by default unless
  `CODEX_LOOPS_SERVER=1` or `true`.

## Scope

Supported: local workflow scripts, MCP lifecycle/tool calls, mock tests, live
Codex runs, SQLite-backed scheduler projections, scheduler API/UI reads, and
release packaging.

Not currently shipped: draft scaffolding, hosted workflow services, and
per-agent skip controls.
