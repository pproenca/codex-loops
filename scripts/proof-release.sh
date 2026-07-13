#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
release_ctl="$repo_root/_build/dev-bundle/libexec/scheduler/bin/agent_loops"
release_cli="$repo_root/_build/dev-bundle/bin/codex-loops"
package_version=$(tr -d '[:space:]' <"$repo_root/VERSION")
host=${CODEX_LOOPS_PROOF_HOST:-127.0.0.1}
port=${CODEX_LOOPS_PROOF_PORT:-47125}
base_url="http://$host:$port"

fail() {
  echo "release proof failed: $*" >&2
  exit 1
}

assert_contains() {
  file=$1
  needle=$2
  label=$3

  if ! grep -Fq "$needle" "$file"; then
    echo "release proof assertion failed: $label" >&2
    echo "expected to find: $needle" >&2
    echo "response:" >&2
    sed 's/^/  /' "$file" >&2
    exit 1
  fi
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

process_running() {
  pid=$1

  if ! kill -0 "$pid" 2>/dev/null; then
    return 1
  fi

  state=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]')

  case "$state" in
    "" | Z*) return 1 ;;
    *) return 0 ;;
  esac
}

release_pid=""
tmpdir=""

stop_scheduler() {
  if [ -z "${release_pid:-}" ]; then
    return 0
  fi

  pid=$release_pid

  if process_running "$pid"; then
    kill -TERM "$pid" 2>/dev/null || true
  fi

  attempts=0
  while process_running "$pid" && [ "$attempts" -lt 100 ]; do
    attempts=$((attempts + 1))
    sleep 0.1
  done

  if process_running "$pid"; then
    echo "release proof: scheduler ignored TERM; forcing PID $pid down" >&2
    kill -KILL "$pid" 2>/dev/null || true
  fi

  wait "$pid" 2>/dev/null || true
  release_pid=""
}

cleanup() {
  stop_scheduler || true

  if [ -n "${tmpdir:-}" ]; then
    rm -rf "$tmpdir"
  fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ ! -x "$release_ctl" ]; then
  echo "packaged release control script not found: $release_ctl" >&2
  echo "run: make dev-bundle" >&2
  exit 2
fi

if [ ! -x "$release_cli" ]; then
  echo "packaged release overlay not found: $release_cli" >&2
  echo "run: make dev-bundle" >&2
  exit 2
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required for the packaged release proof" >&2
  exit 2
fi

case "$host" in
  127.*) ;;
  *)
    echo "CODEX_LOOPS_PROOF_HOST must be an IPv4 loopback address: $host" >&2
    exit 2
    ;;
esac

case "$port" in
  "" | *[!0-9]*)
    echo "CODEX_LOOPS_PROOF_PORT must be an integer from 1 to 65535: $port" >&2
    exit 2
    ;;
esac

if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
  echo "CODEX_LOOPS_PROOF_PORT must be an integer from 1 to 65535: $port" >&2
  exit 2
fi

probe_port() {
  set +e
  curl --noproxy '*' -sS -o /dev/null \
    --connect-timeout 1 --max-time 1 "$base_url/" >/dev/null 2>&1
  port_probe_status=$?
  set -e
}

curl_get() {
  path=$1
  out=$2

  curl --noproxy '*' -fsS --connect-timeout 2 --max-time 10 \
    "$base_url$path" >"$out"
}

curl_get_poll() {
  path=$1
  out=$2

  curl --noproxy '*' -fsS --connect-timeout 1 --max-time 1 \
    "$base_url$path" >"$out" 2>/dev/null
}

curl_json() {
  method=$1
  path=$2
  body=$3
  out=$4

  curl --noproxy '*' -fsS --connect-timeout 2 --max-time 10 \
    -X "$method" \
    -H 'accept: application/json' \
    -H 'content-type: application/json' \
    --data "$body" \
    "$base_url$path" >"$out"
}

mcp_post() {
  body=$1
  out=$2
  mcp_header_version=${3:-}

  if [ -n "$mcp_header_version" ]; then
    if ! http_status=$(curl --noproxy '*' -sS --connect-timeout 2 --max-time 10 \
      -o "$out" -w '%{http_code}' \
      -X POST \
      -H 'accept: application/json, text/event-stream' \
      -H 'content-type: application/json' \
      -H "MCP-Protocol-Version: $mcp_header_version" \
      --data "$body" \
      "$base_url/mcp"); then
      fail "POST /mcp transport request failed"
    fi
  else
    if ! http_status=$(curl --noproxy '*' -sS --connect-timeout 2 --max-time 10 \
      -o "$out" -w '%{http_code}' \
      -X POST \
      -H 'accept: application/json, text/event-stream' \
      -H 'content-type: application/json' \
      --data "$body" \
      "$base_url/mcp"); then
      fail "POST /mcp transport request failed"
    fi
  fi

  if [ "$http_status" != "200" ]; then
    echo "release proof failed: POST /mcp returned HTTP $http_status" >&2
    sed 's/^/  /' "$out" >&2
    exit 1
  fi
}

