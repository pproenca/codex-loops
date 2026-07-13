# Workflow Authoring

## When To Use A Workflow

Use Codex Loops when work benefits from phases, repeatable provider turns,
journal-backed inspection, resume, or an explicit mock-before-live gate. Do not
use it for trivial single-file edits or questions the main agent can answer
directly.

## File Shape

Author executable workflows as Elixir `.exs` files:

```elixir
workflow "example" do
  phase "scout"
  log "starting"
  agent "Inspect README.md and summarize the project goal."
  return :ok
end
```

Save repo-local workflows under `.codex/workflows/<name>.exs` unless the caller
asks for another path.

The file MUST contain exactly one bare, top-level `workflow` declaration. Do not
wrap it in `defmodule`, write `use Workflow`, import a DSL, or define a schema
module. The loader reads at most 1 MiB of UTF-8 source, parses it as AST data,
and never compiles or evaluates the file. The closed vocabulary accepts only
known atoms; arbitrary source text cannot mint atoms in the scheduler VM.

## DSL

- `workflow "name" do ... end` defines the workflow.
- `phase "title"` records progress.
- `log "message"` records a journal log.
- `agent "prompt"` runs one provider turn.
- `agent "prompt", schema: %{...}, retries: n` requests structured output, where
  `n` is `0..5`, and fails closed after invalid attempts. For the Codex provider, the schema is
  passed with the app-server `outputSchema` parameter.
- `let :name = agent(...)`, `let :name = synthesize(...)`, and
  `let :name = refine(...)` bind a top-level producer's journaled output for
  later dataflow rendering.
- `agent(~P"... <%= @name %> ...")` injects earlier explicit bindings into a
  later top-level agent prompt. Template prompts are not allowed in nested
  agents such as `parallel`, `pipeline`, `fanout`, `fan_out`, or loop bodies.
- `emit(~P"... <%= @name %> ...")` sets the final terminal value to rendered
  text from earlier bindings.
- `emit_result(:name)` sets the final terminal value to a structured public
  projection from a result-capable binding. The shipped result-capable producer
  is `refine`.
- `return value` sets the run result.
- `loop max_iterations: n, until: predicate do ... end` is the generic bounded
  loop core.
- `fanout width: n do ... end` is the generic repeated-lane fan-out core.
- Higher-level combinators such as `parallel`, `pipeline`, `collect`, `verify`,
  `judge`, and `synthesize` are available in the workflow language and should
  be used only when the orchestration genuinely needs them.
- `while_budget`, `until_dry`, and `fan_out` remain useful
  sugar/compatibility surfaces. Prefer modeling new orchestration with generic
  `loop`, generic `fanout`, and closed predicates first.
- `gather` and `map` are specified for a future dataflow extension but are not
  available in the shipped compiler. Keep them out of executable workflows.

## Generic Loop And Fanout Core

The live dynamic core is generic `loop`, generic `fanout`, and closed
predicates. Legacy `while_budget`, `until_dry`, and `fan_out` still work, but
they are compatibility/sugar forms, not the whole model.

Use `loop` for bounded repetition:

```elixir
loop max_iterations: 3, until: count(:items) >= 2, on_exhausted: :fail do
  agent "find items", schema: %{"type" => "array"}
  collect into: :items
end
```

`loop max_iterations:` requires an integer from `1` through `1000`. It may use either a header
`until:` predicate or one body-local `until(predicate)`, but not both. A
body-local `until` stops the loop at that point in the body and skips later body
nodes for the current iteration; it cannot contain `dry(...)`, and only one
body-local `until` is allowed.

Use `fanout` for repeated agent lanes:

```elixir
fanout width: 2, bind: :reviews, max_concurrency: 2 do
  agent "Review the current plan and return JSON."
end

emit ~P"Reviews: <%= @reviews %>"
```

`fanout` supports `width:` as an integer, `budget_slices(per: n, max: m)`, or
`path_count(:binding, "/json/pointer", max: m)`. It also supports optional
`bind:`, `max_concurrency:`, and `on_zero: :complete | :fail`. A `bind:` name
produces the ordered lane result list for later top-level templates and
predicates. Requested concurrency is still subject to the runtime-wide cap of
eight tasks, and resolved fanout width is capped at 64. Inside a generic loop,
a previous `fanout bind:` can be used by a
later body-local `until`:

