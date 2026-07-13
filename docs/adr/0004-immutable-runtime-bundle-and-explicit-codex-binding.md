# ADR 0004: Immutable Runtime Bundle And Explicit Codex Binding

## Status

Superseded by ADR 0006. The immutable-bundle and exact-binding requirements were
carried forward there; the Rust/Elixir ownership split was not.

## Context

Codex Loops previously distributed a source-only plugin whose shell launcher
searched environment overrides, PATH, source checkouts, Homebrew prefixes, and
hard-coded installation locations for a separate runtime. The native lifecycle
code independently discovered the scheduler, while the Elixir provider again
discovered `codex` for every agent turn. A long-lived scheduler could therefore
execute a different or stale Codex CLI from the one used during installation.

The replace-in-place source release also allowed a running BEAM to retain an
unlinked working directory, which made later port creation fail with `:enoent`.

## Decision

Codex Loops ships one immutable, versioned directory bundle:

```text
bin/codex-loops
libexec/scheduler/
share/skills/codex-loops/
share/codex-loops/runtime.json
```

The native control plane derives this root only from its installed executable.
Production code has no Homebrew, source-checkout, PATH, or runtime-root search
fallback. Development uses the same layout through `make dev-bundle`.

`codex-loops install --codex /absolute/path/to/codex` probes the selected Codex
CLI, persists its lexical path and exact version, installs the user skill, and
registers the native `codex-loops mcp` command directly through `codex mcp`.
The binding preserves symlink paths such as mise shims. A missing, moved, or
version-changed command fails closed until installation is rerun.
The bundle's machine-readable runtime manifest declares its package target,
binding model, and required Codex CLI protocol; the user-specific path and
probed version remain persisted outside the immutable artifact.

The native scheduler launcher injects a normalized command tuple pointing back
to the versioned control plane. Its private `provider-exec` boundary reloads and
re-probes the persisted `{path, version}` when the scheduler launches its Codex
app-server, then replaces itself with that exact command. A changed long-lived
mise shim therefore fails as unavailable instead of silently selecting another
Codex. The app-server stays pinned until scheduler restart;
`Workflow.Provider.Codex` trusts the injected tuple and never discovers or
validates commands itself.

The marketplace plugin is optional and skill-only. It neither contains nor
discovers an executable runtime.

`make dist` packages the development bundle as one target-specific archive with
a SHA-256 checksum and required minisign signature. Its installer copies the
archive to `~/.local/share/codex-loops/<version>`, atomically switches `current`,
and exposes `~/.local/bin/codex-loops`. GitHub release archives are the canonical
artifacts; package managers are thin adapters for those exact archives.

## Consequences

- One installation action owns the runtime, MCP registration, skill, and Codex
  binding.
- Runtime and provider failures identify a concrete configured path instead of
  depending on inherited process environment.
- Upgrades install side-by-side versioned bundles and switch a stable command
  link atomically; an active scheduler may finish on its old bundle.
- The plugin launcher, MCP executable alias, marketplace installation state
  machine, and runtime discovery environment variables are deleted.
- Updating the selected Codex CLI requires rerunning `codex-loops install` so
  the provider protocol change is explicit and testable.
- Bundling the Codex CLI itself remains a possible future decision, conditional
  on redistribution and release-security review.
- Replacing native supervision with `launchd` remains a separate macOS-specific
  decision.
