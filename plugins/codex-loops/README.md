# Codex Loops Plugin

Codex Loops provides one Codex skill plus a local Elixir MCP adapter for authoring,
validating, executing, and inspecting local Elixir workflow files. The MCP
adapter is the Codex-facing surface: it talks to the scheduler HTTP API and can
start the packaged scheduler release when no local scheduler is already
reachable.

## Install

```bash
brew install pproenca/codex-loops/codex-loops
codex-loops install
```

For a local clone:

```bash
codex plugin marketplace add .
codex plugin add codex-loops@codex-loops
```

Start a new Codex thread after installing so the `codex-loops` skill is loaded.

## Manual CLI Run

Run a workflow and watch its LiveView without configuring environment
variables or calling the HTTP API directly:

```bash
codex-loops serve
codex-loops run .codex/workflows/codex_answer.exs --open
codex-loops stop
```

The defaults are the local scheduler at `127.0.0.1:47125`, the standard user
journal, a generated run ID, and the live `codex` provider. Optional flags
provide custom ports, journals, models, providers, run IDs, and scheduler URLs.

## MCP Surface

The source-only plugin includes a tracked stdio launcher at
`plugins/codex-loops/mcp/codex-loops-mcp`. The launcher finds the
Homebrew-owned runtime, enforces exact plugin/runtime version compatibility,
and executes the Anubis MCP command from that runtime. MCP starts or discovers
the scheduler release when a tool call needs the scheduler HTTP API.
It exposes:

- `workflow_validate`: validates a workflow through `POST /api/workflows/validate`
- `workflow_start`: starts a run through `POST /api/runs` for an existing
  workflow script. Inputs are `script_path`, optional `run_id`, optional
  `provider` (`mock` or `codex`), and optional non-negative integer `budget`.
  The scheduler API defaults to `mock`; selecting `codex` spends a real Codex
  provider turn.
- `workflow_status`: reads `GET /api/runs/:id` and returns the public §7.5
  status projection: `runId`, state, result, failure, usage, agents/rejections,
  refine summaries, tool activity, and ordered `rawRefs`.
- `workflow_inspect`: reads `GET /api/runs/:id/events` and returns the public
  §7.5 inspect/status projection with ordered `rawRefs.journal`; lower-level
  event rows and scheduler-only UI/lifecycle fields are not part of this MCP
  surface.
- `workflow_resume`: resumes an existing scheduler-owned run through
  `POST /api/runs/:id/resume`. Inputs are `run_id`, optional `script_path` or
  scheduler-supported `script` alias, and optional `provider` (`mock` or
  `codex`).
- `workflow_open_ui`: reads the scheduler run projection and returns `uiPath`, `uiUrl`,
  and an absolute `open_url` for the Phoenix LiveView run page.

Before the tool call, the MCP adapter checks `GET /api/health`. If the scheduler
is unreachable, it discovers a packaged release from:

1. `CODEX_LOOPS_SCHEDULER_BIN`
2. `CODEX_LOOPS_RUNTIME_ROOT/scheduler/bin/agent_loops`
3. `CODEX_LOOPS_REPO_ROOT/_build/prod/rel/agent_loops/bin/agent_loops` in
   explicitly configured development environments

`make package-homebrew-runtime` builds one production Mix release and stages the
formula-owned `libexec` tree. It never copies generated artifacts into this
plugin.

When it owns the scheduler lifecycle, it starts the release with
`CODEX_LOOPS_SERVER=1`, `CODEX_LOOPS_HOST`, `CODEX_LOOPS_PORT`, `PORT`, unique
`RELEASE_NODE`, and unique `RELEASE_TMP`. `CODEX_LOOPS_JOURNAL_PATH` is passed
through when present.

The MCP adapter stays on the scheduler HTTP boundary. It does not read SQLite,
call `Workflow.Scheduler`, or reach into journal/runtime internals directly.
Scheduler success envelopes are returned as MCP `structuredContent`; scheduler
typed errors remain typed and are returned with `isError: true`.

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

```text
workflow_validate script_path=.codex/workflows/<name>.exs
workflow_start    script_path=.codex/workflows/<name>.exs run_id=<id> provider=mock
workflow_status   run_id=<id>
workflow_inspect  run_id=<id>
workflow_start    script_path=.codex/workflows/<name>.exs run_id=<id-live> provider=codex
workflow_status   run_id=<id-live>
```

Run data is stored in SQLite at `~/.codex/workflows/runs_1.sqlite` unless
`CODEX_LOOPS_JOURNAL_PATH` is set.

## Development

```bash
make setup
make test
make release
make package-homebrew-runtime
make proof
make proof-mcp
make proof-mcp-live
make proof-live
```

`make proof-mcp` builds the external runtime, copies this source-only plugin to a
temporary installed root, then exercises MCP initialize, tools/list, lifecycle
startup, validation, mock start, status polling, event inspection, resume,
typed scheduler errors, open-ui, and the packaged core/dataflow/refine
conformance workflows through the Codex JSONL provider port.
`make proof-mcp-live` validates through MCP, starts or reuses the packaged
scheduler through MCP lifecycle handling, starts a live `provider: "codex"` run
through `workflow_start`, polls `workflow_status`, and asserts nonzero token
usage plus streamed `agent_activity` journaled before agent settlement. It spends
one real Codex provider turn.
`make proof-live` is an alias for `make proof-mcp-live`.

## License

MIT. See the repository [LICENSE](../../LICENSE).

Third-party MCP/package notices are recorded in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), including the accepted Anubis
LGPL-3.0 distribution gate for this local plugin and Homebrew-oriented package
model.
