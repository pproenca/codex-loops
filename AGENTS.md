# AGENTS.md

This file provides guidance to coding agents when working with code in this repository.

## What this is

Codex Loops is a local, path-first workflow scheduler for Codex. The product
surface is one packaged Elixir/Phoenix OTP release plus an optional skill-only
plugin. The release owns installation reconciliation, user-service lifecycle,
the Streamable HTTP MCP endpoint at `/mcp`, one lazily started shared Codex
app-server, workflow workers, Phoenix PubSub/LiveView, and the SQLite journal.
There is no Rust runtime or separate MCP client process.

## Layout

- `lib/workflow/**` — Elixir scheduler, workflow DSL/compiler, providers,
  journal, installation/service coordination, MCP, Phoenix API, and LiveView UI.
- `test/workflow/**` — scheduler/API/UI test suite.
- `plugins/codex-loops` — optional Codex plugin exposing only the
  `codex-loops` skill; the installer registers the release's `/mcp` URL directly.
- `docs` — canonical runtime, authoring, and operations docs.

## Commands

```sh
make build
make ci
make dev-bundle
make dist
```

`make ci` is the complete deterministic gate: quality, full Elixir tests,
Dialyzer, browser E2E, release/API/service proof, and direct Streamable HTTP MCP
conformance. Live Codex proofs remain manual because they require credentials
and spend a turn.

## Runtime Model

- Runs persist in SQLite at `~/.codex/workflows/runs_1.sqlite` unless
  `CODEX_LOOPS_JOURNAL_PATH` is set.
- Codex connects directly to `http://127.0.0.1:47125/mcp` with Streamable HTTP.
  The Phoenix endpoint dispatches tools into the scheduler context; there is no
  stdio bridge, loopback HTTP adapter, or MCP-owned scheduler lifecycle.
- The archive's `./install` action installs the immutable release and skill,
  persists the exact Codex binding, provisions and starts a per-user service,
  health-checks it, and registers the `/mcp` URL.
- One supervised Elixir process owns and multiplexes the scheduler-wide Codex
  app-server connection. Provider activity is folded by callers, outside that
  protocol owner's mailbox.
- A supervised per-run writer process walks the compiled workflow tree, invokes
  the selected provider, synchronously commits ordered journal events, and only
  then publishes post-commit refresh notifications.
- Phoenix LiveView renders journal-backed scheduler projections.
- Provider attempts are at-most-once: an unsettled durable `agent_started` is
  never redelivered, and resume terminates it as `outcome_unknown`.
- Agent retries are capped at 5, loop iterations at 1000, resolved fanout width
  at 64, active runs at eight, and per-run concurrency at eight tasks. Legacy
  `while_budget`, `until_dry`, and `fan_out` syntax lowers to generic
  `loop`/`fanout` semantics.

## Workflow Scripts

Author executable workflows as Elixir `.exs` files containing exactly one bare,
top-level `workflow "name" do ... end` declaration. The scheduler parses the
declaration as inert data; workflow files do not define modules or use macros.
Agents should validate and mock-run through the MCP tools before live execution:

```text
workflow_validate script_path=.codex/workflows/<name>.exs workspace_root=/absolute/path/to/repo
workflow_start    script_path=.codex/workflows/<name>.exs workspace_root=/absolute/path/to/repo run_id=<id> provider=mock
workflow_status   run_id=<id>
workflow_inspect  run_id=<id>
workflow_open_ui  run_id=<id>
```

Relative MCP script paths require an explicit absolute `workspace_root`.
Absolute `script_path` values may omit it.

## Agent skills

### Issue tracker

Issues live in the repo's GitHub Issues (`gh` CLI, repo `pproenca/codex-loops`). External PRs are a triage surface. See `docs/agents/issue-tracker.md`.

### Triage labels

Canonical label vocabulary — `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.
