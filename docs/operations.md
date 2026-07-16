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
`make dev-bundle` assembles the release overlay, the complete OTP release, and
the skill under `_build/dev-bundle/`. `make dist` signs and packages that exact
layout under `_build/dist/`; it deliberately fails without a minisign key.
`.tool-versions` pins the known-good Erlang, Elixir, and frontend toolchain for
`mise`/`asdf`. Rust and Cargo are not part of the build.

After `make ci`, maintainers may perform a separate authenticated dogfood run
from a fresh Codex task when a release changes the real-provider boundary.

## One-Action Installation

GitHub release archives are the canonical artifacts. Verify the checksum and
minisign signature, unpack the archive matching the host target, enter its root,
and run:

```sh
./install
```

PATH selects the Codex CLI by default. To preserve a particular shim or command
path, select it explicitly:

```sh
./install --codex /absolute/path/to/codex
```

That single action completes the installation:

1. Copies the bundle to `~/.local/share/codex-loops/<version>` and atomically
   activates `~/.local/share/codex-loops/current`.
2. Exposes `~/.local/bin/codex-loops`.
3. Probes and persists the selected Codex CLI's lexical absolute path and exact
   version.
4. Installs the bundled skill under the user skill root.
5. Installs and starts the login service.
6. Waits for the exact scheduler health contract.
7. Registers `http://127.0.0.1:47125/mcp` through `codex mcp add`.

Reactor is compiled into the same OTP release and starts inside the existing
BEAM. It adds no executable, login service, listener, MCP registration,
installer argument, or macOS signing boundary. The installer's existing health
wait now also requires execution readiness.

The corresponding reconciliation command is:

```sh
codex-loops install [--codex /absolute/path/to/codex] [--check|--dry-run] [--json]
```

`codex-loops check` and `codex-loops dry-run` are aliases for the non-mutating
modes. Installation is idempotent. A missing, moved, or version-changed Codex
binding fails closed; rerun installation intentionally to accept the new
binding.

## User Service Lifecycle

The installed OTP release is one login service:

- macOS: `~/Library/LaunchAgents/com.pproenca.codex-loops.plist`
- Linux: `~/.config/systemd/user/codex-loops.service`

Use the release-overlay command for normal operations:

```sh
codex-loops serve
codex-loops stop
codex-loops restart
codex-loops status --json
codex-loops doctor --json
```

`serve` enables and starts the service, then returns after the scheduler passes
its exact health check. `stop` and `restart` operate through `launchd` or
`systemd --user`. `status` reports both service-definition state and scheduler
health. The service manager owns the release's foreground
`libexec/scheduler/bin/agent_loops start` process; the release does not daemonize
itself.

Codex and other MCP clients are HTTP clients only. Connecting, disconnecting,
or restarting Codex never starts or stops the service. Do not launch a second
scheduler or app-server for a normal workflow run.

For a deliberately isolated development proof, stop or avoid the installed
service and start the packaged release directly with a distinct port and
journal:

```sh
CODEX_LOOPS_SERVER=1 \
CODEX_LOOPS_HOST=127.0.0.1 \
CODEX_LOOPS_PORT=47126 \
CODEX_LOOPS_JOURNAL_PATH=/tmp/codex-loops-proof.sqlite \
CODEX_LOOPS_CODEX_BIN="$(command -v codex)" \
CODEX_LOOPS_BINDING_PATH="$HOME/.codex/workflows/codex-binding.json" \
_build/prod/rel/agent_loops/bin/agent_loops start
```

This is a foreground process for the current shell, not a retained product
mode. The direct release does not infer installation state: the Codex binary
and installer-generated binding file must both be supplied as absolute paths.

## Streamable HTTP MCP

Installation registers:

```sh
codex mcp add codex-loops --url http://127.0.0.1:47125/mcp
```

The Phoenix endpoint serves MCP, the scheduler JSON API, and LiveView in the
same OTP application. There is no stdio command, MCP client binary, or loopback
HTTP adapter.

Each `POST /mcp` body is bounded to 1 MiB. Protocol `2025-03-26` accepts a
single JSON-RPC message or a non-empty batch; later protocols accept only one
message. Batch output contains one response per request and omits notification
and client-response entries. Notifications, client responses, and batches made
only from those entries receive `202` with an empty body. `GET` and `DELETE`
return `405`; the endpoint has no SSE stream and issues no `Mcp-Session-Id`.
Across MCP, API, and LiveView, `Host` must be loopback. `Origin` may be absent
for non-browser clients but must be loopback when present.

