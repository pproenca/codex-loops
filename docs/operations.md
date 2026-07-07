# Codex Loops Operations

## Developer Setup

```sh
make setup
make test
make release
```

`make setup` installs Hex/Rebar, fetches Elixir dependencies, and installs the
Node workspace when `pnpm` is available. `.tool-versions` pins the known-good
local toolchain for `mise`/`asdf`.

## Release Proof

```sh
make proof
```

This builds the Mix release and runs the packaged `agent-loops` command against
a temporary workflow and SQLite journal:

```sh
agent-loops validate <script> --json
agent-loops test <script> --run-id <id> --json
agent-loops status --run-id <id> --json
agent-loops inspect --run-id <id> --json
```

## Live Proof

```sh
make proof-live
```

This spends one live Codex provider turn through the packaged release command,
then asserts the run completed and recorded nonzero token usage.

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
