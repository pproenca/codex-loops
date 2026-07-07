#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
release_bin="$repo_root/_build/prod/rel/agent_loops/bin/agent-loops"

if [ ! -x "$release_bin" ]; then
  echo "release binary not found: $release_bin" >&2
  echo "run: make release" >&2
  exit 2
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

workflow="$tmpdir/live_proof_workflow.exs"
journal="$tmpdir/runs.sqlite"
run_id="run_live_release_proof_$(date +%s)"

cat > "$workflow" <<'EOF'
defmodule LiveReleaseProofWorkflow do
  use Workflow

  workflow "live-release-proof" do
    phase "prove live Codex provider"
    log "live release proof started"
    agent "Reply with exactly LIVE-PROOF-OK and no other text."
    return :ok
  end
end
EOF

export CODEX_LOOPS_JOURNAL_PATH="$journal"

echo "workflow=$workflow"
echo "journal=$journal"
echo "run_id=$run_id"

echo "-- validate"
"$release_bin" validate "$workflow" --json

echo "-- run codex"
run_json=$("$release_bin" run "$workflow" --run-id "$run_id" --provider codex --json)
printf '%s\n' "$run_json"

printf '%s\n' "$run_json" | python3 -c '
import json
import sys

payload = json.load(sys.stdin)
assert payload["command"] == "run", payload
assert payload["state"] == "completed", payload
assert payload["usage"]["totalTokens"] > 0, payload
'

echo "-- status"
"$release_bin" status --run-id "$run_id" --json

echo "-- inspect"
"$release_bin" inspect --run-id "$run_id" --json
