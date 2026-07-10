# Codex Loops

Codex Loops is the local, path-first workflow scheduler for Codex. The current
product architecture is a Codex plugin with an Elixir MCP adapter plus a
packaged Elixir/Phoenix scheduler. MCP manages local lifecycle and tool calls;
Elixir owns runtime supervision, workflow workers, Phoenix PubSub/LiveView, and
the SQLite journal.

The distributable scheduler artifact is the `agent_loops` Mix release. The old
`agent-loops` CLI surface has been removed; Codex and agents use MCP tools.

## Canonical Subdocs

- `docs/runtime.md`: architecture, journal model, packaging, providers.
- `docs/workflow-authoring.md`: `.exs` workflow authoring and testing gate.
- `docs/operations.md`: setup, build, release, proof, live proof.
- `docs/adr/`: accepted architecture and packaging decisions.

## Quick Start

```sh
make build
make ci
make release
```

`make build` compiles from a clean checkout. `make ci` owns the full
credential-free validation graph, including static analysis, all Elixir tests,
browser E2E, release/API/CLI proof, and packaged MCP workflow conformance.
`make release` builds the distributable runtime.

## Supported Scope

Supported:

- explicit path-first Elixir workflow scripts;
- offline mock tests;
- live Codex provider runs via `codex exec --json`;
- SQLite-backed scheduler projections for status, inspect, and resume;
- Codex-facing MCP tools for validate/start/status/inspect/resume/open UI;
- scheduler API polling snapshots, journal inspection, and realtime run LiveView;
- self-contained Mix release packaging.

Not currently shipped in the scheduler/plugin product:

- workflow draft scaffolding;
- background launch;
- hosted workflow services;
- per-agent skip controls.
