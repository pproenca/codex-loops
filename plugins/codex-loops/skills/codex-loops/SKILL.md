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

The product surface is an immutable runtime bundle whose native Rust control
plane is registered directly as MCP, plus the local Elixir/Phoenix scheduler.
The optional plugin contains only this skill. The native control plane manages OS-process lifecycle
and calls the scheduler HTTP interface. Elixir owns OTP supervision, workflow
workers, Phoenix PubSub/LiveView, and the SQLite journal. Run data is stored at
`~/.codex/workflows/runs_1.sqlite` by default, or at `CODEX_LOOPS_JOURNAL_PATH`
when set.

## MCP Surface

- `workflow_validate`: validate an existing `.exs` workflow script.
- `workflow_start`: start a run from an existing workflow script. Use
  `provider: "mock"` for offline proof and `provider: "codex"` only after
  approval, because it spends a real Codex turn.
- `workflow_status`: poll the public §7.5 journal-backed status projection.
- `workflow_inspect`: read the public §7.5 inspect/status projection with
  `journalEvents` summaries and ordered `rawRefs.journal`.
- `workflow_resume`: resume an existing run through the scheduler API.
- `workflow_open_ui`: return the Phoenix LiveView run URL. Use this URL for
  realtime watching.

If working from a repo clone, the packaged binary is built with:

```bash
make build
make ci
make dev-bundle
```

For a user-driven manual run from the shell, prefer the progressive CLI over
environment variables or raw HTTP calls:

```bash
./native/codex-loops/target/release/codex-loops run .codex/workflows/<name>.exs --open
./native/codex-loops/target/release/codex-loops stop
```

The defaults are the local scheduler, standard journal, generated run ID, and
live Codex provider; `run` starts the managed scheduler when needed. Use CLI
flags only when the user asks to customize them.

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
workflow "example" do
  phase "scout"
  log "starting"
  agent "Inspect README.md and summarize the project goal."
  return :ok
end
```

Each file contains exactly one bare, top-level `workflow` declaration. The
scheduler parses it as inert data and never compiles or evaluates the file. Do
not add `defmodule`, `use Workflow`, imports, or schema modules; pass structured
output schemas as literal JSON Schema maps.

Use a scout-first authoring loop:

1. Scout repository facts first with local tools; capture evidence-backed facts.
2. Translate facts into exact files, prompts, schemas, budgets, and stop
   conditions.
3. Choose simple sequential phases unless the task genuinely needs fanout,
   `parallel`, `pipeline`, or loop combinators.
4. Write domain-rich worker prompts with exact paths or search scope, evidence
   expectations, semantic field meaning, constraints, and halt conditions. Put
   structural output shape in `schema:` so Codex receives it through
   `--output-schema`.
5. For mutating workflows, include adversarial verification and a final build or
   test gate before reporting completion.
6. Run `workflow_validate` and a mock `workflow_start` before live execution.

Useful DSL forms:

- `workflow "name" do ... end`
- `phase "title"`
- `log "message"`
- `agent "prompt"`
- `agent "prompt", schema: %{...}, retries: n` where `n` is `0..5`
- `let :name = agent(...)`
- `let :name = synthesize(...)`
- `let :name = refine(...)`
- `agent(~P"... <%= @name %> ...")`
- `emit(~P"... <%= @name %> ...")`
- `emit_result(:name)`
- `return value`
- Core orchestration: `loop max_iterations: n, until: predicate do ... end` and
  `fanout width: n do ... end`.
- Advanced orchestration: `parallel`, `pipeline`, `collect`, `verify`, `judge`,
  and `synthesize`.
- Compatibility/sugar surfaces: `while_budget`, `until_dry`, and `fan_out`.
- Deferred and unavailable: `gather` and `map`.
- Explicit heterogeneous fanout lanes:
  `fanout width: 2 do lanes([[agent("a")], [agent("b"), agent("c")]]) end`.

Prefer the generic core for new dynamic workflows. Use `loop max_iterations:` in
the range `1..1000` with either a header `until:` predicate or one body-local `until(predicate)`,
but not both. Body-local `until` stops at that body point, cannot contain
`dry(...)`, and can inspect an earlier loop-local `fanout bind:`.

Use `fanout` for a repeated non-empty lane of `agent` turns or an explicit
non-empty `lanes([...])` list. Explicit lanes require a literal integer width
equal to the lane count. Repeated-lane widths are integer, `budget_slices(per: n, max: m)`, and
`path_count(:binding, "/json/pointer", max: m)`. Optional controls are `bind:`,
`max_concurrency:`, and `on_zero: :complete | :fail`. A `fanout bind:` produces
an ordered result list for later templates and predicates; lane prompts do not
receive implicit per-lane data. Runtime caps remain authoritative: no more than
eight workflow tasks execute concurrently and fanout width never exceeds 64.

Closed predicate examples. For `agree` over a fanout binding, each lane result
must be a structured map, usually from a schema-backed agent:

```elixir
all([count(:items) >= 2, budget_remaining() > 10])
any([path_exists(:reviews, "/0"), path_non_empty(:draft, "/summary")])
dry(rounds: 2, seen_by: [:id])
agree(:reviews, path: "/approved", equals: true, threshold: :all)
path_count(:draft, "/items") >= 2
path_equals(:draft, "/status", "ready")
```

`all_of` and `any_of` are legacy aliases for `all` and `any`.

Implemented dataflow forms are top-level only. Use `let` to bind a previous
producer's journaled output, `agent(~P...)` to inject earlier bindings into a
later top-level agent prompt, `emit(~P...)` as a final rendered text terminal,
and `emit_result(:name)` as a final structured terminal for a result-capable
binding. The shipped result-capable producer is `refine`. Template holes use the
closed `~P` surface, such as `<%= @draft %>`; do not use Elixir interpolation,
helper calls, or nested template prompts in `parallel`, `pipeline`, `fanout`,
`fan_out`, or loop bodies.

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
workflow_open_ui run_id=<id-live>
```

After launch:

```bash
workflow_status run_id=<id-live>
workflow_inspect run_id=<id-live>
workflow_open_ui run_id=<id-live>
```

`workflow_status` is a polling snapshot. `workflow_inspect` is durable journal
inspection. LiveView, opened through `workflow_open_ui`, renders the same
journal-backed projection: every activity entry is appended before a
post-commit `{:journal_committed, run_id, seq}` PubSub signal asks the UI to
refold. The signal carries no event snapshot.

Use `workflow_resume run_id=<id> provider=codex` when a run failed and should
reuse completed journaled nodes. Provider effects are at-most-once: a durable
`agent_started` is written before each call, and an unsettled start is never
redelivered. Resume terminates such a run with `outcome_unknown`; inspect it and
start a fresh run only as an explicit decision.

## Development Gates

For this repo:

```bash
make build
make ci
make dev-bundle
MINISIGN_SECRET_KEY=/path/to/key make dist
```

`make ci` proves the skill-only plugin package, directly registered MCP runtime, scheduler lifecycle,
validation, mock execution, all documented workflow variants, polling status,
journal inspection, resume, typed errors, realtime UI, and open-ui through the
packaged runtime. It is credential-free and does not spend a real Codex turn.
