# Codex Loops runtime artifact distribution options

Date: 2026-07-09

Wayfinder ticket: https://github.com/pproenca/codex-loops/issues/102

Local repos inspected:

- Codex Loops: `/Users/pedroproenca/Documents/Projects/codex-loops`
- Codex: `/Users/pedroproenca/Documents/Projects/opensource/codex`

## Executive answer

Codex Loops can move large scheduler/MCP binaries out of git without changing
the scheduler boundary. The current MCP lifecycle already supports
`CODEX_LOOPS_SCHEDULER_BIN` and then falls back to a scheduler under the plugin
root or the repo build tree. Source: `lib/workflow/mcp/lifecycle.ex:377-389`.

The hard constraint is Codex plugin installation, not scheduler runtime design.
Codex plugin install materializes a plugin root and loads declared runtime
capabilities from it. It does not run a general postinstall command. NPM plugin
sources are fetched with `npm pack --ignore-scripts`, and plugin manifests only
declare capability paths such as `skills`, `mcpServers`, `apps`, `hooks`, and
`interface`. Sources: `/Users/pedroproenca/Documents/Projects/opensource/codex/codex-rs/core-plugins/src/npm_source.rs:90-100`,
`/Users/pedroproenca/Documents/Projects/opensource/codex/codex-rs/core-plugins/src/manifest.rs:22-45`,
`docs/research/codex-plugin-install-marketplace-flow.md`, and
`docs/research/codex-plugin-dependency-install-command-support.md`.

That leaves three credible source-first distribution shapes:

1. A small checked-in plugin launcher that finds an externally installed runtime
   or a verified cached artifact, and fails closed with setup instructions when
   neither is present.
2. Versioned GitHub release artifacts, preferably consumed by that launcher
   only when the user has explicitly opted into bootstrap/download behavior.
3. A Homebrew tap/formula as the best user-facing install/update path for
   macOS and Homebrew-on-Linux users, with the plugin launcher discovering the
   installed executable or scheduler path.

NPM can be a transport for a plugin tarball that already contains artifacts, but
it is not a dependency installer in Codex's plugin flow and has a current Codex
archive cap of 50 MB. Source builds at install or first run should not be the
default product path.

## Current package pressure

The current repo tracks large generated artifacts under the plugin package:

- `plugins/codex-loops/mcp/codex-loops-mcp`: about 11 MB.
- `plugins/codex-loops/scheduler`: about 35 MB.
- `plugins/codex-loops` total: about 46 MB.
- `git ls-files plugins/codex-loops/mcp/codex-loops-mcp plugins/codex-loops/scheduler`
  currently counts 1,577 tracked files.

The current proof and verification scripts also encode "tracked binary payload"
as a requirement:

- `make release` copies `_build/prod/rel/agent_loops` into
  `plugins/codex-loops/scheduler`. Source: `Makefile:74-83`.
- `make release-mcp` copies the Burrito executable into
  `plugins/codex-loops/mcp/codex-loops-mcp`. Source: `Makefile:90-109`.
- `make proof-mcp` first runs both release targets. Source: `Makefile:116-120`.
- `scripts/proof-mcp-validate.exs` copies `plugins/codex-loops` to a temporary
  installed plugin root and asserts that both `mcp/codex-loops-mcp` and
  `scheduler/bin/agent_loops` are executable inside the copy. Source:
  `scripts/proof-mcp-validate.exs:15-31`.
- `scripts/verify-plugin-package.sh` requires tracked scheduler/MCP artifacts
  and fails if the MCP entrypoint is a shell wrapper. Source:
  `scripts/verify-plugin-package.sh:24-31`,
  `scripts/verify-plugin-package.sh:35-40`, and
  `scripts/verify-plugin-package.sh:65-85`.

The migration must therefore replace those assertions with proof that a
source-first plugin can resolve a versioned runtime artifact without exposing
raw scheduler internals or weakening journal/projection behavior.

## Evaluation criteria

The ticket asked each option to be judged against:

- Compatibility with Codex plugin installation.
- macOS/Linux portability.
- Reproducibility.
- Update story.
- Security and trust prompts.
- Offline behavior.
- Verification through `make proof`, `make proof-mcp`, and
  `make proof-mcp-live`.

