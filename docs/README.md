# Codex Loops

Codex Loops is the local, path-first workflow runner for Codex. The current
runtime is Elixir-based: workflow scripts are `.exs` files, run state is an
append-only SQLite journal, and the distributable CLI is a Mix release wrapper
named `agent-loops`.

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
_build/prod/rel/agent_loops/bin/agent-loops help
```

## Supported Scope

Supported:

- explicit path-first Elixir workflow scripts;
- offline mock tests;
- live Codex provider runs via `codex exec --json`;
- SQLite-backed `status`, `inspect`, `list`, and `resume`;
- self-contained Mix release packaging.

Not currently shipped in the Elixir CLI:

- workflow draft scaffolding;
- background launch;
- serve/status UI commands;
- hosted workflow services;
- per-agent skip controls.
