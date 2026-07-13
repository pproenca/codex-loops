# Homebrew-first migration slices

> **Status: superseded by ADR 0004.** The migration completed through a different
> end state: a self-locating immutable bundle, direct MCP registration, and an
> optional skill-only plugin. The slice plan below is historical.

Date: 2026-07-09

Wayfinder ticket: [Plan migration slices for the Homebrew-first installer](https://github.com/pproenca/codex-loops/issues/118)

## Decision

Migrate proof-harness-first.

Do not begin by deleting the checked-in plugin runtime payload. First add the
shared version spine, non-mutating Homebrew-like package target, and
external-runtime proof harness while the current bundled plugin path still
works. Then flip the plugin to source-only runtime discovery, remove generated
payloads in a dedicated slice, add the brewed install command, and only then
publish the public tap/formula path.

This order keeps every PR reviewable and gives a clear rollback point before the
destructive bundled-runtime deletion.

## Slice order

### 1. Add one package version spine

Goal: make strict runtime/plugin compatibility enforceable.

Implementation shape:

- Introduce one package version source for the Mix project, scheduler release,
  MCP release, plugin manifest, and CLI.
- Expose the version through `codex-loops --version`,
  `codex-loops-mcp --version`, MCP `initialize.serverInfo.version`, and
  scheduler `GET /api/health`.
- Keep the current bundled plugin runtime working.

Blocks:

- Source-only launcher version checks.
- `codex-loops install --check` compatibility checks.
- Formula `test do` version assertions.

Rollback:

- Revert the version-source change; bundled runtime behavior should still work.

Docs/proof updates:

- Note in developer docs that plugin/runtime equality is now the package
  compatibility rule.
- Add tests for every version-reporting surface.

### 2. Add a non-mutating Homebrew runtime package target

Goal: produce the formula-owned runtime layout without writing into
`plugins/codex-loops/`.

Implementation shape:

- Add `make package-homebrew-runtime`.
- Build the scheduler release at `_build/prod/rel/agent_loops`.
- Build the Burrito MCP executable at `_build/prod/mcp/codex-loops-mcp`.
- Stage, or at least verify, the intended Homebrew layout:
  `libexec/scheduler/bin/agent_loops` and
  `libexec/mcp/codex-loops-mcp`.
- Keep existing `make release` and `make release-mcp` behavior available during
  the transition.

Blocks:

- External-runtime MCP proof.
- Tap/formula source-build implementation.

Rollback:

- Revert the new target. The current plugin-copy release targets remain the
  release path.

Docs/proof updates:

- Add target help/comments in the Makefile or release docs.
- Product CI should run this target before any public formula work begins.

### 3. Add the external-runtime MCP proof fixture

Goal: prove a source-only plugin can use a Homebrew-like runtime before the real
plugin payload is removed.

Implementation shape:

- Rework `make proof-mcp` and `make proof-mcp-live` to create a temporary
  `opt/codex-loops/libexec` runtime layout from the package target.
- Copy a source-only plugin fixture into a temporary installed-plugin root.
- Exercise missing-runtime, mismatch, initialize, tools/list, validate, mock
  start/status/inspect/resume/open-ui, typed errors, and shutdown.
- Let `make verify-plugin-package` temporarily support both the current bundled
  package and the source-only fixture, or add a separate source-only verifier.

Blocks:

- Deleting the checked-in scheduler and MCP payloads.
- Public tap/formula release gates.

Rollback:

- Revert the proof fixture while keeping the old bundled-plugin proof path.

Docs/proof updates:

- Update proof docs to distinguish bundled-plugin transition proof from the
  Homebrew-like runtime proof.
- Do not update user install docs yet.

### 4. Implement launcher and runtime discovery without deleting payloads

Goal: make the new runtime boundary executable while preserving the old package
as fallback during review.

Implementation shape:

- Add the tracked source launcher that will become
  `plugins/codex-loops/mcp/codex-loops-mcp`.
- In tests or fixtures, have that launcher resolve
  `CODEX_LOOPS_MCP_BIN`, `CODEX_LOOPS_RUNTIME_ROOT`, `codex-loops-mcp` on
  `PATH`, `brew --prefix codex-loops`, and default macOS opt prefixes.
- Update `Workflow.MCP.BurritoEnvironment` so a real MCP binary under
  `runtime_root/mcp/` infers `CODEX_LOOPS_RUNTIME_ROOT`.
- Update `Workflow.MCP.Lifecycle` to prefer `CODEX_LOOPS_SCHEDULER_BIN`,
  `CODEX_LOOPS_RUNTIME_ROOT`, and Burrito runtime-root inference.
- Gate source-tree fallback behind explicit development configuration; do not
  infer production runtime paths from the plugin root.

Blocks:

- Source-only plugin deletion.
- `codex-loops install --check` discovery verification.

Rollback:

- Revert the discovery changes and launcher fixture; current plugin-root
  scheduler discovery remains intact until the deletion slice lands.

Docs/proof updates:

- Document the launcher discovery order for contributors.
- Update MCP lifecycle tests to cover runtime-root discovery and explicit dev
  fallback.

### 5. Switch the plugin package to source-only

Goal: remove generated runtime artifacts from the marketplace plugin in one
reviewable destructive slice.

Implementation shape:

- Replace the checked-in plugin MCP binary with the tiny tracked launcher.
- Delete tracked generated runtime payloads under
  `plugins/codex-loops/scheduler/**`.
- Ensure no generated Burrito executable remains tracked under
  `plugins/codex-loops/mcp/**`.
- Flip `make verify-plugin-package` to reject scheduler releases, ERTS payloads,
  and generated MCP binaries in the plugin tree.
- Keep `.mcp.json` pointed at `./mcp/codex-loops-mcp`.

Blocks:

- Public marketplace source package.
- Tap/formula install path.

Rollback:

- Revert this slice to restore the bundled plugin runtime. Earlier package and
  proof harness slices can stay because they are additive.

Docs/proof updates:

- Update `plugins/codex-loops/README.md`, `plugins/codex-loops/SPEC.md`, and
  `THIRD_PARTY_NOTICES.md` for source-only plugin distribution.
- Add stale-instruction grep coverage for bundled scheduler paths.

### 6. Add `codex-loops install --check` and `--dry-run`

Goal: land the brewed CLI contract before the public formula depends on it.

Implementation shape:

- Add the `codex-loops` CLI artifact or script that the formula will expose.
- Implement `--version`, `install --check`, `install --dry-run`, `--json`, and
  `--verbose` for runtime discovery and bounded preflight checks.
- Verify runtime files, launcher discovery, strict version equality, and Codex
  CLI capability without mutating Codex plugin state.
- Return the stable v1 exit codes from the install-command contract.

Blocks:

- Marketplace/plugin reconciliation.
- Public tap/formula PR.

Rollback:

- Revert the CLI slice; the runtime and source-only plugin proofs remain useful
  but the public install flow is not advertised.

Docs/proof updates:

- Add CLI unit/integration tests with temporary `HOME` and `CODEX_HOME`.
- Document `codex-loops install --check` as the v1 doctor boundary.

### 7. Add Codex marketplace/plugin reconciliation

Goal: make the second command in the promised install flow real.

Implementation shape:

- Implement `codex-loops install` reconciliation for the current GitHub
  marketplace source `pproenca/codex-loops`, pinned to the brewed release tag.
- Add missing-Codex and incompatible-Codex preflights.
- Repair only Codex Loops-owned marketplace/plugin state.
- Fail closed on conflicting marketplace or plugin ownership.
- Leave broad rollback to idempotent reruns, as specified by the install-command
  contract.

Blocks:

- Public tap/formula PR.
- Post-publish non-live install proof.

Rollback:

- Revert this slice; keep `install --check` and runtime proofs in place, but do
  not publish the public flow.

Docs/proof updates:

- Add non-live install proof with temporary `CODEX_HOME`.
- Keep user docs draft-only until the tap/formula slice lands.

### 8. Add tap/formula and Homebrew proof automation

Goal: ship the public `brew install pproenca/codex-loops/codex-loops` runtime
path only after the installer command works.

Implementation shape:

- Create or update tap repo `pproenca/homebrew-codex-loops` with
  `Formula/codex-loops.rb`.
- Formula builds from tagged source, installs runtime under `libexec`, exposes
  `bin/codex-loops`, and does not install the Codex plugin.
- Add `make proof-homebrew-formula` or equivalent tap-check instructions.
- Run formula audit, source build, formula test, linkage, bottle build, bottle
  pour, and post-publish install proof on Apple Silicon macOS.

Blocks:

- Public v1 release announcement.
- Final dogfood checklist.

Rollback:

- Revert the tap PR or do not publish the bottle. The product repo remains able
  to build and prove the Homebrew-like runtime locally.

Docs/proof updates:

- Add release checklist covering tag, tap PR, reviewed bottle publish, bottle
  pour, non-live install proof, and dogfood.
- Document that `brew install` is runtime-only and `codex-loops install` owns
  Codex plugin reconciliation.

### 9. Flip public docs and dogfood gates

Goal: make the Homebrew-first path the documented product path after the public
formula is real.

Implementation shape:

- Update root install docs to show only:
  `brew install pproenca/codex-loops/codex-loops` and `codex-loops install`.
- Update runtime docs to state that Homebrew owns `libexec` runtime artifacts
  and the Codex plugin root is not a runtime root.
- Update `.agents/plugins/marketplace.json` to the release-pinned source-only
  marketplace shape required by the installer.
- Run docs stale-instruction grep.
- Run manual dogfood from a new Codex thread against the installed marketplace
  plugin and brewed runtime.

Blocks:

- Calling the Homebrew-first installer path complete.

Rollback:

- Revert public docs if the bottle or install command is pulled back.

Docs/proof updates:

- Record dogfood version, plugin version, run id, UI URL, and any repair notes
  in the release checklist.

## Expansion boundaries

Linux/Homebrew is not a v1 migration slice. The v1 implementation may include
conservative diagnostics for `/home/linuxbrew/.linuxbrew/opt/codex-loops` if the
code naturally supports it, but Linux CI, bottles, and user-facing support
promises wait until Apple Silicon macOS is proven.

A future official or curated Codex marketplace source is also not a v1 migration
slice. Keep the marketplace source/ref centralized so that changing from
`pproenca/codex-loops` later is cheap, but do not block this migration on that
future channel.

## Completion rule

The migration is ready for implementation tickets when slices 1 through 9 are
captured as normal PR-sized work items with the blocking edges above. The map
does not need another wayfinder ticket unless the implementation discovers that
Homebrew, Codex marketplace behavior, or runtime discovery differs from these
contracts in a way that changes the product boundary.
