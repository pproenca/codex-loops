# Codex Loops Plugin Spec

## Purpose

Provide one Codex skill for authoring, validating, testing, executing, and
inspecting local path-first dynamic workflow scripts with the `agent-loops` CLI.

The plugin is deliberately thin. The published app package owns runner behavior;
the skill teaches when to use it, how to write compatible workflow scripts, how
to run the validation and mock-test gates, and how to relay journal-backed
lifecycle state. It does not define a second runner package or a parallel
command surface.

## Public Surface

Skill:

- `codex-loops`

CLI commands:

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

Programmatic helpers:

- `workflow(nameOrRef: string | { scriptPath: string }, args?: unknown, options?: WorkflowCallOptions): Promise<unknown>`
- `testWorkflow(nameOrRef: string | { scriptPath: string }, args?: unknown, options?: WorkflowCallOptions): Promise<WorkflowCommandResult>`

Artifact-aware authoring:

- User asks to run, execute, test, resume, inspect, launch, or automate through
  Codex Loops: create an executable workflow script and keep the existing
  validation/mock-test gate.
- User asks to save a workflow as a skill, playbook, reusable procedure, or
  future Codex behavior: create or update a `SKILL.md` in a user-approved skill
  location and do not call `agent-loops draft`, `agent-loops validate`,
  `agent-loops test`, `agent-loops workflow`, `agent-loops run`, or
  `agent-loops resume`.
- User asks for both: create the reusable skill as the operating guide and only
  create a workflow script for the executable portion.
- User says only "workflow" and the artifact is ambiguous: ask whether they want
  an executable workflow script, a reusable Codex skill, or both before writing
  files.

Workflow script input is path-first. Inline script and stdin script execution are
out of scope for this version. Local background launch and a live status UI are
supported. Hosted workflow services, external workflow UIs, and per-agent
skip/retry controls are intentionally unsupported by this package.
Live SDK execution must use the TypeScript `@openai/codex-sdk` package; the
SDK's `codexPathOverride` option may select the Codex executable but must not
replace the SDK module itself.

## Journal And Snapshot

The journal is an append-only JSONL event log (`agent-loops/journal@2`) and the
only persistent run artifact. `status`, `inspect`, `list`, `resume`, and `serve`
are pure folds over it; completed nodes replay from the journal on resume.

When no `--journal` is passed, runs write per-run files under
`.agent-loops-runs/` and maintain `.agent-loops-runs/latest.json` as a
`{"$pointer": ...}` file, so the default journal path still names the latest
run for bare `status`/`inspect`/`resume`/`serve`.

Snapshots are derived projections with
`schemaVersion: "workflow-snapshot/v2"`: one canonical `phases[]` progress
representation with embedded node summaries
(`queued|running|done|failed|killed`), `scriptPath` + `scriptSha256` instead of
embedded script text, and the `runtimeContract`. Legacy v1 snapshot journals
are readable by `inspect`/`status`/`list` only; `resume` and `serve` reject
them.

## DSL Requirements

The workflow DSL is implemented by the `agent-loops` package and executed
through mock or Codex SDK-backed workers.

Required globals:

- `args`
- `budget`
- `agent(prompt, opts?)`
- `pipeline(items, ...stages)`
- `parallel(thunks)`
- `workflow(nameOrRef, args?)`
- `phase(title)`
- `log(message)`

Required script constraints:

- `meta` must be the first statement and a pure literal with `name` and
  `description`.
- Scripts are plain JavaScript in an async context.
- Node APIs, imports, dynamic time, random values, TypeScript syntax, and
  runner-only mutation helpers are not allowed.
- Schema-backed `agent()` calls return provider-validated objects and fail
  closed after retry exhaustion.
- `pipeline()` is the default multi-stage primitive; `parallel()` is a barrier.
- Identical-content fan-out should pass explicit `label` options so resumed
  results keep their positions; default labels are content-derived.
- Child workflows share the parent journal, limits, model policy, and abort
  signal.

Expected authoring loop:

