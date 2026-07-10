#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
release_ctl="$repo_root/_build/prod/rel/agent_loops/bin/agent_loops"
release_cli="$repo_root/_build/prod/rel/agent_loops/bin/codex-loops"
package_version="$(tr -d '[:space:]' < "$repo_root/VERSION")"

if [ ! -x "$release_ctl" ]; then
  echo "release control script not found: $release_ctl" >&2
  echo "run: make release" >&2
  exit 2
fi

if [ ! -x "$release_cli" ]; then
  echo "release CLI not found: $release_cli" >&2
  echo "run: make release" >&2
  exit 2
fi

tmpdir=$(mktemp -d)
server_pid=
server_started=0

cleanup() {
  if [ "${server_started:-0}" = "1" ]; then
    CODEX_LOOPS_SERVER=1 \
      CODEX_LOOPS_HOST="$host" \
      CODEX_LOOPS_PORT="$port" \
      PORT="$port" \
      CODEX_LOOPS_JOURNAL_PATH="$journal" \
      RELEASE_DISTRIBUTION=none \
      RELEASE_NODE="$release_node" \
      RELEASE_TMP="$release_tmp" \
      "$release_ctl" stop >/dev/null 2>&1 || true
  fi

  if [ -n "${server_pid:-}" ] && kill -0 "$server_pid" 2>/dev/null; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi

  rm -rf "$tmpdir"
}

trap cleanup EXIT INT TERM

workflow="$tmpdir/proof_workflow.exs"
journal="${CODEX_LOOPS_PROOF_JOURNAL_PATH:-$tmpdir/runs.sqlite}"
host="${CODEX_LOOPS_PROOF_HOST:-127.0.0.1}"
port="${CODEX_LOOPS_PROOF_PORT:-47125}"
base_url="http://$host:$port"
run_id="run_release_proof_$(date +%s)_$$"
server_log="$tmpdir/scheduler.log"
release_node="agent_loops_proof_$(date +%s)_$$"
release_tmp="$tmpdir/release"

cat > "$workflow" <<'EOF'
defmodule ReleaseProofWorkflow do
  use Workflow

  workflow "scheduler-release-proof" do
    phase "api"
    log "scheduler release proof started"
    agent "Reply with proof-ok"
    return :ok
  end
end
EOF

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

assert_contains() {
  file=$1
  needle=$2
  label=$3

  if ! grep -Fq "$needle" "$file"; then
    echo "proof assertion failed: $label" >&2
    echo "expected to find: $needle" >&2
    echo "response:" >&2
    sed 's/^/  /' "$file" >&2
    exit 1
  fi
}

curl_json() {
  method=$1
  path=$2
  body=$3
  out=$4

  curl -fsS \
    -X "$method" \
    -H "accept: application/json" \
    -H "content-type: application/json" \
    -d "$body" \
    "$base_url$path" >"$out"
}

curl_get() {
  path=$1
  out=$2

  curl -fsS "$base_url$path" >"$out"
}

echo "workflow=$workflow"
echo "journal=$journal"
echo "run_id=$run_id"
echo "url=$base_url"
echo "release_node=$release_node"

if [ "$("$release_cli" --version)" != "codex-loops $package_version" ]; then
  echo "release CLI --version did not report $package_version" >&2
  exit 1
fi

if curl -fsS "$base_url/api/health" >/dev/null 2>&1; then
  echo "proof port already serves /api/health: $base_url" >&2
  echo "set CODEX_LOOPS_PROOF_PORT to an unused local port" >&2
  exit 2
fi

echo "-- start scheduler release"
CODEX_LOOPS_SERVER=1 \
  CODEX_LOOPS_HOST="$host" \
  CODEX_LOOPS_PORT="$port" \
  PORT="$port" \
  CODEX_LOOPS_JOURNAL_PATH="$journal" \
  RELEASE_DISTRIBUTION=none \
  RELEASE_NODE="$release_node" \
  RELEASE_TMP="$release_tmp" \
  "$release_ctl" start >"$server_log" 2>&1 &
