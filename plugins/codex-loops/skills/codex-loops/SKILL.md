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

The current runtime is Elixir-based. It executes `.exs` workflow files, stores
runs in SQLite, and exposes the `agent-loops` CLI. Run data is stored at
`~/.codex/workflows/runs_1.sqlite` by default, or at
`CODEX_LOOPS_JOURNAL_PATH` when set.

## CLI Surface

```bash
agent-loops validate <script> [--json]
agent-loops test <script> [--run-id <id>] [--budget <n>] [--json]
agent-loops run <script> [--run-id <id>] [--provider mock|codex] [--budget <n>] [--json]
agent-loops workflow <script> [--run-id <id>] [--provider mock|codex] [--budget <n>] [--json]
agent-loops resume [<script>] [--run-id <id>] [--provider mock|codex] [--json]
agent-loops status [--run-id <id>] [--event-limit <n>] [--json]
agent-loops inspect [--run-id <id>] [--json]
agent-loops list [--limit <n>] [--json]
agent-loops help
```

`workflow` aliases `run`. `test` is always offline and uses the mock provider.
`run`, `workflow`, and `resume` default to the live `codex` provider unless
`--provider mock` is supplied.

If working from a repo clone, the packaged binary is built with:

```bash
make release
_build/prod/rel/agent_loops/bin/agent-loops help
```

## Artifact Selection

Before writing files, classify what the user means by "workflow":

- **Executable workflow script**: use this path when the user asks to run,
  execute, test, resume, inspect, launch, or automate work through Codex Loops.
  Author `.codex/workflows/<name>.exs`, then validate and mock-test before live
  Codex execution.
- **Reusable Codex skill**: use this path when the user asks to save a workflow
  as a skill, playbook, reusable procedure, or future Codex behavior. Write or
  update a `SKILL.md` in a user-approved skill location. Do not call
  `agent-loops validate`, `agent-loops test`, `agent-loops run`, or
  `agent-loops resume` unless the user also asks for an executable script.
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
6. Run `validate` and `test` before live execution.

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
agent-loops validate .codex/workflows/<name>.exs --json
agent-loops test .codex/workflows/<name>.exs --run-id <id> --json
```

Read the JSON payload. If validation or mock testing fails, stop and report the
failure. Do not execute generated mutating workflows when write scope,
verification commands, or caller approval are unclear.

## Live Execution

Run live workflows only after the testing gate is satisfied:

```bash
agent-loops run .codex/workflows/<name>.exs \
  --run-id <id-live> \
  --provider codex \
  --json
```

After launch:

```bash
agent-loops status --run-id <id-live> --json
agent-loops inspect --run-id <id-live> --json
```

Use `resume --run-id <id> --provider codex --json` when a run failed and should
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
