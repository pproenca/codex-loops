#!/bin/sh
set -eu

destination=${1:?manifest destination is required}
version=${2:?package version is required}
target=${3:?distribution target is required}

mkdir -p "$(dirname -- "$destination")"
cat >"$destination" <<EOF
{
  "schema": "codex-loops.runtime.v1",
  "package_version": "$version",
  "target": "$target",
  "codex": {
    "binding": "user-local lexical absolute path plus exact probed version",
    "required_protocol": "codex exec --json JSONL with direct codex mcp registration"
  }
}
EOF
