# codex-loops install command contract

> **Status: superseded by ADR 0004.** The installed native command now accepts an
> explicit Codex path, persists that exact binding, installs the user skill, and
> registers `codex-loops mcp` directly. It does not reconcile a marketplace
> plugin or discover a brewed runtime. The contract below is historical.

Date: 2026-07-09

Wayfinder ticket: [Define the codex-loops install command contract](https://github.com/pproenca/codex-loops/issues/115)

## Sources checked

- Human-in-the-loop decisions in the wayfinder session for the install command contract.
- Current local Codex CLI help from `codex-cli 0.142.5`.
- Current Codex manual sections for plugin marketplaces and plugin installation, fetched on 2026-07-09.
- Existing wayfinder assets:
  - [Codex plugin install and marketplace flow](https://github.com/pproenca/codex-loops/blob/master/docs/research/codex-plugin-install-marketplace-flow.md)
  - [Codex plugin dependency and install-command support](https://github.com/pproenca/codex-loops/blob/master/docs/research/codex-plugin-dependency-install-command-support.md)
  - [Homebrew formula layout and dependency model](https://github.com/pproenca/codex-loops/blob/master/docs/research/homebrew-formula-layout-dependency-model.md)

## Decision

`codex-loops install` is a deterministic reconcile command for the Homebrew-first setup path:

```sh
brew install pproenca/codex-loops/codex-loops
codex-loops install
```

It reconciles the Codex Loops-owned Codex plugin state to the desired release-pinned state, verifies that the brewed runtime is discoverable by the plugin, and prints next-step guidance. It does not install Homebrew formulae or casks, run arbitrary package-manager commands, start the scheduler as a daemon, execute workflows, require Codex login, or act as an interactive setup wizard.

## Desired state

For a brewed runtime version `vX.Y.Z`, the desired state is:

- Homebrew-installed Codex Loops runtime files are present.
- `codex` is available on `PATH` and supports the plugin marketplace command surface.
- Codex marketplace `codex-loops` points at `pproenca/codex-loops` pinned to `vX.Y.Z`.
- Codex plugin `codex-loops@codex-loops` is installed and enabled.
- Plugin version and runtime package version are exactly compatible for v1.
- Plugin/runtime discovery succeeds without leaving a scheduler process running.

The marketplace selector remains `codex-loops@codex-loops` for v1. A future curated or official marketplace source is still map fog, not part of this contract.

## Commands used

The command should use the Codex marketplace-first flow:

```sh
codex plugin marketplace add pproenca/codex-loops --ref vX.Y.Z --json
codex plugin add codex-loops@codex-loops --json
codex plugin list --json
codex plugin marketplace list --json
```

The local command surface checked for this decision is singular `codex plugin`, not `codex plugins`.

## Flags

Required v1 flag surface:

```text
codex-loops install
codex-loops install --check
codex-loops install --dry-run
codex-loops install --json
codex-loops install --verbose
```

Meanings:

- `install`: reconcile desired state, make changes, and print human-readable output.
- `--check`: verify desired state only, make no changes, and exit nonzero if state is missing, incompatible, or drifted.
- `--dry-run`: compute and print the planned changes, make no changes, and exit zero when the plan is computable.
- `--json`: emit a stable machine-readable success or error envelope with no progress prose.
- `--verbose`: include underlying Codex commands, resolved paths, and diagnostic details.

Do not add `--yes`; the command is non-interactive by default. Do not add marketplace/ref override flags for v1 normal install; release pinning is deterministic.

## Codex preflight

Preflight should fail before any writes if the required Codex CLI is missing or incompatible.

Required checks:

- `codex` exists on `PATH`.
- `codex plugin` exists.
- `codex plugin marketplace add --json` is supported.
- `codex plugin add --json` is supported.
- `codex plugin list --json` is supported.
- `codex plugin marketplace list --json` is supported.

Missing `codex` has the exact recommended fix:

```text
Codex CLI was not found on PATH.
Install it with:
  brew install --cask codex
```

An incompatible Codex CLI should fail with an update-oriented message:

```text
This Codex CLI does not support plugin marketplace installation.
Update Codex, then rerun:
  codex update
```

Do not require `codex login`, `codex doctor`, or a live Codex provider turn during install.

## Repair boundary

`codex-loops install` may repair Codex Loops-owned state and should fail closed on ambiguous or conflicting state.

Marketplace behavior:

- Missing `codex-loops` marketplace: add `pproenca/codex-loops --ref vX.Y.Z`.
- Existing `codex-loops` marketplace with expected source/ref: keep it.
- Existing `codex-loops` marketplace with `pproenca/codex-loops` but a different ref: update or re-add it to `vX.Y.Z`.
- Existing `codex-loops` marketplace with any other source: fail closed and report the conflicting source plus manual fix.
- Existing local-path marketplace for development: not part of v1 normal install; only allow later behind an explicit dev-mode decision.

Plugin behavior:

- Missing or disabled `codex-loops@codex-loops`: install or re-enable it.
- Installed and enabled from expected marketplace/version: keep it.
- Installed from conflicting marketplace/source: fail closed with manual remove/reinstall commands.

The command should not remove or disable unrelated plugins or marketplaces.

## Compatibility

v1 compatibility is strict same-release compatibility:

```text
brewed runtime package version == installed plugin version
```

If current implementation has separate Mix app and plugin manifest versions, implementation should introduce one shared Codex Loops package version before enforcing this check.

Avoid semver compatibility ranges for v1. The runtime/plugin boundary is too young; strict equality gives clearer failure modes.

Mismatch message shape:

```text
Codex Loops plugin/runtime version mismatch.
Runtime: vX.Y.Z
Plugin:  vA.B.C

Rerun:
  codex-loops install
```

If rerun cannot repair because state is conflicting, use the conflict-specific manual fix.

## Runtime verification

`codex-loops install` should not start the scheduler or run workflows.

It should verify only bounded install/discovery facts:

- `codex-loops --version` reports the expected runtime package version.
- The scheduler release script exists and is executable.
- The MCP executable exists and can report `--version` or `--help`.
- The plugin can locate the brewed runtime without starting a long-lived scheduler process.

Full scheduler boot, API health, workflow validation, MCP lifecycle, and live provider proof belong to the formula `test do`, proof gates, and normal MCP usage, not to `codex-loops install`.

## Exit codes

Stable v1 exit codes:

```text
0  success, already installed, check passed, or dry-run plan computed
1  desired state not satisfied for --check
2  usage/config error in codex-loops install arguments
3  missing prerequisite, such as codex not found or incompatible Codex CLI
4  conflicting existing Codex marketplace/plugin state requiring manual action
5  Codex CLI command failed unexpectedly
6  runtime/plugin compatibility or discovery verification failed
```

For normal `install`, already-installed desired state is success. For `--check`, missing marketplace/plugin or version drift exits `1`.

## Output

Human success output should be concise and end with new-thread guidance because Codex loads plugin capabilities at thread start.

Example:

```text
Codex Loops is installed.

Runtime:
  Version: vX.Y.Z
  Scheduler: /opt/homebrew/opt/codex-loops/libexec/scheduler/bin/agent_loops
  MCP: /opt/homebrew/opt/codex-loops/libexec/mcp/codex-loops-mcp

Codex plugin:
  Marketplace: codex-loops pproenca/codex-loops@vX.Y.Z
  Plugin: codex-loops@codex-loops installed and enabled

Next:
  Open a new Codex thread and ask: Use the codex-loops skill.
```

`--json` success envelope:

```json
{
  "ok": true,
  "changed": true,
  "runtime": {"version": "vX.Y.Z", "root": "..."},
  "codex": {"path": "...", "version": "..."},
  "marketplace": {"name": "codex-loops", "source": "pproenca/codex-loops", "ref": "vX.Y.Z"},
  "plugin": {"id": "codex-loops@codex-loops", "installed": true, "enabled": true},
  "next_steps": ["Open a new Codex thread and ask: Use the codex-loops skill."]
}
```

`--json` errors should use the same top-level shape with `ok: false`, `changed`, a stable `error.code`, human `message`, optional `details`, optional `step`, and `next_steps`.

## Rollback

No broad rollback is required.

The command should preflight and detect known conflicts before writes. After writes begin:

- If marketplace add/update succeeds but plugin install fails, leave the marketplace because it is desired Codex Loops-owned state.
- If plugin install succeeds but verification fails, leave the plugin installed/enabled so state is inspectable and rerun can repair it.
- `--json` should report `changed: true`, the failing `step`, and successful prior changes.
- Never rollback by touching unrelated plugin or marketplace state.

This contract relies on idempotent reruns rather than broad undo logic.

## Doctor boundary

Do not require a separate `codex-loops doctor` command for v1.

The required verification command is:

```sh
codex-loops install --check
```

It verifies runtime files, compatible Codex command surface, expected marketplace, installed/enabled plugin, strict plugin/runtime compatibility, and runtime discoverability without starting the scheduler.