probe_port
if [ "$port_probe_status" -ne 7 ]; then
  echo "release proof refuses to use an occupied or unverifiably free endpoint: $base_url" >&2
  echo "curl probe exited with status $port_probe_status; set CODEX_LOOPS_PROOF_PORT to an unused port" >&2
  exit 2
fi

tmpdir=$(mktemp -d)
tmpdir=$(CDPATH='' cd -- "$tmpdir" && pwd -P)
HOME="$tmpdir/home"
export HOME
mkdir -p "$HOME/.codex/workflows"
CODEX_HOME="$HOME/.codex"
export CODEX_HOME

unset CODEX_LOOPS_CODEX_MODEL

codex_stub="$tmpdir/codex"
cat >"$codex_stub" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then
  echo "codex-cli proof"
  exit 0
fi

echo "release proof Codex stub must not execute a live turn" >&2
exit 9
EOF
chmod 755 "$codex_stub"

binding_path="$HOME/.codex/workflows/codex-binding.json"
printf '{"path":"%s","version":"codex-cli proof"}\n' \
  "$(json_escape "$codex_stub")" >"$binding_path"
chmod 600 "$binding_path"

workspace="$tmpdir/workspace"
workflow_rel=".codex/workflows/release_proof.exs"
mkdir -p "$workspace/.codex/workflows"
workspace=$(CDPATH='' cd -- "$workspace" && pwd -P)
workflow="$workspace/$workflow_rel"

cat >"$workflow" <<'EOF'
workflow "scheduler-release-proof" do
  phase "api"
  log "scheduler release proof started"
  agent "Reply with proof-ok"
  return :ok
end
EOF

journal="$tmpdir/runs.sqlite"
run_id="run_release_proof_$(date +%s)_$$"
scheduler_log="$tmpdir/scheduler.log"

echo "workflow=$workflow"
echo "workspace_root=$workspace"
echo "journal=$journal"
echo "run_id=$run_id"
echo "url=$base_url"

echo "-- prove package and release-overlay versions"
release_version_file="$tmpdir/release-version.txt"
if ! "$release_ctl" version >"$release_version_file" 2>&1; then
  fail "packaged release version command failed"
fi
assert_contains "$release_version_file" "agent_loops $package_version" "OTP release reports package version"

overlay_version_file="$tmpdir/overlay-version.txt"
if ! "$release_cli" --version >"$overlay_version_file" 2>&1; then
  sed 's/^/  /' "$overlay_version_file" >&2
  fail "release overlay --version failed"
fi

if [ "$(tr -d '\r\n' <"$overlay_version_file")" != "codex-loops $package_version" ]; then
  fail "release overlay --version did not report codex-loops $package_version"
fi

overlay_help="$tmpdir/overlay-help.txt"
if ! "$release_cli" --help >"$overlay_help" 2>&1; then
  sed 's/^/  /' "$overlay_help" >&2
  fail "release overlay --help failed"
fi
assert_contains "$overlay_help" "Usage: codex-loops COMMAND [OPTIONS]" "overlay exposes current help"
assert_contains "$overlay_help" "serve [--json]" "overlay exposes service commands"
assert_contains "$overlay_help" "doctor [--json]" "overlay exposes diagnostics"

echo "-- start packaged OTP scheduler in the foreground"
CODEX_LOOPS_SERVER=1 \
  CODEX_LOOPS_HOST="$host" \
  CODEX_LOOPS_PORT="$port" \
  CODEX_LOOPS_JOURNAL_PATH="$journal" \
  CODEX_LOOPS_CODEX_BIN="$codex_stub" \
  CODEX_LOOPS_BINDING_PATH="$binding_path" \
  ERL_CRASH_DUMP="$tmpdir/erl_crash.dump" \
  RELEASE_DISTRIBUTION=none \
  "$release_ctl" start >"$scheduler_log" 2>&1 &
release_pid=$!

health="$tmpdir/health.json"
ready=0
attempts=0
while [ "$attempts" -lt 30 ]; do
  attempts=$((attempts + 1))

  if ! process_running "$release_pid"; then
    break
  fi

  if curl_get_poll "/api/health" "$health" && \
    grep -Fq '"status":"ok"' "$health" && \
    grep -Fq "\"version\":\"$package_version\"" "$health"; then
    ready=1
    break
  fi

  sleep 0.1
done

if [ "$ready" != "1" ]; then
  echo "packaged scheduler did not become healthy at $base_url" >&2
  echo "scheduler log:" >&2
  sed 's/^/  /' "$scheduler_log" >&2
  exit 1
fi

if ! process_running "$release_pid"; then
  fail "foreground release exited after another process answered the health check"
fi

if [ ! -f "$journal" ]; then
  fail "foreground release did not create the isolated journal: $journal"
fi

assert_contains "$health" '"api_version":"scheduler.v1"' "health response is versioned"
assert_contains "$health" '"status":"ok"' "scheduler health is ok"
assert_contains "$health" "\"version\":\"$package_version\"" "health reports package version"

escaped_workspace=$(json_escape "$workspace")
escaped_workflow_rel=$(json_escape "$workflow_rel")

