# Codex Loops Plugin Spec

## Purpose

Provide one Codex skill plus a local Elixir MCP adapter for authoring, validating,
testing, executing, and inspecting local Elixir workflow scripts.

The plugin is deliberately thin. The Elixir runtime owns runner behavior; the
skill teaches when to use it, how to write compatible `.exs` workflow scripts,
how to run validation and mock-test gates, and how to relay journal-backed
lifecycle state. The MCP adapter is the Codex-facing surface: it reaches the
scheduler only through the published HTTP API and never reads SQLite or calls
internal scheduler modules directly.

## Public Surface

Skill:

- `codex-loops`

MCP tools:

- `workflow_validate`
- `workflow_start`
- `workflow_status`
- `workflow_inspect`
- `workflow_resume`
- `workflow_open_ui`

MCP behavior:

- stdio JSON-RPC transport with newline-delimited messages
- `initialize`, `tools/list`, `tools/call`, and notifications
- `workflow_validate` input schema requires `script_path`
- `workflow_start` input schema requires `script_path` and accepts optional
  `run_id`, optional `provider` (`mock` or `codex`), and optional
  non-negative integer `budget`. The scheduler API defaults to `mock`;
  selecting `codex` spends a real Codex provider turn.
- `workflow_status` input schema requires `run_id`
- `workflow_inspect` input schema requires `run_id`
- `workflow_resume` input schema requires `run_id` and accepts optional
  `script_path`, optional scheduler-supported `script` alias, and optional
  `provider` (`mock` or `codex`)
- `workflow_open_ui` input schema requires `run_id`
- `tools/call` health-checks `GET /api/health` before scheduler operations
- when health fails, the server discovers and starts a packaged scheduler
  release before retrying the operation
- `workflow_start` calls `POST /api/runs` and returns the scheduler success or
  error envelope exactly as MCP `structuredContent`
- `workflow_status` calls `GET /api/runs/:id` and returns the scheduler
  projection exactly as MCP `structuredContent`
- `workflow_inspect` calls `GET /api/runs/:id/events` and returns the ordered
  scheduler event projection exactly as MCP `structuredContent`
- `workflow_resume` calls `POST /api/runs/:id/resume` and returns the scheduler
  success or error envelope exactly as MCP `structuredContent`
- `workflow_open_ui` calls `GET /api/runs/:id` and returns an MCP envelope with
  the scheduler projection plus absolute `open_url` based on the scheduler base
  URL
- scheduler success envelopes are returned as MCP `structuredContent`
- scheduler typed errors remain typed and are returned as MCP `isError: true`
- scheduler lifecycle failures use MCP-friendly `scheduler_unavailable` or
  `scheduler_start_failed` envelopes with actionable details
- the MCP adapter reaches the scheduler only through HTTP API calls; it does not
  read SQLite or call `Workflow.Scheduler`, `Workflow.Journal`, or runtime
  internals directly
- `make release` assembles the scheduler release into
  `plugins/codex-loops/scheduler/` so the MCP adapter can run from a copied
  plugin package without a sibling source `_build` directory

## Artifact-Aware Authoring

- User asks to run, execute, test, resume, inspect, launch, or automate through
  Codex Loops: create an executable `.exs` workflow script and keep the
  validation/mock-test gate.
- User asks to save a workflow as a skill, playbook, reusable procedure, or
  future Codex behavior: create or update a `SKILL.md` in a user-approved skill
  location and do not call Codex Loops execution commands unless the user also
  asks for an executable script.
- User asks for both: create the reusable skill as the operating guide and only
  create a workflow script for the executable portion.
- User says only "workflow" and the artifact is ambiguous: ask whether they want
  an executable workflow script, a reusable Codex skill, or both.

## Workflow DSL

Workflow scripts are Elixir files:

```elixir
defmodule ExampleWorkflow do
  use Workflow

  workflow "example" do
    phase "scout"
    log "starting"
    agent "Inspect README.md and summarize the project goal."
    return :ok
  end
end
```

Useful forms:

- `workflow "name" do ... end`
- `phase "title"`
- `log "message"`
- `agent "prompt"`
- `agent "prompt", schema: %{...}, retries: n`
- `return value`
- Advanced orchestration: `parallel`, `pipeline`, `collect`, `while_budget`,
  `until_dry`, `verify`, `judge`, `synthesize`, and `fan_out`.

Expected authoring loop:

1. Scout repository facts first, using local inventory and focused reads before
   writing the workflow.
2. Translate facts into workflow constraints: file scope, public contracts,
   mutation posture, verification commands, and halt conditions.
3. Choose simple sequential phases unless the task genuinely needs fanout or
   loop combinators.
4. Use domain-rich worker prompts with exact files, constraints, closed schemas,
   and concrete expected outputs.
5. Add adversarial verification and a final build or test gate for mutating
   workflows.
6. Run `workflow_validate` and a mock `workflow_start`; run live Codex only
   after approval.

## Journal And Runtime

Runs are stored in SQLite at `~/.codex/workflows/runs_1.sqlite`, unless
`CODEX_LOOPS_JOURNAL_PATH` is set. Scheduler status, inspect, and resume
projections are folds over the journal. Completed nodes replay from the journal
on resume.

The live provider shells out to `codex exec --json --skip-git-repo-check`.
Schema-backed agents pass `--output-schema`; the writer validates outputs and
fails closed after retry exhaustion.

## Packaging

The production artifact is a Mix release:

```bash
make release
test -x _build/prod/rel/agent_loops/bin/agent_loops
```

The MCP adapter launches the generated `agent_loops` release script when it
owns scheduler lifecycle.

Development and proof commands:

```bash
make setup
make test
make proof
make proof-mcp
make proof-mcp-live
make proof-live
```

`make proof-mcp` copies the plugin package to a temp install location and proves
MCP lifecycle, validation, mock start, status polling, event inspection,
resume, typed scheduler errors, and open-ui response against the copied
package's scheduler release. `make proof-mcp-live` validates through MCP,
starts or reuses the packaged scheduler through MCP lifecycle handling, starts a
live `provider: "codex"` run through `workflow_start`, observes completion
through `workflow_status`, and asserts nonzero token usage from the scheduler
projection. It spends one real Codex provider turn. `make proof-live` aliases
the MCP live proof.

## Safety And Testing

Every executable workflow must pass:

```text
workflow_validate script_path=.codex/workflows/<name>.exs
workflow_start    script_path=.codex/workflows/<name>.exs run_id=<id> provider=mock
workflow_status   run_id=<id>
workflow_inspect  run_id=<id>
```

Generated workflows that can mutate files should return closed plans or declare
live write scope, exact file paths, and verification commands before the caller
authorizes live execution.

When an MCP tool fails, preserve its typed scheduler error envelope.
