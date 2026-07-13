# Codex Loops

Codex Loops is a local, path-first workflow scheduler for Codex. It ships as one
immutable Elixir/Phoenix OTP release with the Codex Loops skill. The release
owns the scheduler, a Streamable HTTP MCP endpoint, Phoenix LiveView, the SQLite
journal, and one lazily started shared Codex app-server. Codex connects directly
to `http://127.0.0.1:47125/mcp`; there is no Rust runtime, stdio bridge, or
second application server.

## Install In One Action

Download and verify the signed archive for the host target, unpack it, and run:

```sh
./install
```

That one action installs the immutable release and skill, selects `codex` from
PATH, records its lexical absolute path and exact version, provisions and starts
the per-user login service, checks scheduler health, and registers the `/mcp`
URL in Codex. To select a specific command instead:

```sh
./install --codex /absolute/path/to/codex
```

The binding preserves paths such as mise/asdf shims. If the selected command
moves or its version changes, rerun `./install` from the current archive (or
`codex-loops install --codex /absolute/path/to/codex`) to reconcile it.

The installed service is a macOS user LaunchAgent or Linux `systemd --user`
unit. Its lifecycle is explicit and independent of Codex connections:

```sh
codex-loops status --json
codex-loops restart
codex-loops stop
codex-loops serve
codex-loops doctor --json
```

`serve` enables and starts the user service, then returns only after the
scheduler is healthy. The service manager owns the foreground OTP release and
restarts it according to the host service policy.

## Workflow Example

```elixir
workflow "audit-workflow" do
  phase "audit"
  log "starting audit"
  agent "Inspect the auth boundary and report the highest-risk issue."
  return :ok
end
```

A workflow file contains exactly one bare, top-level `workflow` declaration.
The scheduler parses that declaration as data; it does not compile the file,
execute it, or discover a module through reflection.

For production-shaped workflows covering incident response, release readiness,
dependency upgrades, bounded discovery, consensus repair, architecture decisions,
and adversarial refinement, see [`examples/`](examples/README.md). The examples
are executable fixtures: the test suite loads every one through the public script
gate and pins their major orchestration shapes.

The language is bounded: agent retries are `0..5`, loops require
`max_iterations` in `1..1000`, resolved fanout width never exceeds 64, the
scheduler admits at most eight active runs, and each run executes at most eight
workflow tasks concurrently. `while_budget`, `until_dry`, and `fan_out` are
compatibility aliases over the generic `loop`/`fanout` semantic core.

Drive it through MCP:

The one-action installer starts the service before registering MCP. If it was
stopped later, run `codex-loops serve` before using the tools.

```text
workflow_validate script_path=.codex/workflows/audit_workflow.exs workspace_root=/absolute/path/to/repo
workflow_start    script_path=.codex/workflows/audit_workflow.exs workspace_root=/absolute/path/to/repo run_id=run_audit provider=mock
workflow_status   run_id=run_audit
workflow_inspect  run_id=run_audit
workflow_open_ui  run_id=run_audit
```

Relative MCP `script_path` values require an explicit absolute existing
`workspace_root`. The scheduler canonicalizes both, rejects paths that escape
the root (including through symlinks), journals the root, and uses it as the
Codex working directory. An absolute `script_path` may omit `workspace_root`.
Run live only after the mock gate is clean by selecting `provider=codex`.

## Development And Distribution

```sh
make build        # compile from a clean checkout
make ci           # complete deterministic gate
make dev-bundle   # assemble the fixed runnable layout
MINISIGN_SECRET_KEY=/path/to/key make dist # create checksum and signed target archive
# after collecting all four target artifacts in DIST_DIR:
make homebrew-formula
```

`make dist` fails unless it can produce the minisign signature required for a
canonical release. Release CI runs it once for each supported target. After all
four archive/checksum/signature triples are collected, `make homebrew-formula`
validates them and emits the one cross-platform Homebrew formula. Each archive
also contains the one-action `install`; after
signature and checksum verification, it installs the bundle under
`~/.local/share/codex-loops/<version>`, atomically switches `current`, exposes
`~/.local/bin/codex-loops`, reconciles the exact Codex binding and skill,
provisions the login service, verifies health, and registers MCP. The canonical
artifact layout is:

```text
bin/codex-loops
libexec/scheduler/
share/skills/codex-loops/
share/codex-loops/runtime.json
install
VERSION
```

Release archives are versioned and immutable. Package managers should install
the exact published archive and run its installer, not independently rebuild or
partially configure it. The runtime itself never infers a package-manager
prefix.

`make ci` runs formatting, audits, Credo, Sobelow, the full Elixir suite,
Dialyzer, browser LiveView E2E, skill-only plugin validation, bundled
release/API/service proof, and direct Streamable HTTP MCP conformance.
Credential-free tests use a schema-aware Codex subprocess fixture;
authenticated live proofs remain manual.

## Runtime Configuration

The installed service binds to loopback port `47125`. The default journal is
`~/.codex/workflows/runs_1.sqlite`; `CODEX_LOOPS_JOURNAL_PATH` is available for
deliberately isolated development and proof releases. Production Codex provider
turns use only the exact binding written during installation and never search
PATH.

## Packages

- Elixir release, scheduler, installer, and MCP: `lib/workflow/**`,
  `test/workflow/**`.
- Optional skill-only plugin: `plugins/codex-loops`.
- Canonical docs: `docs`.

## License

MIT. See [LICENSE](LICENSE).
