# Codex Loops Plugin

Codex Loops provides one Codex skill plus a local Elixir MCP adapter for authoring,
validating, executing, and inspecting local Elixir workflow files. The MCP
adapter is the Codex-facing surface: it talks to the scheduler HTTP API and can
start the packaged scheduler release when no local scheduler is already
reachable.

## Install

```bash
codex plugin marketplace add pproenca/codex-loops --ref master
codex plugin add codex-loops@codex-loops
```

For a local clone:

```bash
codex plugin marketplace add .
codex plugin add codex-loops@codex-loops
```

Start a new Codex thread after installing so the `codex-loops` skill is loaded.

## MCP Surface

The plugin includes a local stdio MCP entrypoint at
`plugins/codex-loops/mcp/codex-loops-mcp`. It launches the packaged Elixir
release and runs `Workflow.MCP.Stdio`.
It exposes:

- `workflow_validate`: validates a workflow through `POST /api/workflows/validate`
- `workflow_start`: starts a run through `POST /api/runs` for an existing
  workflow script. Inputs are `script_path`, optional `run_id`, optional
  `provider` (`mock` or `codex`), and optional non-negative integer `budget`.
  The scheduler API defaults to `mock`; selecting `codex` spends a real Codex
  provider turn.
- `workflow_status`: reads the scheduler projection through
  `GET /api/runs/:id`, preserving run id, state, result, failure, usage, and UI
  link fields.
- `workflow_inspect`: reads ordered scheduler event projections through
  `GET /api/runs/:id/events`, preserving the scheduler event sequence, type, and
  public address fields.
- `workflow_resume`: resumes an existing scheduler-owned run through
  `POST /api/runs/:id/resume`. Inputs are `run_id`, optional `script_path` or
  scheduler-supported `script` alias, and optional `provider` (`mock` or
  `codex`).
- `workflow_open_ui`: reads the run projection and returns `ui_path`, `ui_url`,
  and an absolute `open_url` for the Phoenix LiveView run page.

Before the tool call, the MCP adapter checks `GET /api/health`. If the scheduler
is unreachable, it discovers a packaged release from:

1. `CODEX_LOOPS_SCHEDULER_BIN`
2. `plugins/codex-loops/scheduler/bin/agent_loops`
3. `_build/prod/rel/agent_loops/bin/agent_loops`

`make release` builds the production Mix release and copies it into
`plugins/codex-loops/scheduler/` so the plugin package can be copied or
installed without depending on the source repository's `_build` directory.

When it owns the scheduler lifecycle, it starts the release with
`CODEX_LOOPS_SERVER=1`, `CODEX_LOOPS_HOST`, `CODEX_LOOPS_PORT`, `PORT`, unique
`RELEASE_NODE`, and unique `RELEASE_TMP`. `CODEX_LOOPS_JOURNAL_PATH` is passed
through when present.

The MCP adapter stays on the scheduler HTTP boundary. It does not read SQLite,
call `Workflow.Scheduler`, or reach into journal/runtime internals directly.
Scheduler success envelopes are returned as MCP `structuredContent`; scheduler
typed errors remain typed and are returned with `isError: true`.

## Legacy CLI Surface

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

`workflow` aliases `run`; `test` is always offline and mock-backed. This direct
terminal wrapper remains for compatibility and release proofing while Codex uses
the MCP adapter as the product control surface.

## Workflow Scripts

Executable workflows are Elixir `.exs` files:

```elixir
defmodule ExampleWorkflow do
  use Workflow

  workflow "example" do
    phase "scout"
    log "starting"
    agent "Inspect README.md and summarize the project goal."
    return :ok
  end
end
```

Write repo-local workflows under `.codex/workflows/<name>.exs`, validate them,
then mock-test before live execution:

```bash
agent-loops validate .codex/workflows/<name>.exs --json
agent-loops test .codex/workflows/<name>.exs --run-id <id> --json
agent-loops run .codex/workflows/<name>.exs --run-id <id-live> --provider codex --json
```

Run data is stored in SQLite at `~/.codex/workflows/runs_1.sqlite` unless
`CODEX_LOOPS_JOURNAL_PATH` is set.

## Development

```bash
make setup
make test
make release
make proof
make proof-mcp
make proof-mcp-live
make proof-live
```

`make proof-mcp` exercises MCP initialize, tools/list, lifecycle startup,
validation, mock start, status polling, event inspection, resume, typed
scheduler errors, and open-ui response from a copied plugin package against its
packaged scheduler release. `make proof-mcp-live` validates through MCP, starts
or reuses the packaged scheduler through MCP lifecycle handling, starts a live
`provider: "codex"` run through `workflow_start`, polls `workflow_status`, and
asserts nonzero token usage in the scheduler projection. It spends one real
Codex provider turn. `make proof-live` is an alias for `make proof-mcp-live`;
`make proof-release-live` keeps the legacy direct packaged-release live proof.

## License

MIT. See the repository [LICENSE](../../LICENSE).
