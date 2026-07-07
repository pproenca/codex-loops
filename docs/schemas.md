# Codex Loops Legacy Schemas

These schema files are compatibility artifacts from the pre-scheduler runtime
and legacy CLI wrapper. They are useful when maintaining old integrations, but
they are not the current product command surface. The current Codex-facing
surface is the MCP adapter plus the Elixir/Phoenix scheduler API.

## Sources
Sources:
- `apps/runtime/schema/agent-result.schema.json`
- `apps/runtime/schema/cli-error.schema.json`
- `apps/runtime/schema/journal-event.schema.json`
- `apps/runtime/schema/patch-plan.schema.json`
- `apps/runtime/schema/workflow-command.schema.json`
- `apps/runtime/schema/workflow-draft.schema.json`
- `apps/runtime/schema/workflow-snapshot.schema.json`
- `apps/runtime/schema/workload-plan.schema.json`
- `plugins/codex-loops/SPEC.md`

## Schema Inventory
- `agent-result.schema.json`
- `cli-error.schema.json`
- `journal-event.schema.json`
- `patch-plan.schema.json`
- `workflow-command.schema.json`
- `workflow-draft.schema.json`
- `workflow-snapshot.schema.json`
- `workload-plan.schema.json`

## Compatibility Result Schemas
- `agent-result.schema.json` describes agent turn results: text or structured
  value, thread id, token and tool counts, duration, work item count, mutation
  scope, and optional compatibility warning.
- `cli-error.schema.json` describes the final machine-readable stderr failure
  object with required `code`, `exitCode`, and `message`, plus optional `hint`
  and `details`.

## Journal And Snapshot
- `journal-event.schema.json` describes the variant event envelope for the
  `agent-loops/journal@2` event payload stored in SQLite `event_json` rows. The
  schema is variant-based rather than a single object shape.
- `workflow-snapshot.schema.json` describes projected snapshots with required
  schema version, run id, workflow name, status, script path, database path,
  args, phases, logs, agent count, token totals, and tool-call totals.

## Workflow Authoring
- `workflow-command.schema.json` describes reusable command metadata, including
  command path, workflow reference, supported modes, default mode or budget,
  preflight, read/write posture, and relay metadata.
- `workflow-draft.schema.json` describes historical `draft --json` output with
  script path, workflow name, validation, next steps, optional args, budget,
  command path, workload plan, and write scope. Draft scaffolding is not shipped
  in the scheduler/plugin product surface.

## Patch And Workload Plans
- `patch-plan.schema.json` describes a plan-first mutation contract with required
  approval status, security status, base sha, and operations.
- `workload-plan.schema.json` describes batching and completeness assumptions:
  scope kind, batchability, run completeness, basis, expected or maximum item
  counts, and mutation or prompt caps.

## Compatibility Notes
Schemas are public package artifacts and should not be inlined into narrative
docs. Schema filenames are part of the package contract and are checked by
package contract tests and plugin acceptance checks.
