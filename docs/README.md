# Codex Loops

## Sources
Sources:
- `apps/runtime/README.md`
- `plugins/codex-loops/README.md`
- `plugins/codex-loops/SPEC.md`
- `plugins/codex-loops/skills/codex-loops/SKILL.md`

## Overview
Codex Loops is the local, path-first dynamic workflow runner for Codex. The
runner executes deterministic workflow scripts, spawns mock or SDK-backed agent
turns, and records the run in an append-only journal. Read surfaces such as
`status`, `inspect`, `list`, `resume`, and `serve` are folds over that journal.

The plugin is intentionally thin. The app package owns runner behavior; the
plugin skill teaches when to use it, how to write compatible scripts, and how to
run validation or mock-test gates before live SDK execution.

## Canonical Subdocs
- `docs/cli.md`: command surface, JSON output, exit codes, and help
  drift checks.
- `docs/runtime.md`: architecture, journal model, projections,
  resume, sandbox, and unsupported runtime scope.
- `docs/workflow-authoring.md`: scout-first authoring, DSL rules,
  barrier versus pipeline guidance, mutation posture, and testing gate.
- `docs/operations.md`: preflight, mock tests, live runs,
  background runs, status, inspect, serve, resume, and artifacts.
- `docs/schemas.md`: public JSON schema catalog.

## Supported Scope
Supported:
- path-first workflow scripts from explicit paths, `.codex/workflows`, or
  `~/.codex/workflows`;
- local background launch;
- optional local status UI pages from `npx -y agent-loops-ui <journal.jsonl>`;
- mock provider tests;
- live execution through the TypeScript `@openai/codex-sdk` package;
- journal-backed resume and inspection.

Unsupported in this package:
- hosted workflow services;
- external workflow UIs;
- per-agent skip or retry controls;
- inline script execution.

## Quick Start
```sh
npx -y agent-loops draft --goal 'Audit auth boundaries' --name auth-audit --json
npx -y agent-loops validate auth-audit --args '{"scope":"auth"}' --json --no-input
npx -y agent-loops test auth-audit --args '{"scope":"auth"}' --provider mock --budget small --json --no-input
npx -y agent-loops workflow auth-audit --args '{"scope":"auth"}' --provider sdk --approved --json --no-input
npx -y agent-loops status --json
```

Run live SDK workflows only after validation or mock testing and explicit
approval.

## Contract Summary
- `run` is an alias for `workflow`.
- `draft` writes a deterministic scaffold and runs the compatibility validation
  gate; it does not perform live execution.
- Workflow scripts must begin with pure-literal `export const meta = {...}`.
- Schema-backed `agent()` calls use provider structured output and fail closed.
- Snapshots are projections of the journal and include `runtimeContract`.
- Programmatic exports are exactly `workflow` and `testWorkflow`.
