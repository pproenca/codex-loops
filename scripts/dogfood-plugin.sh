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

step "Proving packaged scheduler plus MCP adapter"
make proof-mcp

step "Resetting codex-loops plugin install"
codex plugin remove codex-loops@codex-loops >/dev/null 2>&1 || true
codex plugin marketplace remove codex-loops >/dev/null 2>&1 || true

step "Installing local marketplace from this checkout"
codex plugin marketplace add .
codex plugin add codex-loops@codex-loops

step "Verifying Codex sees the plugin installed"
if ! codex plugin list --json | grep -q '"pluginId": "codex-loops@codex-loops"'; then
  printf 'codex-loops@codex-loops was not found in codex plugin list --json\n' >&2
  exit 1
fi

cat <<'PROMPT'

==> Next manual step
Open a NEW Codex thread so the freshly installed plugin is loaded.

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
