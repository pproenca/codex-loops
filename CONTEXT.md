# Codex Loops

Codex Loops coordinates local workflow runs for Codex. This language keeps durable run history, realtime progress, provider protocol data, and UI projections distinct.

## Language

**Journal event**:
A durable fact about a workflow run, stored in the run journal and folded to replay, resume, project, or account for the run.
_Avoid_: realtime event, progress event, PubSub event

**Commit notification**:
A transient PubSub delivery sent only after a journal append succeeds. It tells
live surfaces to refold the journal; it never carries authority or state that is
absent from SQLite.
_Avoid_: progress event, durable event, activity event

**Activity entry**:
A normalized provider progress item for an agent attempt, such as lifecycle, tool, reasoning, warning, or assistant-output activity.
_Avoid_: raw Codex event, journal event

**Agent settlement**:
The authoritative outcome of a paid agent attempt: committed, rejected, or failed.
_Avoid_: provider result event, final progress message

**Agent start marker**:
A durable `agent_started` journal event written before a provider call. A start
without a matching settlement makes the paid effect unknowable; it is never
redelivered and resume terminates with `outcome_unknown`.
_Avoid_: provider request receipt, exactly-once guarantee

**At-most-once provider effect**:
The scheduler invokes an attempt only after its start marker is durable and never
redelivers an unsettled attempt. A crash may leave the outcome unknown, but cannot
make the scheduler silently spend the same attempt again.
_Avoid_: exactly-once result, backend idempotency guarantee

**Bounded orchestration**:
The closed runtime limits retries to 5, loop iterations to 1000, resolved fanout
width to 64, and concurrent workflow tasks to 8. Compatibility loop/fan-out
syntax lowers to the generic bounded core.
_Avoid_: unbounded retry, unlimited fanout, runtime-specific legacy semantics

**Codex event**:
A raw JSON object emitted by `codex exec --json`; it is provider protocol input before Codex Loops normalizes it.
_Avoid_: journal event, activity entry

**Run projection**:
A read model derived from journal events, plus scheduler runtime facts where needed for lifecycle affordances.
_Avoid_: run state, writer state

**Raw ref**:
A client-safe pointer to a journal event, usually sequence, type, and address; it is not the raw journal payload.
_Avoid_: raw event, raw payload

**Install command**:
A user-invoked reconciliation operation that persists the exact Codex binding,
installs the user skill, and directly registers the runtime's MCP command.
_Avoid_: plugin postinstall hook, automatic dependency install

**Plugin lifecycle**:
Optional Codex-owned installation, enablement, and update state for the
skill-only presentation plugin; it never owns or discovers the runtime.
_Avoid_: runtime installation, MCP registration, bundled executable

**Runtime bundle**:
A target-specific, immutable Codex Loops directory containing the native
control plane, OTP scheduler release, and user skill at fixed relative paths.
_Avoid_: runtime root search, Homebrew runtime, source runtime

**Codex binding**:
The persisted lexical absolute path and exact probed version of the Codex CLI
selected during `codex-loops install`; scheduler turns never rediscover it.
_Avoid_: Codex discovery, inherited Codex path, PATH fallback
