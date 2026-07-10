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

User CLI:

- `codex-loops serve` starts or discovers the managed local scheduler at
  `127.0.0.1:47125` by default
- `codex-loops run WORKFLOW.exs` starts a missing managed local scheduler,
  validates the workflow, and starts a generated-ID live Codex run; `--open`
  launches the LiveView run page
- `codex-loops stop` stops the managed local scheduler
- host, port, journal, model, provider, run ID, and scheduler URL customization
  are optional flags rather than required environment setup

MCP behavior:

- Anubis MCP server over stdio with newline-delimited JSON-RPC messages
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
- `workflow_status` calls `GET /api/runs/:id` and returns the §7.5 conforming
  status projection as MCP `structuredContent`; scheduler-only lifecycle/UI
  fields are omitted from this public status surface. This is a polling
  snapshot, not a realtime stream
- `workflow_inspect` calls `GET /api/runs/:id/events` and returns the §7.5
  conforming inspect/status projection as MCP `structuredContent`, including
  `journalEvents` summaries and ordered `rawRefs.journal` instead of the
  lower-level legacy `events` rows
- `workflow_resume` calls `POST /api/runs/:id/resume` and returns the scheduler
  success or error envelope exactly as MCP `structuredContent`
- `workflow_open_ui` calls `GET /api/runs/:id` and returns an MCP envelope with
  the scheduler projection plus absolute `open_url` based on the scheduler base
  URL. The returned Phoenix LiveView URL is the realtime watching surface
- scheduler success envelopes are returned as MCP `structuredContent`
- scheduler typed errors remain typed and are returned as MCP `isError: true`
- scheduler lifecycle failures use MCP-friendly `scheduler_unavailable` or
  `scheduler_start_failed` envelopes with actionable details
- the MCP adapter reaches the scheduler only through HTTP API calls; it does not
  read SQLite or call `Workflow.Scheduler`, `Workflow.Journal`, or runtime
  internals directly
- `make package-homebrew-runtime` assembles one external runtime under
  `_build/homebrew/libexec`; the plugin contains no generated release artifacts

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

The plugin authoring surface includes the implemented generic core from root
`SPEC.md`: bounded `loop`, repeated or explicit-lane `fanout`, and the closed predicate
vocabulary. `loop max_iterations:` requires a positive integer and supports a
header `until:` predicate or one body-local `until(predicate)`, but not both.
Body-local `until` cannot contain `dry(...)`, stops the loop at that body point,
and may use an earlier loop-local `fanout bind:`.

Generic `fanout` repeats one non-empty lane of `agent` turns or accepts a
non-empty explicit `lanes([...])` list. Explicit lanes require a literal integer
width equal to the lane count. A repeated lane's `width:` is an integer,
`budget_slices(per: n, max: m)`, or
`path_count(:binding, "/json/pointer", max: m)`. It supports optional `bind:`,
`max_concurrency:`, and `on_zero: :complete | :fail`. A `fanout bind:` produces
the ordered lane result list for later templates and predicates; it does not
inject per-lane data into lane prompts.

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

`all_of` and `any_of` remain legacy aliases for `all` and `any`.

The plugin authoring surface includes the implemented §10 dataflow core. `let`
binds a top-level producer's journaled output for later rendering. A later
top-level `agent(~P...)` may inject earlier bindings through closed template
holes such as `<%= @draft %>`. A final `emit(~P...)` returns rendered text, while
a final `emit_result(:name)` returns a structured public projection from a
result-capable binding. The shipped result-capable producer is `refine`.

Template prompts remain narrow: no Elixir string interpolation, no arbitrary
helper calls, and no template prompts inside nested agents such as `parallel`,
`pipeline`, `fanout`, `fan_out`, or loop bodies. `gather` and `map` are reserved
§10.9 future forms and must not be presented as executable plugin workflow
syntax.

Expected authoring loop:

1. Scout repository facts first, using local inventory and focused reads before
   writing the workflow.
2. Translate facts into workflow constraints: file scope, public contracts,
   mutation posture, verification commands, and halt conditions.
3. Choose simple sequential phases unless the task genuinely needs fanout or
   loop combinators.
4. Use domain-rich worker prompts with exact files, evidence expectations,
   semantic field meaning, constraints, and halt conditions. Put structural
   output shape in `schema:` / `--output-schema`.
5. Add adversarial verification and a final build or test gate for mutating
   workflows.
6. Run `workflow_validate` and a mock `workflow_start`; run live Codex only
   after approval.

## Journal And Runtime

Runs are stored in SQLite at `~/.codex/workflows/runs_1.sqlite`, unless
`CODEX_LOOPS_JOURNAL_PATH` is set. Scheduler status, inspect, and resume
projections are folds over the journal. Completed nodes replay from the journal
on resume.

The live provider shells out to `codex exec --json --skip-git-repo-check`,
normalizes Codex events into activity entries, and streams progress to LiveView.
Schema-backed agents pass `--output-schema`; the schema owns output shape, the
prompt owns task semantics, and the writer validates outputs and fails closed
after retry exhaustion.

## Packaging

The production artifact is a Mix release:

```bash
make release
test -x _build/prod/rel/agent_loops/bin/agent_loops
```

The MCP command is an overlay in the same OTP release:

```bash
make release-mcp
test -x _build/prod/rel/agent_loops/bin/codex-loops-mcp
```

The supported MCP adapter uses Anubis over stdio. A release overlay invokes it
through Mix release `eval`; no hand-rolled stdio protocol layer or second ERTS
payload is shipped.

The MCP executable starts or discovers the generated `agent_loops` release
script when it owns scheduler lifecycle.

Development and proof commands:

```bash
make setup
make test
make proof
make proof-mcp
make proof-mcp-live
make proof-live
```

`make proof-mcp` builds the external runtime, copies the source-only plugin to a
temp install location, and proves MCP lifecycle, validation, mock start, status
polling, journal inspection, resume, typed scheduler errors, and open-ui.
`make proof-mcp-live` validates through MCP, starts or reuses the packaged
scheduler through MCP lifecycle handling, starts a live
`provider: "codex"` run through `workflow_start`, observes completion through
polling `workflow_status`, and asserts nonzero token usage from the scheduler
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
