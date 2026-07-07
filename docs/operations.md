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
make proof-live
make proof-release-live
```

`make proof-live` aliases the MCP live proof. It spends one live Codex provider
turn through the packaged scheduler plus MCP lifecycle path, then asserts the
run completed and recorded nonzero token usage in the scheduler projection.

`make proof-release-live` keeps the legacy direct packaged-release command path
covered for compatibility.

## Normal Workflow Run

```sh
agent-loops validate .codex/workflows/example.exs --json
agent-loops test .codex/workflows/example.exs --run-id run_example --json
agent-loops run .codex/workflows/example.exs --run-id run_example_live --provider codex --json
```

Use `--provider mock` for offline `run`/`workflow` checks. `test` is always
mock-backed.

## Status, Inspect, List, Resume

```sh
agent-loops status --run-id <id> --event-limit 5 --json
agent-loops inspect --run-id <id> --json
agent-loops list --limit 20 --json
agent-loops resume --run-id <id> --provider codex --json
```

Omit `--run-id` to select the latest known run from SQLite.

## Failure Parsing

For `--json` commands, parse stdout as the command payload on success. On
failure, parse the last stderr line as the JSON error object. Backend warnings
may appear earlier on stderr.

## Runtime Artifacts

Treat these as generated runtime artifacts:

- `~/.codex/workflows/runs_1.sqlite`
- `~/.codex/workflows/runs_1.sqlite-wal`
- `~/.codex/workflows/runs_1.sqlite-shm`
- `_build/prod/rel/agent_loops/`
