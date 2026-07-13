# Codex Loops Plugin

This optional plugin distributes the Codex Loops workflow-authoring skill. It
contains no executable, MCP launcher, scheduler, or runtime-discovery logic.

Install the runtime first. From a source checkout:

```sh
make dev-bundle
```

For end users, unpack the signed release archive and run `./install`. That one
action installs the immutable OTP release and skill, binds the exact Codex CLI,
provisions and starts the user service, checks scheduler health, and registers
`http://127.0.0.1:47125/mcp`. Pass
`--codex /absolute/path/to/codex` only when PATH should not choose the binding.
Restart Codex after installation.

The plugin remains useful as an optional marketplace presentation of the same
skill, but it is not the runtime bootstrap path and has no `mcpServers`
declaration.

## MCP Surface

The installed scheduler exposes directly over Streamable HTTP:

- `workflow_validate`
- `workflow_start`
- `workflow_status`
- `workflow_inspect`
- `workflow_resume`
- `workflow_open_ui`

The `/mcp` route is served by the same Phoenix endpoint as the scheduler API and
LiveView. It dispatches into the scheduler context without a stdio bridge or
loopback adapter. Scheduler success envelopes become MCP structured content;
typed scheduler failures remain typed MCP errors.

The OTP release is owned by the installed `launchd` or `systemd --user` service,
not by an MCP session, and therefore survives client disconnection.

## Workflow Gate

Author executable workflows as Elixir `.exs` files, normally under
`.codex/workflows/`. Validate and run with `provider=mock` before selecting the
live `codex` provider:

```text
workflow_validate script_path=.codex/workflows/<name>.exs workspace_root=/absolute/path/to/repo
workflow_start    script_path=.codex/workflows/<name>.exs workspace_root=/absolute/path/to/repo run_id=<id> provider=mock
workflow_status   run_id=<id>
workflow_inspect  run_id=<id>
workflow_open_ui  run_id=<id>
```

Relative `script_path` values require an explicit absolute existing
`workspace_root`. An absolute `script_path` may omit it.

Run data is stored at `~/.codex/workflows/runs_1.sqlite` unless
`CODEX_LOOPS_JOURNAL_PATH` is set.

## Privacy And Terms

The plugin itself contains instructions only. The local runtime reads workflow
files explicitly passed to it and stores local run history in the configured
SQLite journal. Live provider turns are sent through the exact Codex CLI bound
during `codex-loops install` and follow that CLI's authentication and policy.

Use is subject to the repository's MIT license and the terms of the selected
Codex/OpenAI account.
