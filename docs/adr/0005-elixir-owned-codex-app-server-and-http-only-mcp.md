# ADR 0005: Elixir-Owned Codex App Server and HTTP-Only MCP

## Status

Superseded by ADR 0006. The Elixir-owned lazy app-server decision was carried
forward there; the native HTTP-only MCP adapter was not.

## Context

The packaged scheduler already owns one supervised Phoenix endpoint, but live
provider execution crossed the native boundary again. Every agent attempt
started `codex exec --json` through the Rust control plane's private
`provider-exec` command. Independently, every valid MCP tool call ran native
scheduler discovery and startup before making its HTTP request.

That split gave one stdio adapter three unrelated responsibilities: MCP
protocol adaptation, scheduler process management, and provider process
indirection. It also paid process startup and initialization cost for every
agent attempt.

Symphony's Elixir implementation demonstrates the useful ownership rule:
Phoenix is one child in the OTP application, while the process that speaks the
Codex app-server protocol owns its Port and protocol session. Its app-server
client performs `initialize`, `thread/start`, and `turn/start`, keeps the Port
alive for continuation turns, and closes it with the owning worker. Codex Loops
has a different workload shape: several runs may execute concurrently, so a
per-worker session is replaced here by one scheduler-wide, multiplexed
connection.

## Decision

The Elixir release owns both long-lived server resources:

- `Workflow.Web.Endpoint` remains the single HTTP application server.
- A supervised `Workflow.Provider.Codex.AppServer` owns one lazily started
  Codex app-server Port for the scheduler release.

The app-server owner launches the configured, installation-pinned command with
`app-server`. The current private `provider-exec` command remains only as an
`exec(2)` binding guard; after launch, Elixir owns and monitors the resulting
Codex process. Changing the installed binding requires an explicit scheduler
restart.

The connection is a protocol router, not a turn worker. It allocates unique
request IDs, correlates requests and notifications by thread and turn IDs, and
forwards each turn's messages to the calling provider process. The provider
process folds activity and invokes the journal activity sink, so SQLite latency
cannot block Port input handling.

Admission is global to the scheduler: at most eight active turns share the
app-server and the pending queue is bounded. Caller monitors remove abandoned
work. Approval, permission, input, elicitation, and dynamic-tool requests are
handled non-interactively and fail closed. Turn timeouts interrupt only the
affected turn.

The Rust MCP command is an HTTP adapter. It resolves local workflow paths,
enforces the shared-filesystem boundary, verifies the scheduler health/version
over HTTP, calls the requested `scheduler.v1` endpoint, and returns the MCP
envelope. It does not start, stop, restart, lock, or supervise scheduler
processes. An unavailable endpoint tells the operator to start it explicitly.
Native CLI commands retain explicit lifecycle management for `run`, `serve`,
`stop`, `restart`, sandbox proofs, and local operations.

Start and path-bearing resume requests carry a canonical workspace root. The
scheduler verifies that the canonical script is contained by that root,
persists the root in `run_started`, and restores it on resume. Codex receives
that directory as its per-turn `cwd` rather than inheriting the native runtime
directory.

## Failure semantics

The durable `agent_started` event remains the boundary for paid effects.

- Failure before a turn request is sent or admitted is a normal unavailable or
  backend provider failure.
- Admission itself has a bounded five-second deadline. Because a timed-out
  `GenServer.call` may already be in the owner's mailbox, its outcome is unknown;
  an ordered cancellation removes late queued work, but the attempt is not
  redelivered.
- Loss of the shared app-server after `turn/start` is sent is ambiguous. The
  caller exits without settling the attempt; writer supervision records or
  later resume derives `outcome_unknown`. The attempt is never redelivered.
- A configured turn deadline sends `turn/interrupt` for that turn and settles
  it as a timeout.
- A Port failure wakes every pending caller. Calls whose turn was not sent may
  fail normally; in-flight turns preserve the ambiguous-outcome rule.

Mock runs and scheduler health do not require eagerly starting Codex. This
keeps application boot and offline validation independent of credentials while
making the first live attempt responsible for lazy initialization errors.

## Consequences

- Agent turns reuse one initialized Codex process, and concurrent runs have one
  enforceable admission boundary.
- OTP owns the Port and protocol state; the native MCP session can connect and
  disconnect without changing scheduler lifecycle.
- The shared process is a larger failure domain, so correlation, caller death,
  line-size limits, and ambiguous-outcome behavior are required correctness
  properties rather than optional robustness.
- Explicit CLI lifecycle remains available, but MCP callers must arrange for a
  compatible scheduler to be running.
- Runtime and operations proofs must start the scheduler before exercising MCP
  tools and prove that MCP creates no native owner state.