echo "-- validate workflow through scheduler API"
validate="$tmpdir/validate.json"
curl_json POST "/api/workflows/validate" \
  "{\"script_path\":\"$escaped_workflow_rel\",\"workspace_root\":\"$escaped_workspace\"}" \
  "$validate"
assert_contains "$validate" '"valid":true' "workflow validates through API"
assert_contains "$validate" '"workflow_name":"scheduler-release-proof"' "API reports workflow name"

echo "-- start and inspect mock run through scheduler API"
start="$tmpdir/start.json"
curl_json POST "/api/runs" \
  "{\"script_path\":\"$escaped_workflow_rel\",\"workspace_root\":\"$escaped_workspace\",\"run_id\":\"$run_id\",\"provider\":\"mock\"}" \
  "$start"
assert_contains "$start" '"state":"accepted"' "API accepts run"
assert_contains "$start" "\"run_id\":\"$run_id\"" "API returns requested run id"

status="$tmpdir/status.json"
completed=0
attempts=0
while [ "$attempts" -lt 50 ]; do
  attempts=$((attempts + 1))

  if curl_get_poll "/api/runs/$run_id" "$status"; then
    if grep -Fq '"state":"completed"' "$status"; then
      completed=1
      break
    fi

    if grep -Eq '"state":"(failed|killed)"' "$status"; then
      break
    fi
  fi

  sleep 0.1
done

if [ "$completed" != "1" ]; then
  echo "mock run did not complete within the bounded polling window" >&2
  sed 's/^/  /' "$status" >&2
  exit 1
fi

assert_contains "$status" '"treeName":"scheduler-release-proof"' "status reports workflow tree"
assert_contains "$status" "\"runId\":\"$run_id\"" "status reports run id"
assert_contains "$status" "\"workspaceRoot\":\"$escaped_workspace\"" "status reports canonical workspace root"

events="$tmpdir/events.json"
curl_get "/api/runs/$run_id/events" "$events"
for event_type in run_started phase_entered log_emitted agent_started agent_committed run_completed; do
  assert_contains "$events" "\"type\":\"$event_type\"" "events include $event_type"
done

echo "-- fetch journal-backed LiveView"
ui="$tmpdir/run.html"
curl_get "/runs/$run_id" "$ui"
assert_contains "$ui" "data-run-id=\"$run_id\"" "LiveView has target run id"
assert_contains "$ui" 'data-testid="status-strip"' "LiveView renders status shell"

protocol_version="2025-11-25"

echo "-- initialize direct Streamable HTTP MCP"
mcp_initialize="$tmpdir/mcp-initialize.json"
mcp_post \
  "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"$protocol_version\",\"capabilities\":{},\"clientInfo\":{\"name\":\"release-proof\",\"version\":\"1\"}}}" \
  "$mcp_initialize"
assert_contains "$mcp_initialize" "\"protocolVersion\":\"$protocol_version\"" "MCP negotiates protocol version"
assert_contains "$mcp_initialize" '"name":"codex-loops"' "MCP reports scheduler server name"
assert_contains "$mcp_initialize" "\"version\":\"$package_version\"" "MCP reports package version"

echo "-- list tools through direct Streamable HTTP MCP"
mcp_tools="$tmpdir/mcp-tools.json"
mcp_post \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  "$mcp_tools" \
  "$protocol_version"
for tool_name in workflow_validate workflow_start workflow_status workflow_inspect workflow_resume workflow_open_ui; do
  assert_contains "$mcp_tools" "\"name\":\"$tool_name\"" "MCP lists $tool_name"
done

echo "-- call tools through direct Streamable HTTP MCP"
mcp_validate="$tmpdir/mcp-validate.json"
mcp_post \
  "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"workflow_validate\",\"arguments\":{\"script_path\":\"$escaped_workflow_rel\",\"workspace_root\":\"$escaped_workspace\"}}}" \
  "$mcp_validate" \
  "$protocol_version"
assert_contains "$mcp_validate" '"isError":false' "MCP tool call succeeds"
assert_contains "$mcp_validate" '"workflow_name":"scheduler-release-proof"' "MCP tool call reaches scheduler"

mcp_status="$tmpdir/mcp-status.json"
mcp_post \
  "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"workflow_status\",\"arguments\":{\"run_id\":\"$run_id\"}}}" \
  "$mcp_status" \
  "$protocol_version"
assert_contains "$mcp_status" '"isError":false' "MCP status call succeeds"
assert_contains "$mcp_status" "\"runId\":\"$run_id\"" "MCP status returns API run"
assert_contains "$mcp_status" '"state":"completed"' "MCP status reports completed run"

echo "-- terminate foreground scheduler cleanly"
stop_scheduler

closed=0
attempts=0
while [ "$attempts" -lt 30 ]; do
  attempts=$((attempts + 1))
  probe_port

  if [ "$port_probe_status" -eq 7 ]; then
    closed=1
    break
  fi

  sleep 0.1
done

if [ "$closed" != "1" ]; then
  fail "foreground scheduler still owns $base_url after termination"
fi

echo "Packaged OTP release, API, LiveView, and direct Streamable HTTP MCP proof passed."
