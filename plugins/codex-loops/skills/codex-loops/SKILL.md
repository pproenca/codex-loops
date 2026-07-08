---
name: codex-loops
description: "Use when the user explicitly asks for Codex Loops, dynamic workflows, fanout, ultracode-style orchestration, lifecycle/status inspection, an executable workflow script, or a reusable Codex skill that captures a workflow-shaped operating procedure."
---

# Codex Loops

Codex Loops is a local, path-first workflow runner for Codex dynamic workflows.
Use this skill only when the user explicitly asks for Codex Loops, dynamic
workflows, fanout/multi-agent orchestration, ultracode-style work, workflow
lifecycle inspection, an executable workflow script, or a reusable Codex skill
that captures a workflow-shaped operating procedure.

The product surface is the Codex plugin MCP adapter plus the local
Elixir/Phoenix scheduler. MCP manages lifecycle and calls the scheduler HTTP
API. Elixir owns runtime supervision, workflow workers, Phoenix PubSub/LiveView,
and the SQLite journal. Run data is stored at
`~/.codex/workflows/runs_1.sqlite` by default, or at `CODEX_LOOPS_JOURNAL_PATH`
when set.

## MCP Surface

- `workflow_validate`: validate an existing `.exs` workflow script.
- `workflow_start`: start a run from an existing workflow script. Use
  `provider: "mock"` for offline proof and `provider: "codex"` only after
  approval, because it spends a real Codex turn.
- `workflow_status`: read the public §7.5 journal-backed status projection.
- `workflow_inspect`: read the public §7.5 inspect/status projection with ordered
  `rawRefs.journal`.
- `workflow_resume`: resume an existing run through the scheduler API.
- `workflow_open_ui`: return the Phoenix LiveView run URL.

If working from a repo clone, the packaged binary is built with:

```bash
make release
make proof-mcp
```

## Artifact Selection

Before writing files, classify what the user means by "workflow":

- **Executable workflow script**: use this path when the user asks to run,
  execute, test, resume, inspect, launch, or automate work through Codex Loops.
  Author `.codex/workflows/<name>.exs`, then validate and mock-test before live
  Codex execution.
- **Reusable Codex skill**: use this path when the user asks to save a workflow
  as a skill, playbook, reusable procedure, or future Codex behavior. Write or
  update a `SKILL.md` in a user-approved skill location. Do not call MCP
  execution tools unless the user also asks for an executable script.
- **Both**: when explicitly requested, write the reusable skill as the operating
  guide and create a tested workflow script for the executable path.
- **Ambiguous**: ask whether the user wants an executable workflow script, a
  reusable Codex skill, or both.

## Authoring Contract

Author executable workflows as Elixir `.exs` files:

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

Use a scout-first authoring loop:

1. Scout repository facts first with local tools; capture evidence-backed facts.
2. Translate facts into exact files, prompts, schemas, budgets, and stop
   conditions.
3. Choose simple sequential phases unless the task genuinely needs fanout,
   `parallel`, `pipeline`, or loop combinators.
4. Write domain-rich worker prompts with exact paths or search scope,
   constraints, closed schemas, and expected output shape.
5. For mutating workflows, include adversarial verification and a final build or
   test gate before reporting completion.
6. Run `workflow_validate` and a mock `workflow_start` before live execution.

Useful DSL forms:

- `workflow "name" do ... end`
- `phase "title"`
- `log "message"`
- `agent "prompt"`
- `agent "prompt", schema: %{...}, retries: n`
- `return value`
- Advanced orchestration: `parallel`, `pipeline`, `collect`, `while_budget`,
  `until_dry`, `verify`, `judge`, `synthesize`, and `fan_out`.

## Testing Gate

Before live Codex execution:

```bash
workflow_validate script_path=.codex/workflows/<name>.exs
workflow_start script_path=.codex/workflows/<name>.exs run_id=<id> provider=mock
workflow_status run_id=<id>
```

Read the JSON payload. If validation or mock testing fails, stop and report the
failure. Do not execute generated mutating workflows when write scope,
verification commands, or caller approval are unclear.

## Live Execution

Run live workflows only after the testing gate is satisfied:

```bash
workflow_start script_path=.codex/workflows/<name>.exs run_id=<id-live> provider=codex
workflow_status run_id=<id-live>
```

After launch:

```bash
workflow_status run_id=<id-live>
workflow_inspect run_id=<id-live>
workflow_open_ui run_id=<id-live>
```

Use `workflow_resume run_id=<id> provider=codex` when a run failed and should
reuse completed journaled nodes.

## Development Proofs

For this repo:

```bash
make setup
make test
make proof
make proof-mcp
make proof-mcp-live
make proof-live
```

`make proof-mcp` proves MCP lifecycle handling, validation, mock start, status,
inspect, resume, scheduler typed errors, and open-ui against a copied plugin
package. `make proof-mcp-live` validates through MCP, starts or reuses the
packaged scheduler through MCP lifecycle handling, starts a live
`provider: "codex"` run through `workflow_start`, polls `workflow_status`, and
asserts nonzero token usage from the scheduler projection. It spends one real
Codex provider turn. `make proof-live` aliases `make proof-mcp-live`.
