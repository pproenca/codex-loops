# Codex Loops

Codex Loops is a local, path-first workflow scheduler for Codex. The product
surface is a Codex plugin with an Elixir MCP adapter plus a packaged
Elixir/Phoenix scheduler. MCP manages local lifecycle and tool calls; Elixir
owns runtime supervision, workflow workers, Phoenix PubSub/LiveView, and the
SQLite journal.

The packaged `agent_loops` Mix release is a scheduler runtime. It does not ship
the old `agent-loops` CLI surface.

## Quick Start

```sh
make setup
make test
make release
make proof
```

After `make release`, verify the distributable scheduler release with:

```sh
test -x _build/prod/rel/agent_loops/bin/agent_loops
```

`make proof` is the production readiness path: it starts the packaged scheduler
on an isolated local port and journal, checks health, validates a workflow
through the API, starts a mock run through the API, reads status/events through
the API, and fetches the run UI.

For the Codex-facing product path:

```sh
make proof-mcp       # copied plugin package, MCP lifecycle, mock run, status, inspect, resume, open UI
make proof-mcp-live  # same MCP path, one real Codex provider turn
```

## Workflow Example

```elixir
defmodule AuditWorkflow do
  use Workflow

  workflow "audit-workflow" do
    phase "audit"
    log "starting audit"
    agent "Inspect the auth boundary and report the highest-risk issue."
    return :ok
  end
end
```

Run it through the Codex plugin MCP tools:

```text
workflow_validate script_path=.codex/workflows/audit_workflow.exs
workflow_start    script_path=.codex/workflows/audit_workflow.exs run_id=run_audit provider=mock
workflow_status   run_id=run_audit
workflow_inspect  run_id=run_audit
workflow_open_ui  run_id=run_audit
```

Run it live only after the mock gate is clean:

```text
workflow_start  script_path=.codex/workflows/audit_workflow.exs run_id=run_audit_live provider=codex
workflow_status run_id=run_audit_live
```

## Development Commands

```sh
make setup       # install Hex/Rebar and Elixir deps
make build       # compile with warnings as errors
make test        # run the Elixir scheduler/API/UI test suite
make release     # build the self-contained scheduler Mix release
make release-mcp # build the Burrito codex-loops-mcp executable
make proof       # build release and prove scheduler API/UI readiness
make proof-mcp   # prove copied plugin MCP lifecycle with mock scheduler-owned run
make dogfood     # prove MCP, reinstall the local plugin, and print the fresh-thread prompt
make proof-live  # alias for proof-mcp-live; spends one real Codex provider turn through MCP
```

The repository includes `.tool-versions` for `mise`/`asdf` users.

`make release-mcp` builds the Burrito MCP executable at
`_build/prod/mcp/codex-loops-mcp` and installs it as the copied plugin package
entrypoint at `plugins/codex-loops/mcp/codex-loops-mcp`. It requires `xz` on
`PATH` and Zig 0.15.2. On macOS, install the versioned Homebrew formula:

```sh
brew install zig@0.15 xz
```

The target checks those prerequisites before invoking Burrito. On macOS it
prefers `/opt/homebrew/opt/zig@0.15/bin/zig` when present because it is the most
reliable `0.15.2` build for recent Xcode toolchains; otherwise it falls back to
`zig` on `PATH`. You can also pass `ZIG=/path/to/zig`. After copying the
executable into `_build/prod/mcp` and the plugin package, the target clears the
matching local Burrito app/version cache so repeated local proofs execute the
just-built payload.

## Runtime Data

Runs are stored in SQLite at `~/.codex/workflows/runs_1.sqlite` by default.
Set `CODEX_LOOPS_JOURNAL_PATH=/path/to/runs.sqlite` to isolate a run, test, or
proof.

For local release proofs, set `CODEX_LOOPS_PROOF_HOST`,
`CODEX_LOOPS_PROOF_PORT`, or `CODEX_LOOPS_PROOF_JOURNAL_PATH` to override the
default `127.0.0.1:47125` proof server and temporary journal.

The MCP adapter uses `CODEX_LOOPS_SCHEDULER_HOST`,
`CODEX_LOOPS_SCHEDULER_PORT`, `CODEX_LOOPS_SCHEDULER_URL`, and
`CODEX_LOOPS_SCHEDULER_BIN` when you need to point it at a specific local
scheduler. In the packaged plugin path, it discovers
`plugins/codex-loops/scheduler/bin/agent_loops` and starts it when needed.
When the Burrito MCP executable is installed at
`plugins/codex-loops/mcp/codex-loops-mcp`, it infers `CODEX_LOOPS_PLUGIN_ROOT`
from its binary path unless `CODEX_LOOPS_PLUGIN_ROOT` or
`CODEX_LOOPS_SCHEDULER_BIN` is already set.

## Packages

- Elixir runtime: `mix.exs`, `lib/workflow/**`, `test/workflow/**`.
- Codex plugin guidance: `plugins/codex-loops`.
- Docs: `docs`.

## License

MIT. See [LICENSE](LICENSE).
