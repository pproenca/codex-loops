# Codex Loops Operations

## Developer Setup

```sh
make setup
make test
make release
make proof
```

`make setup` installs Hex/Rebar, fetches Elixir dependencies, and installs the
Node workspace when `pnpm` is available. `.tool-versions` pins the known-good
local toolchain for `mise`/`asdf`.

`make test` runs the scheduler/API/UI Elixir test suite. `make release` produces
the distributable local scheduler artifact under `_build/prod/rel/agent_loops/`.

For a repeatable local dogfood run, use:

```sh
make dogfood
```

It proves the packaged scheduler/MCP path, reinstalls `codex-loops@codex-loops`
from the current checkout, verifies Codex sees the plugin, and prints the prompt
to paste into a fresh thread for the actual agent-driven workflow run.

## Release Proof

```sh
make proof
```

This builds the Mix release and exercises the scheduler readiness path. The
proof starts the packaged Phoenix scheduler release on `127.0.0.1:47125` by
default with an isolated SQLite journal, then:

```sh
GET  /api/health
POST /api/workflows/validate
POST /api/runs
GET  /api/runs/<id>
GET  /api/runs/<id>/events
GET  /runs/<id>
```

Override proof binding and journal isolation when needed:

```sh
CODEX_LOOPS_PROOF_HOST=127.0.0.1 \
CODEX_LOOPS_PROOF_PORT=47126 \
CODEX_LOOPS_PROOF_JOURNAL_PATH=/tmp/codex-loops-proof.sqlite \
make proof
```

## Live Proof

```sh
make proof-mcp-live
make proof-live
make proof-release-live
```

`make proof-mcp-live` spends one live Codex provider turn through the packaged
scheduler plus MCP lifecycle path, then asserts the run completed and recorded
nonzero token usage in the scheduler projection. `make proof-live` aliases the
same MCP proof.

`make proof-release-live` keeps the legacy direct packaged-release command path
covered for compatibility.

## Normal Workflow Run

Agents should use the Codex plugin MCP tools. The MCP adapter starts or
discovers the scheduler, health-checks it, and talks to the scheduler HTTP API.
The Elixir/Phoenix scheduler owns the workflow workers, PubSub/LiveView, and
SQLite journal.

```text
workflow_validate script_path=.codex/workflows/example.exs
workflow_start    script_path=.codex/workflows/example.exs run_id=run_example provider=mock
workflow_status   run_id=run_example
workflow_inspect  run_id=run_example
```

Run live only after the mock gate is clean:

```text
workflow_start  script_path=.codex/workflows/example.exs run_id=run_example_live provider=codex
workflow_status run_id=run_example_live
```

## Status, Inspect, Open UI, Resume

```text
workflow_status  run_id=<id>
workflow_inspect run_id=<id>
workflow_open_ui run_id=<id>
workflow_resume  run_id=<id> provider=codex
```

Use the compatible `agent-loops` command only for terminal diagnostics, legacy
scripts, or release-wrapper proofing.

## Failure Parsing

MCP tools return scheduler success envelopes as structured content. Scheduler
typed errors remain typed and are returned as MCP errors. For legacy `--json`
terminal commands, parse stdout as the command payload on success; on failure,
parse the last stderr line as the JSON error object. Backend warnings may
appear earlier on stderr.

## Runtime Artifacts

Treat these as generated runtime artifacts:

- `~/.codex/workflows/runs_1.sqlite`
- `~/.codex/workflows/runs_1.sqlite-wal`
- `~/.codex/workflows/runs_1.sqlite-shm`
- `_build/prod/rel/agent_loops/`
