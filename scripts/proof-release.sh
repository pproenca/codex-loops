#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
release_ctl="$repo_root/_build/prod/rel/agent_loops/bin/agent_loops"
release_cli="$repo_root/native/codex-loops/target/release/codex-loops"
package_version="$(tr -d '[:space:]' < "$repo_root/VERSION")"
CODEX_LOOPS_SCHEDULER_BIN="$release_ctl"
export CODEX_LOOPS_SCHEDULER_BIN

if [ ! -x "$release_ctl" ]; then
  echo "release control script not found: $release_ctl" >&2
  echo "run: make native-build" >&2
  exit 2
fi

if [ ! -x "$release_cli" ]; then
  echo "release CLI not found: $release_cli" >&2
  echo "run: make release" >&2
  exit 2
fi

tmpdir=$(mktemp -d)
scheduler_managed=0
bad_runtime=""
conflict_runtime=""
delay_runtime=""
stale_runtime=""
handoff_runtime=""
CODEX_LOOPS_RUNTIME_DIR="$tmpdir/runtime"
export CODEX_LOOPS_RUNTIME_DIR

cleanup() {
  if [ -n "${bad_runtime:-}" ]; then
    CODEX_LOOPS_RUNTIME_DIR="$bad_runtime" CODEX_LOOPS_SCHEDULER_URL= \
      "$release_cli" stop --host "${host:-127.0.0.1}" --port "${port:-47125}" --force >/dev/null 2>&1 || true
  fi
  if [ -n "${conflict_runtime:-}" ]; then
    CODEX_LOOPS_RUNTIME_DIR="$conflict_runtime" CODEX_LOOPS_SCHEDULER_URL= \
      "$release_cli" stop --host "${host:-127.0.0.1}" --port "${port:-47125}" --force >/dev/null 2>&1 || true
  fi
  if [ -n "${delay_runtime:-}" ]; then
    CODEX_LOOPS_RUNTIME_DIR="$delay_runtime" CODEX_LOOPS_SCHEDULER_URL= \
      "$release_cli" stop --host "${host:-127.0.0.1}" --port "${port:-47125}" --force >/dev/null 2>&1 || true
  fi
  if [ -n "${stale_runtime:-}" ]; then
    CODEX_LOOPS_RUNTIME_DIR="$stale_runtime" CODEX_LOOPS_SCHEDULER_URL= \
      "$release_cli" stop --host "${host:-127.0.0.1}" --port "${port:-47125}" --force >/dev/null 2>&1 || true
  fi
  if [ -n "${handoff_runtime:-}" ]; then
    CODEX_LOOPS_RUNTIME_DIR="$handoff_runtime" CODEX_LOOPS_SCHEDULER_URL= \
      "$release_cli" stop --host "${host:-127.0.0.1}" --port "${port:-47125}" --force >/dev/null 2>&1 || true
  fi
  if [ "${scheduler_managed:-0}" = "1" ]; then
    CODEX_LOOPS_SCHEDULER_URL= \
      "$release_cli" stop --host "${host:-127.0.0.1}" --port "${port:-47125}" --force >/dev/null 2>&1 || true
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

if [ "$("$release_cli" --version)" != "codex-loops $package_version" ]; then
  echo "release CLI --version did not report $package_version" >&2
  exit 1
fi

if curl -fsS "$base_url/api/health" >/dev/null 2>&1; then
  echo "proof port already serves /api/health: $base_url" >&2
  echo "set CODEX_LOOPS_PROOF_PORT to an unused local port" >&2
  exit 2
fi

echo "-- auto-start scheduler through user CLI"
bootstrap_run_id="${run_id}_bootstrap"
bootstrap_output="$tmpdir/bootstrap-run.txt"
scheduler_managed=1
CODEX_LOOPS_SCHEDULER_URL= \
  CODEX_LOOPS_SCHEDULER_HOST="$host" \
  CODEX_LOOPS_SCHEDULER_PORT="$port" \
  CODEX_LOOPS_JOURNAL_PATH="$journal" \
  "$release_cli" run "$workflow" \
  --provider mock \
  --run-id "$bootstrap_run_id" >"$bootstrap_output"
assert_contains "$bootstrap_output" "Codex Loops started at $base_url" "CLI auto-starts scheduler"
assert_contains "$bootstrap_output" "Run accepted: $bootstrap_run_id" "CLI accepts bootstrap run"

health="$tmpdir/health.json"
curl_get "/api/health" "$health"

if [ ! -s "$health" ]; then
  echo "scheduler release did not become healthy at $base_url" >&2
  exit 1
fi

assert_contains "$health" '"api_version":"scheduler.v1"' "health response is scheduler API"
assert_contains "$health" '"status":"ok"' "scheduler health is ok"
assert_contains "$health" "\"version\":\"$package_version\"" "scheduler health reports package version"

doctor="$tmpdir/doctor.json"
CODEX_LOOPS_SCHEDULER_URL="$base_url" "$release_cli" doctor --json >"$doctor"
assert_contains "$doctor" '"scheduler_state":"running"' "native doctor sees the scheduler"

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
open_log="$tmpdir/open-url.txt"
open_stub="$tmpdir/open-url"
cat >"$open_stub" <<'EOF'
#!/bin/sh
set -eu
printf '%s' "$1" >"$CODEX_LOOPS_OPEN_LOG"
EOF
chmod 755 "$open_stub"

CODEX_LOOPS_OPEN_BIN="$open_stub" \
  CODEX_LOOPS_OPEN_LOG="$open_log" \
  "$release_cli" run "$workflow" \
  --provider mock \
  --run-id "$cli_run_id" \
  --server "$base_url" \
  --open >"$cli_output"
assert_contains "$cli_output" "Run accepted: $cli_run_id" "CLI reports accepted run"
assert_contains "$cli_output" "UI: $base_url/runs/$cli_run_id" "CLI reports LiveView URL"
assert_contains "$open_log" "$base_url/runs/$cli_run_id" "CLI opens the LiveView URL"

cli_status="$tmpdir/cli-status.json"
for _ in $(seq 1 100); do
  curl_get "/api/runs/$cli_run_id" "$cli_status"

  if grep -q '"state":"completed"' "$cli_status"; then
    break
  fi

  sleep 0.1
done

assert_contains "$cli_status" '"state":"completed"' "CLI-started run completed"

native_status="$tmpdir/native-status.json"
"$release_cli" status "$cli_run_id" --server "$base_url" --json >"$native_status"
assert_contains "$native_status" '"api_version":"scheduler.v1"' "native status uses scheduler seam"
assert_contains "$native_status" '"state":"completed"' "native status reports completed run"

native_inspect="$tmpdir/native-inspect.json"
"$release_cli" inspect "$cli_run_id" --server "$base_url" --json >"$native_inspect"
assert_contains "$native_inspect" '"journalEvents"' "native inspect reports journal summaries"

cli_ui="$tmpdir/cli-run.html"
curl_get "/runs/$cli_run_id" "$cli_ui"
assert_contains "$cli_ui" "data-run-id=\"$cli_run_id\"" "CLI-started run UI is reachable"

echo "-- stop scheduler through user CLI"
stop_output="$tmpdir/stop.txt"
CODEX_LOOPS_SCHEDULER_URL= "$release_cli" stop --host "$host" --port "$port" >"$stop_output"
scheduler_managed=0
assert_contains "$stop_output" "Codex Loops stopped." "CLI stops managed scheduler"

if curl -fsS "$base_url/api/health" >/dev/null 2>&1; then
  echo "CLI-managed scheduler remained healthy after stop" >&2
  exit 1
fi

echo "-- concurrent start preserves a single durable owner"
concurrent_pids=""
scheduler_managed=1
for index in 1 2 3 4 5 6 7 8; do
  CODEX_LOOPS_JOURNAL_PATH="$journal" \
    "$release_cli" serve --host "$host" --port "$port" --json \
    >"$tmpdir/concurrent-$index.json" 2>"$tmpdir/concurrent-$index.err" &
  concurrent_pids="$concurrent_pids $!"
done
for pid in $concurrent_pids; do
  wait "$pid"
done
started_count=$({ grep -l '"started":true' "$tmpdir"/concurrent-*.json || true; } | wc -l | tr -d ' ')
joined_count=$({ grep -l '"started":false' "$tmpdir"/concurrent-*.json || true; } | wc -l | tr -d ' ')
if [ "$started_count" != "1" ] || [ "$joined_count" != "7" ]; then
  echo "concurrent identical starts did not report exactly one owner and seven joiners" >&2
  exit 1
fi
curl_get "/api/health" "$tmpdir/concurrent-health.json"
assert_contains "$tmpdir/concurrent-health.json" '"status":"ok"' "concurrent start reaches one healthy scheduler"
assert_contains "$CODEX_LOOPS_RUNTIME_DIR/owner.json" '"supervisor_pid"' "native supervisor records its owner"

owner_file="$CODEX_LOOPS_RUNTIME_DIR/owner.json"
supervisor_pid=$(sed -n 's/.*"supervisor_pid":\([0-9][0-9]*\).*/\1/p' "$owner_file")
scheduler_pid=$(sed -n 's/.*"scheduler_pid":\([0-9][0-9]*\).*/\1/p' "$owner_file")

echo "-- supervisor restarts a crashed scheduler child"
kill -KILL "$scheduler_pid"
recovered=0
for _ in $(seq 1 100); do
  new_scheduler_pid=$(sed -n 's/.*"scheduler_pid":\([0-9][0-9]*\).*/\1/p' "$owner_file" 2>/dev/null || true)
  new_supervisor_pid=$(sed -n 's/.*"supervisor_pid":\([0-9][0-9]*\).*/\1/p' "$owner_file" 2>/dev/null || true)
  if [ -n "$new_scheduler_pid" ] && [ "$new_scheduler_pid" != "$scheduler_pid" ] && \
     [ "$new_supervisor_pid" = "$supervisor_pid" ] && \
     curl -fsS "$base_url/api/health" >/dev/null 2>&1; then
    recovered=1
    break
  fi
  sleep 0.1
done
if [ "$recovered" != "1" ]; then
  echo "native supervisor did not recover the crashed scheduler" >&2
  exit 1
fi

echo "-- logs and restart expose power-user lifecycle controls"
"$release_cli" logs --host "$host" --port "$port" --json >"$tmpdir/logs.json"
assert_contains "$tmpdir/logs.json" '"command":"logs"' "logs command returns stable JSON"
"$release_cli" restart --host "$host" --port "$port" --model proof-model --json >"$tmpdir/restart.json"
assert_contains "$tmpdir/restart.json" '"command":"restart"' "restart command returns stable JSON"
curl_get "/api/health" "$tmpdir/restart-health.json"
"$release_cli" status "$cli_run_id" --server "$base_url" --json >"$tmpdir/restart-status.json"
assert_contains "$tmpdir/restart-status.json" '"state":"completed"' "restart inherits the custom journal"
"$release_cli" restart --host "$host" --port "$port" --json >"$tmpdir/restart-inherit.json"
assert_contains "$owner_file" '"model":"proof-model"' "restart inherits the configured model"
assert_contains "$owner_file" "\"journal\":\"$journal\"" "restart inherits the configured journal path"

echo "-- wildcard lifecycle targets normalize to loopback ownership"
"$release_cli" stop --host 0.0.0.0 --port "$port" >/dev/null
scheduler_managed=0
CODEX_LOOPS_JOURNAL_PATH="$journal" \
  "$release_cli" serve --host 0.0.0.0 --port "$port" --json >"$tmpdir/wildcard-serve.json"
scheduler_managed=1
curl_get "/api/health" "$tmpdir/wildcard-health.json"
"$release_cli" restart --port "$port" --json >"$tmpdir/wildcard-restart.json"
assert_contains "$owner_file" '"bind_host":"0.0.0.0"' "restart inherits the wildcard bind host"

echo "-- stop honors scheduler host and port environment variables"
CODEX_LOOPS_SCHEDULER_HOST=0.0.0.0 CODEX_LOOPS_SCHEDULER_PORT="$port" \
  "$release_cli" stop >/dev/null
scheduler_managed=0

echo "-- foreground serve owns the scheduler until interrupted"
CODEX_LOOPS_JOURNAL_PATH="$journal" \
  "$release_cli" serve --host "$host" --port "$port" --foreground \
  >"$tmpdir/foreground.out" 2>"$tmpdir/foreground.err" &
foreground_pid=$!
scheduler_managed=1
for _ in $(seq 1 100); do
  if curl -fsS "$base_url/api/health" >/dev/null 2>&1; then break; fi
  sleep 0.1
done
curl_get "/api/health" "$tmpdir/foreground-health.json"
kill -TERM "$foreground_pid"
wait "$foreground_pid"
scheduler_managed=0

echo "-- force stop safely recovers an orphaned packaged scheduler"
CODEX_LOOPS_JOURNAL_PATH="$journal" \
  "$release_cli" serve --host "$host" --port "$port" --json >"$tmpdir/force-serve.json"
scheduler_managed=1
orphan_supervisor=$(sed -n 's/.*"supervisor_pid":\([0-9][0-9]*\).*/\1/p' "$owner_file")
kill -KILL "$orphan_supervisor"
for _ in $(seq 1 50); do
  if ! kill -0 "$orphan_supervisor" 2>/dev/null; then break; fi
  sleep 0.1
done
if "$release_cli" stop --host "$host" --port "$port" --json \
  >"$tmpdir/orphan-stop.out" 2>"$tmpdir/orphan-stop.err"; then
  echo "ordinary stop unexpectedly accepted an orphaned scheduler" >&2
  exit 1
fi
assert_contains "$tmpdir/orphan-stop.err" '"code":"scheduler_orphaned"' "ordinary stop preserves verified orphan metadata"
assert_contains "$owner_file" '"scheduler_pid"' "ordinary orphan discovery retains force-stop metadata"
"$release_cli" stop --host "$host" --port "$port" --force >/dev/null
scheduler_managed=0

nonloopback_host=""
if command -v route >/dev/null 2>&1 && command -v ipconfig >/dev/null 2>&1; then
  default_interface=$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')
  if [ -n "$default_interface" ]; then
    nonloopback_host=$(ipconfig getifaddr "$default_interface" 2>/dev/null || true)
  fi
fi
if [ -n "$nonloopback_host" ]; then
  echo "-- explicit serve accepts an assigned non-loopback interface"
  nonloopback_url="http://$nonloopback_host:$port"
  CODEX_LOOPS_JOURNAL_PATH="$journal" \
    "$release_cli" serve --host "$nonloopback_host" --port "$port" --json >"$tmpdir/nonloopback-serve.json"
  scheduler_managed=1
  curl --noproxy '*' -fsS "$nonloopback_url/api/health" >"$tmpdir/nonloopback-health.json"
  "$release_cli" stop --host "$nonloopback_host" --port "$port" >/dev/null
  scheduler_managed=0
fi

echo "-- crash backoff remains explicitly stoppable"
bad_runtime="$tmpdir/bad-runtime"
bad_scheduler="$tmpdir/bad-scheduler/bin/agent_loops"
mkdir -p "$(dirname "$bad_scheduler")"
cat >"$bad_scheduler" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod 755 "$bad_scheduler"
CODEX_LOOPS_RUNTIME_DIR="$bad_runtime" CODEX_LOOPS_SCHEDULER_BIN="$bad_scheduler" \
  "$release_cli" serve --host "$host" --port "$port" --json \
  >"$tmpdir/bad-backoff.out" 2>"$tmpdir/bad-backoff.err" &
bad_client_pid=$!
backoff_seen=0
for _ in $(seq 1 150); do
  if grep -Fq 'restarting in 3200 ms' "$bad_runtime/scheduler.log" 2>/dev/null; then
    backoff_seen=1
    break
  fi
  sleep 0.1
done
if [ "$backoff_seen" != "1" ]; then
  echo "scheduler did not reach the crash-backoff fixture state" >&2
  exit 1
fi
CODEX_LOOPS_RUNTIME_DIR="$bad_runtime" \
  "$release_cli" stop --host "$host" --port "$port" --json >"$tmpdir/bad-backoff-stop.json"
kill -TERM "$bad_client_pid" 2>/dev/null || true
wait "$bad_client_pid" 2>/dev/null || true

echo "-- failed startup releases ownership for a corrected retry"
if CODEX_LOOPS_RUNTIME_DIR="$bad_runtime" \
  CODEX_LOOPS_SCHEDULER_START_TIMEOUT_MS=1200 \
  CODEX_LOOPS_SCHEDULER_BIN="$bad_scheduler" \
  "$release_cli" serve --host "$host" --port "$port" --json \
  >"$tmpdir/bad-timeout.out" 2>"$tmpdir/bad-timeout.err"; then
  echo "invalid journal unexpectedly started the scheduler" >&2
  exit 1
fi
assert_contains "$tmpdir/bad-timeout.err" '"code":"scheduler_start_failed"' "failed startup remains typed"
CODEX_LOOPS_RUNTIME_DIR="$bad_runtime" CODEX_LOOPS_JOURNAL_PATH="$journal" \
  "$release_cli" serve --host "$host" --port "$port" --json >"$tmpdir/corrected-retry.json"
CODEX_LOOPS_RUNTIME_DIR="$bad_runtime" \
  "$release_cli" stop --host "$host" --port "$port" >/dev/null

echo "-- conflicting concurrent starts fail one caller without altering the winner"
conflict_runtime="$tmpdir/conflict-runtime"
set +e
CODEX_LOOPS_RUNTIME_DIR="$conflict_runtime" \
  "$release_cli" serve --host "$host" --port "$port" \
  --journal "$tmpdir/conflict-a.sqlite" --model model-a --json \
  >"$tmpdir/conflict-a.out" 2>"$tmpdir/conflict-a.err" &
conflict_a_pid=$!
CODEX_LOOPS_RUNTIME_DIR="$conflict_runtime" \
  "$release_cli" serve --host "$host" --port "$port" \
  --journal "$tmpdir/conflict-b.sqlite" --model model-b --json \
  >"$tmpdir/conflict-b.out" 2>"$tmpdir/conflict-b.err" &
conflict_b_pid=$!
wait "$conflict_a_pid"
conflict_a_status=$?
wait "$conflict_b_pid"
conflict_b_status=$?
set -e
if [ "$conflict_a_status" -eq 0 ] && [ "$conflict_b_status" -eq 0 ]; then
  echo "conflicting concurrent starts both succeeded" >&2
  exit 1
fi
if [ "$conflict_a_status" -ne 0 ] && [ "$conflict_b_status" -ne 0 ]; then
  echo "conflicting concurrent starts both failed" >&2
  exit 1
fi
if ! grep -Fq '"started":true' "$tmpdir/conflict-a.out" "$tmpdir/conflict-b.out"; then
  echo "conflicting concurrent start winner did not report ownership" >&2
  exit 1
fi
if ! grep -Fq '"code":"scheduler_configuration_conflict"' \
  "$tmpdir/conflict-a.err" "$tmpdir/conflict-b.err"; then
  echo "conflicting concurrent start loser was not typed" >&2
  exit 1
fi
CODEX_LOOPS_RUNTIME_DIR="$conflict_runtime" \
  "$release_cli" stop --host "$host" --port "$port" >/dev/null

echo "-- short-timeout joiners cannot terminate a delayed lock winner"
delay_runtime="$tmpdir/delay-runtime"
delay_scheduler="$tmpdir/delay-scheduler/bin/agent_loops"
mkdir -p "$(dirname "$delay_scheduler")"
cat >"$delay_scheduler" <<'EOF'
#!/bin/sh
sleep 2
exec "$REAL_SCHEDULER" "$@"
EOF
chmod 755 "$delay_scheduler"
CODEX_LOOPS_RUNTIME_DIR="$delay_runtime" CODEX_LOOPS_SCHEDULER_BIN="$delay_scheduler" \
  REAL_SCHEDULER="$release_ctl" \
  "$release_cli" serve --host "$host" --port "$port" \
  --journal "$tmpdir/delay-a.sqlite" --model delay-model --json \
  >"$tmpdir/delay-winner.out" 2>"$tmpdir/delay-winner.err" &
delay_winner_pid=$!
for _ in $(seq 1 50); do
  if [ -s "$delay_runtime/owner.json" ]; then break; fi
  sleep 0.05
done
assert_contains "$delay_runtime/owner.json" '"owner_token"' "delayed winner publishes stable ownership"
if CODEX_LOOPS_RUNTIME_DIR="$delay_runtime" CODEX_LOOPS_SCHEDULER_BIN="$delay_scheduler" \
  CODEX_LOOPS_SCHEDULER_START_TIMEOUT_MS=300 REAL_SCHEDULER="$release_ctl" \
  "$release_cli" serve --host "$host" --port "$port" \
  --journal "$tmpdir/delay-a.sqlite" --model delay-model --json \
  >"$tmpdir/delay-joiner.out" 2>"$tmpdir/delay-joiner.err"; then
  echo "short-timeout identical joiner unexpectedly reached readiness" >&2
  exit 1
fi
if CODEX_LOOPS_RUNTIME_DIR="$delay_runtime" CODEX_LOOPS_SCHEDULER_BIN="$delay_scheduler" \
  CODEX_LOOPS_SCHEDULER_START_TIMEOUT_MS=300 REAL_SCHEDULER="$release_ctl" \
  "$release_cli" serve --host "$host" --port "$port" \
  --journal "$tmpdir/delay-b.sqlite" --model other-model --json \
  >"$tmpdir/delay-conflict.out" 2>"$tmpdir/delay-conflict.err"; then
  echo "conflicting delayed joiner unexpectedly succeeded" >&2
  exit 1
fi
assert_contains "$tmpdir/delay-conflict.err" '"code":"scheduler_configuration_conflict"' "delayed conflict is typed before health"
wait "$delay_winner_pid"
assert_contains "$tmpdir/delay-winner.out" '"started":true' "delayed owner survives joiner timeouts"
CODEX_LOOPS_RUNTIME_DIR="$delay_runtime" \
  "$release_cli" stop --host "$host" --port "$port" >/dev/null

echo "-- stale dead-owner metadata cannot conflict with a fresh lock generation"
stale_runtime="$tmpdir/stale-runtime"
mkdir -p "$stale_runtime/attempts"
cat >"$stale_runtime/owner.json" <<EOF
{"owner_token":"dead-token","supervisor_pid":999999,"scheduler_pid":null,"version":"$package_version","port":$port,"scheduler_root":"$repo_root/_build/prod/rel/agent_loops","config":{"bind_host":"$host","journal":"$tmpdir/stale.sqlite","model":"stale-model"}}
EOF
: >"$stale_runtime/owner.lock"
: >"$stale_runtime/attempts/dead-token"
CODEX_LOOPS_RUNTIME_DIR="$stale_runtime" \
  "$release_cli" serve --host "$host" --port "$port" \
  --journal "$tmpdir/fresh.sqlite" --model fresh-model --json >"$tmpdir/stale-retry.json"
assert_contains "$tmpdir/stale-retry.json" '"started":true' "fresh starter owns the replacement generation"
assert_contains "$stale_runtime/owner.json" "\"journal\":\"$tmpdir/fresh.sqlite\"" "fresh generation replaces stale configuration"
assert_contains "$stale_runtime/owner.json" '"model":"fresh-model"' "fresh generation persists requested model"
if grep -Fq 'dead-token' "$stale_runtime/owner.json"; then
  echo "fresh generation retained the stale owner token" >&2
  exit 1
fi
if [ -e "$stale_runtime/attempts/dead-token" ]; then
  echo "fresh generation did not prune the stale unlocked attempt marker" >&2
  exit 1
fi
CODEX_LOOPS_RUNTIME_DIR="$stale_runtime" \
  "$release_cli" stop --host "$host" --port "$port" >/dev/null

echo "-- health cannot complete the supervisor ownership handoff after owner death"
handoff_runtime="$tmpdir/handoff-runtime"
handoff_scheduler="$tmpdir/handoff-scheduler/bin/agent_loops"
mkdir -p "$(dirname "$handoff_scheduler")"
cat >"$handoff_scheduler" <<'EOF'
#!/bin/sh
set -eu
for _ in $(seq 1 100); do
  if grep -Eq '"scheduler_pid":[0-9]+' "$CODEX_LOOPS_RUNTIME_DIR/owner.json" 2>/dev/null; then
    break
  fi
  sleep 0.01
done
supervisor_pid=$(sed -n 's/.*"supervisor_pid":\([0-9][0-9]*\).*/\1/p' "$CODEX_LOOPS_RUNTIME_DIR/owner.json")
cp "$CODEX_LOOPS_RUNTIME_DIR/owner.json" "$CODEX_LOOPS_RUNTIME_DIR/owner.saved.json"
kill -KILL "$supervisor_pid"
cp "$CODEX_LOOPS_RUNTIME_DIR/owner.saved.json" "$CODEX_LOOPS_RUNTIME_DIR/owner.json"
"$REAL_SCHEDULER" "$@" &
child=$!
trap 'kill -TERM "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; exit 0' TERM INT
wait "$child"
EOF
chmod 755 "$handoff_scheduler"
if CODEX_LOOPS_RUNTIME_DIR="$handoff_runtime" CODEX_LOOPS_SCHEDULER_BIN="$handoff_scheduler" \
  REAL_SCHEDULER="$release_ctl" \
  "$release_cli" serve --host "$host" --port "$port" --journal "$tmpdir/handoff.sqlite" --json \
  >"$tmpdir/handoff.out" 2>"$tmpdir/handoff.err"; then
  echo "serve claimed success after its durable supervisor died" >&2
  exit 1
fi
assert_contains "$tmpdir/handoff.err" '"code":"scheduler_orphaned"' "health without owner lock is typed as orphaned"
if grep -Fq '"started":true' "$tmpdir/handoff.out"; then
  echo "orphaned handoff reported managed ownership" >&2
  exit 1
fi
CODEX_LOOPS_RUNTIME_DIR="$handoff_runtime" CODEX_LOOPS_SCHEDULER_BIN="$handoff_scheduler" \
  "$release_cli" stop --host "$host" --port "$port" --force >/dev/null 2>&1 || true

if curl -fsS "$base_url/api/health" >/dev/null 2>&1; then
  echo "scheduler remained healthy after lifecycle control proofs" >&2
  exit 1
fi

CODEX_LOOPS_SCHEDULER_URL= "$release_cli" stop --host "$host" --port "$port" >/dev/null 2>&1 || true
scheduler_managed=0

echo "-- proof complete"
