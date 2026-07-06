# Codex Loops CLI

## Sources
Sources:
- `apps/runtime/README.md`
- `plugins/codex-loops/README.md`
- `plugins/codex-loops/SPEC.md`
- `plugins/codex-loops/skills/codex-loops/SKILL.md`
- `apps/runtime/scripts/gen-help.mjs`

## Commands
The generated command block is the authoritative user-facing command surface:

```bash
agent-loops draft --goal '<goal>' [--name name] [--output .codex/workflows/name.ts] [--json]
agent-loops validate <script-or-name> --args '<json>' [--json] [--no-input]
agent-loops test <script-or-name> --args '<json>' [--run-id <id>] [--provider mock|sdk] [--budget small|standard|deep] [--json] [--no-input]
agent-loops workflow <script-or-name> --args '<json>' [--run-id <id>] [--provider sdk|mock] [--budget small|standard|deep] [--approved] [--json] [--no-input]
agent-loops workflow <script-or-name> --args '<json>' --background [--status-server] [--json] [--no-input]
agent-loops run <script-or-name> --args '<json>' [--run-id <id>] [--provider sdk|mock] [--budget small|standard|deep] [--approved] [--json] [--no-input]
agent-loops resume [--run-id <id>] [--provider sdk|mock] [--approved] [--json] [--no-input]
agent-loops inspect [--run-id <id>] [--json]
agent-loops status [--run-id <id>] [--event-limit 5] [--json]
agent-loops list [--limit 20] [--event-limit 5] [--json]
agent-loops serve [--run-id <id>] [--host 127.0.0.1] [--port 0] [--json]
agent-loops help
```

## Command Notes
- Invoke with `npx -y agent-loops <command> ...` when using the package CLI.
- `run` aliases `workflow`.
- `draft` is deterministic and makes no model call.
- `validate` runs the compatibility gate.
- `test` defaults to the mock provider.
- `workflow` defaults to the SDK provider.
- New `test`, `workflow`, and `run` commands use `--run-id` when a stable run
  identifier is needed.
- `resume`, `inspect`, `status`, and `serve` use the latest run when
  `--run-id` is omitted. Pass `--run-id <id>` to select a specific run.
- `--journal` is removed on every command and fails with
  `--journal was removed; use --run-id`.
- Run data is stored in `~/.codex/workflows/runs_1.sqlite`. JSON envelopes
  include `runId` and `databasePath` where run storage is surfaced.
- `serve` is read-only and binds to `127.0.0.1` by default.

## JSON Output Discipline
With `--json`, stdout carries exactly one final payload and every envelope has a
`command` field. Progress and diagnostics belong on stderr. On failure, the last
stderr line is a single-line JSON object shaped by
`apps/runtime/schema/cli-error.schema.json`:

```json
{"code":"validation","exitCode":6,"message":"...","hint":"..."}
```

## Exit Codes
| Exit code | Meaning |
|---|---|
| 0 | success |
| 2 | usage error |
| 4 | provider configuration error |
| 6 | validation or budget failure |
| 8 | malformed structured output |
| 130 | killed |
| 1 | other runtime failure |

## Generated Help Drift Check
The command blocks in the app README, plugin README, plugin spec, and skill are
generated from the CLI contract and checked by:

```sh
pnpm -C apps/runtime help:check
```
