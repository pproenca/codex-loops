# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Codex Loops is a local, event-sourced, path-first dynamic workflow runner for Codex. The runner executes deterministic workflow scripts, spawns mock- or SDK-backed agent turns, and records every run in an append-only journal. All read surfaces (`status`, `inspect`, `list`, `resume`, `serve`) are pure folds/projections over that journal — never independent state.

## Monorepo layout (pnpm workspace, Node ≥24)

- `apps/runtime` — npm package `agent-loops`, CLI binary `agent-loops`. The core runner. Publishable.
- `apps/status-ui` — npm package `agent-loops-ui`, standalone read-only status UI (Vite + React 19 + TanStack). Its built assets are copied into the runtime's `dist/status-ui` at publish time (`scripts/publish-status-ui.mjs`).
- `plugins/codex-loops` — thin Codex plugin exposing one `codex-loops` skill. Owns *when/how to use* the runner, not runner behavior.
- `docs` — canonical usage/runtime docs (`cli.md`, `runtime.md`, `workflow-authoring.md`, `operations.md`, `schemas.md`).

## Commands

Root (runs both packages):
```sh
pnpm install
pnpm run check          # typecheck + help-drift + boundary + tests, both packages
pnpm run test           # tests only, both packages
pnpm run pack:packages  # dry-run pack both publishable packages
```

Runtime package (`apps/runtime`, most work happens here):
```sh
pnpm -C apps/runtime check       # typecheck + help:check + boundary + test
pnpm -C apps/runtime test        # builds, then: node --test tests/*.test.ts
pnpm -C apps/runtime typecheck   # tsc --noEmit
pnpm -C apps/runtime boundary    # architecture boundary linter (see below) — RUN AFTER ANY src/ CHANGE
pnpm -C apps/runtime gen-help    # regenerate the README command block from cli-spec
pnpm -C apps/runtime build       # esbuild bundle to dist/ (also builds + embeds status-ui)
```

Run a single test file:
```sh
pnpm -C apps/runtime build && node --test apps/runtime/tests/core.test.ts
```

Status UI (`apps/status-ui`): `pnpm -C apps/status-ui dev|build|typecheck|test`.

## Architecture: strict layered runtime (the thing to understand first)

`apps/runtime/src` is a hexagonal design with a **mechanically enforced trust/effect split**. Layer rules live in `apps/runtime/scripts/check-boundaries.mjs` and are enforced by `pnpm run boundary` (part of `check`). Understand the layers before editing, because the linter will reject imports and even language constructs that violate them:

- `domain/` — pure types, branding (`Proven`), JSON contracts. Imports nothing else.
- `trust/` — the **only** layer that parses untrusted input (CLI args, child protocol lines, provider events, journal JSON) and mints `Proven` values. Only layer allowed to use `zod`, `JSON.parse`, `typeof`, `instanceof`, `in`, `Array.isArray`, type assertions, non-null assertions, `??`, parameter defaults, and `acorn` (only in `trust/workflow-script.ts`).
- `core/` — pure folds over event streams and decisions. No I/O, no `Date`, no `process`.
- `ports/` — port interfaces between core and adapters.
- `consistency/` — the **only** layer that writes SQLite (commits, idempotency, run leases, serve sessions) and the only layer allowed to import `fs`.
- `containment/` — the **only** layer allowed to spawn subprocesses (`child_process`) and the only place SDK calls may run, always wrapped in `runContainedAgentTurn`.
- `effects/` — process/fs-read/status-server/SDK/preparation adapters. **Only** layer that may import `@openai/codex-sdk`, and it must route every SDK call through `containment`'s `runContainedAgentTurn`.
- `app/` — wires ports together and assembles CLI/API envelopes.
- entry (`cli.ts`, `index.ts`) — composition roots.

Consequences worth internalizing:
- Need to parse/validate something? It belongs in `trust/`. Other layers cannot use `JSON.parse`/`instanceof`/etc. — the linter blocks them.
- `node:vm` is banned outright; workflow execution must cross a real process boundary (`containment/workflow-child-process.ts`, embedded `WORKFLOW_CHILD_SOURCE` string that has its own linter checks).
- `Date`, `Math.random`, `fetch`, `setTimeout` are only allowed at effect/consistency/containment/entry rims — core stays deterministic.
- After changing `src/`, run `pnpm -C apps/runtime boundary` (or full `check`); violations print as `file:line:col: message`.
- `tsnuke.config.json` lists lint rules intentionally ignored — do not "fix" code to satisfy those; they are suppressed on purpose.

## Journal & run model (source of truth)

- Runs persist in SQLite at `~/.codex/workflows/runs_1.sqlite` (storage schema version is in the filename). Committed events are `agent-loops/journal@2` JSON rows keyed by `(run_id, seq)`. There are **no** filesystem run journals or aux run-state files.
- Tables: `metadata` (incl. `latest_run_id`), `runs`, `events`, `idempotency_keys`, `mutations`, `run_locks` (live-writer leases), `serve_sessions`.
- Run selection: `test`/`workflow`/`run` create a run (use `--run-id` or a generated id). `status`/`inspect`/`resume`/`serve` select via `--run-id`, else `metadata.latest_run_id`. `--journal` is rejected everywhere.
- One live writer per run via a `run_locks` lease inside `BEGIN IMMEDIATE`; heartbeat + pid probe drive stale detection; `resume` can take over a stale lease.
- Snapshots are `workflow-snapshot/v2` — pure projections, never embed script text (reference by `scriptPath` + `scriptSha256`), and always carry `runtimeContract`.
- Programmatic exports from the package are exactly `workflow` and `testWorkflow` (`src/index.ts`).

## Workflow scripts (what the runner executes)

- Path-first only: resolved from an explicit path, `.codex/workflows`, or `~/.codex/workflows`. Inline script text is not accepted.
- Deterministic plain JavaScript; first statement must be a pure-literal `export const meta = {...}` (`name`, `description` required). Scripts cannot import modules, touch fs/process, or spawn shells; `Date`/`Math.random` throw inside them.
- `validate` runs an acorn AST gate (rustc-style findings) and the same gate runs before every execution path. `test --provider mock` before any live `--provider sdk` run.
- Schema-backed `agent()` calls use provider structured output and **fail closed**: invalid/unparseable output retries on-thread up to the retry limit, then fails the node (exit 8).

## JSON/CLI discipline

- With `--json`, stdout carries exactly one final payload and every envelope has a `command` field. Failures print a single-line JSON error object as the last stderr line (`code` ∈ `usage|provider-config|validation|malformed-output|killed|runtime`).
- Exit codes: 0 ok, 2 usage, 4 provider config, 6 validation/budget, 8 malformed structured output, 130 killed, 1 otherwise.
- The README command block is generated — after changing the CLI surface, run `gen-help` and keep `help:check` green.

## Conventions

- ESM everywhere, `.ts` extensions in relative imports, no semicolon-heavy style (match surrounding code).
- The runtime bundles to a single `dist/` via esbuild; `@openai/codex-sdk` is the only externalized runtime dependency.

## Agent skills

### Issue tracker

Issues live in the repo's GitHub Issues (`gh` CLI, repo `pproenca/codex-loops`). External PRs are not a triage surface. See `docs/agents/issue-tracker.md`.

### Triage labels

Canonical label vocabulary — `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.