1. Scout repository facts first, using local inventory and focused reads before
   writing the workflow.
2. Translate facts into workflow constraints: file scope, public contracts,
   mutation posture, verification commands, and halt conditions.
3. Choose barrier versus pipeline per phase and document why that dependency
   shape is required.
4. Use domain-rich worker prompts with exact files, constraints, closed schemas,
   and concrete expected outputs.
5. Add adversarial verification and a final build or test gate for mutating
   workflows.
6. Run `validate` or `test --provider mock`; run live SDK only after approval.

## Runtime Contract

Snapshots include a `runtimeContract` object that makes guidance decisions
inspectable:

- activation source and command
- permission decision and caller-owned approval source
- structured-output fail-closed policy
- scheduling caps and queue-state visibility
- task-budget/accounting threshold policy
- resume cache key and journal path
- hosted-service support set to `false`

Status and inspect commands must surface this contract without rerunning the
workflow.

## Safety And Testing

Every workflow must pass `agent-loops validate` or `agent-loops test --provider
mock` before live SDK execution. Generated workflows that can mutate files
should use bounded args during testing and should return closed plans or a
declared live write scope, exact file paths, and verification commands before
the caller authorizes live execution.

The skill must report:

- workflow path
- journal path
- budget plan and explicit caps
- runtime contract, including permission and hosted-service support
- test result and failed node diagnostics, if any
- exact args
- intended file changes or a no-change statement

Live execution remains caller-owned. The skill should stop when tests fail or
when the intended write scope is unclear. Pass `--approved` only when the caller
or host UI has already approved the live SDK run.

Visual status UI launch is also caller-owned. If the current request asks to
run a workflow and explicitly asks to start, serve, show, or open the UI, the
skill launches one integrated CLI envelope:

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

It parses the `async_launched` JSON envelope and relays both `journalPath` and
`statusUrl`. After a live or background run starts without an explicit UI
request, the skill must report the journal path and ask whether the user wants a
visual UI. Unless the current user request explicitly asked to serve or open the
UI, the skill must wait for the user's yes/no answer before starting a server.
When accepted for an already-running workflow, the skill launches the integrated
status server with:

```bash
npx -y agent-loops serve --journal <journal.jsonl> --json
```

It then relays the JSON envelope URL and keeps the server process alive while
the user needs the visual progress page.

When a `--json` invocation fails, the last stderr line is a single-line JSON
error object (`schema/cli-error.schema.json`); parse that instead of scraping
prose diagnostics.

## Acceptance Checks

- Exactly one `SKILL.md` exists under `plugins/codex-loops/skills`.
- `node apps/runtime/scripts/gen-help.mjs --check` exits 0: the
  `gen:commands` blocks in the app README, this spec, the plugin README, and
  the skill match the CLI `COMMANDS` table.
- `node .plugin-eval/codex-loops/verifiers/verify-plugin-structure.js`
  exits 0.
- Plugin text explicitly says local background launch and status pages are
  supported, while hosted workflow services remain unsupported in this package.
- Plugin text explicitly says the skill asks before starting the visual status
  UI, uses `workflow --background --status-server --json` when the current
  request asks to launch with UI, and uses
  `npx -y agent-loops serve --journal <journal.jsonl> --json` for an existing
  run.
- Plugin text distinguishes executable workflow scripts from reusable Codex
  skills and includes the artifact clarification question.
- Skill-saving requests are documented as `SKILL.md` authoring requests that do
  not call Codex Loops execution or validation commands unless an executable
  script is also requested.
- `agent-loops status`, `inspect`, `list`, `validate`, and `resume` work against
  local journals.
- The app ships exactly these schemas: `agent-result.schema.json`,
  `cli-error.schema.json`, `journal-event.schema.json`,
  `patch-plan.schema.json`, `workflow-command.schema.json`,
  `workflow-draft.schema.json`, `workflow-snapshot.schema.json`,
  `workload-plan.schema.json`.
- App typecheck, tests, and build pass.