```elixir
loop max_iterations: 2 do
  fanout width: 2, bind: :checks do
    agent "Check the draft.",
      schema: %{
        "type" => "object",
        "properties" => %{"approved" => %{"type" => "boolean"}},
        "required" => ["approved"]
      }
  end

  until agree(:checks, path: "/approved", equals: true, threshold: :all)
end
```

For heterogeneous work, a literal width may match an explicit list of non-empty
agent lanes:

```elixir
fanout width: 2 do
  lanes([[agent("check the API")], [agent("check the UI"), agent("check the docs")]])
end
```

Deferred dataflow `gather` and `map` remain unavailable.

## Schema-Backed Prompts

For schema-backed agents, the schema owns output shape and the prompt owns task
semantics. Do not paste JSON Schema into the prompt or add generic boilerplate
such as "return JSON matching this schema." Instead, write the prompt to explain
what evidence to inspect, what the fields mean, how to judge edge cases, and any
domain constraints the schema cannot express. The writer validates the final
provider output locally and retries or fails closed when it does not conform.
`schema:` accepts a literal JSON Schema map; there is no schema-module or
schema-sub-DSL form.

Closed predicate examples that match the live parser/evaluator. For `agree`
over a fanout binding, each lane result must be a structured map, usually from a
schema-backed agent:

```elixir
all([count(:items) >= 2, budget_remaining() > 10])
any([path_exists(:reviews, "/0"), path_non_empty(:draft, "/summary")])
dry(rounds: 2, seen_by: [:id])
agree(:reviews, path: "/approved", equals: true, threshold: :all)
path_count(:draft, "/items") >= 2
path_equals(:draft, "/status", "ready")
```

`all_of` and `any_of` are legacy aliases for `all` and `any`.

## Dataflow Core

The implemented dataflow core is deliberately narrow: bind a previous producer
with `let`, render it through a `~P` template in a later top-level `agent` or
final `emit`, or return a structured result with `emit_result`.

Use `~P` holes like `<%= @draft %>` for dataflow. Do not use Elixir string
interpolation (`"#{...}"`), variables, helper calls, or control-flow tags inside
prompts. Bindings are define-before-use: a top-level template may reference
earlier in-scope bindings from `let` or top-level `fanout bind:` names. A
loop-local `fanout bind:` name is only available to later body-local `until`
predicates in that same generic loop body.

Valid text-producing example:

```elixir
workflow "draft-improve" do
  let :draft = agent("Draft a concise project update. Return prose.")

  let :improved = agent(~P"""
  Improve this draft for clarity and actionability.

  Draft:
  <%= @draft %>
  """)

  emit(~P"""
  # Project Update

  <%= @improved %>
  """)
end
```

Valid structured-result example:

```elixir
workflow "review-loop" do
  let :final = refine(agent("Draft a migration plan."),
    reviewers: [
      reviewer(:spec, "Check the plan against the spec."),
      reviewer(:runtime, "Check runtime and test risks.")
    ],
    revise_with: agent("Revise the plan using the review findings."),
    until: :unanimous,
    max_rounds: 1
  )

  emit_result(:final)
end
```

`let :summary = synthesize([...], "...")` is also bindable for later `~P`
rendering, but `synthesize` itself still takes literal inputs and a literal
prompt. The deferred `gather(~P"...")` and `map :item, over: :items, ...`
forms remain unavailable.

## Authoring Loop

1. Scout repository facts first with local tools.
2. Convert those facts into exact files, prompts, schemas, budgets, and stop
   conditions.
3. Keep worker prompts specific: include paths, evidence scope, semantic field
   meaning, and halt conditions. Put structural shape in `schema:`.
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
workflow_open_ui run_id=<id-live>
```

Use `workflow_open_ui` to watch activity in LiveView. Every activity entry is
durably appended before the UI is notified. `workflow_status` polls the same
journal-backed projection, and `workflow_inspect` returns durable journal
summaries and raw refs.

## Resume

Resume replays the event log and reuses completed nodes. It can continue after
settled attempts and deterministic control-flow markers:

```text
workflow_resume run_id=<id> provider=codex
workflow_status run_id=<id>
```

Provider effects are at-most-once. The scheduler writes `agent_started` before
each provider call. If that marker has no matching committed, rejected, or
failed settlement, the effect may have happened and its outcome is unknowable;
resume does not redeliver it. Instead the run terminates with
`outcome_unknown`. Starting a fresh run after inspecting that attempt is an
explicit operator decision.
