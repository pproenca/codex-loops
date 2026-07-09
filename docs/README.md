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
make setup
make quality
make release
make proof
make proof-mcp
make proof-mcp-live
test -x _build/prod/rel/agent_loops/bin/agent_loops
```

`make quality` is the fast local gate for formatting, compile, spec lint, and
the scheduler/API/UI test suite. The proof commands remain the packaged product
readiness checks.

## Supported Scope

Supported:

- explicit path-first Elixir workflow scripts;
- offline mock tests;
- live Codex provider runs via `codex exec --json`;
- SQLite-backed scheduler projections for status, inspect, and resume;
- Codex-facing MCP tools for validate/start/status/inspect/resume/open UI;
- scheduler API and run LiveView;
- self-contained Mix release packaging.

Not currently shipped in the scheduler/plugin product:

- workflow draft scaffolding;
- background launch;
- hosted workflow services;
- per-agent skip controls.
