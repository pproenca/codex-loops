# Codex Loops Runtime

## Sources
Sources:
- `apps/runtime/DESIGN.md`
- `apps/runtime/README.md`
- `plugins/codex-loops/SPEC.md`

## Architecture
The shipped package implements a local event-sourced runner. The core model is a
pure reducer over journal events plus a thin effect shell. CLI parsing and
request preparation happen at the edge, core code computes decisions and
projections, consistency code owns journal writes, and effects contain filesystem,
process, status-server, and SDK adapters.

Runtime flow:
```text
CLI request -> parsed command -> run preparation -> isolated workflow script
             -> DSL intents -> pure decisions -> provider or child effects
             -> append-only journal -> projections
```

## Journal Model
The current journal format is `agent-loops/journal@2`: one append-only JSONL file
whose lines are closed journal events with strictly increasing `seq` values.
When no `--journal` is passed for a new run, Codex Loops writes a per-run JSONL
file under `.agent-loops-runs/` and updates `.agent-loops-runs/latest.json` as a
one-hop pointer.

The file journal store is the serialization point. A writer holds
`<journal>.lock`, appends are serialized, durable events are fsynced, idempotency
keys prevent duplicate logical commits, and readers tolerate a torn final line by
surfacing `truncatedTail` in projections.

## Snapshots And Status
Snapshots are projections, not stored authorities. `inspect` renders
`schemaVersion: "workflow-snapshot/v2"` with phases, embedded node summaries,
logs, totals, script path and hash, journal path, status, and `runtimeContract`.
`status` summarizes node counts, staleness, and a bounded event tail. `list`
scans known journals and projects each entry.

Legacy v1 snapshot journals are readable by `inspect`, `status`, and `list` but
are rejected by `resume` and `serve`.

## Node Identity And Resume
Node identity is based on run id, phase title, label, prompt hash, schema hash,
and options hash. Completed nodes replay from the journal on resume, so an
identical re-run makes no provider calls. Failed nodes re-run with a new attempt;
script edits emit `script_changed` and invalidate only calls whose identity
inputs changed.

Default labels are content-derived. Explicit labels are recommended for
byte-identical fan-out whose positional results matter.

## Sandbox And Determinism
Workflow scripts run in an isolated child/runtime context with deterministic DSL
globals and restricted host access. Scripts cannot import modules, access Node or
process APIs, use dynamic time or random values, or use TypeScript syntax. The
sandbox enforces determinism and hygiene for caller-approved scripts; it is not a
multi-tenant security boundary.

## Structured Output
Schema-backed `agent()` calls use provider structured output. Schema-invalid or
unparseable structured output is retried according to the configured schema retry
limit and then fails closed with exit code 8 when it cannot validate.

## Unsupported Runtime Scope
The implemented package is local-only. Hosted workflow services, external
workflow UIs, per-agent skip/retry controls, and inline script execution are not
shipped Codex Loops runtime behavior.
