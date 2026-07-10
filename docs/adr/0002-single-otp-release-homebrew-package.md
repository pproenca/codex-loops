# ADR 0002: Single OTP Release Homebrew Package

## Status

Superseded by ADR 0003.

## Context

Codex Loops needs a scheduler process and an MCP stdio command. The earlier
package built a normal Mix release for the scheduler and a second
Burrito-wrapped Mix release for MCP. That duplicated ERTS and application code,
added Zig and XZ to the build, and made the source plugin carry generated
runtime artifacts.

Homebrew already owns a target-specific runtime tree under `libexec`. A
single-file self-extracting archive does not add value inside that package.
Mix release commands also preserve trailing arguments in `System.argv/0`, so
small release overlays can expose normal user and MCP commands without a second
application boot mode.

## Decision

Ship one target-specific OTP release named `agent_loops` with ERTS included.
The release explicitly includes Anubis in loaded state and provides two overlay
commands:

- `codex-loops` calls `Workflow.CLI.main(System.argv())` through release `eval`.
- `codex-loops-mcp` calls `Workflow.MCP.AnubisStdio.main(System.argv())` through
  release `eval`.

The Homebrew package stages this layout:

```text
libexec/scheduler/                 # complete agent_loops release
libexec/mcp/codex-loops-mcp        # stable MCP command
libexec/bin/codex-loops            # stable user command
```

The Codex marketplace plugin is source-only. Its tracked launcher discovers the
Homebrew runtime, verifies exact package-version compatibility, and executes the
MCP command. Production discovery never treats the plugin directory as a
runtime root.

## Consequences

- ERTS and application code are packaged once.
- Burrito, Zig, XZ, Burrito extraction caches, and the MCP-only OTP application
  branch are removed.
- `make release-mcp` remains as a compatibility alias for the MCP command in the
  single release.
- `make package-homebrew-runtime` is the non-mutating formula input.
- Mix releases remain target-specific; bottles must be built on each supported
  Homebrew target and include all NIFs for that target.
- Formula source builds require Elixir/Erlang. Runtime dependencies are derived
  from bottle linkage rather than copied from the build toolchain.
