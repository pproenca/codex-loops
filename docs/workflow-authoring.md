# Workflow Authoring

## When To Use A Workflow

Use Codex Loops when work benefits from phases, repeatable provider turns,
journal-backed inspection, resume, or an explicit mock-before-live gate. Do not
use it for trivial single-file edits or questions the main agent can answer
directly.

## File Shape

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

Save repo-local workflows under `.codex/workflows/<name>.exs` unless the caller
asks for another path.

## DSL

- `workflow "name" do ... end` defines the workflow.
- `phase "title"` records progress.
- `log "message"` records a journal log.
- `agent "prompt"` runs one provider turn.
- `agent "prompt", schema: %{...}, retries: n` requests structured output and
  fails closed after invalid attempts.
- `return value` sets the run result.
- Higher-level combinators such as `parallel`, `pipeline`, `collect`,
  `while_budget`, `until_dry`, `verify`, `judge`, `synthesize`, and `fan_out`
  are available in the Elixir DSL and should be used only when the orchestration
  genuinely needs them.

## Authoring Loop

1. Scout repository facts first with local tools.
2. Convert those facts into exact files, prompts, schemas, budgets, and stop
   conditions.
3. Keep worker prompts specific: include paths, evidence scope, output shape,
   and halt conditions.
4. Prefer mock testing before live execution.
5. For mutating workflows, include an adversarial verification phase and a final
   build/test gate in the workflow design.

## Testing Gate

```text
workflow_validate script_path=.codex/workflows/<name>.exs
workflow_start    script_path=.codex/workflows/<name>.exs run_id=<id> provider=mock
workflow_status   run_id=<id>
workflow_inspect  run_id=<id>
```

Only run the live provider after validation and mock testing:

```text
workflow_start  script_path=.codex/workflows/<name>.exs run_id=<id-live> provider=codex
workflow_status run_id=<id-live>
```

## Resume

Resume replays the event log and reuses completed nodes. Failed runs can be
retried with:

```text
workflow_resume run_id=<id> provider=codex
workflow_status run_id=<id>
```
