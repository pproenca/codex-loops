# Codex Loops Plugin

Codex Loops provides one Codex skill for authoring, validating, executing, and
inspecting deterministic dynamic workflow files through the published
`agent-loops` CLI.

## Install

Install from the public Git marketplace:

```bash
codex plugin marketplace add pproenca/codex-loops --ref master
codex plugin add codex-loops@codex-loops
```

For a local clone, run the same install from the repository root:

```bash
codex plugin marketplace add .
codex plugin add codex-loops@codex-loops
```

Start a new Codex thread after installing so the `codex-loops` skill is loaded.

## Workflow Scripts Vs Skills

When a request says "workflow", the plugin first determines the artifact:

- executable workflow scripts are saved under `.codex/workflows/<name>.ts` and
  go through validation or mock testing before live execution;
- reusable Codex skills are saved as `SKILL.md` guidance in a user-approved
  skill location and do not require `agent-loops draft`, validation, testing,
  execution, or resume commands;
- explicit "both" requests can create the skill as the reusable guide and a
  tested workflow script for the executable path.

For ambiguous requests, the plugin asks whether the user wants an executable
workflow script, a reusable Codex skill, or both.

The plugin exposes the local journal-backed lifecycle surface:

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

Workflow files are path-first. The skill writes or reviews
`.codex/workflows/<name>.ts`, validates or tests it with bounded args, and only
then uses the live workflow command when the caller has approved execution.
`draft` creates a deterministic scaffold and runs the compatibility validation
gate; run `test --provider mock` explicitly before live SDK execution.

Author workflows scout-first: gather repository facts, translate them into file
scope and verification constraints, choose barrier versus pipeline phases
deliberately, and give workers domain-rich prompts with exact paths, closed
schemas, caps, and halt conditions. Mutating workflows should include
adversarial verification plus a final build or test gate before completion.

This package is local-only: background launch and live status UI pages are
supported through local journals. Hosted workflow services, external workflow
UIs, and per-agent skip/retry controls are not implemented.
Journals are append-only event logs (`agent-loops/journal@2`) and the single
source of truth for status, inspection, stale-run detection, and resume; when
no `--journal` is passed, `.agent-loops-runs/latest.json` points at the latest
per-run journal.
Live SDK execution uses the TypeScript `@openai/codex-sdk` package only.
`codexPathOverride` may select the Codex executable behind that SDK; it must not
be used to swap in another TypeScript SDK implementation.

The skill does not start the visual status UI implicitly after a run. When the
current request asks to launch a workflow and show the UI, it uses the main CLI
in one envelope:

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

The `async_launched` JSON envelope supplies both `journalPath` and `statusUrl`.
For an existing run, the skill reports the journal path, asks whether the user
wants the UI, and only then launches:

```bash
npx -y agent-loops serve --journal <journal.jsonl> --json
```

The JSON startup envelope supplies the local URL to open. The standalone
`agent-loops-ui` package remains available for package testing and standalone
use, but it is not the preferred plugin operator path.

## Contract

- One skill: `codex-loops`.
- One app: `apps/runtime`.
- One package CLI: `agent-loops`.
- Workflow scripts use the Codex SDK workflow DSL implemented by the
  `agent-loops` package.
- Snapshots are projections of the journal and include a `runtimeContract`
  describing activation, permission, structured-output, scheduling, budgeting,
  resume, and hosted-service posture.
- Generated mutating workflows must be validated or tested with bounded args
  before live execution.
- Testing does not mutate repository files. Live SDK execution is the only
  mutating path, and the caller owns approval.

## Privacy

The plugin stores no service credentials. Workflow execution uses the
installed `agent-loops` package and any configured Codex SDK credentials in the
user environment.

## Terms

This local development plugin is provided as-is for repository automation and
workflow orchestration.

## License

MIT. See the repository [LICENSE](../../LICENSE).
