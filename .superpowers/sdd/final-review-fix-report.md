## Final Review Fix Report

Status: fixed.

Fixes:

- Made `Workflow.Status.fold/2` total over additive/unknown `%Workflow.Event{}` types by counting them and leaving the rest of the status projection unchanged.
- Added an external scheduler API regression for `GET /api/runs/:id/events` that appends an unknown event, returns its compact `seq/type/address` projection, preserves the inspector, counts the unknown event, and does not expose raw payload data.
- Pinned the public scheduler HTTP/MCP status and inspect JSON shapes in `SPEC.md`, including the additive `inspector` shape and JSON-safe idempotency key serialization, while separating that contract from the legacy CLI JSON envelope.
- Broadened the provider activity typespec to match runtime/spec behavior for atom or string keys and text-coerced values.

Verification:

- `mix test test/workflow/web/scheduler_api_test.exs test/workflow/run_inspector_test.exs test/workflow/scheduler_test.exs` -> 75 tests, 0 failures.
- `scripts/check-spec.sh SPEC.md` -> ok.
- `mix compile --warnings-as-errors` -> ok.
- `git diff --check` -> ok.
- `mix format --check-formatted lib/workflow/status.ex lib/workflow/provider.ex test/workflow/web/scheduler_api_test.exs` -> ok.

Concerns: none.
