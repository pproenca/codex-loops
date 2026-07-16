# Codex Loops Plugin Spec

## Purpose

Specify the optional skill-only plugin and the scheduler-owned Streamable HTTP
MCP surface for authoring, validating, testing, executing, and inspecting local
Elixir workflow scripts.

The plugin is deliberately skill-only. The Elixir runtime owns runner behavior; the
skill teaches when to use it, how to write compatible `.exs` workflow scripts,
how to run validation and mock-test gates, and how to relay journal-backed
lifecycle state. Codex connects directly to the release's `/mcp` route. The MCP
transport is stateless and dispatches tools into the same scheduler context as
the JSON API; there is no Rust runtime, stdio bridge, or loopback HTTP adapter.

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

- archive `./install [--codex /absolute/path/to/codex]` completes the immutable
  bundle, skill, exact Codex binding, login service, health gate, and MCP URL
  registration in one action
- `codex-loops install [--codex PATH] [--check|--dry-run] [--json]` is the
  idempotent reconciliation command; `check` and `dry-run` are aliases
- `codex-loops serve`, `stop`, and `restart` operate the installed user service
- `codex-loops status [--json]` reports service definition plus scheduler health
- `codex-loops doctor [--json]` diagnoses the installed runtime

MCP behavior:

- Codex registers `http://127.0.0.1:47125/mcp` as `streamable_http`
- each `POST /mcp` body is bounded to 1 MiB; `2025-03-26` accepts one message or
  a non-empty batch, while later versions accept one message only; batch output
  includes request responses and omits notification/client-response entries
- notifications, client responses, and batches containing only those entries
  return `202` with no body
- `GET` and `DELETE` return `405`; there is no SSE stream or
  `Mcp-Session-Id`
- MCP, API, and LiveView require a loopback Host; absent Origin is accepted for
  non-browser clients and a present Origin must be loopback
- `initialize`, `ping`, `tools/list`, `tools/call`, and notifications
- supported protocol versions are `2025-03-26`, `2025-06-18`, and
  `2025-11-25`; subsequent calls validate `MCP-Protocol-Version`, defaulting a
  missing header to `2025-03-26`
- `workflow_validate` input schema requires `script_path` and accepts optional
  absolute `workspace_root` and optional structured JSON `args`; when present,
  the concrete invocation is validated
- `workflow_start` input schema requires `script_path` and accepts optional
  absolute `workspace_root`, optional `run_id`, optional `provider` (`mock` or
  `codex`), optional non-negative integer `budget`, and optional structured JSON
  `args`. The scheduler defaults
  to `mock`; selecting `codex` spends a real Codex provider turn.
- `workflow_status` input schema requires `run_id`
- `workflow_inspect` input schema requires `run_id`
- `workflow_resume` input schema requires `run_id` and accepts optional
  `script_path`, optional scheduler-supported `script` alias, optional absolute
  `workspace_root`, and optional `provider` (`mock` or `codex`)
- `workflow_open_ui` input schema requires `run_id`
- every explicit `run_id` is route-safe ASCII and at most 128 bytes
- relative `script_path` values require an explicit absolute existing
  `workspace_root`; absolute script paths may omit it. The scheduler
  canonicalizes both and rejects paths outside the root, including symlink
  escapes
- `workflow_start` invokes the scheduler context and returns the scheduler
  success or error envelope as MCP `structuredContent`
- `workflow_status` returns the §7.5 conforming status projection as MCP
  `structuredContent`; scheduler-only lifecycle/UI
  fields are omitted from this public status surface. This is a polling
  snapshot, not a realtime stream
- `workflow_inspect` returns the §7.5 conforming inspect/status projection as
  MCP `structuredContent`, including
  `journalEvents` summaries and ordered `rawRefs.journal` instead of the
  lower-level legacy `events` rows
- `workflow_resume` invokes resume in the scheduler context and returns the
  scheduler success or error envelope exactly as MCP `structuredContent`
