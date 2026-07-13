# Homebrew bottle, release, and proof gates

> **Status: superseded by ADR 0004 for product packaging.** The current release
> gate builds, signs, and proves the immutable runtime bundle through `make dist`;
> the formula/bottle proposal below remains only generic future packaging
> research.

Date: 2026-07-09

Wayfinder ticket: [Specify Homebrew bottle, release, and proof gates](https://github.com/pproenca/codex-loops/issues/117)

## Sources checked

- [Homebrew Formula Cookbook](https://docs.brew.sh/Formula-Cookbook), especially
  formula audit guidance, `libexec` script wrappers, and `test do` expectations.
- [Adding Software to Homebrew](https://docs.brew.sh/Adding-Software-to-Homebrew),
  especially `brew install --build-from-source`, `brew audit --strict --new
  --online`, and `brew test`.
- [How to Create and Maintain a Tap](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap),
  especially generated tap GitHub Actions workflows, bottle publishing, and
  `brew pr-pull --head-sha`.
- [brew(1) manpage](https://docs.brew.sh/Manpage), especially `brew bottle`,
  `brew test`, and `brew test-bot`.
- [BrewTestBot](https://docs.brew.sh/BrewTestBot) and
  [BrewTestBot for Maintainers](https://docs.brew.sh/BrewTestBot-For-Maintainers).
- [GitHub-hosted runners reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
  and [macOS 26 runner announcement](https://github.blog/changelog/2026-02-26-macos-26-is-now-generally-available-for-github-hosted-runners/).
- [Burrito README](https://github.com/burrito-elixir/burrito), especially target
  support and macOS Gatekeeper notes.
- Existing map decisions:
  [Homebrew formula layout and dependency model](./homebrew-formula-layout-dependency-model.md),
  [codex-loops install command contract](./codex-loops-install-command-contract.md),
  and [Brewed runtime discovery for the Codex marketplace plugin](./brewed-runtime-discovery-for-codex-marketplace-plugin.md).
- Local source: `.github/workflows/elixir-ci.yml`, `Makefile`,
  `scripts/proof-release.sh`, `scripts/proof-mcp-validate.exs`,
  `scripts/proof-mcp-live.exs`, `scripts/verify-plugin-package.sh`,
  `scripts/dogfood-plugin.sh`, `.agents/plugins/marketplace.json`, and
  `plugins/codex-loops/.codex-plugin/plugin.json`.

## Decision

Implementation is done only when the Homebrew-first path has a repeatable
Apple Silicon macOS release gate:

```sh
brew install pproenca/codex-loops/codex-loops
codex-loops install
```

The required v1 release artifact is an Apple Silicon macOS bottle from the tap
`pproenca/codex-loops` (`pproenca/homebrew-codex-loops` on GitHub), plus a
source-build fallback proof on the same architecture. Intel macOS and
Linux/Homebrew are expansion checks, not v1 blockers.

The release process should use Homebrew's normal tap machinery instead of a
custom bottle publisher:

1. Product repo tag `vX.Y.Z`.
2. Automation opens or updates a tap PR changing `Formula/codex-loops.rb` to
   that tag and source tarball checksum.
3. Tap CI runs Homebrew's generated `brew test-bot` workflows on Apple Silicon
   macOS.
4. Maintainer publishes bottles with `brew pr-pull --tap=pproenca/codex-loops
   --head-sha=<reviewed-sha> <pr-number>` or the generated `brew pr-pull`
   workflow with the same reviewed SHA.
5. Post-publish smoke installs from the fully qualified formula name and proves
   runtime, plugin setup, MCP mock execution, and docs/package invariants.

## Required Apple Silicon v1 gates

These are release blockers for v1.

| Gate | Where | Required proof |
| --- | --- | --- |
| Product repo CI | Product repo PR and tag | Existing Ubuntu Elixir checks keep passing: format, compile, spec lint, tests. |
| Product packaging smoke | Product repo PR before tap update | `make package-homebrew-runtime` or equivalent builds scheduler and MCP artifacts into `_build/prod` without copying generated artifacts into `plugins/codex-loops/`. |
| Source-only plugin package | Product repo PR | `make verify-plugin-package` proves manifests, skills, notices, and the launcher are tracked, and rejects tracked scheduler/MCP binaries. |
| MCP product proof | Product repo PR | `make proof-mcp` runs from a copied source-only plugin plus a temporary Homebrew-like runtime prefix and covers missing-runtime, mismatch, initialize, tools/list, validate, mock start/status/inspect/resume/open-ui, typed errors, and shutdown. |
| Live MCP proof | Manual pre-release or protected workflow | `make proof-mcp-live` uses the same source-only plugin plus Homebrew-like runtime path and spends one real Codex provider turn. Required before declaring the first public v1 stable release; later releases may run it manually when runtime/MCP/provider behavior changes. |
| Formula audit | Tap PR | `brew audit --strict --new --online codex-loops` passes. |
| Formula source build | Tap PR on `macos-26` arm64 | `brew install --build-from-source pproenca/codex-loops/codex-loops` succeeds with only formula-declared dependencies. |
| Formula test | Tap PR and post-publish | `brew test codex-loops` runs the non-interactive runtime test: CLI version, scheduler health, workflow validation, scheduler stop, and MCP initialize/tools-list. |
| Linkage | Tap PR and post-publish | `brew linkage --test codex-loops` passes; any Homebrew-linked runtime library discovered here becomes an explicit formula dependency. |
| Bottle build | Tap PR on `macos-26` arm64 | `brew test-bot` builds a bottle, runs the formula test, and uploads the bottle artifact. |
| Bottle pour | Post-publish on `macos-26` arm64 | Fresh runner installs with `brew install --force-bottle pproenca/codex-loops/codex-loops`, then runs `brew test`, `brew linkage --test`, and `codex-loops --version`. |
| Install command non-live proof | Post-publish on `macos-26` arm64 | With current Codex CLI available and a temporary `CODEX_HOME`, `codex-loops install --json` installs the release-pinned marketplace/plugin, and `codex-loops install --check --json` passes without starting the scheduler or requiring login. |
| Dogfood | Manual release checklist | A new Codex thread uses the installed marketplace plugin and MCP tools to validate, mock-run, poll status, inspect, and open UI for a tiny workflow. |
| Docs package gate | Product repo and tap PR | Docs describe the brewed runtime/plugin boundary; a grep gate fails on stale bundled-runtime install instructions. |

Use the explicit `macos-26` runner label for v1 Apple Silicon automation rather
than `macos-latest`, because GitHub documents that `-latest` labels can move and
may not mean the newest vendor OS. As of this decision, GitHub lists `macos-26`
as a standard arm64 macOS runner, with `macos-26-intel` available for the future
Intel expansion path.

## Tap and bottle workflow

Create the tap with Homebrew's generated structure:

```sh
brew tap-new pproenca/codex-loops
```

The actual GitHub repository is `pproenca/homebrew-codex-loops`, because
Homebrew tap shorthand `pproenca/codex-loops` maps to `homebrew-codex-loops`.
Keep the generated `.github/workflows` unless there is a specific failure. The
Homebrew tap docs say those default workflows build bottles with GitHub Actions,
and the `brew test-bot` manpage describes the full lifecycle gate: clean/setup,
install, checks/tests, bottle build, and dependent checks.

Release automation should not publish bottles directly from the product repo. It
should open a tap PR and let tap CI build bottle artifacts. Publishing happens
after human review of the tap PR, using `brew pr-pull --head-sha` or the
generated workflow's reviewed SHA input so bottle publishing cannot race a
changed PR head.

If the tap later chooses GitHub Packages, make that an explicit tap-maintenance
decision. It is not required for v1; default `brew tap-new` bottle publishing is
the simpler path.

## Formula `test do`

The formula test should stay non-interactive and offline except for loopback
HTTP calls to the scheduler it starts. It must not install Codex, call
`codex-loops install`, require Codex login, or run a live `provider: "codex"`
turn.

Minimum formula test:

1. Set `HOME` and `CODEX_LOOPS_JOURNAL_PATH` under `testpath`.
2. Assert `#{bin}/codex-loops --version` equals the formula version.
3. Assert `#{opt_libexec}/scheduler/bin/agent_loops` is executable.
4. Assert `#{opt_libexec}/mcp/codex-loops-mcp --version` or `--help` exits
   successfully.
5. Start the scheduler release on an isolated loopback port with
   `CODEX_LOOPS_SERVER=1`, `CODEX_LOOPS_HOST=127.0.0.1`, unique
   `RELEASE_NODE`, unique `RELEASE_TMP`, `RELEASE_DISTRIBUTION=none`, and a
   `testpath` journal.
6. Check `GET /api/health` returns `scheduler.v1`, status `ok`, and the package
   version.
7. Write a tiny workflow under `testpath` and validate it through
   `POST /api/workflows/validate`.
8. Run MCP JSON-RPC `initialize` and `tools/list` through the installed
   `codex-loops-mcp --stdio`, using the brewed runtime discovery path.
9. Stop the scheduler and prove the loopback port no longer serves health.

Full mock run, resume, inspect, open-ui, and shutdown remain in `make proof-mcp`
rather than the formula test so `brew test` stays small and deterministic.

## Source-build fallback proof

Source build is not the normal user path, but it is a release blocker because
Homebrew formulae must remain buildable when a bottle is unavailable.

Required Apple Silicon v1 source-build proof:

```sh
brew uninstall --force codex-loops || true
brew install --build-from-source pproenca/codex-loops/codex-loops
brew test codex-loops
brew linkage --test codex-loops
```

This proof must demonstrate that build-only dependencies are correctly scoped:
Elixir, Erlang, Zig 0.15, and XZ may be needed to build, but a normal bottle
pour should not leave users debugging those tools.

## `make` target changes

Add or reshape targets so local and CI proofs match the Homebrew-first model:

| Target | Contract |
| --- | --- |
| `make package-homebrew-runtime` | Build scheduler release and Burrito MCP into `_build/prod/rel/agent_loops` and `_build/prod/mcp/codex-loops-mcp`; do not mutate `plugins/codex-loops/`. |
| `make proof` | Keep scheduler-release API/UI proof from `_build/prod/rel/agent_loops`. |
| `make proof-mcp` | Build/copy artifacts into a temporary `opt/codex-loops/libexec` layout, copy source-only plugin, run launcher and full MCP mock proof. |
| `make proof-mcp-live` | Same external runtime/plugin shape as `proof-mcp`, then run one live Codex provider turn. |
| `make verify-plugin-package` | Enforce source-only plugin package and reject generated runtime payloads. |
| `make proof-homebrew-formula` | In a tap checkout or formula fixture, run audit, source install, test, linkage, and bottle-pour smoke when a bottle artifact exists. |
| `make dogfood` | Use the normal installed formula plus `codex-loops install`; do not call `make proof-mcp` as a substitute for user setup. |

The existing `release` and `release-mcp` targets can survive as lower-level build
targets during migration, but their plugin-copy side effects must be removed
before the Homebrew-first path is considered done.

## Plugin install proof

The post-publish non-live install proof should run on macOS Apple Silicon after
the bottle is available:

```sh
tmp_home="$(mktemp -d)"
export CODEX_HOME="$tmp_home/codex"
export HOME="$tmp_home/home"

brew install --force-bottle pproenca/codex-loops/codex-loops
codex-loops install --json
codex-loops install --check --json
codex plugin marketplace list --json
codex plugin list --json
```

Assertions:

- Marketplace `codex-loops` is `pproenca/codex-loops` pinned to `vX.Y.Z`.
- Plugin `codex-loops@codex-loops` is installed and enabled.
- Plugin manifest version equals brewed runtime version.
- Runtime discovery passes without starting a scheduler.
- Missing Codex and conflicting marketplace/plugin cases have separate unit or
  integration tests and return the exit codes from the install command contract.

This proof may require installing the Codex CLI in CI. It still must not require
Codex login or spend a provider turn.

## Dogfood flow

Keep an explicit manual dogfood checklist because Codex loads plugin
capabilities at thread start and the most important end-to-end proof is a real
new thread using the MCP tools:

1. Start from a clean Codex Loops plugin install in a disposable `CODEX_HOME`.
2. Install with the public commands:
   `brew install pproenca/codex-loops/codex-loops` and `codex-loops install`.
3. Open a new Codex thread.
4. Ask: `Use the codex-loops skill.`
5. Create a tiny workflow under `.codex/workflows/smoke.exs`.
6. Use MCP tools, not shell commands, to validate, start with `provider=mock`,
   poll status, inspect, and open UI.
7. Record the installed runtime version, plugin version, run id, UI URL, and any
   repair notes in the release checklist.

Live dogfood with `provider=codex` is required before the first v1 stable release
and before releases that change provider execution, token folding, MCP lifecycle,
or scheduler supervision. It is not required for every docs-only or formula-only
patch release.

## Documentation gates

Documentation is part of the release gate because stale bundled-plugin
instructions will actively break the install path.

Required updates:

- Root README or install docs: show only the Homebrew-first happy path.
- `docs/runtime.md`: runtime is Homebrew-owned under `libexec`; plugin root is
  not a runtime root.
- `plugins/codex-loops/README.md` and `plugins/codex-loops/SPEC.md`: source-only
  plugin, launcher, runtime discovery, and MCP tool behavior.
- `docs/operations.md` or a new release checklist: release sequence, tap PR,
  bottle publish, post-publish smoke, dogfood.
- `.agents/plugins/marketplace.json`: v1 marketplace source should point at the
  source-only plugin path/repo shape that `codex-loops install` will pin by tag.
- `THIRD_PARTY_NOTICES.md`: keep notices for source plugin and runtime package
  distribution; remove claims that rely on checked-in generated payloads.

Add a grep/check script that fails on stale product docs mentioning the old
bundled runtime as the user-facing path, especially:

- `plugins/codex-loops/scheduler/bin/agent_loops`
- `copied plugin package should include scheduler release`
- `make release` as the user install step
- `codex plugin marketplace add .` outside development/dogfood instructions

## Code signing and notarization boundary

Burrito documents that macOS Gatekeeper needs either a security exemption or
code signing for direct execution of Burrito binaries. For v1, do not add Apple
Developer ID signing or notarization as a planned release gate because the
supported distribution path is Homebrew formula/bottle, not direct browser
download of a standalone app.

Instead, make execution from a poured Apple Silicon bottle the release gate:

- `codex-loops-mcp --version` or `--help` runs.
- MCP `initialize` and `tools/list` run from the installed plugin launcher.
- `make proof-mcp` passes against the Homebrew-like runtime layout.
- Post-publish bottle pour smoke passes on `macos-26` arm64.

If those gates fail because macOS blocks the Burrito executable, create a new
implementation ticket for code signing/notarization. If future releases add
direct GitHub binary downloads outside Homebrew, that distribution path needs
its own signing/notarization decision.

## Future expansion gates

These checks are valuable but not v1 blockers.

| Expansion | Gate |
| --- | --- |
| macOS Intel | Add tap CI on `macos-26-intel`: source build, bottle build, bottle pour, formula test, linkage, plugin install, MCP mock proof. |
| Older Apple Silicon macOS | Add explicit `macos-15` arm64 bottle CI if the product wants a normal bottle path for macOS 15 users instead of source-build fallback. |
| Linux/Homebrew x86_64 | Add Linuxbrew tap CI on `ubuntu-latest`: source build, bottle build if supported, formula test, linkage, runtime-root discovery under `/home/linuxbrew/.linuxbrew`, and MCP mock proof. |
| Linux/Homebrew arm64 | Add only after x86_64 Linuxbrew passes and Burrito target proof is stable. |
| Homebrew Packages or alternate bottle host | Decide root URL, authentication, bottle JSON merge, and post-upload fetch proof separately. |
| Official/curated Codex marketplace | Replace the GitHub marketplace source only after a separate marketplace-source decision. |

## Release checklist

For an Apple Silicon v1 release, the maintainer should be able to check off:

1. Product repo CI is green.
2. Shared package version is `vX.Y.Z` across Mix, plugin manifest, CLI, MCP, and
   scheduler health.
3. Source-only plugin verification is green.
4. `make proof`, `make proof-mcp`, and required `make proof-mcp-live` state are
   green or explicitly waived by the release policy.
5. Product tag `vX.Y.Z` exists.
6. Tap PR updates `Formula/codex-loops.rb` to the tag and checksum.
7. Tap CI audit, source build, formula test, linkage, and bottle build pass on
   `macos-26` arm64.
8. Bottle is published with reviewed `--head-sha`.
9. Fresh post-publish bottle install and plugin install checks pass.
10. Manual new-thread dogfood passes through MCP tools.
11. Docs and marketplace metadata point at the Homebrew-first path.

No new wayfinder ticket is needed from this decision. It unblocks the migration
slicing ticket.
