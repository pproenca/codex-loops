# Elixir, Burrito, and Homebrew distribution guidance

Date: 2026-07-09

Wayfinder context: simplify Codex Loops installation so developers can use
Homebrew for the local runtime and `codex-loops install` for Codex plugin setup.

Primary sources:

- [Mix release docs](https://mix.hexdocs.pm/Mix.Tasks.Release.html)
- [Elixir v1.9 release announcement](https://elixir-lang.org/blog/2019/06/24/elixir-v1-9-0-released/)
- [Burrito README](https://github.com/burrito-elixir/burrito)
- [Burrito package page](https://hex.pm/packages/burrito)
- [Homebrew tap guide](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap)
- [Homebrew Formula Cookbook](https://docs.brew.sh/Formula-Cookbook)
- [Homebrew Acceptable Formulae](https://docs.brew.sh/Acceptable-Formulae)
- [Homebrew Maintainer Guide](https://docs.brew.sh/Homebrew-homebrew-core-Maintainer-Guide)
- [Homebrew Tap Trust](https://docs.brew.sh/Tap-Trust)

## Executive answer

The standard path for Codex Loops should stay close to the tools' native
models:

1. Package the scheduler as a normal Elixir Mix release.
2. Package the MCP adapter as a Burrito-wrapped executable.
3. Put both artifacts behind a normal Homebrew tap formula.
4. Let Homebrew bottles deliver the fast, low-friction install path for
   developers.
5. Keep `codex-loops install` as a post-install setup command that uses the
   Codex CLI to install or enable the Codex plugin from the Codex marketplace.

This keeps developer setup simple without making the formula run surprise
installers, download unversioned code, or depend on Codex plugin install hooks
that do not exist today.

## Elixir release guidance

Elixir's release system is the right shape for the scheduler runtime. The Mix
docs describe `mix release` as assembling a self-contained release for the
project, and the Elixir v1.9 announcement says releases package application
code, dependencies, and the Erlang VM/runtime into one deployable unit.

That matches `agent_loops`: it is a local Phoenix scheduler, not a single CLI
entrypoint. The release gives us the generated `bin/agent_loops` lifecycle
script that the MCP adapter already knows how to start and stop.

Important constraints:

- A release artifact is target-specific. The Mix docs say host and target must
  match architecture, vendor/OS, and ABI, commonly represented as target
  triples.
- Dependencies with NIFs must be compiled for the same target. This matters for
  Codex Loops because `exqlite` brings SQLite NIF artifacts.
- Runtime system package needs still matter. Mix calls out OpenSSL as a common
  dynamically linked runtime dependency for `:crypto` or `:ssl`.
- `include_erts` should remain enabled by default for our user-facing artifact;
  disabling it requires an exact matching ERTS on the target and is not the
  simple developer path.

For Homebrew, this points to building the release in the formula/CI environment
and publishing bottles per supported target, rather than asking users to build
locally in normal use.

## Burrito guidance

Burrito is the right shape for the MCP adapter, not necessarily for the whole
scheduler. Burrito's README frames the project around distributing Elixir CLI
applications when the target environment cannot be assumed to have Erlang
installed. Its feature overview says it builds a self-extracting archive
containing compiled BEAM code, required ERTS, and compilation artifacts for
Elixir-make based NIFs.

Current Codex Loops already follows that split:

- `agent_loops`: normal Mix release for the scheduler.
- `codex_loops_mcp`: Mix release wrapped with `Burrito.wrap/1`.

Burrito's runtime notes say Linux has no runtime dependencies and macOS has no
runtime dependencies, but macOS Gatekeeper needs a security exemption unless the
binary is code-signed. For a polished macOS-first package, code signing and
notarization may need a later decision if users see Gatekeeper friction when the
Burrito executable is installed outside normal Homebrew bottle handling.

Burrito also provides precompiled Erlang/OTP distributions for darwin x86_64,
darwin aarch64, linux x86_64, linux aarch64, and windows x86_64. That supports
the idea of CI-built artifacts per target, but Homebrew's simpler user story is
still a formula plus bottles.

## Homebrew guidance

Homebrew's recommended tap install path is direct install with a fully qualified
formula name, for example `brew install user/repository/formula`; Homebrew will
add the tap before installing the formula.

Formulae should declare dependencies with `depends_on`. The Formula Cookbook
also warns that Homebrew's prefix `bin` directory is not on `PATH` during
formula installation, so build dependencies must be declared for Homebrew to add
them to the build environment.

Homebrew guidance favors minimal, accurate dependencies. The maintainer guide
says dependencies should be accurate and minimal, and the default formula should
avoid optional features that pull in large dependency trees.

Homebrew formulae should have `test do` blocks that run without user input and
exercise basic functionality. For Codex Loops, that suggests tests such as:

- `codex-loops --version`
- `codex-loops doctor --no-codex` or equivalent non-interactive preflight
- the scheduler release booting on an isolated loopback port and answering
  `/api/health`
- the MCP executable returning a useful `--help` or initializing in a bounded
  local fixture, if practical

Homebrew `caveats` are the right place to print the next step after install,
such as `codex-loops install`. Caveats should explain packaging-specific setup,
not hide complex installation behavior.

For non-official taps, Homebrew tap trust matters. Directly installing a
fully-qualified formula trusts only that item; broad `brew tap` plus short-name
install may require broader trust. The docs recommend fully-qualified install
for one-command user setup.

## What this means for Codex Loops

The developer-facing path should be:

```sh
brew install pproenca/codex-loops/codex-loops
codex-loops install
```

The formula should:

- build the scheduler Mix release;
- build the Burrito MCP executable;
- install release payloads under Homebrew-managed paths, likely `libexec`;
- expose a small `codex-loops` command from `bin`;
- expose or wrap the MCP executable so the Codex plugin can find it;
- declare build dependencies such as Elixir/Erlang, Zig, and xz only as needed
  for source builds;
- rely on bottles so regular developers are not installing or debugging that
  build stack manually;
- include a `test do` block that proves the installed artifacts work without
  requiring Codex login or a paid Codex provider turn;
- print caveats pointing to `codex-loops install`.

The `codex-loops install` command should:

- require a working `codex` CLI on `PATH`;
- if missing, fail with `brew install --cask codex` as the recommended fix;
- idempotently run the documented Codex plugin marketplace flow;
- avoid installing Homebrew casks or running package-manager operations itself;
- verify the plugin is enabled and can find the Homebrew-installed runtime;
- keep Codex plugin updates owned by Codex.

## Open implementation questions

- Exact Homebrew layout: where to put the scheduler release, MCP executable,
  plugin launcher metadata, and any wrapper scripts under `libexec`, `bin`, and
  `etc`.
- Exact build dependency set and scopes for formula source builds, especially
  Elixir/Erlang, Zig 0.15.2, xz, and any OpenSSL/libsqlite implications.
- Whether the tap CI can reliably build bottles for macOS Apple Silicon first,
  then macOS Intel and Linux later.
- Whether the Burrito MCP executable needs code signing or notarization beyond
  what Homebrew bottle installation normally provides.
- Exact runtime/plugin compatibility contract between the Codex marketplace
  plugin and the brewed runtime.

