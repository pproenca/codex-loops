# Codex Loops CLI

Dynamic local workflow runner for Codex. The run journal is an append-only
event log and the single source of truth: every read surface (`status`,
`inspect`, `list`, `resume`, `serve`) is a pure fold over it.

Node.js 24 or newer is required.

## Commands

<!-- gen:commands -->
```bash
agent-loops draft --goal '<goal>' [--name name] [--output .codex/workflows/name.ts] [--json]
agent-loops validate <script-or-name> --args '<json>' [--json] [--no-input]
agent-loops test <script-or-name> --args '<json>' [--run-id <id>] [--provider mock|sdk] [--budget small|standard|deep] [--json] [--no-input]
agent-loops workflow <script-or-name> --args '<json>' [--run-id <id>] [--provider sdk|mock] [--budget small|standard|deep] [--approved] [--json] [--no-input]
agent-loops workflow <script-or-name> --args '<json>' --background [--status-server] [--json] [--no-input]
agent-loops run <script-or-name> --args '<json>' [--run-id <id>] [--provider sdk|mock] [--budget small|standard|deep] [--approved] [--json] [--no-input]
agent-loops resume [--run-id <id>] [--provider sdk|mock] [--approved] [--json] [--no-input]
agent-loops inspect [--run-id <id>] [--json]
agent-loops status [--run-id <id>] [--event-limit 5] [--json]
agent-loops list [--limit 20] [--event-limit 5] [--json]
agent-loops serve [--run-id <id>] [--host 127.0.0.1] [--port 0] [--json]
agent-loops help
```
<!-- /gen:commands -->

`run` is an alias for `workflow`.

```bash
npx -y agent-loops draft --goal 'Audit auth boundaries' --name auth-audit --json
npx -y agent-loops validate auth-audit --args '{"scope":"auth"}' --json --no-input
npx -y agent-loops test auth-audit --args '{"scope":"auth"}' --provider mock --budget small --json --no-input
npx -y agent-loops workflow auth-audit --args '{"scope":"auth"}' --provider sdk --approved --json --no-input
npx -y agent-loops status --json
npx -y agent-loops resume --provider sdk --approved --json --no-input
```

## Journal: append-only event log

- Runs are stored in SQLite at `~/.codex/workflows/runs_1.sqlite`.
  Canonical committed events remain `agent-loops/journal@2`, stored as
  `event_json` rows keyed by `(run_id, seq)`.
- New `test`, `workflow`, and `run` commands choose their durable identity from
  `--run-id` when provided, otherwise the preparer generates one.
- `resume`, `inspect`, `status`, and `serve` use `--run-id <id>` to select a
  run. When `--run-id` is omitted, they use the latest run id in SQLite.
- `--journal` is removed on every command and fails with
  `--journal was removed; use --run-id`.
- JSON envelopes expose `runId` and `databasePath` explicitly. They do not
  expose a storage locator alias.
- One live writer per run is guarded by SQLite leases in `run_locks`. Runner
  heartbeat events plus pid probes drive stale-run detection, and a stale lease
  can be taken over by `resume`.

## Snapshots are projections

`inspect` (and the snapshot embedded in command results) renders
`schemaVersion: "workflow-snapshot/v2"` — a pure projection of the folded
event log. There is one canonical progress representation: `phases[]` with
embedded node summaries (node states are `queued|running|done|failed|killed`).
Snapshots reference the script by `scriptPath` + `scriptSha256` and never
embed script text. Every snapshot carries `runtimeContract`, recording
activation, permission, structured-output, scheduling, budgeting, resume, and
hosted-service posture.

## Workflow scripts

- Path-first: scripts resolve from a path, `.codex/workflows`, or
  `~/.codex/workflows`. Inline script text is not accepted.
- Deterministic plain JavaScript with a first-statement pure-literal
  `export const meta = {...}` (`name` and `description` required). Scripts
  cannot import modules, access fs, access process, or spawn shell commands;
  `Date` and `Math.random` throw.
- `validate` runs an AST-based gate (acorn) with rustc-style findings
  (line/column/frame/hint); tokens inside prompt strings or comments never
  false-positive. The same gate runs before every execution path.
- Schema-backed `agent()` calls use provider structured output and fail
  closed: schema-invalid and unparseable outputs are retried on the same
  thread up to the schema retry limit, then fail the node (exit 8).

Author workflows scout-first. Inventory the repository with local tools, turn
facts into workflow constraints, choose barrier versus pipeline phases
deliberately, and give each worker exact files or search scope, closed schemas,
caps, and halt conditions. Mutating workflows should include adversarial
verification and a final build or test gate before reporting completion.

