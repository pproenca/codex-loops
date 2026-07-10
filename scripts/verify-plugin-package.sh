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

require_tracked() {
  git ls-files --error-unmatch "$1" >/dev/null 2>&1 || fail "not tracked by git: $1"
}

package_version="$(tr -d '[:space:]' < VERSION)"
plugin_version="$({
  sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    plugins/codex-loops/.codex-plugin/plugin.json
} | head -n 1)"

[ "$plugin_version" = "$package_version" ] ||
  fail "plugin manifest version $plugin_version does not match VERSION $package_version"

require_file plugins/codex-loops/.codex-plugin/plugin.json
require_file plugins/codex-loops/THIRD_PARTY_NOTICES.md
require_file plugins/codex-loops/skills/codex-loops/SKILL.md

require_tracked plugins/codex-loops/.codex-plugin/plugin.json
require_tracked plugins/codex-loops/THIRD_PARTY_NOTICES.md
require_tracked plugins/codex-loops/skills/codex-loops/SKILL.md

[ -z "$(git ls-files plugins/codex-loops/scheduler)" ] ||
  fail "generated scheduler runtime is tracked in the source-only plugin"

[ -z "$(find plugins/codex-loops -type f -path '*/erts-*/*' -print -quit)" ] ||
  fail "generated ERTS payload is present in the source-only plugin"

if grep -Fq '"mcpServers"' plugins/codex-loops/.codex-plugin/plugin.json; then
  fail "skill-only plugin must not rediscover or launch the installed runtime"
fi

printf 'Plugin package is skill-only and runtime-independent.\n'