server_pid=$!
server_started=1

health="$tmpdir/health.json"
for _ in $(seq 1 100); do
  if curl_get "/api/health" "$health" 2>/dev/null; then
    break
  fi

  if ! kill -0 "$server_pid" 2>/dev/null; then
    echo "scheduler release exited before becoming healthy" >&2
    sed 's/^/  /' "$server_log" >&2
    exit 1
  fi

  sleep 0.1
done

if [ ! -s "$health" ]; then
  echo "scheduler release did not become healthy at $base_url" >&2
  sed 's/^/  /' "$server_log" >&2
  exit 1
fi

assert_contains "$health" '"api_version":"scheduler.v1"' "health response is scheduler API"
assert_contains "$health" '"status":"ok"' "scheduler health is ok"
assert_contains "$health" "\"version\":\"$package_version\"" "scheduler health reports package version"

echo "-- validate workflow through API"
validate="$tmpdir/validate.json"
curl_json POST "/api/workflows/validate" \
  "{\"script_path\":\"$(json_escape "$workflow")\"}" \
  "$validate"
assert_contains "$validate" '"valid":true' "workflow validates"
assert_contains "$validate" '"workflow_name":"scheduler-release-proof"' "validated workflow name"

echo "-- start mock run through API"
start="$tmpdir/start.json"
curl_json POST "/api/runs" \
  "{\"script_path\":\"$(json_escape "$workflow")\",\"run_id\":\"$run_id\",\"provider\":\"mock\"}" \
  "$start"
assert_contains "$start" '"state":"accepted"' "run was accepted"
assert_contains "$start" "\"run_id\":\"$run_id\"" "accepted run id"

echo "-- read run status through API"
status="$tmpdir/status.json"
for _ in $(seq 1 100); do
  curl_get "/api/runs/$run_id" "$status"

  if grep -q '"state":"completed"' "$status"; then
    break
  fi

  sleep 0.1
done

assert_contains "$status" '"state":"completed"' "run completed"
assert_contains "$status" '"treeName":"scheduler-release-proof"' "status tree name"
assert_contains "$status" '"eventCount":5' "status event count"

echo "-- read run events through API"
events="$tmpdir/events.json"
curl_get "/api/runs/$run_id/events" "$events"
assert_contains "$events" '"type":"run_started"' "events include run_started"
assert_contains "$events" '"type":"phase_entered"' "events include phase_entered"
assert_contains "$events" '"type":"log_emitted"' "events include log_emitted"
assert_contains "$events" '"type":"agent_committed"' "events include agent_committed"
assert_contains "$events" '"type":"run_completed"' "events include run_completed"

echo "-- fetch run UI"
ui="$tmpdir/run.html"
curl_get "/runs/$run_id" "$ui"
assert_contains "$ui" "data-run-id=\"$run_id\"" "run UI has target run id"
assert_contains "$ui" "scheduler-release-proof" "run UI renders workflow projection"

echo "-- run workflow through user CLI"
cli_run_id="${run_id}_cli"
cli_output="$tmpdir/cli-run.txt"
"$release_cli" run "$workflow" \
  --provider mock \
  --run-id "$cli_run_id" \
  --server "$base_url" >"$cli_output"
assert_contains "$cli_output" "Run accepted: $cli_run_id" "CLI reports accepted run"
assert_contains "$cli_output" "UI: $base_url/runs/$cli_run_id" "CLI reports LiveView URL"

cli_status="$tmpdir/cli-status.json"
for _ in $(seq 1 100); do
  curl_get "/api/runs/$cli_run_id" "$cli_status"

  if grep -q '"state":"completed"' "$cli_status"; then
    break
  fi

  sleep 0.1
done

assert_contains "$cli_status" '"state":"completed"' "CLI-started run completed"

cli_ui="$tmpdir/cli-run.html"
curl_get "/runs/$cli_run_id" "$cli_ui"
assert_contains "$cli_ui" "data-run-id=\"$cli_run_id\"" "CLI-started run UI is reachable"

echo "-- proof complete"
