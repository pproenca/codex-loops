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

Use an explicit `--journal <path>` when the run needs a stable named artifact.

## Background Runs
`--background` initializes the journal, then launches a detached resume worker.

```sh
agent-loops workflow <script-or-name> --args '<json>' --background --json --no-input
```

The launch result includes the workflow name, pid, run id, journal path, and
script path. Worker output is written next to the journal.

## Status And Inspect
```sh
agent-loops status --journal <path> --event-limit 5 --json
agent-loops inspect --journal <path> --json
agent-loops list --journal-root .agent-loops-runs --limit 20 --event-limit 5 --json
```

Omit `--journal` to follow `.agent-loops-runs/latest.json` to the latest run.

## Serve
```sh
npx -y agent-loops-ui <journal.jsonl> --json
```

The Codex Loops plugin should not start this visual status UI implicitly after a
run. It should report the journal path, ask whether the user wants the UI, and
only run `npx -y agent-loops-ui <journal.jsonl> --json` after the user accepts.
The JSON envelope includes the local URL. The server exposes `GET /status.json`,
a local dashboard, and SSE updates derived from the journal.

## Resume
```sh
agent-loops resume --journal <path> --provider sdk --approved --json --no-input
```

Resume folds the journal, reuses completed nodes, and re-runs failed or changed
nodes. Legacy v1 snapshot journals are inspectable but not resumable.

## Failure Parsing
For `--json` commands, parse the final stderr line as a JSON error object. Do not
scrape earlier human diagnostics for automation.

## Operational Artifacts
Treat these as generated runtime artifacts rather than source docs:
- `.agent-loops-runs/`
- `<journal>.worker.log`
- `<journal>.serve.json`
- `<journal>.mutations.jsonl`
