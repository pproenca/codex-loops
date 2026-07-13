# Codex Loops

Codex Loops is a local, path-first workflow scheduler for Codex. It ships as one
immutable runtime bundle containing a native Rust CLI/MCP control plane, a
packaged Elixir/Phoenix scheduler, and the Codex Loops skill. Rust owns
installation, OS-process lifecycle, stdio MCP, and scheduler HTTP calls; Elixir
owns OTP supervision, workflow workers, Phoenix PubSub/LiveView, and the SQLite
journal.

The single `codex-loops` executable exposes both the user CLI and the `mcp`
subcommand. It resolves the scheduler and skill only from fixed paths inside its
bundle. `codex-loops install` binds one exact Codex CLI, installs the user skill,
and registers MCP directly in shared Codex configuration. No process searches
Homebrew prefixes, source checkouts, application bundles, or PATH during a run.

## Source Checkout

```sh
make dev-bundle
_build/dev-bundle/bin/codex-loops install --codex "$(command -v codex)"
```

The Codex binding preserves the selected lexical path, including a mise/asdf
shim, and records its exact `codex --version`. If that command moves or changes,
rerun installation explicitly.

## Run From The CLI

```sh
_build/dev-bundle/bin/codex-loops run .codex/workflows/codex_answer.exs --open
_build/dev-bundle/bin/codex-loops stop
```

`run` starts the managed scheduler when needed, validates the script, generates
a run ID, uses the live Codex provider, and prints the LiveView URL. The default
endpoint is `http://127.0.0.1:47125`; the default journal is
`~/.codex/workflows/runs_1.sqlite`.

Use `serve`, `restart`, `logs`, `--server`, `--journal`, `--model`, and
`--provider mock` for explicit lifecycle and test configuration. Use
`serve --foreground` for an external process manager.

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

The language is bounded: agent retries are `0..5`, loops require
`max_iterations` in `1..1000`, resolved fanout width never exceeds 64, and the
runtime executes at most eight workflow tasks concurrently. `while_budget`,
`until_dry`, and `fan_out` are compatibility aliases over the generic
`loop`/`fanout` semantic core.

Drive it through MCP:

```text
workflow_validate script_path=.codex/workflows/audit_workflow.exs
workflow_start    script_path=.codex/workflows/audit_workflow.exs run_id=run_audit provider=mock
workflow_status   run_id=run_audit
workflow_inspect  run_id=run_audit
workflow_open_ui  run_id=run_audit
```

Run live only after the mock gate is clean by selecting `provider=codex`.

## Development And Distribution

```sh
make build        # compile from a clean checkout
make ci           # complete deterministic gate
make dev-bundle   # assemble the fixed runnable layout
MINISIGN_SECRET_KEY=/path/to/key make dist # create checksum and signed target archive
```

`make dist` fails unless it can produce the minisign signature required for a
canonical release. Each archive also contains `install`; after signature and
checksum verification, it installs the bundle under
`~/.local/share/codex-loops/<version>`, atomically switches `current`, and
exposes `~/.local/bin/codex-loops`. The canonical artifact layout is:

```text
bin/codex-loops
libexec/scheduler/
share/skills/codex-loops/
share/codex-loops/runtime.json
install
VERSION
```

Release archives are versioned and immutable. Package managers should install
the exact published archive and expose a stable symlink to `bin/codex-loops`.
The runtime itself never infers a package-manager prefix.

`make ci` runs formatting, audits, Credo, Sobelow, the full Elixir suite,
Dialyzer, browser LiveView E2E, skill-only plugin validation, bundled
release/API/CLI proof, and MCP workflow conformance. Credential-free tests use a
schema-aware Codex subprocess fixture; authenticated live proofs remain manual.

## Runtime Configuration

Host/port configuration identifies a locally managed scheduler. An explicit
`--server URL` or `CODEX_LOOPS_SCHEDULER_URL` identifies an externally managed
scheduler that is health/version checked but never started or stopped locally.
`CODEX_LOOPS_JOURNAL_PATH` overrides the journal for isolated runs and proofs.

The scheduler executable is not configurable in production. The Codex provider
uses only the binding written by `codex-loops install --codex ...`.

## Packages

- Elixir scheduler: `lib/workflow/**`, `test/workflow/**`.
- Native control plane: `native/codex-loops/**`.
- Optional skill-only plugin: `plugins/codex-loops`.
- Canonical docs: `docs`.

## License

MIT. See [LICENSE](LICENSE).
