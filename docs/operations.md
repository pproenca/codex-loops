# Codex Loops Operations

## Developer Setup

```sh
make setup
make quality
make release
make proof
```

`make setup` installs Hex/Rebar and fetches Elixir dependencies.
`.tool-versions` pins the known-good local toolchain for `mise`/`asdf`.

`make quality` is the fast pre-handoff gate: it checks formatting through
Styler, audits dependencies, compiles with warnings as errors, runs Credo, runs
Sobelow, runs the spec lint, and runs the scheduler/API/UI Elixir test suite.
`make release` produces the distributable local scheduler artifact under
`_build/prod/rel/agent_loops/`.

For a repeatable local dogfood run, use:

```sh
make dogfood
```

It proves the source plugin against the staged external runtime, reinstalls
`codex-loops@codex-loops` from the current checkout, verifies Codex sees the
plugin, and prints the environment-aware command and prompt for a fresh CLI
thread.

## Fast Quality Gate

```sh
make quality
```

Run this before handing off ordinary code changes. It is intentionally local and
fast: `mix format --check-formatted` with Styler, dependency audits, compile
with warnings as errors, Credo, Sobelow, the spec lint, and the scheduler/API/UI
test suite. It does not build releases, package the MCP executable, reinstall
the plugin, run browser tests, build Dialyzer PLTs, or spend live Codex provider
turns.

The individual fast gates are also available:

```sh
make format-check
make audit-check
make build
make credo-check
make security-check
make test
```

Sobelow runs against the explicit Phoenix router at medium-or-higher confidence
and intentionally ignores `Config.HTTPS` and `Config.CSP`. Codex Loops defaults
the packaged scheduler to loopback (`CODEX_LOOPS_HOST=127.0.0.1`) as a local
product surface, and it does not yet ship an asset pipeline CSP policy.
Non-loopback binding is an explicit deployment choice and must be paired with
the host's normal access controls, such as a trusted reverse proxy, tunnel,
firewall, or private network boundary.

Low-confidence Sobelow categories are intentionally kept out of the fast
`make quality` gate to avoid turning the ordinary handoff loop into a noisy
static-analysis triage queue. Review them out-of-band when changing the Phoenix
surface, security-sensitive runtime configuration, or dependency stack, and
promote any concrete finding into code-level skips or a stricter gate. The
journal's local term decoding uses `binary_to_term(..., [:safe])`; the two
remaining Sobelow term-decoding reports are skipped at the function level with
that rationale in code.

## Optional Analysis

```sh
make dialyzer-check
```

Dialyzer is available through Dialyxir but stays out of `make quality` so the
ordinary handoff loop does not depend on PLT setup. Run it when changing specs,
cross-module data contracts, or runtime boundaries. The current opt-in baseline
is intentionally not hidden: first setup builds the dev PLT, then Dialyzer
reports the existing type-shape warnings for later cleanup.

## Browser E2E

```sh
make browser-e2e-setup
make browser-e2e
```

`make browser-e2e-setup` installs the Playwright Node package and Chromium under
the local `assets` workspace. `make browser-e2e` depends on that setup target,
then starts the test endpoint on a local port and runs only tests tagged
`:browser_e2e`. These tests use mock providers and isolated test state; they do
not spend live Codex provider turns.

The browser stack is PhoenixTest plus PhoenixTest Playwright. Recode, Green,
Wallaby, Hound, Selenium, Cypress, and non-Elixir browser frameworks are not
part of the selected gate for this rollout.

## Release Proof

```sh
make proof
```

This builds the Mix release and exercises the scheduler readiness path. The
proof starts the packaged Phoenix scheduler release on `127.0.0.1:47125` by
default with an isolated SQLite journal, then:

```sh
GET  /api/health
POST /api/workflows/validate
POST /api/runs
GET  /api/runs/<id>
GET  /api/runs/<id>/events
GET  /runs/<id>
```

The API checks are polling contracts: `/api/runs/<id>` is the run projection
snapshot, and `/api/runs/<id>/events` is a durable journal-summary inspection
surface. The `/runs/<id>` route is the LiveView surface used for realtime
progress activity.

