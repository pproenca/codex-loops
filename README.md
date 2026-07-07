# Codex Loops

Codex Loops is a local, path-first workflow runner for Codex. The Elixir runtime
executes deterministic `.exs` workflow scripts, records each run in a SQLite
journal, and exposes `validate`, `test`, `run`, `resume`, `status`, `inspect`,
and `list` through the `agent-loops` CLI.

## Quick Start

```sh
make setup
make test
make release
```

The distributable CLI is built at:

```sh
_build/prod/rel/agent_loops/bin/agent-loops help
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

Run it offline with the mock provider:

```sh
agent-loops validate .codex/workflows/audit_workflow.exs --json
agent-loops test .codex/workflows/audit_workflow.exs --run-id run_audit --json
agent-loops status --run-id run_audit --json
```

Run it live through the installed Codex CLI:

```sh
agent-loops run .codex/workflows/audit_workflow.exs \
  --run-id run_audit_live \
  --provider codex \
  --json
```

## Development Commands

```sh
make setup       # install Hex/Rebar deps, Elixir deps, and Node workspace deps when pnpm exists
make build       # compile with warnings as errors
make test        # run the Elixir test suite
make release     # build the self-contained Mix release
make proof       # build release and run packaged validate/test/status/inspect
make proof-live  # build release and spend one real Codex provider turn
```

The repository includes `.tool-versions` for `mise`/`asdf` users.

## Runtime Data

Runs are stored in SQLite at `~/.codex/workflows/runs_1.sqlite` by default.
Set `CODEX_LOOPS_JOURNAL_PATH=/path/to/runs.sqlite` to isolate a run, test, or
proof.

## Packages

- Elixir runtime: `mix.exs`, `lib/workflow/**`, `test/workflow/**`.
- Codex plugin guidance: `plugins/codex-loops`.
- Legacy Node packages: `apps/runtime` and `apps/status-ui`.
- Docs: `docs`.

## License

MIT. See [LICENSE](LICENSE).