## Option comparison

| Option | Compatibility with Codex plugin install | Portability | Reproducibility | Update story | Security/trust | Offline behavior | Proof route |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Homebrew formula/tap | Codex cannot run `brew install`; works if the plugin carries a small launcher that discovers the Homebrew-installed runtime or fails closed. | Strong for macOS and supported Homebrew-on-Linux users; bottles depend on supported prefixes/platforms. | Good: formula URLs and `sha256` are explicit; bottles add per-platform checksums. | `brew update` / `brew upgrade`; plugin can require matching runtime version. | Explicit user install. Non-official taps require trust in Homebrew 6; formulae are executable Ruby. | Works after install; first install needs network or cache. | Keep `make proof` for local release. Change MCP proofs to install or simulate a formula-provided runtime, then run the plugin launcher from a copied source-only plugin. |
| Homebrew cask | Technically possible for binary artifacts, but less appropriate for open-source CLI-only software. | Cask support is strongest on macOS; Linux support exists but is newer and more constrained. | Good when cask has versioned URL and checksum. | `brew upgrade --cask`; less natural for CLI/runtime split. | Cask artifacts are treated as trusted vendor installer actions and may run outside normal sandbox boundaries. | Works after install. | Same as formula, but not favored unless formula is rejected or GUI/app bundle packaging becomes relevant. |
| GitHub release artifacts | Codex cannot fetch them at plugin install time. Works behind a plugin launcher or a documented user install command. | Good if CI publishes per-target assets for darwin/linux and x86_64/aarch64. | Good when the plugin pins version plus SHA256; GitHub also exposes asset digests through Releases/API. | Publish new release assets and bump the plugin's pinned artifact manifest. Avoid unpinned `latest` by default. | First-run download of executable code needs explicit opt-in or prior user install; default should fail closed. | Works if the artifact is already cached; otherwise needs network. | Build artifacts locally in proof, serve or expose them through a file URL/cache fixture, verify checksum, run mock and live MCP proofs through the launcher. |
| NPM package as Codex plugin source | Codex supports NPM plugin sources, but only as `npm pack --ignore-scripts`; the package tarball must already contain everything needed. | NPM itself is portable, but platform-specific native artifacts require separate packages or a large multi-platform tarball. | Fair to good for a single platform package; Codex caps NPM plugin archive at 50 MB and extracted payload at 250 MB. | NPM version bump plus marketplace/plugin version bump. | Codex avoids NPM lifecycle scripts in this path, which is good; user-managed `npm install -g` is separate and may run scripts. | Installed plugin contains the packed files; first install needs registry/cache. | Add package-size assertions and a local `npm pack` proof. MCP proofs still need a source-only plugin launcher or a tarball with runtime artifacts. |
| NPM global CLI/runtime package | Codex plugin install cannot invoke it. A plugin launcher can find a `codex-loops` command on `PATH`. | Good where Node/npm is available; native payload still needs per-platform handling. | Depends on package contents and lock/build process. | `npm update -g` or package manager update. | Explicit user install; avoid lifecycle scripts for trust. | Works after install. | Simulate PATH-installed runtime in MCP proofs; do not rely on Codex NPM plugin materialization. |
| Source build at install or first run | No Codex postinstall hook; only possible inside a plugin launcher, before MCP starts. | Fragile: requires Elixir/Erlang, Mix, C compiler/native deps, xz, Zig 0.15.2 for MCP Burrito, and network unless caches are warm. | Weak for end users despite `mix.lock`; compilers, native libs, and package-manager state matter. | Rebuild on plugin/runtime version changes; cache invalidation gets complex. | High trust cost: executes build tools and dependency code from a plugin path. Should require explicit user command, not automatic MCP startup. | Poor unless all deps and build cache are already present. | Keep as a developer-only proof path. Do not make it a user-facing product proof. |
| Small checked-in launcher | Best Codex fit: `.mcp.json` can keep pointing at a file under the plugin root, but that file is source-sized and delegates to a verified runtime. | Good for macOS/Linux with POSIX shell or a tiny compiled launcher. | Good if it pins runtime version and verifies digest before execution. | Plugin update changes expected runtime version. Launcher can tell user how to upgrade Homebrew/NPM/cache. | Best if default behavior is non-authoritative and fail-closed: no silent `brew`, `npm`, `mix`, or network execution. Optional bootstrap should require explicit env/command. | Works when external runtime or verified cache exists; otherwise fail with setup instructions. | Primary proof target: missing-runtime failure, external-runtime discovery, verified artifact cache, scheduler start, MCP mock proof, and MCP live proof. |

