# ADR 0003: Native Control Plane and Elixir Scheduler

> Partially superseded by ADR 0005: MCP no longer performs implicit scheduler
> lifecycle management. Explicit native CLI lifecycle commands remain accepted.

## Status

Accepted. Supersedes ADR 0002 and the Anubis decision in ADR 0001.

## Context

Codex Loops has two unlike workloads. Workflow execution, journal ownership,
provider concurrency, PubSub, and LiveView are long-lived supervised work. CLI
commands and MCP stdio adaptation are latency-sensitive local control-plane
work. Putting both inside release `eval` made every command boot a BEAM and made
an ephemeral MCP session the owner of a durable scheduler process.

## Decision

Ship two target-specific artifacts in one Homebrew package:

- One Rust binary, installed as `codex-loops` and `codex-loops-mcp`, owns CLI
  parsing, installation, stdio MCP through the official `rmcp` SDK, scheduler
  discovery/start/stop, health checks, and scheduler HTTP translation.
- One `agent_loops` Mix release owns the workflow DSL/compiler, providers,
  journal, run supervision, Phoenix API, PubSub, and LiveView.

The scheduler HTTP `scheduler.v1` interface is the deployment seam. The native
binary does not read SQLite or call scheduler internals. A durable native
per-user supervisor is the only scheduler process owner. MCP sessions do not
own the scheduler and never stop it during stdio cleanup; an explicit user
command owns shutdown. The supervisor retains an exclusive per-endpoint owner
lock, commits owner metadata transactionally, and restarts unexpected scheduler
exits with bounded backoff. Supervisor identity and effective lifecycle
configuration persist across child generations; a failed initial health
deadline tears down the owner for an immediate corrected retry. Concurrent
starters use an owner token and must match the winning bind/journal/model
configuration before joining. Health alone never completes ownership handoff:
the supervisor must still hold the endpoint lock when readiness is returned.
Explicit URL configuration is a separate externally owned mode: it requires a
compatible health envelope, never creates local ownership state, and delegates
lifecycle commands to the external process manager.

## Consequences

- One-shot commands no longer boot a BEAM.
- MCP no longer consumes a second BEAM or couples runs to a client connection.
- The package now has Rust and Elixir build toolchains, hidden from normal users
  by Homebrew bottles.
- Rust and Elixir compatibility is enforced by the package version and the
  scheduler health envelope.
- MCP conformance, release/API/CLI proof, and plugin-launcher discovery remain
  package release gates.
