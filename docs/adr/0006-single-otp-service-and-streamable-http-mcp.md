# ADR 0006: Single OTP Service And Streamable HTTP MCP

## Status

Accepted. Supersedes ADR 0003, ADR 0004, and ADR 0005. Those records remain as
historical context; their native control-plane, stdio MCP, and split-lifecycle
decisions are no longer part of the product architecture.

## Context

The native control plane once separated short-lived CLI and stdio MCP work from
the long-lived scheduler. That separation stopped MCP sessions from owning the
scheduler, but it left two implementations, two toolchains, a loopback HTTP
adapter, custom process ownership, and a multi-step installation contract.

Codex can connect to a local Streamable HTTP MCP server directly. Phoenix is
already the scheduler's supervised HTTP server, and the Elixir application
already owns the journal, workflow workers, LiveView, and the one shared Codex
app-server connection. Keeping a native adapter no longer creates an ownership
boundary that the transport requires.

The installation contract must also be one action. Installing files while
leaving service provisioning, Codex binding, skill installation, and MCP
registration for a later command is not a complete install.

## Decision

Ship one target-specific, immutable OTP release. There is no Rust binary or
separate MCP runtime. One supervised `Workflow.Application` owns:

- the Phoenix endpoint for `/mcp`, `/api`, and LiveView;
- the scheduler, journal, run supervision, PubSub, and projections; and
- one lazily initialized, scheduler-wide Codex app-server Port.

`POST /mcp` implements stateless JSON-response Streamable HTTP. Codex registers
the URL `http://127.0.0.1:47125/mcp` and connects to the scheduler directly.
The transport creates no MCP session process, SSE stream, or stdio subprocess;
disconnecting a client does not affect application lifecycle. MCP tool dispatch
enters the same scheduler context as the JSON API rather than calling back over
loopback HTTP.

The immutable bundle contains the release-overlay `bin/codex-loops`, the full
release under `libexec/scheduler`, the skill, and the runtime manifest. The
overlay exposes installation reconciliation and explicit service operations;
it does not hide a second runtime.

The release archive's `./install` is the one-action installation boundary. It
installs and activates the immutable version, invokes `codex-loops install`,
persists the selected Codex CLI's lexical absolute path and exact probed
version, installs the skill, provisions and starts the login service, verifies
health, and registers the `/mcp` URL. PATH selects Codex by default; an explicit
`--codex /absolute/path/to/codex` overrides it. macOS uses a user LaunchAgent and
Linux uses a `systemd --user` unit.

The binding is revalidated before the lazy app-server starts. A moved command
or changed version fails closed until installation is reconciled again. Mock
runs and MCP health do not start the Codex app-server.

The shared transport does not retain one subscription per completed run. Each
turn starts a fresh ephemeral Codex thread, and terminal, failed, interrupted,
or cancelled work explicitly releases it with `thread/unsubscribe`. If release
cannot be confirmed, the owner lets unrelated in-flight turns settle and then
retires the Port before admitting queued work on a fresh connection. This makes
connection reuse bounded without allowing one failed cleanup to cancel another
paid turn.

Codex keeps successfully unsubscribed threads loaded for an idle grace period.
The owner therefore retires the shared Port after 64 released threads, again
only after unrelated in-flight turns settle. A fresh Port then serves queued
work. This preserves a single app-server process at a time while placing a hard
bound on connection-local idle thread retention.

The run DynamicSupervisor admits at most eight live writers. Admission beyond
that bound returns a typed capacity error and does not create a journal index
entry, so HTTP request or legacy MCP batch cardinality cannot determine live
process fan-out.

Relative MCP `script_path` values require an explicit absolute, existing
`workspace_root`. The scheduler joins and canonicalizes the path, rejects
symlink escapes, persists the canonical root with the run, and uses it as the
Codex turn working directory. Absolute script paths may omit the root; a
provided root is still a containment boundary.

There is no supported `sandbox-run` mode that launches a second scheduler or
app-server. Tests and operators may launch the packaged release with isolated
configuration, but the product model remains one service and one application
server per installation.

## Failure Semantics

The durable `agent_started` marker remains the at-most-once boundary for paid
provider effects. Loss of the shared app-server after a turn is sent is
ambiguous; the attempt is not redelivered and resume terminates it as
`outcome_unknown`. Transport disconnection is unrelated to provider ownership
and cannot settle, retry, or cancel a run.

## Consequences

- The production build, archive, and runtime require only Elixir/OTP and the
  frontend asset toolchain; Cargo and the Rust SDK are removed.
- Codex talks directly to the scheduler, eliminating stdio protocol adaptation
  and duplicate HTTP envelopes.
- One login service owns process lifetime and restarts independently of Codex
  connections.
- Installation and upgrade reconciliation have one public entrypoint:
  archive `./install`.
- The shared Phoenix endpoint is a single failure and security boundary, so
  loopback binding, Origin checks, body limits, and bounded MCP request handling
  are required.
- ADRs 0003 through 0005 remain useful research records but must not be used as
  current operational guidance.
