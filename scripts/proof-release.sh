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

workflow="$tmpdir/proof_workflow.exs"
journal="$tmpdir/runs.sqlite"
run_id="run_release_proof_$(date +%s)"

cat > "$workflow" <<'EOF'
defmodule ReleaseProofWorkflow do
  use Workflow

  workflow "release-proof" do
    phase "prove packaged CLI"
    log "release proof started"
    agent "Reply with proof-ok"
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

echo "-- test"
"$release_bin" test "$workflow" --run-id "$run_id" --json

echo "-- status"
"$release_bin" status --run-id "$run_id" --json

echo "-- inspect"
"$release_bin" inspect --run-id "$run_id" --json
