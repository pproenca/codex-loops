# Codex Loops

Codex Loops is the local, path-first workflow scheduler for Codex. The current
product architecture is a Codex plugin with a native Rust CLI/MCP control plane
plus a packaged Elixir/Phoenix scheduler. Rust manages OS-process lifecycle and
tool calls through the scheduler HTTP interface; Elixir owns OTP supervision,
workflow workers, Phoenix PubSub/LiveView, and the SQLite journal.

The distributable scheduler artifact is the `agent_loops` Mix release. The user
CLI and MCP adapter are modes of the native `codex-loops` binary.

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
`make release` builds the scheduler; `make native-build` builds the control
plane. `make package-homebrew-runtime` stages both as the distributable layout.

## Supported Scope

Supported:

- explicit path-first Elixir workflow scripts;
- offline mock tests;
- live Codex provider runs via `codex exec --json`;
- SQLite-backed scheduler projections for status, inspect, and resume;
- Codex-facing MCP tools for validate/start/status/inspect/resume/open UI;
- scheduler API polling snapshots, journal inspection, and realtime run LiveView;
- native CLI/MCP plus self-contained Mix scheduler release packaging.

Not currently shipped in the scheduler/plugin product:

- workflow draft scaffolding;
- automatic launch at OS login;
- hosted workflow services;
- per-agent skip controls.
