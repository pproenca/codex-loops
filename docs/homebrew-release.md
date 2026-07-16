# Homebrew Distribution Adapter

GitHub release bundles are the canonical Codex Loops artifacts. Homebrew must be
a thin installer for the exact published target archive; it must not rebuild or
reconstruct the OTP release independently.

## Publish The Canonical Artifact

```sh
make ci
# Run locally for the host target.
MINISIGN_SECRET_KEY=/path/to/key make dist
make verify-dist

# After collecting all four target artifact triples under DIST_DIR.
make homebrew-formula DIST_DIR=/path/to/collected-artifacts
```

`make dist` writes a target-specific archive and SHA-256 file under
`_build/dist/`. The command requires `MINISIGN_SECRET_KEY` and writes a minisign
signature; an unsigned canonical artifact cannot be produced. Run that signed
step for `aarch64-apple-darwin`, `x86_64-apple-darwin`,
`aarch64-unknown-linux-gnu`, and `x86_64-unknown-linux-gnu`, then collect each
archive, `.sha256`, and `.minisig` file into one directory.

The `Release Matrix` GitHub Actions workflow is the canonical native build
gate. It runs on `macos-15`, `macos-15-intel`, `ubuntu-24.04-arm`, and
`ubuntu-24.04`, asserts the detected target, boots the packaged release, proves
the one-action installer, signs the archive, verifies its signature/checksum
and fixed layout, and aggregates all four triples into one formula. Pull
requests and `master` use per-job ephemeral keys. A `v*` tag or a manual run
with `canonical=true` fails unless the `MINISIGN_SECRET_KEY` Actions secret is
present and derives the committed `release/minisign.pub` identity.

`make homebrew-formula` is the deterministic aggregation step. It requires all
four immutable triples, verifies each archive against its recorded checksum,
and emits one `codex-loops.rb` whose macOS/Linux and ARM/Intel branches each
carry their own release URL and SHA-256. Publish all four triples on the
matching GitHub release tag and copy the generated adapter into the tap. The
formula installs the selected archive unchanged beneath Homebrew's versioned
Cellar and delegates product reconciliation to `codex-loops install` from
`post_install`.

## Tap/Cask Contract

The external tap should:

1. Select one of the four GitHub archives matching the host OS and architecture.
2. Verify the published SHA-256 (and minisign signature when supported).
3. Run the installed `codex-loops install` reconciliation from `post_install`
   so the same `brew install` action binds Codex, installs the skill, provisions
   and starts the user service, verifies health and MCP, and registers the
   Streamable HTTP URL.
4. Preserve the archive's immutable layout and Homebrew-owned stable command.
5. Keep old versioned bundles until no service process references them.

The package must not create a `codex-loops-mcp` alias, inject runtime-root
environment variables, build an OTP release, install a marketplace plugin, or
substitute its own service/MCP configuration.

The resulting Homebrew user action is complete when it returns; there is no
second `codex-loops install` step. The canonical installer defaults to `codex`
on PATH and also accepts an explicit lexical path when the adapter provides one:

```sh
./install --codex /absolute/path/to/codex
```

The installer owns the exact Codex binding, user skill, login service, health
gate, and direct registration of `http://127.0.0.1:47125/mcp`. An upgrade runs
the same reconciliation after atomically activating the new immutable bundle.

## Adapter Proof

From a clean test prefix:

```sh
codex-loops --version
codex-loops check --json
codex-loops status --json
codex mcp get codex-loops --json
```

The product repository's `make ci` remains authoritative for scheduler health,
one-action installation, user-service lifecycle, workflow validation, direct
Streamable HTTP MCP initialization/tools, and conformance.
