# Codex Loops

Codex Loops is a local, path-first workflow runner for Codex. The Elixir runtime
executes deterministic `.exs` workflow scripts, records each run in a SQLite
journal, and packages the local Phoenix workflow scheduler/API/UI as the
`agent_loops` Mix release. The release keeps the compatible `agent-loops` CLI
wrapper for `validate`, `test`, `run`, `resume`, `status`, `inspect`, and `list`.

## Quick Start

```sh
make setup
make test
make release
make proof
```

The distributable scheduler release is built at:

```sh
_build/prod/rel/agent_loops/bin/agent_loops
```

`make proof` is the production readiness path: it starts the packaged scheduler
on an isolated local port and journal, checks health, validates a workflow
through the API, starts a mock run through the API, reads status/events through
the API, and fetches the run UI.

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
make test        # run the Elixir scheduler/API/UI test suite
make release     # build the self-contained scheduler Mix release
make proof       # build release and prove scheduler API/UI readiness
make proof-live  # build release and spend one real Codex provider turn
```

The repository includes `.tool-versions` for `mise`/`asdf` users.

## Runtime Data

Runs are stored in SQLite at `~/.codex/workflows/runs_1.sqlite` by default.
Set `CODEX_LOOPS_JOURNAL_PATH=/path/to/runs.sqlite` to isolate a run, test, or
proof.

For local release proofs, set `CODEX_LOOPS_PROOF_HOST`,
`CODEX_LOOPS_PROOF_PORT`, or `CODEX_LOOPS_PROOF_JOURNAL_PATH` to override the
default `127.0.0.1:47125` proof server and temporary journal.

## Packages

- Elixir runtime: `mix.exs`, `lib/workflow/**`, `test/workflow/**`.
- Codex plugin guidance: `plugins/codex-loops`.
- Legacy Node packages: `apps/runtime` and `apps/status-ui`.
- Docs: `docs`.

## License

MIT. See [LICENSE](LICENSE).
