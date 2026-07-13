# Codex Loops Plugin Spec

## Purpose

Specify the optional skill-only plugin and the native runtime's directly
registered MCP adapter for authoring, validating, testing, executing, and
inspecting local Elixir workflow scripts.

The plugin is deliberately skill-only. The Elixir runtime owns runner behavior; the
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

- `rmcp` MCP server over stdio with newline-delimited JSON-RPC messages
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
- every `tools/call` health-checks `GET /api/health` and verifies the published
  scheduler API version before its scheduler operation
- when health or compatibility checks fail, the MCP server returns an actionable
  `scheduler_unavailable` or version-mismatch error directing the operator to
  `codex-loops serve`; it does not discover, start, stop, lock, or supervise a
  scheduler
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
  version-mismatch envelopes with actionable details
- the MCP adapter reaches the scheduler only through HTTP API calls; it does not
  read SQLite or call `Workflow.Scheduler`, `Workflow.Journal`, or runtime
  internals directly, and it does not create native owner-state files
- the packaging stage of `make ci` assembles one fixed runtime under
  `_build/dev-bundle`; the plugin contains no generated release artifacts or
  MCP launcher

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
workflow "example" do
  phase "scout"
  log "starting"
  agent "Inspect README.md and summarize the project goal."
  return :ok
end
```

Each script contains exactly one bare, top-level `workflow` declaration. It is
parsed as inert AST data, not compiled or evaluated; do not wrap it in a module,
write `use Workflow`, or define a schema DSL. Structured agents use literal JSON
Schema maps.

Useful forms:

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

The plugin authoring surface includes the implemented generic core from root
`SPEC.md`: bounded `loop`, repeated or explicit-lane `fanout`, and the closed predicate
vocabulary. `loop max_iterations:` requires an integer from `1` through `1000` and supports a
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
inject per-lane data into lane prompts. The scheduler caps concurrent tasks at
eight and resolved fanout width at 64; script-level limits may only reduce those
system bounds.

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
   output shape in `schema:` / app-server `outputSchema`.
5. Add adversarial verification and a final build or test gate for mutating
   workflows.
6. Run `workflow_validate` and a mock `workflow_start`; run live Codex only
   after approval.

## Journal And Runtime

Runs are stored in SQLite at `~/.codex/workflows/runs_1.sqlite`, unless
`CODEX_LOOPS_JOURNAL_PATH` is set. Scheduler status, inspect, and resume
projections are folds over the journal. Completed nodes replay from the journal
on resume.

The live provider submits independent threads and turns to one scheduler-owned
Codex app-server, normalizes correlated notifications into activity entries,
and synchronously journals each entry before publishing a post-commit refresh
notification to LiveView. Schema-backed agents pass app-server `outputSchema`;
the schema owns output shape, the prompt owns task semantics, and the writer
validates outputs and fails closed after retry exhaustion.

Immediately before every provider call, the writer appends `agent_started`.
`agent_committed`, `agent_attempt_rejected`, or `agent_failed` settles that
attempt. If a crash leaves a start without settlement, resume does not
redeliver the possibly-paid effect; it terminates with `outcome_unknown`.
Provider turns have finite time, bounded protocol lines, and global admission.

## Packaging

The production package is one immutable directory containing a Mix scheduler
release, native Rust control-plane binary, and the skill:

```bash
make dev-bundle
make dist
```

The single `codex-loops` command selects stdio mode with the `mcp` subcommand.
`codex-loops install` registers that exact command directly in Codex shared
configuration and installs the skill under the user skill root. It calls the
scheduler only through HTTP and does not boot a second ERTS payload.

Explicit native CLI lifecycle subcommands start or discover the generated
`agent_loops` release through a durable per-user supervisor. The MCP subcommand
never calls that lifecycle layer, owns no supervisor, and cannot stop one when
disconnected; scheduler shutdown is always explicit. The supervisor restarts
unexpected scheduler exits with bounded backoff.

Public development commands:

```bash
make build
make ci
make dev-bundle
make dist
```

`make ci` builds and tests the external runtime, copied source-only plugin,
scheduler lifecycle, validation, mock execution, all workflow variants, status,
inspection, resume, typed errors, streaming activity, browser UI, and open-ui.
It is deterministic, credential-free, and does not spend a real Codex turn.

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
