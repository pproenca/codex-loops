# Task 1 Report — Slice 1: Extract shared run inspector projection

Status: DONE

## Summary

- Added `Workflow.RunInspector`, a pure projection over `Workflow.Status` that exposes inspector-grade phases, phase-scoped agents, stable agent identity by address plus iteration, normalized activity, outcomes, rejected attempts, and failed rejected-only attempts.
- Updated `Workflow.Web.RunLive` to assign and render through the shared projection/detail shape instead of owning private phase grouping, agent selection, rejection filtering, failed-attempt visibility, activity normalization, agent id, and slug rules.
- Preserved the journal/status fold as the source of truth. No process, persistence table, macro DSL, live per-tool streaming, `SPEC.md`, or scheduler API projection changes were introduced.

## Tests

- Added `test/workflow/run_inspector_test.exs` for the projection/status seam:
  - same-address loop agents remain distinct by iteration;
  - activity is normalized from atom-keyed and string-keyed activity maps;
  - selected detail keeps rejected attempts separated by agent identity;
  - failed rejected-only attempts remain visible in the projected detail model.
- Adjusted `test/workflow/web/run_live_test.exs` with a rendered-behavior check for string-keyed activity flowing through the shared projection.
- Ran focused tests:

```sh
mix test test/workflow/run_test.exs test/workflow/run_inspector_test.exs test/workflow/web/run_live_test.exs
```

Result: 25 tests, 0 failures.

## Concerns

None.
