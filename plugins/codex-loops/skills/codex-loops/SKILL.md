---
name: codex-loops
description: "Use when the user explicitly asks for Codex Loops, dynamic workflows, fanout, ultracode-style orchestration, lifecycle/status inspection, an executable workflow script, or a reusable Codex skill that captures a workflow-shaped operating procedure."
---

# Codex Loops

Codex Loops is the local, path-first workflow runner for Codex dynamic
workflows. Use this skill only when the user explicitly asks for Codex Loops,
fanout/multi-agent orchestration, ultracode-style work, workflow lifecycle
inspection, an executable workflow script, or a reusable Codex skill that
captures a workflow-shaped operating procedure.

The runner is local and journal-backed. The journal is an append-only event
log; `status`, `inspect`, `list`, `serve`, and `resume` read it directly.
When no `--journal` is passed, commands follow the
`.agent-loops-runs/latest.json` pointer to the latest per-run journal, so bare
`status`/`resume` mean "the latest run". The runner supports local background
launch and a live status UI. It does not implement hosted workflow services,
external workflow UIs, or per-agent skip/retry controls in this package.

Live SDK execution must use the TypeScript `@openai/codex-sdk` package.
`--codex-path-override` may point that SDK at a local Codex executable; do not
swap in another TypeScript SDK or module shim.

Use the published CLI surface:

<!-- gen:commands -->
```bash
agent-loops draft --goal '<goal>' [--name name] [--output .codex/workflows/name.ts] [--json]
agent-loops validate <script-or-name> --args '<json>' [--journal <path>] [--json] [--no-input]
agent-loops test <script-or-name> --args '<json>' [--provider mock|sdk] [--budget small|standard|deep] [--json] [--no-input]
agent-loops workflow <script-or-name> --args '<json>' [--journal <path>] [--provider sdk|mock] [--budget small|standard|deep] [--approved] [--json] [--no-input]
agent-loops workflow <script-or-name> --args '<json>' --background [--status-server] [--json] [--no-input]
agent-loops run <script-or-name> --args '<json>' [--journal <path>] [--provider sdk|mock] [--budget small|standard|deep] [--approved] [--json] [--no-input]
agent-loops resume [--journal <path>] [--provider sdk|mock] [--approved] [--json] [--no-input]
agent-loops inspect [--journal <path>] [--json]
agent-loops status [--journal <path>] [--event-limit 5] [--json]
agent-loops list [--journal-root .agent-loops-runs] [--limit 20] [--event-limit 5] [--json]
agent-loops serve [--journal <path>] [--host 127.0.0.1] [--port 0] [--json]
agent-loops help
```
<!-- /gen:commands -->

Invoke via `npx -y agent-loops <command> ...`, or via
`agent-loops <command> ...` when the package binary is already installed. `run`
is an alias for `workflow`. `list --journal-root .agent-loops-runs --json` summarizes known
journals. `draft` writes a deterministic scaffold (no LLM), runs the
compatibility validation gate, and returns `nextSteps`. It does not execute a
mock workflow; run `test --provider mock` explicitly before live SDK execution.

## Artifact Selection

Before writing files, classify what the user means by "workflow":

- **Executable workflow script**: use this path when the user asks to run,
  execute, test, resume, inspect, launch, or automate work through Codex Loops.
  Author `.codex/workflows/<name>.ts`, then use the validation or mock-test
  gate before live SDK execution.
- **Reusable Codex skill**: use this path when the user asks to save a workflow
  as a skill, playbook, reusable procedure, or future Codex behavior. Write or
  update a `SKILL.md` in a user-approved skill location using Codex skill
  conventions. Do not call `agent-loops draft`, `agent-loops validate`,
  `agent-loops test`, `agent-loops workflow`, `agent-loops run`, or
  `agent-loops resume` unless the user also asks for an executable script.
- **Both**: when the user explicitly asks for both, write the reusable skill as
  the operating guide and create a tested workflow script only for the
  executable part.
- **Ambiguous**: when the user only says "turn this into a workflow" and the
  intended artifact is unclear, ask: "Do you want this saved as an executable workflow script, a reusable Codex skill, or both?"

For skill-saving requests, produce skill frontmatter, trigger guidance, workflow
steps, safety gates, and verification expectations. Treat the skill as reusable
operator guidance, not as a TypeScript workflow script.

## When To Use

Use a workflow when the task benefits from independent agents, phased synthesis,
parallel read-only review, adversarial checks, or guarded mutation after a
preflight. Scout locally first when the inventory is unknown: use `rg --files`,
focused `rg`, and small file reads before authoring the workflow.

Do not use Codex Loops for trivial single-file edits, basic command output, or
questions the main agent can answer directly.

## Authoring Contract

Author workflow files under `.codex/workflows/<name>.ts`. Scripts run as plain
JavaScript in an async workflow context.

Use a scout-first authoring loop:

1. Scout repository facts first with local tools; capture evidence-backed facts
   and consequences, not broad guesses.
2. Translate those facts into workflow constraints: exact files, package
   contracts, approval posture, mutation limits, and verification commands.
3. Choose barrier versus pipeline deliberately. Use barriers only where later
   work genuinely needs all upstream results together; otherwise pipeline work
   so review and verification can stay close to each changed unit.
4. Write domain-rich worker prompts with exact files or search scope,
   constraints, closed schemas, and the expected output shape.
