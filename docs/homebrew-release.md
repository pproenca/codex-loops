# Homebrew Distribution Adapter

GitHub release bundles are the canonical Codex Loops artifacts. Homebrew must be
a thin installer for the exact published target archive; it must not rebuild or
reconstruct the Rust/OTP bundle independently.

## Publish The Canonical Artifact

```sh
make ci
MINISIGN_SECRET_KEY=/path/to/key make dist
```

`make dist` writes a target-specific archive and SHA-256 file under
`_build/dist/`. The command requires `MINISIGN_SECRET_KEY` and writes a minisign
signature; an unsigned canonical artifact cannot be produced. Publish the
archive, checksum, and signature on the matching GitHub release tag.

## Tap/Cask Contract

The external tap should:

1. Select the GitHub archive matching the host target.
2. Verify the published SHA-256 (and minisign signature when supported).
3. Run the archive's `install` command (or reproduce its exact versioned layout).
4. Expose the installer-owned stable `codex-loops` symlink.
5. Preserve old versioned bundles until their schedulers have stopped.

The package must not create a `codex-loops-mcp` alias, inject runtime-root
environment variables, build an OTP release, or install a marketplace plugin.

After installation the user runs:

```sh
codex-loops install --codex /absolute/path/to/codex
```

The command owns direct MCP registration, the user skill, and the exact Codex
binding. A package-manager upgrade changes only the stable bundle symlink; the
user reruns `codex-loops install` to converge Codex configuration and the skill.

## Adapter Proof

From a clean test prefix:

```sh
codex-loops --version
codex-loops install --dry-run --codex /path/to/hermetic-codex --json
```

The product repository's `make ci` remains authoritative for scheduler health,
workflow validation, MCP initialization/tools, lifecycle, and conformance.
