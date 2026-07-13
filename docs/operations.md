# Codex Loops Operations

## Developer Setup

```sh
make build
make ci
make dev-bundle
MINISIGN_SECRET_KEY=/path/to/key make dist
```

`make build` installs missing dependencies and compiles with warnings as
errors. `make ci` executes every deterministic validation stage end-to-end.
`make dev-bundle` assembles the native command, scheduler release, and skill
under `_build/dev-bundle/`. `make dist` signs and packages that exact layout
under `_build/dist/`; it deliberately fails without a minisign key. The archive's
`install` command performs the versioned installation and atomic `current` link
switch. `.tool-versions` pins the known-good local
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

## Bundle Proof

The bundle-proof stage of `make ci` builds the complete runtime and exercises the scheduler readiness path. The
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
rendering. Provider activity is appended to SQLite before LiveView receives a
post-commit refresh notification, so browser reconnects and polling reads see
the same projection.

## Live Provider Diagnostic

The credential-free CI gate uses a schema-aware Codex subprocess fixture to
prove streaming and provider protocol behavior deterministically. Maintainers
may separately run the live-provider proof when changing the Codex boundary;
it requires authentication and spends one real turn, so it is intentionally
not part of normal CI.

Provider subprocesses have a finite 30-minute default deadline and 16 MiB input
and stdout limits. Workflow concurrency is capped system-wide at eight tasks and
fanout width at 64, even when a script asks for more. Agent retries are capped at
five and loop iterations at 1000. A limit breach is a typed provider or run
failure, never an infinite wait or unbounded accumulation.

## Manual CLI Run

For a normal interactive run, assemble and bind the bundle once, then launch a
workflow. No runtime-discovery environment variables or raw HTTP calls are
required:

```sh
make dev-bundle
_build/dev-bundle/bin/codex-loops install --codex "$(command -v codex)"
_build/dev-bundle/bin/codex-loops run .codex/workflows/codex_answer.exs --open
```

The CLI defaults to `127.0.0.1:47125`, the standard user journal, a generated
run ID, and the live `codex` provider. `run` validates before starting, prints
the LiveView URL even without `--open`, and starts the managed scheduler when
the local endpoint is not already healthy.

```sh
_build/dev-bundle/bin/codex-loops stop
```

Use `_build/dev-bundle/bin/codex-loops serve` when you want to
start or customize the scheduler separately. Configuration is progressively
disclosed through `serve --host`, `--port`, `--journal`, and `--model`, or
`run --provider`, `--run-id`, and `--server`.
The native control plane is the single scheduler owner. It supervises the
foreground OTP release from a per-user runtime directory under
`~/.codex/workflows/runtime`; MCP sessions never own or stop that supervisor.
Unexpected scheduler exits are restarted with bounded backoff while the native
supervisor retains its owner lock. Startup is transactional: a scheduler is
terminated if owner metadata cannot be committed. Stable supervisor metadata
remains addressable while a child is in crash backoff, and a failed initial
health deadline stops the supervisor so a corrected command can retry
immediately. A healthy HTTP endpoint is only reported as managed-ready while
that durable owner lock is still held; a scheduler that outlives its supervisor
returns a typed ownership error instead of a successful start result.

An explicit `--server URL` or `CODEX_LOOPS_SCHEDULER_URL` selects an externally
managed scheduler. The client requires a compatible `scheduler.v1` health
envelope but does not create local owner state, autostart it, or control its
lifecycle and logs. Status, inspection, UI, and pathless resume use the HTTP
seam directly. Validation, start, or resume with a workflow path additionally
requires `CODEX_LOOPS_SHARED_FILESYSTEM=1` when the URL is remote; set that only
when the client and scheduler resolve the same absolute paths.

Power-user lifecycle controls use the same host/port identity and honor
`CODEX_LOOPS_SCHEDULER_HOST` plus `CODEX_LOOPS_SCHEDULER_PORT`:

```sh
./native/codex-loops/target/release/codex-loops logs --lines 500
./native/codex-loops/target/release/codex-loops restart --journal /tmp/isolated.sqlite
./native/codex-loops/target/release/codex-loops serve --foreground
./native/codex-loops/target/release/codex-loops stop --force
```

`--foreground` is intended for an external process manager and exits on
SIGINT/SIGTERM. `--force` is a recovery tool for an orphaned scheduler: it
requires valid owner metadata and verifies the recorded process belongs to the
packaged release before signaling it. It does not kill arbitrary services on a
configured port. Ordinary stop preserves verified orphan metadata and returns
`scheduler_orphaned` with explicit force-stop guidance.

