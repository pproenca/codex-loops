# Codex Loops Runtime

## Architecture

The Elixir runtime is a supervised, journal-backed workflow runner. Workflow
scripts compile into inert trees. A per-run writer process walks the tree,
invokes the selected provider, commits ordered events to SQLite, and exits.
Read surfaces are projections over the journal.

```text
CLI argv -> workflow compile gate -> supervised run writer
         -> provider turn or mock turn -> append-only SQLite journal
         -> status / inspect / list projections
```

## Packaging

The production artifact is a Mix release named `agent_loops`. It includes ERTS,
compiled BEAM code, dependency `priv/` directories, and native artifacts such as
`exqlite`'s SQLite NIF.

```sh
make release
_build/prod/rel/agent_loops/bin/agent-loops help
```

The release includes a small `bin/agent-loops` wrapper over the generated
`bin/agent_loops` release script. The wrapper forwards the original argv through
`Workflow.ReleaseCLI` and then calls the normal `Workflow.CLI.exec/1` seam.

## Journal Model

Runs are stored in SQLite at `~/.codex/workflows/runs_1.sqlite` by default, or
at `CODEX_LOOPS_JOURNAL_PATH` when set. Events are keyed by `{run_id, seq}` and
folded to reconstruct status, summaries, and resume decisions.

## Providers

- `mock`: offline provider used by `test`.
- `codex`: live provider that shells out to `codex exec --json
  --skip-git-repo-check` and folds the JSONL stream into a result plus token
  usage.

Schema-backed turns use Codex structured output via `--output-schema`; the
writer validates results and fails closed after configured retries.

## Supervision

The application supervises:

- `Workflow.Run.Registry`: unique per-run writer lease.
- `Workflow.PubSub`: post-commit notifications.
- `Workflow.Journal`: SQLite owner process.
- `Workflow.Run.Supervisor`: dynamic supervisor for run writers.
- `Workflow.Web.Endpoint`: optional endpoint, disabled by default in release CLI
  mode unless `CODEX_LOOPS_SERVER=1` or `true`.

## Scope

Supported: local workflow scripts, mock tests, live Codex runs, SQLite-backed
status/inspect/list/resume, and release packaging.

Not currently shipped in the Elixir CLI: draft scaffolding, background launch,
serve/status UI commands, hosted workflow services, and per-agent skip controls.
