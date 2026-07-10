# Homebrew Release

The following user install path is planned but not published yet:

```sh
brew install pproenca/codex-loops/codex-loops
codex-loops install
```

The product repository builds the runtime; the separate
`pproenca/homebrew-codex-loops` tap publishes the formula and bottles.

## Prepare

1. Run `make ci`.
2. Tag the exact product commit as `v<VERSION>` and publish its GitHub source
   archive.
3. Calculate the source archive SHA-256.
4. Render the tap formula:

```sh
mix run --no-start scripts/render-homebrew-formula.exs \
  "$(cat VERSION)" "$SOURCE_SHA256" /path/to/homebrew-codex-loops/Formula/codex-loops.rb
```

## Prove The Formula

Run these checks from the tap checkout on Apple Silicon macOS:

```sh
brew audit --strict --new --online pproenca/codex-loops/codex-loops
brew install --build-from-source --build-bottle pproenca/codex-loops/codex-loops
brew test pproenca/codex-loops/codex-loops
brew linkage --test pproenca/codex-loops/codex-loops
brew bottle --json pproenca/codex-loops/codex-loops
```

Publish the reviewed bottle and update the formula's `bottle do` checksums.
Then uninstall the source build and prove the bottle path:

```sh
brew uninstall codex-loops
brew install pproenca/codex-loops/codex-loops
codex-loops --version
codex-loops install --dry-run --json
```

The formula test is intentionally Codex-login-free. It checks both command
versions, scheduler health/version, workflow validation, MCP initialize and
tools/list, and clean scheduler shutdown.

## Publish

After the bottle proof passes:

1. Run `codex-loops install` in a disposable `CODEX_HOME` proof environment.
2. Confirm an idempotent rerun and `codex-loops install --check` both succeed.
3. Complete an authenticated workflow from a new Codex thread using the brewed
   runtime and release-pinned plugin.
4. Record the product tag, tap commit, bottle SHA, runtime/plugin version, run
   id, and UI URL in the release notes.
