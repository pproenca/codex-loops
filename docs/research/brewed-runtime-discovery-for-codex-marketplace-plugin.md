# Brewed runtime discovery for the Codex marketplace plugin

> Implementation update: ADR 0002 replaces the real Burrito MCP executable
> described below with an MCP command overlay in the single OTP release. The
> launcher discovery order and runtime-root boundary remain current.

Date: 2026-07-09

Wayfinder ticket: [Design brewed runtime discovery for the Codex marketplace plugin](https://github.com/pproenca/codex-loops/issues/116)

## Sources checked

- Current Codex Loops plugin manifest and MCP config:
  `plugins/codex-loops/.codex-plugin/plugin.json:1-29` and
  `plugins/codex-loops/.mcp.json:1-10`.
- Current MCP runtime discovery code:
  `lib/workflow/mcp/burrito_environment.ex:24-52` and
  `lib/workflow/mcp/lifecycle.ex:377-416`.
- Current proof/package checks that assume bundled runtime artifacts:
  `scripts/proof-mcp-validate.exs:15-31`,
  `scripts/proof-mcp-live.exs:24-40`, and
  `scripts/verify-plugin-package.sh:24-31`.
- Existing packaging decisions:
  [Homebrew formula layout and dependency model](./homebrew-formula-layout-dependency-model.md),
  especially `libexec` layout and `bin` shims, and
  [codex-loops install command contract](./codex-loops-install-command-contract.md),
  especially strict plugin/runtime compatibility and bounded runtime verification.
- Existing Codex plugin research:
  [Codex plugin install and marketplace flow](./codex-plugin-install-marketplace-flow.md)
  and [Codex plugin dependency and install-command support](./codex-plugin-dependency-install-command-support.md).

## Decision

The marketplace plugin should become source-only, but it should still contain a
small tracked MCP launcher at the path Codex starts today:

```json
{
  "mcpServers": {
    "codex-loops": {
      "command": "./mcp/codex-loops-mcp",
      "args": ["--stdio"],
      "cwd": ".",
      "tool_timeout_sec": 120
    }
  }
}
```

That file should no longer be the Burrito executable. It should be a tiny
launcher, checked into `plugins/codex-loops/mcp/codex-loops-mcp`, that resolves a
Homebrew-installed runtime, verifies version compatibility, sets the runtime
environment, and then `exec`s the real Burrito MCP executable from Homebrew's
`libexec`.

The actual runtime lives only in the brewed formula layout:

```text
#{opt_libexec}/scheduler/bin/agent_loops
#{opt_libexec}/mcp/codex-loops-mcp
#{opt_bin}/codex-loops
#{opt_bin}/codex-loops-mcp
```

This keeps the Codex plugin install model simple: Codex still loads the plugin
from its installed plugin root and starts a declared MCP command, while Homebrew
owns build artifacts, upgrades, bottles, and runtime paths.

## Why a plugin launcher instead of direct PATH command

Codex plugin MCP config is loaded from the installed plugin root, and relative
plugin `cwd` values are resolved under that plugin root. The current config uses
that behavior already. Source: [Codex plugin install and marketplace flow](./codex-plugin-install-marketplace-flow.md#runtime-loading-and-mcp-entrypoints).

Pointing `.mcp.json` directly at `codex-loops-mcp` on `PATH` would work in many
terminal-launched sessions, but it is weaker for the product path:

- Codex desktop or GUI-launched environments may not inherit Homebrew's `bin`
  directory.
- Missing runtime failures would happen before the MCP server starts, with less
  project-specific guidance.
- The plugin would lose an installed-plugin-root place to pin the expected
  plugin version.

The launcher is still source-only. It is not a packaged scheduler, not the
Burrito executable, and not a build step.

## Discovery contract

The source launcher should try these candidates in order and stop at the first
version-compatible runtime:

1. `CODEX_LOOPS_MCP_BIN`, when set to an absolute executable path. This is for
   tests, local development, and custom installs.
2. `CODEX_LOOPS_RUNTIME_ROOT`, when set to an absolute directory containing:
   `mcp/codex-loops-mcp` and `scheduler/bin/agent_loops`.
3. `codex-loops-mcp` on `PATH`. The Homebrew `bin/codex-loops-mcp` shim should
   set `CODEX_LOOPS_RUNTIME_ROOT` and `CODEX_LOOPS_SCHEDULER_BIN` before
   executing the real `libexec/mcp/codex-loops-mcp`.
4. `brew --prefix codex-loops`, if `brew` is already on `PATH`. This is a
   read-only lookup only; the launcher must not run `brew install`, `brew
   update`, or `brew upgrade`.
5. Default macOS Homebrew opt locations:
   `/opt/homebrew/opt/codex-loops/libexec` and
   `/usr/local/opt/codex-loops/libexec`.

Linux/Homebrew prefix probing should stay conservative until the map resolves
the Linux support boundary. Adding `/home/linuxbrew/.linuxbrew/opt/codex-loops`
as a diagnostic candidate is fine, but Linux success should not become a v1
release promise through this ticket.

The launcher must never build from source, download artifacts, run Mix, run NPM,
or install package-manager dependencies. Missing runtime is a hard failure with
setup instructions.

## Environment variables

User-facing and proof-facing variables:

| Variable | Owner | Meaning |
| --- | --- | --- |
| `CODEX_LOOPS_RUNTIME_ROOT` | launcher, MCP, tests | Absolute runtime root. Expected layout is `mcp/codex-loops-mcp` plus `scheduler/bin/agent_loops` beneath it. |
| `CODEX_LOOPS_MCP_BIN` | launcher, tests | Absolute path to the real Burrito MCP executable. More specific than `CODEX_LOOPS_RUNTIME_ROOT`. |
| `CODEX_LOOPS_SCHEDULER_BIN` | MCP lifecycle, tests | Absolute scheduler release script. Existing override remains supported and should be set by the Homebrew MCP shim or plugin launcher when known. |
| `CODEX_LOOPS_SCHEDULER_URL` | MCP lifecycle | Existing external scheduler URL override. If set, MCP should still require a compatible scheduler health version. |
| `CODEX_LOOPS_SCHEDULER_HOST` / `CODEX_LOOPS_SCHEDULER_PORT` | MCP lifecycle | Existing local loopback bind controls used when MCP owns scheduler startup. |
| `CODEX_LOOPS_SCHEDULER_REQUEST_TIMEOUT_MS` | MCP client | Existing HTTP timeout control. |
| `CODEX_LOOPS_JOURNAL_PATH` | scheduler | Existing journal path override. |
| `CODEX_LOOPS_CODEX_BIN` | scheduler provider | Existing Codex CLI override for live provider turns. |
| `CODEX_LOOPS_PARENT_PATH` | MCP lifecycle | Existing original PATH passed through to the scheduler/provider environment. |

Internal and development variables:

| Variable | Owner | Meaning |
| --- | --- | --- |
| `CODEX_LOOPS_PLUGIN_ROOT` | launcher | Installed source plugin root, used for diagnostics and reading the expected plugin version. It is not a runtime root. |
| `CODEX_LOOPS_REPO_ROOT` | dev/proof only | Source checkout root for local development fallback. Production discovery must not invent this from the plugin root. |
| `CODEX_LOOPS_ENTRYPOINT` | Burrito/Mix release | Existing signal that the release should start the MCP entrypoint rather than the scheduler. |
| `__BURRITO_BIN_PATH` / `__BURRITO` | Burrito | Burrito-owned metadata. Codex Loops may infer runtime root from it when the real MCP binary is under `runtime_root/mcp/`. |

## MCP lifecycle discovery

Inside the real Burrito MCP process, scheduler discovery should be:

1. If `CODEX_LOOPS_SCHEDULER_URL` points at a reachable scheduler, use it only
   when `/api/health` reports a compatible Codex Loops version.
2. If MCP owns local startup, use `CODEX_LOOPS_SCHEDULER_BIN` when set.
3. Use `CODEX_LOOPS_RUNTIME_ROOT/scheduler/bin/agent_loops` when
   `CODEX_LOOPS_RUNTIME_ROOT` is set.
4. Infer `runtime_root` from `__BURRITO_BIN_PATH` when the actual binary path is
   `.../mcp/codex-loops-mcp`, then use
   `runtime_root/scheduler/bin/agent_loops`.
5. In development only, use
   `CODEX_LOOPS_REPO_ROOT/_build/prod/rel/agent_loops/bin/agent_loops` when
   `CODEX_LOOPS_REPO_ROOT` is explicitly set.

Remove the production default that currently derives:

```text
CODEX_LOOPS_PLUGIN_ROOT/scheduler/bin/agent_loops
CODEX_LOOPS_PLUGIN_ROOT/../../_build/prod/rel/agent_loops/bin/agent_loops
```

Those paths are the bundled-plugin/source-tree model. The Homebrew-first plugin
must not treat the installed plugin root as a runtime root.

## Version compatibility

Use strict same-release compatibility for v1, matching the install command
contract:

```text
plugin version == runtime package version == MCP version == scheduler version
```

Implementation should introduce one shared Codex Loops package version before
enforcing this. Today the plugin manifest and Mix project can drift, so the
implementation work should make these surfaces derive from one value:

- `.codex-plugin/plugin.json` version.
- `mix.exs` project/release version.
- `codex-loops --version`.
- `codex-loops-mcp --version`.
- MCP `initialize.serverInfo.version`.
- Scheduler `GET /api/health` response, for example
  `data.version: "vX.Y.Z"`.

The source launcher should compare the installed plugin's expected version with
the candidate runtime MCP version before `exec`. The MCP process should compare
its own runtime version with scheduler health both when reusing an already
running scheduler and after starting one. A scheduler that omits version data is
not compatible for v1.

## Fail-closed messages

Launcher missing-runtime failure should be explicit:

```text
Codex Loops runtime was not found.

Install it with:
  brew install pproenca/codex-loops/codex-loops
  codex-loops install

Searched:
  CODEX_LOOPS_MCP_BIN
  CODEX_LOOPS_RUNTIME_ROOT
  codex-loops-mcp on PATH
  brew --prefix codex-loops
  /opt/homebrew/opt/codex-loops/libexec
  /usr/local/opt/codex-loops/libexec
```

Launcher mismatch failure:

```text
Codex Loops plugin/runtime version mismatch.
Plugin:  vA.B.C
Runtime: vX.Y.Z

Repair with:
  brew upgrade pproenca/codex-loops/codex-loops
  codex-loops install
```

Invalid override failure:

```text
CODEX_LOOPS_RUNTIME_ROOT is set but does not contain a usable Codex Loops runtime:
  <path>

Expected:
  <path>/mcp/codex-loops-mcp
  <path>/scheduler/bin/agent_loops
```

MCP scheduler discovery failure should keep the structured MCP envelope, but
change the guidance from local build instructions to installed-runtime
instructions:

```text
No Codex Loops scheduler release was found for the brewed runtime.
Run:
  brew reinstall pproenca/codex-loops/codex-loops
  codex-loops install --check
```

## Required implementation changes

- Keep `plugins/codex-loops/.mcp.json` pointed at `./mcp/codex-loops-mcp`, but
  replace that file with a small tracked launcher script.
- Stop tracking generated runtime artifacts under `plugins/codex-loops/mcp/` and
  `plugins/codex-loops/scheduler/`.
- Update `Workflow.MCP.BurritoEnvironment` so Burrito path inference populates
  `CODEX_LOOPS_RUNTIME_ROOT`, not `CODEX_LOOPS_PLUGIN_ROOT`, when the actual MCP
  binary lives under `runtime_root/mcp/`.
- Update `Workflow.MCP.Lifecycle.discover_release/0` to prefer
  `CODEX_LOOPS_SCHEDULER_BIN`, `CODEX_LOOPS_RUNTIME_ROOT`, and Burrito
  runtime-root inference. Delete or dev-gate plugin-root and implicit repo-root
  fallbacks.
- Add `--version` support to the real MCP executable and expose the shared
  package version in scheduler health and MCP initialize.
- Update `codex-loops install --check` to run the same launcher discovery in
  check mode without starting the scheduler.
- Rewrite `make proof-mcp` and `make proof-mcp-live` so they copy a source-only
  plugin, create a temporary Homebrew-like runtime prefix, assert missing-runtime
  and mismatch failures, then run the full MCP proof against the external
  runtime.
- Invert `scripts/verify-plugin-package.sh`: require source files, launcher,
  notices, and manifest; reject tracked scheduler/MCP binaries.
- Update `plugins/codex-loops/README.md`, `plugins/codex-loops/SPEC.md`, and
  `docs/runtime.md` so they describe the brewed runtime boundary instead of a
  copied plugin package containing release artifacts.

## Proof implications

`make proof` remains the scheduler-release proof and can keep building
`_build/prod/rel/agent_loops`.

`make proof-mcp` becomes the product-path proof:

1. Build scheduler and MCP artifacts into `_build/prod`.
2. Install/copy them into a temporary `opt/codex-loops/libexec` layout.
3. Copy only the source plugin into a temporary installed plugin root.
4. Run the source launcher as Codex would run it.
5. Prove missing-runtime and version-mismatch failures.
6. Prove MCP initialize, tools/list, validate, mock start, status, inspect,
   resume, open-ui, typed errors, and owned-scheduler shutdown against the
   external runtime.

`make proof-mcp-live` should use the same source-only plugin plus external
runtime path, then spend the existing live Codex provider turn.

No new wayfinder ticket is needed from this decision. It directly unblocks the
Homebrew bottle/release proof-gates ticket.
