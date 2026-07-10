# Codex Loops Documentation

Codex Loops is a local, path-first workflow scheduler distributed as one
immutable runtime bundle. Its native Rust control plane owns installation,
stdio MCP, scheduler HTTP translation, and OS-process lifecycle. Its packaged
Elixir/Phoenix scheduler owns OTP supervision, workflow workers, the SQLite
journal, PubSub, and LiveView.

## Canonical Subdocs

- `docs/runtime.md`: runtime architecture, bundle, journal, and providers.
- `docs/workflow-authoring.md`: executable `.exs` workflows and testing gates.
- `docs/operations.md`: development, installation, proofs, and release work.
- `docs/adr/`: accepted and superseded architecture decisions.

## Quick Start

```sh
make dev-bundle
_build/dev-bundle/bin/codex-loops install --codex "$(command -v codex)"
make ci
make dist
```

`make dev-bundle` assembles the same fixed layout used by production archives.
`make dist` emits one target-specific archive plus checksum and optional
minisign signature.

## Supported Scope

- explicit path-first Elixir workflow scripts;
- offline mock and live Codex provider runs;
- SQLite-backed status, inspect, and resume projections;
- MCP validate/start/status/inspect/resume/open-UI tools;
- Phoenix API polling and realtime LiveView;
- one native control-plane command plus one self-contained OTP scheduler release.

Not currently shipped: workflow draft scaffolding, OS-login launch, hosted
workflow services, and per-agent skip controls.
