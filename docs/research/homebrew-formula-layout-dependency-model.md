# Homebrew formula layout and dependency model

> Implementation update: ADR 0002 removes the second Burrito release. The
> formula no longer needs Zig or XZ and stages both commands from one OTP
> release. The ownership and `libexec` decisions below remain current.

Date: 2026-07-09

Wayfinder ticket: [Specify the Homebrew formula layout and dependency model](https://github.com/pproenca/codex-loops/issues/114)

## Primary sources checked

- [Homebrew Formula Cookbook](https://docs.brew.sh/Formula-Cookbook), especially dependency scoping, `libexec`, language-specific resources, and `test do` guidance.
- [How to Create and Maintain a Tap](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap), especially direct tap installs with `brew install user/repository/formula`.
- [Adding Software to Homebrew](https://docs.brew.sh/Adding-Software-to-Homebrew), especially local source-build, audit, and `brew test` proof expectations.
- [Mix release documentation](https://mix.hexdocs.pm/Mix.Tasks.Release.html), especially host/target matching, NIFs, runtime system packages, and release control commands.
- [Burrito README](https://github.com/burrito-elixir/burrito), especially target support and the current build tool requirements.
- [Homebrew `zig@0.15` formula page](https://formulae.brew.sh/formula/zig%400.15), confirming the versioned formula currently provides Zig 0.15.2.
- [Homebrew `elixir` formula page](https://formulae.brew.sh/formula/elixir) and [Homebrew `erlang` formula page](https://formulae.brew.sh/formula/erlang), confirming the current source-build toolchain available through Homebrew.
- Local source: `mix.exs`, `mix.lock`, `Makefile`, `docs/runtime.md`, `plugins/codex-loops/.mcp.json`, `lib/workflow/mcp/lifecycle.ex`, and `lib/workflow/mcp/burrito_environment.ex`.

## Decision

The v1 Homebrew formula should be a tap formula named `codex-loops`, installed by the already-chosen user path:

```sh
brew install pproenca/codex-loops/codex-loops
```

The formula should build the runtime from a tagged Codex Loops source release and install only Homebrew-owned runtime artifacts. It should not install the Codex marketplace plugin, shell out to `codex`, copy the plugin package into Homebrew, or run nested package-manager installs during `brew install`.

The formula should build and install two runtime artifacts:

- `agent_loops`: the scheduler Mix release.
- `codex-loops-mcp`: the Burrito-wrapped MCP executable.

Normal developers should get those artifacts from bottles. Source builds remain a maintainer and fallback path, but the happy path should not require users to have Elixir, Erlang, Zig, XZ, Hex, or Rebar in their normal environment after installation.

## Formula shape

The tap should contain the formula at `Formula/codex-loops.rb`, with class `CodexLoops`. The formula `url` should point at a tagged source archive from the product repo, for example:

```ruby
url "https://github.com/pproenca/codex-loops/archive/refs/tags/v#{version}.tar.gz"
license "MIT"
```

Use the tap formula to build from source in CI and to pour bottles for supported targets. Do not make the formula depend on a checked-in plugin payload or release binaries from `plugins/codex-loops/`.

The install step should use a formula-specific build path or Make target that produces the same artifacts as today's `make release` and `make release-mcp` without treating `plugins/codex-loops/` as the final install tree. The current Make targets are a good starting point, but implementation should add a non-mutating packaging target before the formula is finalized.

## Installed layout

Install the runtime root under `libexec`, not under the Codex plugin root:

```text
#{libexec}/scheduler/                 # full agent_loops Mix release root
#{libexec}/scheduler/bin/agent_loops   # release control script
#{libexec}/mcp/codex-loops-mcp         # Burrito MCP executable
#{libexec}/bin/codex-loops             # product CLI implementation, if shipped as a script/artifact
```

Expose stable command shims from `bin`:

```text
#{bin}/codex-loops                     # user-facing install/doctor/runtime command
#{bin}/codex-loops-mcp                 # optional stable MCP runtime entrypoint
```

`bin/codex-loops` is required by the target flow because users run `codex-loops install` after `brew install`. Its exact subcommand behavior belongs to [Define the codex-loops install command contract](https://github.com/pproenca/codex-loops/issues/115), but the formula layout should reserve the command now.

`codex-loops-mcp` can be exposed either as a symlink to `libexec/mcp/codex-loops-mcp` or as a tiny wrapper. The actual MCP executable should live at `libexec/mcp/codex-loops-mcp` because the current Burrito environment inference and lifecycle discovery already fit this shape: an MCP binary under an `mcp` directory infers the parent as the runtime root, and the scheduler release can then be discovered at `runtime_root/scheduler/bin/agent_loops`.

Do not install mutable runtime state into the Cellar, `var`, or `etc`. The journal remains at `~/.codex/workflows/runs_1.sqlite` unless `CODEX_LOOPS_JOURNAL_PATH` is set. `etc` should remain unused for v1 unless implementation adds an optional sample env file; required configuration should stay environment-driven.

## Dependency model

Use Homebrew dependencies only for platform and toolchain packages, not for Mix application dependencies.

Recommended formula dependencies for macOS v1:

```ruby
depends_on :macos

depends_on "elixir" => :build
depends_on "erlang" => :build
depends_on "zig@0.15" => :build
depends_on "xz" => :build

depends_on "openssl@3"
uses_from_macos "ncurses"
uses_from_macos "zlib"
```

Rationale:

- `elixir` and `erlang` are build-time dependencies for `mix release`. The project currently allows Elixir `~> 1.18`, and Homebrew's current `elixir` formula is newer than that lower bound, so do not pin a versioned Elixir formula unless source-build proof shows a break.
- `erlang` is explicit even though Homebrew's `elixir` depends on it, because the formula is building and packaging an ERTS-bearing release and should make that build relationship obvious.
- `zig@0.15` is build-only because Burrito 1.5 requires Zig 0.15.2. Use the versioned formula path explicitly when invoking the build, for example by passing `ZIG=#{Formula["zig@0.15"].opt_bin/"zig"}`.
- `xz` is build-only because Burrito requires `xz`. Do not add `p7zip` for macOS v1; Burrito only needs `7z` for Windows targets, which are out of scope for this package.
- `openssl@3` should be runtime, not build-only, because Mix release guidance calls out OpenSSL as a common runtime package for Erlang `:crypto` and `:ssl`, and Codex Loops includes both applications.
- `ncurses` and `zlib` are system libraries on macOS. The current local release's ERTS links to `/usr/lib/libncurses` and `/usr/lib/libz`; bottle CI should still run `brew linkage --test codex-loops` and promote any Homebrew-linked libraries it finds into runtime `depends_on` entries.
- `codex` is not a formula dependency. Missing Codex CLI is handled by `codex-loops install`, which should fail with the exact fix chosen by the map: `brew install --cask codex`.
- Node, pnpm, Playwright, browser E2E dependencies, Dialyzer, Credo, Sobelow, and development/test-only Mix dependencies are not formula dependencies.
- SQLite is not a Homebrew dependency for macOS v1 unless linkage proof shows otherwise. The current `exqlite` NIF in the local built release links only to system libraries.

Mix and Hex dependencies from `mix.lock` should be treated as application dependencies that are compiled into the release, not as Homebrew formula dependencies. If later bottle/source-build proof requires fully offline source builds, solve that with generated formula resources or a vendored source artifact; do not model every Hex package as a top-level Homebrew dependency.

## Build commands

The formula build should do the moral equivalent of:

```ruby
system "mix", "local.hex", "--if-missing", "--force"
system "mix", "local.rebar", "--if-missing", "--force"
system "mix", "deps.get", "--only", "prod"
system "make", "release"
system "make", "release-mcp",
  "MCP_BURRITO_TARGET=native",
  "ZIG=#{Formula["zig@0.15"].opt_bin/"zig"}"

libexec.install "_build/prod/rel/agent_loops" => "scheduler"
libexec.install "_build/prod/mcp/codex-loops-mcp" => "mcp/codex-loops-mcp"
```

Implementation should prefer a new packaging target over reusing the existing plugin-copy side effects forever. The final formula should install from `_build/prod/rel/agent_loops` and `_build/prod/mcp/codex-loops-mcp`, not from `plugins/codex-loops/scheduler` or `plugins/codex-loops/mcp`.

## `test do` contract

The formula test must be non-interactive, use `testpath` for `HOME` and journal state, and require no Codex login or paid provider turn.

Minimum required proof:

- `#{bin}/codex-loops --version` returns the installed Codex Loops version.
- The scheduler release at `#{libexec}/scheduler/bin/agent_loops` starts on an isolated loopback port with `CODEX_LOOPS_SERVER=1`, `CODEX_LOOPS_JOURNAL_PATH=#{testpath}/runs.sqlite`, `RELEASE_DISTRIBUTION=none`, and a unique `RELEASE_NODE`.
- `GET /api/health` returns a scheduler `ok` envelope.
- A tiny workflow validates through `POST /api/workflows/validate`.
- The scheduler stops cleanly through the release control script.
- The MCP executable can at least complete JSON-RPC `initialize` and `tools/list` over stdio against the installed runtime, or `codex-loops doctor --runtime-only` should cover the same MCP/scheduler discovery path once that command exists.

Do not make `brew test` run `codex-loops install`, install the Codex marketplace plugin, require the `codex` CLI, or start a live `provider: "codex"` run.

## Caveats

The formula should print only the packaging-specific next step and useful runtime paths:

```text
Codex Loops runtime was installed.

Next:
  codex-loops install

Runtime:
  Scheduler release: #{opt_libexec}/scheduler/bin/agent_loops
  MCP executable:    #{opt_libexec}/mcp/codex-loops-mcp
  Journal default:   ~/.codex/workflows/runs_1.sqlite
```

Keep caveats short. Do not hide real setup work inside caveats, and do not suggest manual plugin file copying.

## Bottle boundary

The formula should be bottle-first:

- Apple Silicon macOS bottle is required for the v1 happy path.
- Intel macOS bottle can follow once proof gates are in place.
- Linux/Homebrew remains outside this ticket's final decision; the map already keeps the exact Linux boundary as not-yet-specified fog.
- Source builds are allowed but are not the normal developer path. They require the build-only toolchain and must pass `brew install --build-from-source`, `brew test`, `brew audit --strict --new --online`, and the package-specific proof gates before release.

Normal users should not see or install build-only dependencies when pouring a bottle. `codex-loops install` must never repair missing build dependencies by running Homebrew itself.

## Follow-on implications

This decision leaves the existing map tickets intact:

- [Define the codex-loops install command contract](https://github.com/pproenca/codex-loops/issues/115) should define the `codex-loops install`, `doctor`, non-interactive, and missing-`codex` behavior exposed by `bin/codex-loops`.
- [Design brewed runtime discovery for the Codex marketplace plugin](https://github.com/pproenca/codex-loops/issues/116) should use the `libexec` runtime root and avoid plugin-relative bundled scheduler assumptions.
- [Specify Homebrew bottle, release, and proof gates](https://github.com/pproenca/codex-loops/issues/117) should turn the bottle-first boundary and source-build proof into CI gates.

No new wayfinder ticket is needed from this answer.
