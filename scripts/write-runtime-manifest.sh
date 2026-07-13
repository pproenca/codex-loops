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
  "runtime": {
    "command": "Elixir release overlay",
    "scheduler": "packaged OTP release",
    "mcp": "scheduler-owned Streamable HTTP at /mcp"
  },
  "codex": {
    "binding": "user-local lexical absolute path plus exact probed version",
    "required_protocol": "codex app-server JSONL with direct codex mcp registration"
  }
}
EOF