5. Add adversarial verification and, for mutating workflows, a final build or
   test gate that must pass before reporting completion.
6. Run `validate` or `test --provider mock` first. Use live SDK execution only
   after approval.

Required DSL facts:

- `export const meta = {...}` must be the first statement, a pure literal, and
  include string `name` and `description`.
- `args` is the parsed JSON value from `--args`, not a JSON-encoded string.
- `budget` exposes `total`, `spent()`, and `remaining()` for task-budget
  visibility; it is separate from provider max-output tokens and dollar/cost
  accounting.
- `agent(prompt, opts?)` spawns one Codex worker. Schema-backed agents must
  return through the provider structured-output channel; ordinary final text is
  not accepted as structured output.
- `pipeline(items, ...stages)` is the default multi-stage primitive.
- `parallel(thunks)` is a barrier and must receive functions such as
  `() => agent(...)`, not already-started promises.
- Pass an explicit `label` to each branch of identical-content fan-out (same
  prompt, schema, and options); default labels are content-derived, so
  identical siblings may swap result positions on resume without labels.
- `workflow(nameOrRef, args?)` invokes one child workflow by saved name or
  `{ scriptPath }`; child workflows share the parent journal and limits.
- `phase(title)` and `log(message)` annotate progress.
- Scripts cannot use Node APIs, imports, dynamic time, random values, TypeScript
  syntax, or runner-only mutation helpers.

Prefer closed, deterministic outputs. For mutating workflows, either keep the
workflow plan-first and let the host/main Codex agent apply reviewed edits, or
make the live workflow's write scope explicit and narrow with `workspace-write`
or `full-access` isolation. In both cases, return exact file paths, expected
changes, and verification commands.

## Runtime Contract

Every run journal records a `runtimeContract` with:

- activation source and command
- permission decision and caller-owned approval source
- structured-output fail-closed policy
- scheduling limits and visible queued/running/done/failed/killed states
- task-budget/accounting policy
- resume cache key and journal path
- hosted-service support set to `false`

Use `status` or `inspect` to relay those fields when the user asks what is
running, why a run failed, whether it is stale, or how to resume.

## Testing Gate

Before live SDK execution:

1. Run `validate` or `test --provider mock` with bounded args.
2. Read the JSON result, especially `snapshot.status`, `budgetPlan`,
   `runtimeContract`, `snapshot.phases` node summaries, and any failed node
   errors.
3. If mutation is possible, report the workflow path, journal path, exact args,
   budget preset and caps, intended write scope, and verification command.
4. Ask for or rely on explicit caller approval before live SDK execution. Pass
   `--approved` only after that approval exists.

If validation or testing fails, stop and report the failure. Do not execute a
generated mutating workflow when the intended write scope is unclear.

When any `--json` invocation fails, the last stderr line is a single-line JSON
error object `{code, exitCode, message, hint?, details?}` — parse that instead
of scraping prose diagnostics.

## Live Execution

Run live workflows only after the testing gate is satisfied:

```bash
npx -y agent-loops workflow .codex/workflows/<name>.ts \
  --args '<json>' \
  --journal .agent-loops-runs/<name>.jsonl \
  --provider sdk \
  --budget small \
  --approved \
  --json \
  --no-input
```

After launch, use:

```bash
npx -y agent-loops status --journal .agent-loops-runs/<name>.jsonl --json
npx -y agent-loops inspect --journal .agent-loops-runs/<name>.jsonl --json
```

Omit `--journal` to target the latest run via the `latest.json` pointer.

For local async launch, add `--background`. If the current request also
explicitly asks to start, serve, show, or open the UI, launch the workflow and
integrated status server in one command:

```bash
npx -y agent-loops workflow <script-or-name> \
  --args '<json>' \
  --journal .agent-loops-runs/<name>.jsonl \
  --provider sdk \
  --budget <small|standard|deep> \
  --approved \
  --background \
  --status-server \
  --json \
  --no-input
```

Parse the `async_launched` JSON envelope and relay both `journalPath` and
`statusUrl`. Background worker output lands in `<journal>.worker.log`.

## Visual Status UI

After a live or background launch, report the journal path and ask whether the
user wants the visual status UI started. Do not start a UI server implicitly
unless the user's current request explicitly asked to start, serve, or open the
UI. A concise prompt is enough:

```text
Do you want me to start the Codex Loops status UI for <journal-path>?
```

If the user says yes for an already-running workflow, start the integrated
status server from the journal with:

```bash
npx -y agent-loops serve --journal <journal-path> --json
```

Keep that process running while the user needs the page, parse the JSON startup
envelope for the local `url`, and share that URL. If Browser is available and
the user asked to see progress visually, open the URL in the in-app browser.
When the user says no, continue with `status`/`inspect` text updates only.
`agent-loops-ui` remains available for standalone package testing, but it is
not the default operator path for this skill.

Use `resume --journal ...` when a run failed, was killed, or went stale: it
replays the event log, reuses completed nodes from the journal (an identical
re-run makes zero provider calls), and re-runs only failed or changed nodes.
If the script or args changed in a way that invalidates prior node cache keys,
the changed calls re-run and a `script_changed` notice is recorded. Legacy
pre-0.2 snapshot journals are readable by `inspect`/`status`/`list` only;
`resume` and `serve` reject them.
