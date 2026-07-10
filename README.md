# Codex Loops

Codex Loops is a local, path-first workflow scheduler for Codex. The product
surface is a Codex plugin with an Elixir MCP adapter plus a packaged
Elixir/Phoenix scheduler. MCP manages local lifecycle and tool calls; Elixir
owns runtime supervision, workflow workers, Phoenix PubSub/LiveView, and the
SQLite journal.

The packaged `agent_loops` Mix release owns the scheduler, the user CLI, and the
MCP stdio command. The Codex plugin is source-only and discovers that runtime
through Homebrew.

## Install

The release install path is:

```sh
brew install pproenca/codex-loops/codex-loops
codex-loops install
```

The tap is published as a separate release step. Until the first public formula
is published, use the development path below.

## Development

```sh
make build
make ci
make release
```

`make build` installs missing build dependencies and compiles with warnings as
errors. `make ci` is the complete deterministic gate: formatting, audits,
Credo, Sobelow, the full Elixir suite, Dialyzer, browser LiveView E2E, plugin
validation, packaged release/API/CLI proof, and packaged MCP conformance across
the documented workflow variants. `make release` produces the distributable
self-contained runtime.

## Run From The CLI

The normal manual path has no required configuration:

```sh
codex-loops run .codex/workflows/codex_answer.exs --open
```

`run` starts the managed local scheduler when needed, validates the script,
generates a run ID, uses the live Codex provider, prints the LiveView URL, and
opens it when `--open` is present. The scheduler defaults to
`http://127.0.0.1:47125` and `~/.codex/workflows/runs_1.sqlite`. Stop it later
with:

```sh
codex-loops stop
```

Customize only when needed:

```sh
codex-loops serve --port 48100 --journal /tmp/loops.sqlite --model gpt-5.5
codex-loops run workflow.exs --provider mock --run-id dry-run --server http://127.0.0.1:48100
```

The CI gate is credential-free and does not spend a Codex turn. Real-provider
smokes are maintainer-run diagnostics; the same provider protocol and streaming
path are covered deterministically in `make ci` with the schema-aware Codex
subprocess fixture.

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
workflow_open_ui run_id=run_audit_live
```

`workflow_status` is a polling snapshot. Use `workflow_open_ui` to watch
realtime progress activity in LiveView; use `workflow_inspect` for durable
journal summaries and raw refs.

## Development Commands

```sh
make build    # compile from a clean checkout
make ci       # run the entire deterministic validation stack end-to-end
make release  # build the self-contained distributable runtime
```

The narrower Make targets are implementation details used by `make ci`; normal
contributors should not need to compose them manually.

The repository includes `.tool-versions` for `mise`/`asdf` users. The release
contains the scheduler, user CLI, and MCP command in one ERTS payload; no Zig or
XZ toolchain is required.

## Runtime Data

Runs are stored in SQLite at `~/.codex/workflows/runs_1.sqlite` by default.
Set `CODEX_LOOPS_JOURNAL_PATH=/path/to/runs.sqlite` to isolate a run, test, or
proof.

For local release proofs, set `CODEX_LOOPS_PROOF_HOST`,
`CODEX_LOOPS_PROOF_PORT`, or `CODEX_LOOPS_PROOF_JOURNAL_PATH` to override the
default `127.0.0.1:47125` proof server and temporary journal.

The MCP adapter uses `CODEX_LOOPS_RUNTIME_ROOT`, `CODEX_LOOPS_SCHEDULER_HOST`,
`CODEX_LOOPS_SCHEDULER_PORT`, `CODEX_LOOPS_SCHEDULER_URL`, and
`CODEX_LOOPS_SCHEDULER_BIN` when you need to point it at a specific local
scheduler. The plugin launcher resolves the Homebrew runtime and sets
`CODEX_LOOPS_RUNTIME_ROOT` plus `CODEX_LOOPS_SCHEDULER_BIN` before starting MCP.
Source-tree fallback requires an explicit `CODEX_LOOPS_REPO_ROOT`.

## Packages

- Elixir runtime: `mix.exs`, `lib/workflow/**`, `test/workflow/**`.
- Codex plugin guidance: `plugins/codex-loops`.
- Docs: `docs`.

## License

MIT. See [LICENSE](LICENSE).
