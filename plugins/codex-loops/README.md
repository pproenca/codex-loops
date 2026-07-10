# Codex Loops Plugin

This optional plugin distributes the Codex Loops workflow-authoring skill. It
contains no executable, MCP launcher, scheduler, or runtime-discovery logic.

Install the runtime first. From a source checkout:

```sh
make dev-bundle
_build/dev-bundle/bin/codex-loops install --codex "$(command -v codex)"
```

Installation registers `_build/dev-bundle/bin/codex-loops mcp` directly in
shared Codex configuration and installs the skill under
`~/.agents/skills/codex-loops`. Restart Codex after installation.

The plugin remains useful as an optional marketplace presentation of the same
skill, but it is not the runtime bootstrap path and has no `mcpServers`
declaration.

## MCP Surface

The installed native control plane exposes:

- `workflow_validate`
- `workflow_start`
- `workflow_status`
- `workflow_inspect`
- `workflow_resume`
- `workflow_open_ui`

MCP calls only the scheduler HTTP interface. It never reads SQLite or calls
scheduler internals. Scheduler success envelopes become MCP structured content;
typed scheduler failures remain typed MCP errors.

The scheduler is owned by the native per-user supervisor, not by the MCP stdio
session, and therefore survives client disconnection until an explicit
`codex-loops stop`.

## Workflow Gate

Author executable workflows as Elixir `.exs` files, normally under
`.codex/workflows/`. Validate and run with `provider=mock` before selecting the
live `codex` provider:

```text
workflow_validate script_path=.codex/workflows/<name>.exs
workflow_start    script_path=.codex/workflows/<name>.exs run_id=<id> provider=mock
workflow_status   run_id=<id>
workflow_inspect  run_id=<id>
workflow_open_ui  run_id=<id>
```

Run data is stored at `~/.codex/workflows/runs_1.sqlite` unless
`CODEX_LOOPS_JOURNAL_PATH` is set.

## Privacy And Terms

The plugin itself contains instructions only. The local runtime reads workflow
files explicitly passed to it and stores local run history in the configured
SQLite journal. Live provider turns are sent through the exact Codex CLI bound
during `codex-loops install` and follow that CLI's authentication and policy.

Use is subject to the repository's MIT license and the terms of the selected
Codex/OpenAI account.