- `workflow_open_ui` reads the scheduler projection and returns an MCP envelope
  with the projection plus absolute `open_url` based on the scheduler base URL.
  The returned Phoenix LiveView URL is the realtime watching surface
- scheduler success envelopes are returned as MCP `structuredContent`
- scheduler typed errors remain typed and are returned as MCP `isError: true`
- the MCP transport owns no run, provider, journal, or service state; tool
  dispatch enters `Workflow.Scheduler`, whose public projections and errors stay
  authoritative
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
workflow "example",
  inputs: %{
    "type" => "object",
    "properties" => %{"scope" => %{"type" => "string"}},
    "required" => ["scope"]
  } do
  phase "scout"
  log "starting"
  agent ~P|Inspect <%= path(@args, "/scope") %>.|
  return :ok
end
```

Each script contains exactly one bare, top-level `workflow` declaration. It is
parsed as inert AST data, not compiled or evaluated; do not wrap it in a module,
write `use Workflow`, or define a schema DSL. Structured agents use literal JSON
Schema maps.

Useful forms:

- `workflow "name" do ... end`
- `workflow "name", inputs: %{...} do ... end`
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
inject per-lane data into lane prompts. The scheduler admits at most eight
active runs, caps concurrent tasks within each run at eight, and caps resolved
fanout width at 64; script-level limits may only reduce those system bounds.

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
helper calls, and nested prompts may template only over predefined `@args`.
Templates over prior agent results remain top-level only. `gather` and `map` are reserved
§10.9 future forms and must not be presented as executable plugin workflow
syntax.

`args` is an actual JSON value, not a JSON-encoded string. It defaults to `{}`
when omitted, is limited to 64 KiB, validates before provider work, and is
journaled and visible rather than secret. Resume reuses it, accepts no
replacement, and rejects a changed compiled tree by fingerprint.

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
Threads are ephemeral and explicitly unsubscribed. The owner recycles its one
Port after 64 successful releases, after unrelated live turns settle, to bound
Codex's grace-period retention of idle threads.

## Packaging

The production package is one immutable directory containing one Mix/OTP
release, its release-overlay command, and the skill:

```bash
make dev-bundle
make dist
```

The archive's `./install` copies and activates the immutable bundle, then calls
the release overlay's reconciliation command. Installation persists the exact
Codex binding, installs the skill, provisions and starts the macOS LaunchAgent
or Linux `systemd --user` unit, waits for scheduler health, and registers the
direct `/mcp` URL. There is no post-install command left for the user.

The service manager owns the foreground `agent_loops start` process. MCP
connections own no supervisor and cannot stop the release when disconnected.
The shared Codex app-server is a lazy supervised child of that one release;
mock execution and health checks do not start it. No supported command launches
an isolated second scheduler or app-server.

Public development commands:

```bash
make build
make ci
make dev-bundle
make dist
```

`make ci` builds and tests the OTP release, copied source-only plugin,
one-action installation, user-service lifecycle, direct Streamable HTTP MCP,
validation, mock execution, all workflow variants, status, inspection, resume,
typed errors, streaming activity, browser UI, and open-ui. It is deterministic,
credential-free, and does not spend a real Codex turn.

## Safety And Testing

Every executable workflow must pass:

```text
workflow_validate script_path=.codex/workflows/<name>.exs workspace_root=/absolute/path/to/repo args={"scope":"auth"}
workflow_start    script_path=.codex/workflows/<name>.exs workspace_root=/absolute/path/to/repo run_id=<id> provider=mock args={"scope":"auth"}
workflow_status   run_id=<id>
workflow_inspect  run_id=<id>
```

Generated workflows that can mutate files should return closed plans or declare
live write scope, exact file paths, and verification commands before the caller
authorizes live execution.

When an MCP tool fails, preserve its typed scheduler error envelope.
