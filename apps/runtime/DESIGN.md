# Codex Loops Runtime Design

Codex Loops is a local, event-sourced workflow runner. The durable run store is
SQLite at `~/.codex/workflows/runs_1.sqlite`; the storage schema version is
encoded in the filename. The event payload schema remains
`agent-loops/journal@2`, stored as canonical JSON text in `events.event_json`
rows keyed by `(run_id, seq)`.

## Boundaries

The runtime keeps a strict trust/effect split:

- `trust/` parses untrusted CLI args, child protocol lines, provider events,
  journal event JSON, and public output envelopes.
- `core/` folds event streams and makes pure decisions.
- `consistency/` owns SQLite writes, idempotency, mutation records, run leases,
  and serve-session rows.
- `effects/` contains process, filesystem, status-server, SDK, and preparation
  adapters.
- `app/` wires the ports together and assembles CLI/API envelopes.

Boundary tests enforce these ownership rules.

## SQLite Store

The database contains:

- `metadata`, including `storage_schema_version` and `latest_run_id`
- `runs`, one row per run
- `events`, ordered committed event rows
- `idempotency_keys`, one row per logical commit key
- `mutations`, run-wide mutation records
- `run_locks`, live runner leases
- `serve_sessions`, status-server handshakes

There are no filesystem run journals or auxiliary run-state files. `list`,
`status`, `inspect`, `resume`, and `serve` all read SQLite rows and then pass raw
JSON event text through the trust parsers before projection.

## Run Selection

New `test`, `workflow`, and `run` commands create a run. They use `--run-id`
when supplied and otherwise use the preparer's generated id. `--journal` is
removed on every command and fails with `--journal was removed; use --run-id`.

`status`, `inspect`, `resume`, and `serve` select a run with `--run-id <id>`.
When omitted, they select `latest` through `metadata.latest_run_id`.

## Public Output

Machine output remains JSON when `--json` is supplied. Public run payloads expose
`runId` and `databasePath`; no public payload includes a storage locator alias.
Snapshots use `workflow-snapshot/v2` and are pure projections of the folded
event rows.

## Locking And Resume

SQLite is the serialization point. Writers acquire a `run_locks` lease inside a
`BEGIN IMMEDIATE` transaction. A live owner is rejected when the pid probe is
fresh or a recent heartbeat exists. Stale locks are removed, and the resuming
runner appends a fresh `runner_attached` event before replaying the workflow.

Completed nodes replay from the event stream using the cache key recorded in the
runtime contract. Failed or invalidated nodes re-run with a new attempt, and
script hash changes are recorded as `script_changed`.

## Background And Serve

`--background` initializes the run and launches `resume --run-id <id>` as the
detached worker. `--status-server` launches `serve --run-id <id>` and reads the
`serve_sessions` row to fill `statusUrl` in the async launch envelope.

`serve` is read-only. It projects SQLite event rows into `/status.json` and SSE
payloads, and it serves the bundled static status UI.
