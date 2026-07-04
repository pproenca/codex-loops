# Workflow Authoring

## Sources
Sources:
- `plugins/codex-loops/skills/codex-loops/SKILL.md`
- `plugins/codex-loops/SPEC.md`

## When To Use A Workflow
Use Codex Loops when the task benefits from independent agents, phased synthesis,
parallel read-only review, adversarial checks, or guarded mutation after a
preflight. Do not use it for trivial single-file edits, basic command output, or
questions the main agent can answer directly.

## Choose The Artifact
Use an executable workflow script when the user wants Codex Loops to run,
validate, mock-test, resume, inspect, or launch orchestration through the local
runtime. Use a reusable Codex skill when the user wants to save a workflow as
operator guidance, a playbook, or future Codex behavior.

Skill-saving requests should produce `SKILL.md` frontmatter, trigger guidance,
workflow steps, safety gates, and verification expectations. They should not run
`agent-loops draft`, `agent-loops validate`, `agent-loops test`,
`agent-loops workflow`, `agent-loops run`, or `agent-loops resume` unless the
user also asks for an executable script.

## Scout-First Loop
Author workflows from repository facts:
1. Scout locally with `rg --files`, focused `rg`, and small file reads.
2. Convert facts into file scope, package contracts, mutation posture, approval
   posture, and verification commands.
3. Choose barrier or pipeline execution per phase.
4. Give workers exact paths, search scope, constraints, schemas, caps, and halt
   conditions.
5. Add adversarial verification and a final build or test gate for mutating work.
6. Run `validate` or `test --provider mock` before live execution.

## DSL Requirements
- `export const meta = {...}` must be the first statement, a pure literal, and
  include string `name` and `description`.
- `args` is the parsed JSON value from `--args`.
- `budget` exposes synchronous `total`, `spent()`, and `remaining()` reads.
  With no task budget, `total` is `null` and `remaining()` is `Infinity`.
- `agent(prompt, opts?)` spawns one worker turn.
- `pipeline(items, ...stages)` is the default multi-stage primitive.
- `parallel(thunks)` is a barrier and requires deferred functions.
- `workflow(nameOrRef, args?)` invokes one child workflow.
- `phase(title)` and `log(message)` annotate progress.
- Scripts cannot use Node APIs, imports, dynamic time, random values, TypeScript
  syntax, or runner-only mutation helpers.

## Worker Prompt Framing
Workflow-spawned workers start cold. Worker prompts should give higher-level
tasks, exact evidence scope, closed output shape, and clear stop conditions. Do
not ask one worker to check on another; the host aggregates results from the
journal.

Dynamic-workflow prompt sources should preserve structured notification
evidence. Codex Loops uses that authoring principle while documenting its own
local runner behavior.

## Barrier Vs Pipeline
Use `parallel()` when later work truly needs all upstream results together, such
as a ranking, vote, or cross-check. Use `pipeline()` when each item can move
through stages independently, keeping review and verification close to the
changed unit.

## Mutation Posture
Prefer plan-first workflows for mutations: agents return exact file paths,
expected changes, and verification commands, then the host or main agent applies
reviewed edits. If live SDK execution may write, keep write scope explicit and
narrow with the intended isolation mode.

## Testing Gate
Before live SDK execution, run:

```sh
agent-loops validate <script-or-name> --args '<json>' --json --no-input
agent-loops test <script-or-name> --args '<json>' --provider mock --budget small --json --no-input
```

Read the JSON result, including snapshot status, budget plan, runtime contract,
phase summaries, and failed node diagnostics.

## Budget Model
Without `--budget` or `--task-budget`, workflows use structural backstops
(`maxAgents: 1000`, `maxConcurrentAgents: 8`, `maxParallelItems: 4096`,
`maxPipelineItems: 4096`) and no token ceiling. Named presets are structural:
`small` lowers agent/work-item caps, while `standard` and `deep` keep the high
defaults. Only `--task-budget` or the programmatic `taskBudget` option creates
a hard token ceiling. Explicit limit flags and programmatic options override
the selected preset.

Token spend is observed from completed host responses. Once observed spend
reaches an explicit task budget, future `agent()` calls fail; already-started
agent turns are not retroactively killed.

## Halt Conditions
Stop before live execution when validation fails, mock testing fails, intended
write scope is unclear, required approval is missing, or the workflow would need
unsupported hosted-workflow behavior.
