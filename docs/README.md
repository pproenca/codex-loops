# Codex Loops

Codex Loops is the local, path-first workflow runner for Codex. The current
runtime is Elixir-based: workflow scripts are `.exs` files, run state is an
append-only SQLite journal, and the distributable scheduler artifact is the
`agent_loops` Mix release with a compatible `agent-loops` CLI wrapper.

## Canonical Subdocs

- `docs/cli.md`: command surface, JSON output, exit codes, release proofs.
- `docs/runtime.md`: architecture, journal model, packaging, providers.
- `docs/workflow-authoring.md`: `.exs` workflow authoring and testing gate.
- `docs/operations.md`: setup, build, release, proof, live proof.
- `docs/schemas.md`: legacy schema notes.

## Quick Start

```sh
make setup
make test
make release
make proof
_build/prod/rel/agent_loops/bin/agent_loops
```

## Supported Scope

Supported:

- explicit path-first Elixir workflow scripts;
- offline mock tests;
- live Codex provider runs via `codex exec --json`;
- SQLite-backed `status`, `inspect`, `list`, and `resume`;
- scheduler API and run LiveView;
- self-contained Mix release packaging.

Not currently shipped in the Elixir CLI:

- workflow draft scaffolding;
- background launch;
- hosted workflow services;
- per-agent skip controls.
