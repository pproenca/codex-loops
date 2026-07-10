# Codex Loops

Codex Loops coordinates local workflow runs for Codex. This language keeps durable run history, realtime progress, provider protocol data, and UI projections distinct.

## Language

**Journal event**:
A durable fact about a workflow run, stored in the run journal and folded to replay, resume, project, or account for the run.
_Avoid_: realtime event, progress event, PubSub event

**Progress message**:
A transient PubSub delivery about work happening now, used by live surfaces and subscribers but not authoritative for replay or resume.
_Avoid_: journal event, durable event

**Activity entry**:
A normalized provider progress item for an agent attempt, such as lifecycle, tool, reasoning, warning, or assistant-output activity.
_Avoid_: raw Codex event, journal event

**Agent settlement**:
The authoritative outcome of a paid agent attempt: committed, rejected, or failed.
_Avoid_: provider result event, final progress message

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
A user-invoked Codex Loops setup operation that installs or enables the Codex plugin and verifies the local runtime is available.
_Avoid_: plugin postinstall hook, automatic dependency install

**Plugin lifecycle**:
Codex-owned installation, enablement, and update state for the Codex Loops plugin, separate from the Homebrew-owned runtime package.
_Avoid_: bundled plugin copy, Homebrew-owned plugin update

**Runtime bundle**:
A target-specific, immutable Codex Loops directory containing the native
control plane, OTP scheduler release, and user skill at fixed relative paths.
_Avoid_: runtime root search, Homebrew runtime, source runtime

**Codex binding**:
The persisted lexical absolute path and exact probed version of the Codex CLI
selected during `codex-loops install`; scheduler turns never rediscover it.
_Avoid_: Codex discovery, inherited Codex path, PATH fallback
