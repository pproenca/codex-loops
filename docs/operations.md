# Codex Loops Operations

## Sources
Sources:
- `apps/runtime/README.md`
- `plugins/codex-loops/skills/codex-loops/SKILL.md`
- `plugins/codex-loops/SPEC.md`

## Preflight
Use `validate` to check script compatibility before execution:

```sh
agent-loops validate <script-or-name> --args '<json>' --json --no-input
```

For generated workflows, verify that the workflow path, args, budget, intended
write scope, and expected verification commands are known before running a live
provider.

## Mock Test Gate
Run a bounded mock test before live SDK execution:

```sh
agent-loops test <script-or-name> --args '<json>' --provider mock --budget small --json --no-input
```

Inspect `snapshot.status`, `budgetPlan`, `runtimeContract`, phase node summaries,
and failed node errors.

## Live Execution
Run live SDK execution only after the gate passes and approval exists:

```sh
agent-loops workflow <script-or-name> --args '<json>' --provider sdk --budget small --approved --json --no-input
```

Use an explicit `--run-id <id>` when the run needs a stable durable identifier.

## Background Runs
`--background` initializes the journal, then launches a detached resume worker.

```sh
agent-loops workflow <script-or-name> --args '<json>' --background --json --no-input
```

The launch result includes the workflow name, pid, run id, `databasePath`, and
script path.

## Status And Inspect
```sh
agent-loops status --run-id <id> --event-limit 5 --json
agent-loops inspect --run-id <id> --json
agent-loops list --limit 20 --event-limit 5 --json
```

Omit `--run-id` to read the latest run id from
`~/.codex/workflows/runs_1.sqlite`.

## Serve
```sh
npx -y agent-loops serve --run-id <id> --json
```

The Codex Loops plugin should not start this visual status UI implicitly after a
run. It should report the run id, ask whether the user wants the UI, and only
run `agent-loops serve --run-id <id> --json` after the user accepts.
The JSON envelope includes the local URL. The server exposes `GET /status.json`,
a local dashboard, and SSE updates derived from SQLite run events.

## Resume
```sh
agent-loops resume --run-id <id> --provider sdk --approved --json --no-input
```

Resume folds the journal, reuses completed nodes, and re-runs failed or changed
nodes.

## Failure Parsing
For `--json` commands, parse the final stderr line as a JSON error object. Do not
scrape earlier human diagnostics for automation.

## Operational Artifacts
Treat these as generated runtime artifacts rather than source docs:
- `~/.codex/workflows/runs_1.sqlite`
- `~/.codex/workflows/runs_1.sqlite-wal`
- `~/.codex/workflows/runs_1.sqlite-shm`
