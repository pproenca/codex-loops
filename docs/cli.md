# Codex Loops CLI

The Elixir release exposes the `agent-loops` command through
`_build/prod/rel/agent_loops/bin/agent-loops` after `make release`.

## Commands

```bash
agent-loops validate <script> [--json]
agent-loops test <script> [--run-id <id>] [--budget <n>] [--json]
agent-loops run <script> [--run-id <id>] [--provider mock|codex] [--budget <n>] [--json]
agent-loops workflow <script> [--run-id <id>] [--provider mock|codex] [--budget <n>] [--json]
agent-loops resume [<script>] [--run-id <id>] [--provider mock|codex] [--json]
agent-loops status [--run-id <id>] [--event-limit <n>] [--json]
agent-loops inspect [--run-id <id>] [--json]
agent-loops list [--limit <n>] [--json]
agent-loops help
```

`workflow` is an alias for `run`. `test` always uses the offline mock provider,
even if a provider flag is passed. `run`, `workflow`, and `resume` default to the
live `codex` provider unless `--provider mock` is supplied.

## JSON Discipline

With `--json`, stdout carries exactly one JSON payload for the command result.
Diagnostics and backend warnings belong on stderr. On failure, the last stderr
line is a single JSON error object:

```json
{"code":"validation","exitCode":6,"message":"...","hint":"..."}
```

## Exit Codes

| Exit code | Meaning |
|---|---|
| 0 | success |
| 2 | usage error |
| 4 | provider configuration error |
| 6 | validation or budget failure |
| 8 | malformed structured output |
| 130 | killed |
| 1 | other runtime failure |

## Release Proofs

```sh
make proof
make proof-mcp
make proof-mcp-live
make proof-live
make proof-release-live
```

`make proof` builds the release, starts the packaged Phoenix scheduler, and
proves the API/UI path against an isolated temporary workflow and SQLite journal:
health, validate, start mock run, read status/events, and fetch the run UI.
`make proof-mcp` proves the copied plugin MCP package path with mock runs.
`make proof-mcp-live` spends one real Codex turn through MCP and asserts
nonzero usage from scheduler status. `make proof-live` aliases
`make proof-mcp-live`; `make proof-release-live` keeps the compatible direct
release wrapper path covered.
