#!/usr/bin/env bash
set -euo pipefail

repo_root="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

files=(
  README.md
  docs/operations.md
  docs/runtime.md
  plugins/codex-loops/README.md
  plugins/codex-loops/SPEC.md
  plugins/codex-loops/skills/codex-loops/SKILL.md
)

stale='Burrito|plugins/codex-loops/scheduler|copied plugin package|bundled runtime|bundled scheduler|zig@0\.15'

if rg -n "$stale" "${files[@]}"; then
  echo "stale bundled-runtime installation guidance found" >&2
  exit 1
fi

echo "Install documentation uses the source-plugin and external-runtime model."