`restart` inherits the active bind address, journal path, and model unless a
replacement flag or environment value is supplied. This prevents a restart of
a custom-journal scheduler from silently switching to the default database.
Concurrent cold starts coordinate through an owner token: exactly one caller
reports `started: true`, compatible callers join with `started: false`, and a
caller requesting a different bind, journal, or model receives the typed
`scheduler_configuration_conflict` error without changing the winner.
Timeout cleanup is owner-token scoped, so a short-timeout joiner cannot stop a
slower lock winner.

Power-user reads use the same scheduler HTTP seam:

```sh
_build/dev-bundle/bin/codex-loops status RUN_ID --json
_build/dev-bundle/bin/codex-loops inspect RUN_ID --json
_build/dev-bundle/bin/codex-loops resume RUN_ID --provider codex
_build/dev-bundle/bin/codex-loops open RUN_ID
_build/dev-bundle/bin/codex-loops doctor --json
```

## Manual MCP Smoke

Build the scheduler and native control plane first:

```sh
make dev-bundle
_build/dev-bundle/bin/codex-loops install --codex "$(command -v codex)"
_build/dev-bundle/bin/codex-loops serve
```

Then, from a restarted Codex task, run a non-mutating
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

## Retained Sandbox Runs

`sandbox-run` is the inspectable end-to-end MCP surface. It creates a detached
worktree from the repository's current `HEAD`, so the workflow script must be
committed. The run uses its own home, scheduler owner/runtime directory, journal,
and reserved loopback port. It also points the scheduler and MCP process at a
config-isolated `CODEX_HOME` under the retained artifact. On Unix, when the
source `CODEX_HOME/auth.json` is a regular file or a symlink to one, the sandbox
home exposes only that credential file through a symlink; it does not expose or
copy user `config.toml`, plugins, or instruction files. Environment-based
`CODEX_ACCESS_TOKEN` authentication remains inherited when no file credential
exists. Codex namespaces keyring credentials by the canonical `CODEX_HOME`, so
an existing source-home keyring entry is not visible from the isolated home;
use file authentication or `CODEX_ACCESS_TOKEN` for a config-isolated sandbox.
For `provider=codex`, the isolated scheduler's app-server uses an ephemeral
thread, a workspace-write policy, and the detached worktree as its explicit
working directory.

```sh
codex-loops sandbox-run .codex/workflows/smoke.exs --provider mock --json
codex-loops sandbox-run .codex/workflows/smoke.exs --provider codex --open
```

The retained directory contains:

```text
manifest.json
mcp-transcript.jsonl
initialize.json
tools.json
validation.json
start.json
status.json
inspect.json
open-ui.json
journal.sqlite
runtime/scheduler.log
git-status.txt
git-diff.patch
repo/
```

`sandbox-clean ARTIFACT_DIR` stops the isolated scheduler and removes the Git
worktree plus artifacts. It returns `sandbox_worktree_dirty` if the worktree has
changes; use `--force` only after inspecting or preserving them. An explicit
`--output DIRECTORY` selects a different retained artifact location.

## Normal Workflow Run

Agents should use the registered Codex Loops MCP tools after starting the
scheduler explicitly with `codex-loops serve`, `codex-loops run`, or an external
process manager. The MCP adapter health-checks the configured endpoint and talks
only to its HTTP API; it does not create owner state or manage processes. The
Elixir/Phoenix scheduler owns the shared Codex app-server, workflow workers,
PubSub/LiveView, and SQLite journal.

Relative MCP script paths resolve against the client's workspace root, so the
usual `.codex/workflows/<name>.exs` form works independently of the installed
bundle directory. Clients without MCP roots may set
`CODEX_LOOPS_WORKSPACE_ROOT` explicitly. Sending workflow paths to a non-local
scheduler is rejected unless `CODEX_LOOPS_SHARED_FILESYSTEM=1` confirms that the
same absolute paths exist on both sides.

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
`workflow_open_ui` returns the Phoenix LiveView URL. LiveView refolds the
journal after the post-commit PubSub signal `{:journal_committed, run_id, seq}`;
the signal carries no event snapshot, and LiveView does not maintain a separate
transient progress state.

Resume reuses committed turns and continues after settled rejected attempts.
It never redelivers an attempt whose durable `agent_started` marker has no
matching settlement. Such a run terminates with `outcome_unknown`, because the
provider may already have completed or charged and Codex Loops cannot infer the
result. Inspect the attempt and start a new run only as an explicit operator
decision.

## Failure Parsing

MCP tools return scheduler success envelopes as structured content. Scheduler
typed errors remain typed and are returned as MCP errors.

## Runtime Artifacts

Treat these as generated runtime artifacts:

- `~/.codex/workflows/runs_1.sqlite`
- `~/.codex/workflows/runs_1.sqlite-wal`
- `~/.codex/workflows/runs_1.sqlite-shm`
- `_build/prod/rel/agent_loops/`
