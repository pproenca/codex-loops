# ADR 0001: MCP and CLI Packaging Libraries

## Status

Accepted

## Context

Codex Loops currently exposes its MCP server through a small shell wrapper that
finds the packaged `agent_loops` Mix release and runs:

```sh
agent_loops eval 'Workflow.MCP.Stdio.main(["--stdio"])'
```

This works, and `eval` is supported by Mix releases, but it is a release
maintenance command rather than a polished product entrypoint. The MCP protocol
handling is also hand-rolled in `Workflow.MCP.Stdio`, which increases the cost of
tracking MCP protocol changes.

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

- The current shell wrapper plus `agent_loops eval ...` path should be treated as
  a transitional implementation.
- The future `codex-loops-mcp --stdio` entrypoint should be a real executable,
  not a shell wrapper around release `eval`.
- The scheduler can remain a Mix release unless a later packaging decision folds
  scheduler and MCP entrypoint into one executable.
- `anubis_mcp` is LGPL-3.0. Before public binary distribution, confirm this
  license is acceptable for the plugin and Homebrew packaging model. If it is
  not acceptable, reopen this ADR and evaluate `hermes_mcp` as the MIT-licensed
  fallback.
- Do not add these dependencies without migrating the entrypoint/protocol code
  and preserving the existing MCP proof suite (`make proof-mcp` and
  `make proof-mcp-live`).
