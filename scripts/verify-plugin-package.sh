#!/usr/bin/env bash
set -euo pipefail

repo_root="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fail() {
  printf 'verify-plugin-package: %s\n' "$1" >&2
  exit 1
}

require_file() {
  [ -f "$1" ] || fail "missing file: $1"
}

require_executable() {
  [ -x "$1" ] || fail "missing executable: $1"
}

require_tracked() {
  git ls-files --error-unmatch "$1" >/dev/null 2>&1 || fail "not tracked by git: $1"
}

package_version="$(tr -d '[:space:]' < VERSION)"
release_dir="plugins/codex-loops/scheduler/releases/$package_version"
app_lib_dir="plugins/codex-loops/scheduler/lib/codex_loops-$package_version"
plugin_version="$(
  sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    plugins/codex-loops/.codex-plugin/plugin.json |
    head -n 1
)"

[ "$plugin_version" = "$package_version" ] ||
  fail "plugin manifest version $plugin_version does not match VERSION $package_version"

require_file plugins/codex-loops/.codex-plugin/plugin.json
require_file plugins/codex-loops/.mcp.json
require_file plugins/codex-loops/THIRD_PARTY_NOTICES.md
require_file "$release_dir/runtime.exs"
require_executable plugins/codex-loops/mcp/codex-loops-mcp
require_executable plugins/codex-loops/scheduler/bin/agent_loops
require_executable plugins/codex-loops/scheduler/bin/codex-loops

if ! grep -Fq 'host = System.get_env("CODEX_LOOPS_HOST", "127.0.0.1")' "$release_dir/runtime.exs"; then
  fail "bundled scheduler runtime must default CODEX_LOOPS_HOST to 127.0.0.1"
fi

cli_version="$(plugins/codex-loops/scheduler/bin/codex-loops --version)"
[ "$cli_version" = "codex-loops $package_version" ] ||
  fail "bundled codex-loops --version returned: $cli_version"

if head -c 2 plugins/codex-loops/mcp/codex-loops-mcp | grep -q '#!'; then
  fail "MCP entrypoint is still a shell wrapper; run make release-mcp to install the Burrito executable"
fi

mcp_version="$(plugins/codex-loops/mcp/codex-loops-mcp --version)"
[ "$mcp_version" = "codex-loops-mcp $package_version" ] ||
  fail "bundled codex-loops-mcp --version returned: $mcp_version"

if grep -a "Workflow.MCP.Stdio.main" plugins/codex-loops/mcp/codex-loops-mcp >/dev/null; then
  fail "packaged MCP entrypoint still uses transitional Workflow.MCP.Stdio eval wrapper"
fi

legacy_stdio_beams="$(
  find plugins/codex-loops/scheduler/lib -name 'Elixir.Workflow.MCP.Stdio.beam' -print
)"

[ -z "$legacy_stdio_beams" ] ||
  fail "bundled scheduler still contains removed hand-rolled Workflow.MCP.Stdio beam"

[ ! -e plugins/codex-loops/scheduler/bin/agent-loops ] ||
  fail "removed CLI wrapper is present: plugins/codex-loops/scheduler/bin/agent-loops"

erts_files="$(find plugins/codex-loops/scheduler -path '*/erts-*/*' -type f | wc -l | tr -d ' ')"
[ "$erts_files" -gt 0 ] ||
  fail "scheduler ERTS payload is missing"

lib_files="$(find plugins/codex-loops/scheduler/lib -type f | wc -l | tr -d ' ')"
[ "$lib_files" -gt 0 ] ||
  fail "scheduler lib payload is missing"

release_files="$(find plugins/codex-loops/scheduler/releases -type f | wc -l | tr -d ' ')"
[ "$release_files" -gt 0 ] ||
  fail "scheduler releases payload is missing"

require_tracked plugins/codex-loops/.codex-plugin/plugin.json
require_tracked plugins/codex-loops/.mcp.json
require_tracked plugins/codex-loops/THIRD_PARTY_NOTICES.md
require_tracked "$release_dir/runtime.exs"
require_tracked plugins/codex-loops/mcp/codex-loops-mcp
require_tracked plugins/codex-loops/scheduler/bin/agent_loops
require_tracked plugins/codex-loops/scheduler/bin/codex-loops
require_tracked "$app_lib_dir/ebin/Elixir.Workflow.Run.Stream.beam"

require_file "$app_lib_dir/ebin/Elixir.Workflow.Run.Stream.beam"

if ! grep -Fq "'Elixir.Workflow.Run.Stream'" "$app_lib_dir/ebin/codex_loops.app"; then
  fail "bundled scheduler app metadata is missing Workflow.Run.Stream; run make release"
fi

if ! grep -Fq "'Elixir.Workflow.Run.Stream'" "$release_dir/start.script"; then
  fail "bundled scheduler boot script is missing Workflow.Run.Stream; run make release"
fi

tracked_scheduler_files="$(git ls-files plugins/codex-loops/scheduler | wc -l | tr -d ' ')"
[ "$tracked_scheduler_files" -ge 30 ] ||
  fail "expected bundled scheduler release to be tracked, found only $tracked_scheduler_files tracked scheduler files"

ignored_scheduler_files="$(
  git ls-files --others --ignored --exclude-standard plugins/codex-loops/scheduler
)"

[ -z "$ignored_scheduler_files" ] ||
  fail "scheduler contains ignored untracked files; run git add or update ignores"

untracked_scheduler_files="$(
  git ls-files --others --exclude-standard plugins/codex-loops/scheduler
)"

[ -z "$untracked_scheduler_files" ] ||
  fail "scheduler contains untracked files; run git add for the bundled scheduler payload"

printf 'Plugin package is installable with bundled scheduler (%s tracked scheduler files).\n' "$tracked_scheduler_files"