## Source details by option

### Homebrew formula or tap

Homebrew taps are external repositories of formulae, casks, or commands; a
GitHub tap can be added with `brew tap user/repo`, and formulae in taps can be
installed and updated through normal `brew` commands. Source:
[Homebrew Taps](https://docs.brew.sh/Taps) and
[How to Create and Maintain a Tap](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap).

Homebrew's formula workflow expects stable, tagged versions, formula files, and
checksums. Tap maintenance docs call out formula `url` and `sha256` verification
and recommend keeping formulae updated. Source:
[Formula Cookbook](https://docs.brew.sh/Formula-Cookbook) and
[How to Create and Maintain a Tap](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap#troubleshooting).

Homebrew has a strong update story and explicit user trust boundary. However,
as of Homebrew 6.0.0, non-official taps require explicit trust because formulae,
casks, and external commands are executable Ruby package definitions. Source:
[Tap Trust](https://docs.brew.sh/Tap-Trust).

Homebrew also supports Linux, but it expects standard Linux development tools
and its best binary-package behavior depends on supported/default prefixes.
Source: [Homebrew on Linux](https://docs.brew.sh/Homebrew-on-Linux),
[Homebrew Installation](https://docs.brew.sh/Installation), and
[Homebrew FAQ](https://docs.brew.sh/FAQ#why-should-i-install-homebrew-in-the-default-location).

For Codex Loops, the most useful Homebrew shape is a formula that installs:

- `codex-loops-mcp` as a command or libexec entrypoint.
- The scheduler release under `libexec`.
- A wrapper that sets `CODEX_LOOPS_SCHEDULER_BIN` to the installed scheduler.

The Codex plugin should not assume Codex can run Homebrew. Instead, a small
plugin launcher can discover the formula-installed runtime or fail closed with
instructions such as `brew install pproenca/codex-loops/codex-loops`.

### Homebrew cask

Casks can distribute binary artifacts, and taps can contain casks. Source:
[How to Create and Maintain a Tap](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap#casks).

But for a CLI-only open-source project, Homebrew's acceptable-cask policy says
to submit as a formula first; cask is the fallback if formula is rejected.
Source: [Acceptable Casks](https://docs.brew.sh/Acceptable-Casks).

Cask installation also has a broader trust model: Homebrew treats accepted cask
installation artifacts as trusted vendor installation actions, and installer or
pkg artifacts may run outside the cask sandbox. Source:
[Cask Cookbook](https://docs.brew.sh/Cask-Cookbook#cask-artifact-trust-and-sandboxing).

That makes cask a weaker default for Codex Loops than a formula, unless the
future product surface needs app-bundle semantics.

### GitHub release artifacts

GitHub Releases can carry uploaded binary assets. Current GitHub docs state that
each release can have up to 1,000 assets, each asset must be under 2 GiB, and
there is no release-total or bandwidth limit in the documented quota. Source:
[GitHub Docs: About releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases#storage-and-bandwidth-quotas).

The release-asset REST API includes fields such as `browser_download_url`,
`size`, and `digest`, and upload uses the release-specific `upload_url`. Source:
[GitHub REST API: release assets](https://docs.github.com/en/rest/releases/assets).
GitHub announced SHA256 release-asset digests in 2025. Source:
[GitHub Changelog: Releases now expose digests](https://github.blog/changelog/2025-06-03-releases-now-expose-digests-for-release-assets/).

For Codex Loops, a release can publish per-target assets, for example:

- `codex-loops-runtime-v0.2.8-darwin-aarch64.tar.gz`
- `codex-loops-runtime-v0.2.8-darwin-x86_64.tar.gz`
- `codex-loops-runtime-v0.2.8-linux-aarch64.tar.gz`
- `codex-loops-runtime-v0.2.8-linux-x86_64.tar.gz`

The source-first plugin should commit a small artifact manifest with expected
version, target triples, URLs, and SHA256 digests. The launcher should never
download `latest` by default. It should run only a verified cached artifact, or
download only when the user has explicitly opted in through an install command
or environment variable such as `CODEX_LOOPS_ALLOW_BOOTSTRAP=1`.

This option composes well with Homebrew: Homebrew can consume the same release
assets and checksums, while the plugin launcher can use release assets as a
manual or opt-in fallback.

### NPM package

NPM packages can choose tarball contents with the `files` field and can expose
commands with the `bin` field. Source:
[npm package.json docs](https://docs.npmjs.com/cli/v11/configuring-npm/package-json/#files)
and
[npm package.json docs: bin](https://docs.npmjs.com/cli/v11/configuring-npm/package-json/#bin).

NPM lifecycle scripts exist, including `prepare`, which can run during
`npm pack` and related operations. Source:
[npm scripts docs](https://docs.npmjs.com/cli/v11/using-npm/scripts/#life-cycle-scripts).

Codex's NPM plugin-source path deliberately runs `npm pack --ignore-scripts`,
extracts the package, and enforces current size limits of 50 MB archive and
250 MB extracted payload. Source:
`/Users/pedroproenca/Documents/Projects/opensource/codex/codex-rs/core-plugins/src/npm_source.rs:11-14`
and `/Users/pedroproenca/Documents/Projects/opensource/codex/codex-rs/core-plugins/src/npm_source.rs:90-100`.

Therefore:

- An NPM Codex plugin package can work only if the package tarball already
  contains the source plugin plus any required runtime artifacts.
- It cannot rely on `postinstall`, `prepare`, optional dependencies, or a
  generated binary build during Codex plugin materialization.
- A multi-platform NPM package with all runtime artifacts is likely too large
  or close enough to the 50 MB cap to be brittle.
- Per-platform NPM packages are possible, but Codex plugin install currently
  chooses a package source from marketplace metadata rather than resolving a
  platform package family.

NPM remains useful as a user-installed global runtime (`npm install -g ...`) if
the plugin launcher only discovers it. It is not the cleanest Codex-native
artifact distribution path for the scheduler/MCP pair.

### Source build at install or first run

Mix releases are self-contained production artifacts. The official Mix docs say
releases do not require source code in production artifacts and include the
Erlang VM/runtime by default; they also include management scripts such as
`bin/RELEASE_NAME start`. Source:
[Mix release docs](https://mix.hexdocs.pm/Mix.Tasks.Release.html).

Elixir's release announcement also notes that an assembled release can be
packaged and deployed to a target as long as the target runs on the same OS
distribution/version as the machine running `mix release`. Source:
[Elixir v1.9 release announcement](https://elixir-lang.org/blog/2019/06/24/elixir-v1-9-0-released/#releases).

Burrito can produce self-contained single-file executables for macOS, Linux,
and Windows and packages BEAM code, ERTS, and NIF artifacts; it requires build
tools such as Zig and XZ. Source:
[Burrito README](https://github.com/burrito-elixir/burrito#feature-overview)
and [Burrito preparation requirements](https://github.com/burrito-elixir/burrito#preparation-and-requirements).
This repo currently requires Zig 0.15.2 and xz for `make release-mcp`. Source:
`Makefile:85-95`.

That makes source build an acceptable contributor path, but not a reliable
Codex plugin install path. It would require running compilers, package managers,
and dependency code before the MCP server can start, with no Codex-owned
install consent flow.

### Small checked-in launcher

The current `.mcp.json` points Codex at `./mcp/codex-loops-mcp` with `cwd: "."`.
Source: `plugins/codex-loops/.mcp.json:1-10`. Codex rewrites relative plugin
MCP cwd values under the installed plugin root. Source:
`/Users/pedroproenca/Documents/Projects/opensource/codex/codex-rs/codex-mcp/src/plugin_config.rs:117-154`.

A small source launcher is therefore the best Codex-compatible bridge. It can
remain inside the plugin root and keep Codex's runtime surface declarative,
while removing generated binaries from git.

Recommended launcher behavior for the next decision ticket:

- Discover an explicitly configured runtime first, e.g.
  `CODEX_LOOPS_MCP_BIN` / `CODEX_LOOPS_SCHEDULER_BIN`.
- Discover a Homebrew or NPM installed runtime on `PATH` only when the version
  matches the plugin's expected runtime version.
- Discover a verified artifact cache under a user-owned data directory, not
  inside the Codex-managed installed plugin root.
- If runtime is missing, fail closed with clear setup commands. Do not run
  `brew`, `npm`, `mix`, or network downloads by default.
- Optional bootstrap can be a separate command or opt-in environment variable
  that downloads a pinned GitHub release asset, verifies SHA256, installs into
  the cache, and then execs the MCP binary.
- Preserve the existing MCP/scheduler boundary by passing
  `CODEX_LOOPS_SCHEDULER_BIN` when the external runtime layout needs it.

This launcher path does not change writer-owned agent settlements, journal
event durability, progress-message non-authoritativeness, run projections, raw
refs, or the API/MCP/LiveView surface split. It only changes how the MCP process
locates the executable artifact that already talks to the scheduler HTTP API.

## Proof-route changes

### `make proof`

Keep proving the scheduler release artifact itself. It should continue to build
`_build/prod/rel/agent_loops` and exercise the scheduler API and LiveView route
from that local build. This proof is independent of plugin packaging.

Later migration work may rename the release packaging target so it does not
copy into `plugins/codex-loops/scheduler`, but `make proof` should still answer:
"does this scheduler release boot and serve correct journal-backed projections?"

### `make proof-mcp`

Change from "copied plugin contains tracked runtime binaries" to "copied
source-only plugin resolves a verified runtime":

1. Build scheduler and MCP artifacts into `_build/prod`.
2. Create a temporary artifact store or external install prefix.
3. Create a source-only installed plugin copy.
4. Run the plugin launcher as Codex would run it.
5. Assert the missing-runtime path fails closed when no runtime is available.
6. Assert external runtime discovery works through env/PATH.
7. Assert verified artifact-cache discovery works without network.
8. Run MCP initialize, tools/list, validate, mock start, status, inspect,
   resume, typed error, open-ui, and shutdown as today.

If GitHub-release bootstrap is supported, the proof should use a local `file://`
or localhost artifact source with pinned SHA so the test is deterministic and
does not require GitHub availability.

### `make proof-mcp-live`

Use the same source-only plugin and verified runtime path as `make proof-mcp`,
then spend the live Codex provider turn exactly as today. The live proof should
not introduce a network artifact download unless explicitly requested; live
Codex usage is already the intentionally networked part.

### `verify-plugin-package`

Replace tracked-artifact assertions with source-package assertions:

- `.codex-plugin/plugin.json`, `.mcp.json`, skill files, notices, and launcher
  are tracked.
- `plugins/codex-loops/scheduler/**` and generated MCP binaries are absent or
  ignored, not tracked.
- The launcher is small, executable, and does not contain the old
  `agent_loops eval 'Workflow.MCP.Stdio.main(...)'` transitional path.
- Artifact manifest, version, and checksums are present if GitHub release
  bootstrap is supported.
- The packaged plugin can be copied and run against an external verified
  runtime through `make proof-mcp`.

## Implications for the next ticket

The final packaging model can remain a Codex Loops repo/release change. It does
not require an upstream Codex plugin install-hook feature if the product accepts
an explicit external runtime install or a fail-closed, opt-in bootstrap.

The strongest candidate for the next decision is:

- source-only Codex plugin in git,
- tiny checked-in MCP launcher as the plugin entrypoint,
- versioned GitHub release artifacts as the canonical binary runtime payload,
- Homebrew formula/tap as the primary ergonomic install/update path on macOS
  and supported Linux,
- no automatic install commands during Codex plugin installation,
- no raw release binaries committed to the source repo.

The main open design choice for the next ticket is whether the launcher should
only discover externally installed artifacts, or also provide an explicitly
enabled GitHub-release bootstrap command/cache.
