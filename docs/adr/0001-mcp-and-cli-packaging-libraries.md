# ADR 0001: MCP and CLI Packaging Libraries

## Status

Accepted

## Context

Codex Loops originally exposed its MCP server through a small shell wrapper that
found the packaged `agent_loops` Mix release and ran:

```sh
agent_loops eval 'Workflow.MCP.Stdio.main(["--stdio"])'
```

That worked, and `eval` is supported by Mix releases, but it is a release
maintenance command rather than a polished product entrypoint. The original MCP
protocol handling was also hand-rolled, which increased the cost of tracking MCP
protocol changes.

## Decision

Use `anubis_mcp` for the MCP protocol/runtime layer and `burrito` for the
standalone executable packaging layer.

- MCP dependency target: `{:anubis_mcp, "~> 1.6"}`
- CLI packaging dependency target: `{:burrito, "~> 1.5"}`

`anubis_mcp` is the preferred MCP library because it is actively maintained,
has current releases, supports MCP server implementations, and includes stdio
transport support. `burrito` is the preferred packaging tool because it produces
self-contained single-file Elixir executables for macOS, Linux, and Windows.

## Consequences

- The shell wrapper plus `agent_loops eval ...` path was a transitional
  implementation and is no longer part of the supported product path.
- The `codex-loops-mcp --stdio` entrypoint is a real Burrito executable, not a
  shell wrapper around release `eval`.
- The scheduler can remain a Mix release unless a later packaging decision folds
  scheduler and MCP entrypoint into one executable.
- `anubis_mcp` is LGPL-3.0. Before public binary distribution, confirm this
  license is acceptable for the plugin and Homebrew packaging model. If it is
  not acceptable, reopen this ADR and evaluate `hermes_mcp` as the MIT-licensed
  fallback.
- Keep the Anubis/Burrito product path covered by the MCP proof suite
  (`make proof-mcp` and `make proof-mcp-live`).

## Distribution Gate

The `anubis_mcp` LGPL-3.0 gate is accepted for the current local plugin and
Homebrew-oriented distribution model. Codex Loops may ship the packaged
Burrito MCP executable with Anubis included, provided distribution artifacts
carry the dependency's license notice and source location. If that packaging
model becomes unacceptable for public distribution, reopen this ADR and replace
the MCP layer with the MIT-licensed `hermes_mcp` fallback.
