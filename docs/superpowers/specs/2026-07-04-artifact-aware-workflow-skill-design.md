# Artifact-Aware Workflow Skill Design

## Context

Codex Loops currently presents workflow authoring as script-first. The plugin
skill describes a "saved workflow script", the runtime `draft` command writes
`.codex/workflows/<name>.ts`, and the spec focuses on path-first executable
workflow files.

Users may also use "workflow" to mean a reusable operating procedure. When a
user says they want to save a workflow as a skill, forcing the request through
`agent-loops draft` creates the wrong artifact. A Codex skill is reusable
guidance in `SKILL.md`; a Codex Loops workflow script is executable
orchestration through the `agent-loops` runtime.

## Goal

Make the plugin guidance artifact-aware so Codex can choose between an
executable workflow script, a reusable Codex skill, or both before writing
files.

## Non-Goals

- Do not add `agent-loops draft --format skill` in this change.
- Do not turn the runtime package into a skill scaffolder.
- Do not relax the validation or mock-test gate for executable workflow
  scripts.
- Do not start status UI or live execution behavior from skill-saving requests.

## User-Facing Behavior

When a user asks to "turn this into a workflow", the skill should classify the
intended artifact before writing anything:

- Executable workflow: write `.codex/workflows/<name>.ts`, then run the existing
  validation or mock-test gate before live execution.
- Reusable skill: write or update a `SKILL.md` in a user-approved skill
  location, using Codex skill conventions rather than the `agent-loops` DSL.
- Both: create the skill as the reusable operating guide and optionally link to
  or include a tested workflow script when execution is also needed.
- Ambiguous: ask one short question: "Do you want this saved as an executable
  workflow script, a reusable Codex skill, or both?"

## Design

The runtime remains script-focused. Artifact selection lives in plugin guidance
because the distinction is about user intent and authoring behavior, not about
executing workflows.

The `codex-loops` skill should add a routing section before the existing
authoring contract:

1. Treat requests to run, execute, test, resume, inspect, or launch a workflow
   as executable workflow-script requests.
2. Treat requests to save a workflow as a skill, playbook, reusable procedure,
   or future Codex behavior as skill-authoring requests.
3. Treat explicit "both" requests as a two-artifact flow.
4. Ask the artifact question when the request only says "workflow" and the
   intended artifact is unclear.

Skill-authoring requests should produce a skill document, not a workflow DSL
file. The generated skill should include frontmatter, trigger guidance,
required workflow steps, safety gates, and verification expectations. It should
not call `agent-loops draft`, `validate`, `test`, `workflow`, or `resume`
unless the user also asks for an executable script.

Executable workflow requests keep the current scout-first loop and testing
gate.

## Files To Update Later

- `plugins/codex-loops/skills/codex-loops/SKILL.md`
- `plugins/codex-loops/SPEC.md`
- `plugins/codex-loops/README.md`
- `docs/workflow-authoring.md`
- `.plugin-eval/codex-loops` benchmark or verifier coverage

## Evaluation

Add or update eval coverage for at least these cases:

- "Save this workflow as a skill" should create or propose `SKILL.md` and must
  not call `agent-loops draft`.
- "Turn this into an executable Codex Loops workflow" should still create
  `.codex/workflows/<name>.ts` and use validation or mock testing before live
  execution.
- "Turn this into a workflow" without artifact detail should ask the artifact
  clarification question.

The custom verifier should inspect proof artifacts for the selected artifact
path and command evidence. A skill-saving proof should fail if it includes
unapproved workflow execution or treats the skill as a TypeScript workflow
script.

## Acceptance Criteria

- Plugin guidance distinguishes reusable skills from executable workflow
  scripts.
- Ambiguous "workflow" requests ask the artifact question before file writes.
- Skill-saving requests avoid `agent-loops draft` unless the user also asks for
  an executable script.
- Existing script execution safety gates remain unchanged.
- Plugin eval still passes, and the Codex Loops-specific metric pack covers the
  skill-saving route.
