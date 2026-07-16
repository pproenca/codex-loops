# Codex Loops Documentation

Codex Loops is a local, path-first workflow scheduler distributed as one
immutable Elixir/Phoenix OTP release. The release owns installation and
user-service coordination, a stateless Streamable HTTP MCP endpoint at `/mcp`,
one lazily started shared Codex app-server, workflow workers, the SQLite
journal, PubSub, and LiveView. Codex connects directly to `/mcp`; there is no
Rust runtime, stdio bridge, or second application server.

## Canonical Subdocs

- `docs/runtime.md`: runtime architecture, bundle, journal, and providers.
- `docs/workflow-authoring.md`: executable `.exs` workflows and testing gates.
- `docs/operations.md`: development, installation, proofs, and release work.
- `docs/plans/reactor-execution-refactor.md`: implementation, rollback, and
  live-verification plan for adopting Reactor as the internal execution engine.
- `docs/adr/`: accepted and superseded architecture decisions.
- `docs/adr/0006-single-otp-service-and-streamable-http-mcp.md`: current
  deployment and ownership decision; it supersedes ADRs 0003 through 0005.

## Quick Start

```sh
make dev-bundle
make ci
MINISIGN_SECRET_KEY=/path/to/key make dist
```

For an end-user install, verify and unpack the matching signed archive, then
run its single reconciliation action:

```sh
./install
```

It installs the immutable bundle and skill, binds the exact `codex` command,
provisions and starts the user service, verifies health, and registers
`http://127.0.0.1:47125/mcp` in Codex. Pass
`--codex /absolute/path/to/codex` only when PATH should not select the binding.

`make dev-bundle` assembles the same fixed layout used by production archives.
`make dist` emits one target-specific archive plus checksum and required
minisign signature; it fails without a signing key. Release CI collects all
four supported target triples, then `make homebrew-formula` validates every
archive checksum and emits one formula that selects the correct host archive.

## Supported Scope

- explicit path-first Elixir workflow scripts;
- offline mock and live Codex provider runs;
- SQLite-backed status, inspect, and resume projections;
- MCP validate/start/status/inspect/resume/open-UI tools;
- Phoenix API polling and realtime LiveView;
- one self-contained OTP release and one installer-owned login service.

Not currently shipped: workflow draft scaffolding, hosted workflow services,
retained isolated scheduler environments, and per-agent skip controls.
