# AGENTS.md

This file provides guidance to coding agents when working with code in this repository.

## What this is

Codex Loops is a local, path-first workflow scheduler for Codex. The product
surface is a Codex plugin with an Elixir MCP adapter plus a packaged
Elixir/Phoenix scheduler. MCP manages local lifecycle and tool calls; Elixir
owns runtime supervision, workflow workers, Phoenix PubSub/LiveView, and the
SQLite journal.

## Layout

- `lib/workflow/**` — Elixir scheduler, workflow DSL/compiler, providers,
  journal, MCP adapter, Phoenix API, and LiveView UI.
- `test/workflow/**` — scheduler/API/UI test suite.
- `plugins/codex-loops` — Codex plugin exposing one `codex-loops` skill plus
  the local MCP entrypoint.
- `docs` — canonical runtime, authoring, and operations docs.

## Commands

```sh
make build
make ci
make release
```

`make ci` is the complete deterministic gate: quality, full Elixir tests,
Dialyzer, browser E2E, release/API/CLI proof, and packaged MCP conformance. Live
Codex proofs remain manual because they require credentials and spend a turn.

## Runtime Model

- Runs persist in SQLite at `~/.codex/workflows/runs_1.sqlite` unless
  `CODEX_LOOPS_JOURNAL_PATH` is set.
- MCP tools call the scheduler HTTP API. They do not read SQLite or call
  scheduler internals directly.
- A supervised per-run writer process walks the compiled workflow tree, invokes
  the selected provider, commits ordered journal events, and publishes updates.
- Phoenix LiveView renders journal-backed scheduler projections.

## Workflow Scripts

Author executable workflows as Elixir `.exs` files using `use Workflow`.
Agents should validate and mock-run through the MCP tools before live execution:

```text
workflow_validate script_path=.codex/workflows/<name>.exs
workflow_start    script_path=.codex/workflows/<name>.exs run_id=<id> provider=mock
workflow_status   run_id=<id>
workflow_inspect  run_id=<id>
workflow_open_ui  run_id=<id>
```

## Agent skills

### Issue tracker

Issues live in the repo's GitHub Issues (`gh` CLI, repo `pproenca/codex-loops`). External PRs are a triage surface. See `docs/agents/issue-tracker.md`.

### Triage labels

Canonical label vocabulary — `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.
