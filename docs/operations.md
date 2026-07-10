# Codex Loops Operations

## Developer Setup

```sh
make build
make ci
make release
```

`make build` installs missing dependencies and compiles with warnings as
errors. `make ci` executes every deterministic validation stage end-to-end.
`make release` produces the distributable local scheduler artifact under
`_build/prod/rel/agent_loops/`. `.tool-versions` pins the known-good local
toolchain for `mise`/`asdf`.

After `make ci`, maintainers can perform a separate authenticated dogfood run
from a fresh Codex thread when a release changes the real-provider boundary.

## CI Gate

```sh
make ci
```

Run this before handing off any code change. It includes Styler formatting,
dependency audits, warnings-as-errors compilation, Credo, Sobelow, spec lint,
the complete scheduler/API/UI Elixir suite, Dialyzer, PhoenixTest Playwright
browser E2E, plugin-package validation, packaged release/API/CLI proof, and
packaged MCP lifecycle plus workflow-conformance proof.

The narrower internal targets remain available for diagnosing a failing stage,
but contributors should not need to compose the validation graph themselves.

Sobelow runs against the explicit Phoenix router at medium-or-higher confidence
and intentionally ignores `Config.HTTPS` and `Config.CSP`. Codex Loops defaults
the packaged scheduler to loopback (`CODEX_LOOPS_HOST=127.0.0.1`) as a local
product surface, and it does not yet ship an asset pipeline CSP policy.
Non-loopback binding is an explicit deployment choice and must be paired with
the host's normal access controls, such as a trusted reverse proxy, tunnel,
firewall, or private network boundary.

Low-confidence Sobelow categories are intentionally kept out of `make ci` to
avoid turning the ordinary handoff loop into a noisy
static-analysis triage queue. Review them out-of-band when changing the Phoenix
surface, security-sensitive runtime configuration, or dependency stack, and
promote any concrete finding into code-level skips or a stricter gate. The
journal's local term decoding uses `binary_to_term(..., [:safe])`; the two
remaining Sobelow term-decoding reports are skipped at the function level with
that rationale in code.

## Static Analysis

Dialyzer is part of `make ci`. Its checked-in ignore baseline remains explicit,
and any new type warning fails the gate.

## Browser E2E

As part of `make ci`, the browser stage installs the Playwright Node package and
Chromium under the local `assets` workspace, starts the test endpoint on a local
port, and runs tests tagged `:browser_e2e`. These tests use mock providers and
isolated test state; they do not spend live Codex provider turns.

The browser stack is PhoenixTest plus PhoenixTest Playwright. Recode, Green,
Wallaby, Hound, Selenium, Cypress, and non-Elixir browser frameworks are not
part of the selected gate for this rollout.

## Release Proof

The release-proof stage of `make ci` builds the Mix release and exercises the scheduler readiness path. The
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

## Live Provider Diagnostic

The credential-free CI gate uses a schema-aware Codex subprocess fixture to
prove streaming and provider protocol behavior deterministically. Maintainers
may separately run the live-provider proof when changing the Codex boundary;
it requires authentication and spends one real turn, so it is intentionally
not part of normal CI.

## Manual CLI Run

For a normal interactive run, start the managed local scheduler and launch the
workflow directly with one command. No environment variables or raw HTTP calls
are required:

```sh
codex-loops run .codex/workflows/codex_answer.exs --open
```

The CLI defaults to `127.0.0.1:47125`, the standard user journal, a generated
run ID, and the live `codex` provider. `run` validates before starting, prints
the LiveView URL even without `--open`, and starts the managed scheduler when
the local endpoint is not already healthy.

```sh
codex-loops stop
```

Use `codex-loops serve` when you want to start or customize the scheduler
separately. Configuration is progressively disclosed through `serve --host`, `--port`,
`--journal`, and `--model`, or `run --provider`, `--run-id`, and `--server`.

## Manual MCP Smoke

Build the external runtime first:

```sh
make release
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
