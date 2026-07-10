# Codex Loops Plugin

Codex Loops provides one Codex skill plus a native Rust MCP adapter for authoring,
validating, executing, and inspecting local Elixir workflow files. The MCP
adapter is the Codex-facing surface: it talks to the scheduler HTTP API and can
start the packaged scheduler release when no local scheduler is already
reachable.

## Install

The Homebrew tap is not published yet. For a local clone, build the native
control plane and scheduler first:

```bash
make build
make release
```

Then install the source plugin:

```bash
codex plugin marketplace add .
codex plugin add codex-loops@codex-loops
```

Start a new Codex thread after installing so the `codex-loops` skill is loaded.
For a local source install, start Codex in this checkout; the cached plugin
launcher resolves the configured `codex-loops` local marketplace and discovers
the artifacts built in that checkout automatically.

## Manual CLI Run

Run a workflow and watch its LiveView without configuring environment
variables or calling the HTTP API directly:

```bash
./native/codex-loops/target/release/codex-loops run .codex/workflows/codex_answer.exs --open
./native/codex-loops/target/release/codex-loops stop
```

The defaults are the local scheduler at `127.0.0.1:47125`, the standard user
journal, a generated run ID, and the live `codex` provider. `run` starts the
managed scheduler automatically when needed. Optional flags
provide custom ports, journals, models, providers, run IDs, and scheduler URLs.

## MCP Surface

The source-only plugin includes a tracked stdio launcher at
`plugins/codex-loops/mcp/codex-loops-mcp`. From a source checkout, the launcher
finds the native and scheduler artifacts created by `make build` and
`make release` from either its own location or the configured local marketplace
root, including when Codex has copied the plugin into its cache. It also
supports a staged packaged runtime, enforces exact plugin/runtime version
compatibility, and executes the native MCP command from that runtime. Homebrew
distribution is planned but is not published. MCP starts or discovers the
scheduler release when a tool call needs the scheduler HTTP API.
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

The packaging stage inside `make ci` builds one production Mix release and
stages the formula-owned `libexec` tree. It never copies generated artifacts
into this plugin.

When it starts the scheduler, the native control plane uses
`CODEX_LOOPS_SERVER=1`, `CODEX_LOOPS_HOST`, `CODEX_LOOPS_PORT`, `PORT`, unique
per-endpoint `RELEASE_TMP`, and `RELEASE_DISTRIBUTION=none`.
`CODEX_LOOPS_JOURNAL_PATH` is passed through when present. The scheduler is not
owned by the MCP session and survives stdio disconnection.

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
make build
make ci
make release
```

`make ci` includes MCP initialize/tools, scheduler lifecycle, validation, mock
execution, status, inspection, resume, typed errors, UI opening, and packaged
core/dataflow/refine conformance through the Codex JSONL provider port. It is
credential-free and does not spend a real Codex turn.

## License

MIT. See the repository [LICENSE](../../LICENSE).

Third-party MCP/package notices are recorded in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), including the Apache-2.0
`rmcp` dependency used by the native MCP adapter.