## Labels, node identity, and resume

- Node identity is `runId+phaseTitle+label+promptHash+schemaHash+optionsHash`
  (sha256 over a stable stringify, 32-hex prefix).
- Default labels are content-occurrence: `auto:<contentHash>.<occ>`, a pure
  function of each call's content plus an occurrence counter for byte-identical
  siblings. Distinct-content fan-out resumes order-independently. For
  identical-content fan-out whose distinct results you consume positionally,
  pass an explicit `label` — identical siblings are interchangeable by
  construction, so occurrence numbering may swap their positions on resume.
- `resume` re-executes the script from the top and replays completed nodes from
  the journal: an identical re-run makes zero provider calls. Failed nodes
  re-run with an incremented attempt. An edited script proceeds with a
  `script_changed` notice; content-hashed identities invalidate exactly the
  changed calls.

## draft: deterministic scaffold (no LLM)

`draft` writes a deterministic workflow scaffold — it makes no model calls.
After writing, it runs the compatibility validation gate and prints next-step
commands. Run `test --provider mock` explicitly before live SDK execution. The
`--json` envelope is
`{command:"draft", workflowName, scriptPath, validation:{ok,findings},
nextSteps:[...]}`.

## Background runs and serve

- `--background` prints the `async_launched` handle (`workflowName`, `pid`,
  `runId`, `databasePath`, `scriptPath`, optional `statusUrl`/
  `statusServerPid`) and detaches a worker process.
- To launch a background run with the status UI in one package-safe command,
  use `workflow ... --background --status-server --json`; parse the
  `async_launched` envelope and open `statusUrl`.
- `serve` is read-only: it reads the SQLite run events, serves
  `GET /status.json` plus `GET /events` for SSE updates, binds 127.0.0.1:0
  by default, and publishes its `{url,pid}` handshake in the `serve_sessions`
  table (`--status-server` reads it to fill `statusUrl`). `/` serves the shipped
  static status UI built from `apps/status-ui`; the published CLI package
  includes those assets under `dist/status-ui`.
- For an existing run, use `npx -y agent-loops serve --run-id <id> --json`
  and open the returned `url`.
- Status UI development commands:
  `pnpm -C apps/status-ui dev`,
  `pnpm -C apps/status-ui build`, and
  `pnpm -C apps/runtime build`.

## JSON output discipline

stdout carries exactly one final payload, and every `--json` envelope has
`command`. When a `--json` invocation fails, the last stderr line is a
single-line JSON error object `{code, exitCode, message, hint?, details?}`
(`code` is one of `usage|provider-config|validation|malformed-output|killed|
runtime`; see `schema/cli-error.schema.json`). Exit codes: 0 ok, 2 usage,
4 provider config, 6 validation/budget, 8 malformed structured output,
130 killed, 1 anything else.

## Sandbox threat model

Workflow scripts run inside a data-only `node:vm` membrane: no host objects
enter the context, guest code generation is disabled, and all host calls cross
as JSON strings. This closes all known reflective escapes, but `node:vm` is
not a hard security boundary (unbounded synchronous loops and hypothetical V8
bugs remain). Scripts run with caller approval; the sandbox is determinism and
hygiene enforcement plus defense in depth, not multi-tenant isolation.

## Scope

- Live SDK execution uses the TypeScript `@openai/codex-sdk` package only.
  `--codex-path-override` selects the Codex executable passed to that SDK; it
  does not swap in another TypeScript SDK implementation.
- Hosted workflow services, external workflow UIs, and per-agent skip/retry
  controls are intentionally unsupported by this local package.
- Programmatic exports are exactly `workflow` and `testWorkflow`.

## License

MIT. See [LICENSE](LICENSE).

## What changed in 0.2.0

- Journal format: `agent-loops/journal@2` event payloads are stored as rows in
  SQLite. Filesystem run journals are not read by this version.
- Snapshot is now `workflow-snapshot/v2` without embedded script text; the
  `paused` status is gone (nothing ever emitted it).
- Removed: the no-op `--approval-mode` flag (`--approved`/`--no-input` remain,
  record-only), the dead `deterministic-apply` runtime (patch plans remain a
  data contract — agents return plans, the caller applies them), inline-script
  execution, dead SDK client options (use `--codex-config` passthrough), the
  shipped `config/` directory, and the `workflow-progress-event` /
  `frontmatter-patch-plan` schemas.
- `draft` now auto-runs the validation gate and reports `validation` +
  `nextSteps` in its JSON envelope.
- Run persistence now lives in SQLite at `~/.codex/workflows/runs_1.sqlite`;
  no auxiliary run-state files are written.