Supported protocol versions are `2025-03-26`, `2025-06-18`, and
`2025-11-25`. Calls after initialization validate `MCP-Protocol-Version`; a
missing header uses the compatibility default `2025-03-26`. Supported methods
are `initialize`, `ping`, `tools/list`, and `tools/call`.

To inspect the registered transport:

```sh
codex mcp get codex-loops --json
```

It must report a `streamable_http` transport with the exact loopback `/mcp` URL
and no bearer-token or header indirection.

## Manual MCP Smoke

The archive installer starts the service. If an operator stopped it, run
`codex-loops serve`, then open a fresh Codex task and use an absolute workspace
root with every relative workflow path:

```text
workflow_validate script_path=.codex/workflows/example.exs workspace_root=/absolute/path/to/repo
workflow_start    script_path=.codex/workflows/example.exs workspace_root=/absolute/path/to/repo run_id=run_example provider=mock
workflow_status   run_id=run_example
workflow_inspect  run_id=run_example
workflow_open_ui  run_id=run_example
```

Only run the live smoke after the mock path is clean:

```text
workflow_start   script_path=.codex/workflows/example.exs workspace_root=/absolute/path/to/repo run_id=run_example_live provider=codex
workflow_status  run_id=run_example_live
workflow_open_ui run_id=run_example_live
workflow_inspect run_id=run_example_live
```

`workflow_status` polls the current run projection. `workflow_inspect` returns
durable journal summaries and ordered raw refs. `workflow_open_ui` returns the
Phoenix LiveView URL for realtime watching.

## Workspace Paths

Streamable HTTP has no client process working directory or implicit filesystem
root. Therefore:

- a relative MCP `script_path` requires an explicit `workspace_root`;
- `workspace_root` must be an absolute existing directory;
- the scheduler joins and canonicalizes both paths and rejects containment or
  symlink escapes;
- an absolute `script_path` may omit `workspace_root`; and
- a supplied root is persisted in `run_started`, restored on resume, and used
  as the Codex turn working directory.

Clients must not assume MCP `roots` or the installed bundle directory supplies
the workflow workspace.

## CI Gate

```sh
make ci
```

Run this before handing off a code change. It includes formatting, dependency
audits, warnings-as-errors compilation, Credo, Sobelow, spec lint, the complete
scheduler/API/UI Elixir suite, Dialyzer, PhoenixTest Playwright browser E2E,
plugin-package validation, packaged release/API/service proof, installer proof,
and direct Streamable HTTP MCP conformance.

Sobelow runs against the explicit Phoenix router at medium-or-higher confidence
and intentionally ignores `Config.HTTPS` and `Config.CSP`. The scheduler binds
only to loopback, and runtime configuration rejects wildcard or non-loopback
addresses.

Dialyzer is part of `make ci`; new type warnings fail the gate. Browser E2E uses
mock providers and isolated test state and does not spend live Codex turns.

## Bundle And Provider Proofs

The bundle proof starts the packaged release with an isolated journal and
checks:

```text
GET  /api/health
POST /api/workflows/validate
POST /api/runs
GET  /api/runs/<id>
GET  /api/runs/<id>/events
GET  /runs/<id>
POST /mcp
```

The API status endpoint is a polling projection, the events endpoint is a
durable journal-summary surface, and `/runs/<id>` is LiveView. Provider activity
is appended to SQLite before PubSub sends a post-commit refresh signal, so
polling, reconnecting LiveView clients, and MCP inspect observe the same facts.

Credential-free CI uses a schema-aware Codex subprocess fixture. The live
provider proof remains manual because it requires authentication and spends a
real turn. The scheduler lazily starts one shared Codex app-server only when the
first live attempt needs it; health checks and mock runs do not start Codex.

## Resume And Unknown Outcomes

Provider effects are at-most-once. Immediately before a provider call, the run
writer commits `agent_started`. A matching `agent_committed`,
`agent_attempt_rejected`, or `agent_failed` settles it.

Resume reuses settled work. It never redelivers an attempt whose durable start
has no settlement, because the provider may already have completed or charged.
Such a run terminates with `outcome_unknown`; inspect it and start a new run
only as an explicit operator decision.

## Runtime Artifacts

Treat these as generated runtime artifacts:

- `~/.codex/workflows/runs_1.sqlite`
- `~/.codex/workflows/runs_1.sqlite-wal`
- `~/.codex/workflows/runs_1.sqlite-shm`
- `~/.codex/workflows/codex-binding.json`
- `~/.local/share/codex-loops/`
- the user LaunchAgent or `systemd --user` unit
- `_build/prod/rel/agent_loops/`
