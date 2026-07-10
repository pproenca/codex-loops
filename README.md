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
make setup
make quality
make release
make proof
```

`make quality` is the fast pre-handoff gate. It checks formatting, compiles
with warnings as errors, runs the spec lint, and runs the Elixir
scheduler/API/UI test suite. It does not build release artifacts or run MCP
product proofs.

After `make release`, verify the distributable scheduler release with:

```sh
test -x _build/prod/rel/agent_loops/bin/agent_loops
```

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

`make proof` is the production readiness path: it starts the packaged scheduler
on an isolated local port and journal, checks health, validates a workflow
through the API, starts a mock run through the API, reads the polling status
snapshot and journal summaries through the API, and fetches the LiveView run UI.
It also starts a second run through the packaged `codex-loops run` command and
checks that command's reported LiveView URL.

For the Codex-facing product path against a source-only plugin and an external
Homebrew-style runtime:

```sh
make proof-mcp       # source plugin, external runtime, lifecycle, mock run, status, inspect, resume, open UI
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
workflow_open_ui run_id=run_audit_live
```

`workflow_status` is a polling snapshot. Use `workflow_open_ui` to watch
realtime progress activity in LiveView; use `workflow_inspect` for durable
journal summaries and raw refs.

## Development Commands

```sh
make setup        # install Hex/Rebar and Elixir deps
make format-check # check mix formatting without rewriting files
make quality      # fast pre-handoff gate: format, compile, spec lint, tests
make audit-check  # scan dependency advisories and retired Hex packages
make credo-check  # run maintainability linting
make security-check # run Sobelow against the Phoenix API/UI surface
make dialyzer-check # optional Dialyzer analysis; may build PLTs
make browser-e2e-setup # install Playwright's Node package and Chromium
make browser-e2e # run tagged PhoenixTest Playwright browser tests
make build        # compile with warnings as errors
make test         # run the Elixir scheduler/API/UI test suite
make release      # build the self-contained scheduler Mix release
make release-mcp  # compatibility alias: verify MCP in the single release
make package-homebrew-runtime # stage the formula-owned libexec tree
make proof        # build release and prove scheduler API/UI readiness
make proof-mcp    # prove source-plugin MCP lifecycle against the staged runtime
make dogfood      # prove MCP, reinstall the local plugin, and print the fresh-thread prompt
make proof-live   # alias for proof-mcp-live; spends one real Codex provider turn through MCP
```

Use `make proof`, `make proof-mcp`, and `make proof-live` for packaged product
readiness. They remain separate from the fast `make quality` loop.

The quality stack is `mix format` plus Styler, Credo, Sobelow, Hex/MixAudit,
and the existing ExUnit suite. Dialyzer is available through
`make dialyzer-check` as an explicit opt-in gate. Browser E2E uses PhoenixTest
with PhoenixTest Playwright and remains separate from the fast local loop.
Install its Node/browser dependencies with `make browser-e2e-setup`.

The repository includes `.tool-versions` for `mise`/`asdf` users.

`make package-homebrew-runtime` builds one target-specific OTP release and
stages `_build/homebrew/libexec/{scheduler,mcp,bin}` without changing the Codex
plugin. `make release-mcp` remains usable, but now verifies the MCP command in
that same release. No Zig or XZ toolchain is required.

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
