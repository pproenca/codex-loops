# Codex Loops Plugin

Codex Loops provides one Codex skill for authoring, validating, executing, and
inspecting local Elixir workflow files through the `agent-loops` CLI.

## Install

```bash
codex plugin marketplace add pproenca/codex-loops --ref master
codex plugin add codex-loops@codex-loops
```

For a local clone:

```bash
codex plugin marketplace add .
codex plugin add codex-loops@codex-loops
```

Start a new Codex thread after installing so the `codex-loops` skill is loaded.

## CLI Surface

```bash
agent-loops validate <script> [--json]
agent-loops test <script> [--run-id <id>] [--budget <n>] [--json]
agent-loops run <script> [--run-id <id>] [--provider mock|codex] [--budget <n>] [--json]
agent-loops workflow <script> [--run-id <id>] [--provider mock|codex] [--budget <n>] [--json]
agent-loops resume [<script>] [--run-id <id>] [--provider mock|codex] [--json]
agent-loops status [--run-id <id>] [--event-limit <n>] [--json]
agent-loops inspect [--run-id <id>] [--json]
agent-loops list [--limit <n>] [--json]
agent-loops help
```

`workflow` aliases `run`; `test` is always offline and mock-backed.

## Workflow Scripts

Executable workflows are Elixir `.exs` files:

```elixir
defmodule ExampleWorkflow do
  use Workflow

  workflow "example" do
    phase "scout"
    log "starting"
    agent "Inspect README.md and summarize the project goal."
    return :ok
  end
end
```

Write repo-local workflows under `.codex/workflows/<name>.exs`, validate them,
then mock-test before live execution:

```bash
agent-loops validate .codex/workflows/<name>.exs --json
agent-loops test .codex/workflows/<name>.exs --run-id <id> --json
agent-loops run .codex/workflows/<name>.exs --run-id <id-live> --provider codex --json
```

Run data is stored in SQLite at `~/.codex/workflows/runs_1.sqlite` unless
`CODEX_LOOPS_JOURNAL_PATH` is set.

## Development

```bash
make setup
make test
make release
make proof
```

`make proof-live` spends one real Codex provider turn through the packaged
release.

## License

MIT. See the repository [LICENSE](../../LICENSE).