Override proof binding and journal isolation when needed:

```sh
CODEX_LOOPS_PROOF_HOST=127.0.0.1 \
CODEX_LOOPS_PROOF_PORT=47126 \
CODEX_LOOPS_PROOF_JOURNAL_PATH=/tmp/codex-loops-proof.sqlite \
make proof
```

## Live Proof

```sh
make proof-mcp-live
make proof-live
```

`make proof-mcp-live` spends one live Codex provider turn through the
source-plugin launcher, external OTP runtime, and scheduler lifecycle path, then asserts the run
completed and recorded nonzero token usage in the scheduler projection. It
proves the polling MCP path for live Codex completion; the realtime viewing
surface remains the LiveView URL returned by `workflow_open_ui`.
`make proof-live` aliases the same MCP proof.

## Manual CLI Run

For a normal interactive run, start the managed local scheduler and launch the
workflow directly. No environment variables or raw HTTP calls are required:

```sh
codex-loops serve
codex-loops run .codex/workflows/codex_answer.exs --open
```

The CLI defaults to `127.0.0.1:47125`, the standard user journal, a generated
run ID, and the live `codex` provider. `run` validates before starting and
prints the LiveView URL even without `--open`.

```sh
codex-loops stop
```

Configuration is progressively disclosed through `serve --host`, `--port`,
`--journal`, and `--model`, or `run --provider`, `--run-id`, and `--server`.

## Manual MCP Smoke

Build the external runtime first:

```sh
make release
make package-homebrew-runtime
```

Then, from a Codex thread with the local plugin installed, run a non-mutating
workflow through the MCP tools:

```text
workflow_validate script_path=.codex/workflows/example.exs
workflow_start    script_path=.codex/workflows/example.exs run_id=run_example provider=mock
workflow_status   run_id=run_example
workflow_inspect  run_id=run_example
workflow_open_ui  run_id=run_example
```

Only run the live smoke after the mock path is clean:

```text
workflow_start  script_path=.codex/workflows/example.exs run_id=run_example_live provider=codex
workflow_status run_id=run_example_live
workflow_open_ui run_id=run_example_live
workflow_inspect run_id=run_example_live
```

Use `workflow_open_ui` to watch live provider activity. `workflow_status` polls
the latest run projection, and `workflow_inspect` returns durable journal
summaries plus raw refs; neither MCP tool is a realtime stream.

## Normal Workflow Run

Agents should use the Codex plugin MCP tools. The MCP adapter starts or
discovers the scheduler, health-checks it, and talks to the scheduler HTTP API.
The Elixir/Phoenix scheduler owns the workflow workers, PubSub/LiveView, and
SQLite journal.

```text
workflow_validate script_path=.codex/workflows/example.exs
workflow_start    script_path=.codex/workflows/example.exs run_id=run_example provider=mock
workflow_status   run_id=run_example
workflow_inspect  run_id=run_example
```

Run live only after the mock gate is clean:

```text
workflow_start  script_path=.codex/workflows/example.exs run_id=run_example_live provider=codex
workflow_status run_id=run_example_live
workflow_open_ui run_id=run_example_live
```

## Status, Inspect, Open UI, Resume

```text
workflow_status  run_id=<id>
workflow_inspect run_id=<id>
workflow_open_ui run_id=<id>
workflow_resume  run_id=<id> provider=codex
```

`workflow_status` is a polling snapshot of the current run projection.
`workflow_inspect` is a durable inspection view with `journalEvents` summaries
and ordered `rawRefs`; it does not expose raw Codex JSONL by default.
`workflow_open_ui` returns the Phoenix LiveView URL, which is where realtime
progress messages and activity entries are watched.

## Failure Parsing

MCP tools return scheduler success envelopes as structured content. Scheduler
typed errors remain typed and are returned as MCP errors.

## Runtime Artifacts

Treat these as generated runtime artifacts:

- `~/.codex/workflows/runs_1.sqlite`
- `~/.codex/workflows/runs_1.sqlite-wal`
- `~/.codex/workflows/runs_1.sqlite-shm`
- `_build/prod/rel/agent_loops/`
