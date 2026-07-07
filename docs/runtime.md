# Codex Loops Runtime

## Architecture

The Elixir runtime is a supervised, journal-backed workflow runner. Workflow
scripts compile into inert trees. A per-run writer process walks the tree,
invokes the selected provider, commits ordered events to SQLite, and exits.
Read surfaces are projections over the journal.

```text
Codex MCP tool -> scheduler HTTP API -> supervised run writer
               -> provider turn or mock turn -> append-only SQLite journal
               -> scheduler API / Phoenix LiveView projections
```

MCP owns adapter concerns: discovering or starting the local scheduler release,
health-checking it, translating MCP tool calls into scheduler HTTP requests, and
returning MCP-friendly envelopes. Elixir owns runtime supervision: the OTP
application, `DynamicSupervisor`, `Registry`, run writers, journal owner,
Phoenix PubSub, and Phoenix LiveView.

## Packaging

The production artifact is the local Elixir/Phoenix workflow scheduler packaged
as a Mix release named `agent_loops`. It includes ERTS, compiled BEAM code,
dependency `priv/` directories, and native artifacts such as `exqlite`'s SQLite
NIF.

```sh
make release
test -x _build/prod/rel/agent_loops/bin/agent_loops
```

The release includes the generated `bin/agent_loops` script used by the MCP
adapter. It also includes a small `bin/agent-loops` wrapper over the generated
script for developer diagnostics and legacy scripts. The wrapper forwards the
original argv through `Workflow.ReleaseCLI` and calls `Workflow.CLI.exec/1`; it
is not the product integration surface.

Run the scheduler server from the release by enabling the endpoint at runtime:

```sh
CODEX_LOOPS_SERVER=1 \
CODEX_LOOPS_HOST=127.0.0.1 \
CODEX_LOOPS_PORT=47125 \
CODEX_LOOPS_JOURNAL_PATH=/tmp/codex-loops-runs.sqlite \
_build/prod/rel/agent_loops/bin/agent_loops start
```

`CODEX_LOOPS_HOST` defaults to `0.0.0.0` for ordinary release deployments. Set
it to `127.0.0.1` or `localhost` for deterministic local proofs.
`CODEX_LOOPS_PORT` defaults to `PORT`, then `4000`.

`make proof` is the production readiness proof for this artifact: it starts the
packaged scheduler, checks `/api/health`, validates a workflow through
`/api/workflows/validate`, starts a mock run through `/api/runs`, reads status
and events through `/api/runs/<id>` and `/api/runs/<id>/events`, and verifies
the `/runs/<id>` LiveView route is reachable.

`make proof-mcp` proves the Codex-facing product path from a copied plugin
package: MCP starts/discovers the packaged scheduler, validates a workflow,
starts a mock run, reads status/events, resumes, returns the UI URL, and shuts
down its owned scheduler. `make proof-mcp-live` repeats the MCP path with
`provider: "codex"` and asserts nonzero token usage from scheduler status.

## Journal Model

Runs are stored in SQLite at `~/.codex/workflows/runs_1.sqlite` by default, or
at `CODEX_LOOPS_JOURNAL_PATH` when set. Events are keyed by `{run_id, seq}` and
folded to reconstruct status, summaries, and resume decisions.

## Providers

- `mock`: offline provider used by `test`.
- `codex`: live provider that shells out to `codex exec --json
  --skip-git-repo-check` and folds the JSONL stream into a result plus token
  usage.

Schema-backed turns use Codex structured output via `--output-schema`; the
writer validates results and fails closed after configured retries.

## Supervision

The application supervises:

- `Workflow.Run.Registry`: unique per-run writer lease.
- `Workflow.PubSub`: post-commit notifications.
- `Workflow.Journal`: SQLite owner process.
- `Workflow.Run.Supervisor`: dynamic supervisor for run writers.
- `Workflow.Web.Endpoint`: optional endpoint, disabled by default in release CLI
  mode unless `CODEX_LOOPS_SERVER=1` or `true`.

## Scope

Supported: local workflow scripts, MCP lifecycle/tool calls, mock tests, live
Codex runs, SQLite-backed scheduler projections, scheduler API/UI reads, and
release packaging.

Not currently shipped: draft scaffolding, hosted workflow services, and
per-agent skip controls. The compatible Elixir CLI remains developer-only.
