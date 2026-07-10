#!/usr/bin/env bash
set -euo pipefail

repo_root="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

step() {
  printf '\n==> %s\n' "$1"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  fi
}

step "Checking required commands"
require_cmd codex
require_cmd mix

step "Proving immutable bundle plus direct MCP"
make proof-mcp

step "Binding this Codex CLI and registering the runtime"
"$repo_root/_build/dev-bundle/bin/codex-loops" install --codex "$(command -v codex)"

step "Verifying direct MCP registration"
codex mcp get codex-loops --json | grep -q '"command"' || {
  printf 'direct codex-loops MCP registration was not found\n' >&2
  exit 1
}

cat <<'PROMPT'

==> Next manual step
Open a NEW Codex thread so the freshly installed skill and MCP server are loaded.

Paste this prompt:

Use the codex-loops skill.

Create a tiny executable workflow script at .codex/workflows/smoke.exs.
It should log a phase, run one mock-safe agent step, and return :ok.

Then use the Codex Loops MCP tools to:
1. validate it
2. start it with provider=mock and run_id=manual_smoke_1
3. poll status until complete
4. inspect events
5. open the Phoenix UI URL

Do not use shell commands for the workflow run; this dogfood run is meant to
exercise the MCP tools.
PROMPT
