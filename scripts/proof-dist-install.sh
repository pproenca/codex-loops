#!/bin/sh
set -eu

bundle=${1:?development bundle is required}
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmpdir=$(mktemp -d)
proof_server_pid=

cleanup() {
  if [ -n "${proof_server_pid:-}" ]; then
    kill "$proof_server_pid" 2>/dev/null || true
    wait "$proof_server_pid" 2>/dev/null || true
  fi

  rm -rf "$tmpdir"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

version=$(tr -d '[:space:]' < "$repo_root/VERSION")
archive_stage="$tmpdir/codex-loops-$version-archive"

mkdir -p "$archive_stage"
cp -R "$bundle/." "$archive_stage/"
cp "$repo_root/scripts/install-bundle.sh" "$archive_stage/install"
printf '%s\n' "$version" >"$archive_stage/VERSION"
chmod 755 "$archive_stage/install"

# The canonical fixture must retain and execute the real release overlay. The
# logger replacement below belongs only to the separate outer-forwarding tests.
cmp "$bundle/bin/codex-loops" "$archive_stage/bin/codex-loops"
grep -Fq 'Workflow.CLI.main(System.argv())' "$archive_stage/bin/codex-loops"
test -f "$archive_stage/share/codex-loops/THIRD_PARTY_NOTICES.md"

if [ "$(uname -s)" = Linux ]; then
  for command in curl python3; do
    if ! command -v "$command" >/dev/null 2>&1; then
      echo "$command is required for the real archive reconciliation proof" >&2
      exit 2
    fi
  done

  real_share_root="$tmpdir/real-install-root"
  real_bin_root="$tmpdir/real-bin"
  real_destination="$real_share_root/$version"
  real_stable_command="$real_bin_root/codex-loops"
  proof_home="$tmpdir/real-home"
  runtime_fake_bin="$tmpdir/runtime-fake-bin"
  codex_state="$tmpdir/codex-state.json"
  codex_log="$tmpdir/codex-calls.log"
  service_log="$tmpdir/service-calls.log"
  server_log="$tmpdir/server-requests.log"
  server_stderr="$tmpdir/server.stderr"
  real_output="$tmpdir/real-install-output.json"

  mkdir -p "$real_share_root" "$proof_home" "$runtime_fake_bin"
  cp -R "$archive_stage" "$real_destination"

  cat >"$runtime_fake_bin/codex" <<'EOF'
#!/bin/sh
set -eu

state=${CODEX_LOOPS_PROOF_CODEX_STATE:?}
log=${CODEX_LOOPS_PROOF_CODEX_LOG:?}
printf '%s\n' "$*" >>"$log"

if [ "$#" -eq 1 ] && [ "$1" = "--version" ]; then
  printf 'codex-cli 0.0.0-proof\n'
  exit 0
fi

if [ "$#" -eq 3 ] && [ "$1" = "mcp" ] && [ "$2" = "add" ] && [ "$3" = "--help" ]; then
  printf 'Usage: codex mcp add NAME --url URL\n'
  exit 0
fi

if [ "$#" -eq 3 ] && [ "$1" = "mcp" ] && [ "$2" = "list" ] && [ "$3" = "--json" ]; then
  if [ -f "$state" ]; then
    cat "$state"
  else
    printf '[]\n'
  fi
  exit 0
fi

if [ "$#" -eq 4 ] && [ "$1" = "mcp" ] && [ "$2" = "get" ] &&
  [ "$3" = "codex-loops" ] && [ "$4" = "--json" ]; then
  if [ ! -f "$state" ]; then
    echo "No MCP server named 'codex-loops' found." >&2
    exit 1
  fi
  cat <<'JSON'
{"name":"codex-loops","enabled":true,"disabled_reason":null,"transport":{"type":"streamable_http","url":"http://127.0.0.1:47125/mcp","bearer_token_env_var":null,"http_headers":null,"env_http_headers":null},"enabled_tools":null,"disabled_tools":null,"startup_timeout_sec":null,"tool_timeout_sec":null}
JSON
  exit 0
fi

if [ "$#" -eq 5 ] && [ "$1" = "mcp" ] && [ "$2" = "add" ] &&
  [ "$3" = "codex-loops" ] && [ "$4" = "--url" ] &&
  [ "$5" = "http://127.0.0.1:47125/mcp" ]; then
  cat >"$state" <<'JSON'
[{"name":"codex-loops","enabled":true,"disabled_reason":null,"transport":{"type":"streamable_http","url":"http://127.0.0.1:47125/mcp","bearer_token_env_var":null,"http_headers":null,"env_http_headers":null},"startup_timeout_sec":null,"tool_timeout_sec":null,"auth_status":"unsupported"}]
JSON
  exit 0
fi

if [ "$#" -eq 3 ] && [ "$1" = "mcp" ] && [ "$2" = "remove" ] && [ "$3" = "codex-loops" ]; then
  rm -f "$state"
  exit 0
fi

echo "unexpected fake Codex invocation: $*" >&2
exit 97
EOF

  cat >"$runtime_fake_bin/systemctl" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"${CODEX_LOOPS_PROOF_SERVICE_LOG:?}"

case "$*" in
  "--user is-enabled codex-loops.service" | "--user is-active codex-loops.service") exit 0 ;;
  *) echo "unexpected fake systemctl mutation: $*" >&2; exit 98 ;;
esac
EOF

  cat >"$tmpdir/proof-server.py" <<'PY'
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

version, request_log = sys.argv[1:]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def send_payload(self, status, payload):
        body = json.dumps(payload, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def record(self):
        with open(request_log, "a", encoding="utf-8") as stream:
            stream.write(f"{self.command} {self.path}\n")

    def do_GET(self):
        self.record()
        if self.path == "/api/health":
            self.send_payload(
                200,
                {"api_version": "scheduler.v1", "data": {"status": "ok", "version": version}},
            )
        else:
            self.send_payload(404, {"error": "not_found"})

    def do_POST(self):
        self.record()
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length))
        if self.path == "/mcp" and body.get("method") == "initialize":
            self.send_payload(
                200,
                {
                    "jsonrpc": "2.0",
                    "id": body.get("id"),
                    "result": {
                        "protocolVersion": "2025-03-26",
                        "capabilities": {"tools": {"listChanged": False}},
                        "serverInfo": {"name": "codex-loops", "version": version},
                    },
                },
            )
        else:
            self.send_payload(404, {"error": "not_found"})

    def log_message(self, _format, *_args):
        pass


ThreadingHTTPServer(("127.0.0.1", 47125), Handler).serve_forever()
PY

  chmod 755 "$runtime_fake_bin/codex" "$runtime_fake_bin/systemctl"

  python3 "$tmpdir/proof-server.py" "$version" "$server_log" >"$server_stderr" 2>&1 &
  proof_server_pid=$!
  attempt=0
  until curl --noproxy '*' -fsS --connect-timeout 1 --max-time 1 \
    http://127.0.0.1:47125/api/health >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    if ! kill -0 "$proof_server_pid" 2>/dev/null || [ "$attempt" -ge 50 ]; then
      echo "isolated proof server failed to bind to 127.0.0.1:47125" >&2
      sed 's/^/  /' "$server_stderr" >&2
      exit 1
    fi
    sleep 0.1
  done

  # Persist the expected binding and exact managed-service definition so the
  # real installer observes an already healthy isolated service. The fake
  # manager rejects every mutating operation, proving reconciliation did not
  # reach the host systemd instance.
  HOME="$proof_home" \
    PATH="$runtime_fake_bin:/usr/bin:/bin" \
    CODEX_LOOPS_RELEASE_COMMAND="$real_destination/libexec/scheduler/bin/codex-loops-server" \
    CODEX_LOOPS_PROOF_CODEX_STATE="$codex_state" \
    CODEX_LOOPS_PROOF_CODEX_LOG="$codex_log" \
    CODEX_LOOPS_PROOF_SERVICE_LOG="$service_log" \
    CODEX_LOOPS_PROOF_CODEX_BIN="$runtime_fake_bin/codex" \
    RELEASE_DISTRIBUTION=none \
    "$real_destination/libexec/scheduler/bin/agent_loops" eval '
      alias Workflow.Install.{CodexBinding, Service}
      codex = System.fetch_env!("CODEX_LOOPS_PROOF_CODEX_BIN")
      {:ok, binding} = CodexBinding.probe(codex)
      :ok = CodexBinding.persist(binding)
      {:ok, service} = Service.config(binding)
      File.mkdir_p!(Path.dirname(service.definition_path))
      File.write!(service.definition_path, service.content)
    ' >/dev/null

  HOME="$proof_home" \
    PATH="$runtime_fake_bin:/usr/bin:/bin" \
    CODEX_LOOPS_INSTALL_ROOT="$real_share_root" \
    CODEX_LOOPS_BIN_ROOT="$real_bin_root" \
    CODEX_LOOPS_PROOF_CODEX_STATE="$codex_state" \
    CODEX_LOOPS_PROOF_CODEX_LOG="$codex_log" \
    CODEX_LOOPS_PROOF_SERVICE_LOG="$service_log" \
    "$archive_stage/install" --codex "$runtime_fake_bin/codex" --json >"$real_output"

  cmp "$archive_stage/bin/codex-loops" "$real_destination/bin/codex-loops"
  cmp "$bundle/bin/codex-loops" "$real_destination/bin/codex-loops"
  test "$(readlink "$real_share_root/current")" = "$version"
  test "$(readlink "$real_stable_command")" = "$real_share_root/current/bin/codex-loops"
  test "$(tr -d '[:space:]' <"$proof_home/.agents/skills/codex-loops/.codex-loops-version")" = "$version"
  test -f "$codex_state"
  grep -Fq '"api_version":"codex-loops.cli.v1"' "$real_output"
  grep -Fq '"install_skill"' "$real_output"
  grep -Fq '"add_mcp"' "$real_output"
  grep -Fq 'mcp add codex-loops --url http://127.0.0.1:47125/mcp' "$codex_log"
  grep -Fq '"type":"streamable_http"' "$codex_state"
  grep -Fq '"url":"http://127.0.0.1:47125/mcp"' "$codex_state"
  grep -Fq 'GET /api/health' "$server_log"
  grep -Fq 'POST /mcp' "$server_log"

  if grep -Ev '^--user (is-enabled|is-active) codex-loops\.service$' "$service_log" | grep -q .; then
    echo "real reconciliation attempted a host service-manager mutation" >&2
    exit 1
  fi

  HOME="$proof_home" PATH="$runtime_fake_bin:/usr/bin:/bin" \
    "$real_stable_command" --version | grep -Fq "codex-loops $version"

  kill "$proof_server_pid"
  wait "$proof_server_pid" 2>/dev/null || true
  proof_server_pid=
else
  # Linux CI executes the complete isolated reconciliation above. Other hosts
  # still execute the untouched packaged overlay and the portable forwarding,
  # activation, rollback, and locking assertions below.
  HOME="$tmpdir/overlay-home" "$archive_stage/bin/codex-loops" --version |
    grep -Fq "codex-loops $version"
fi

stage="$tmpdir/codex-loops-$version-forwarding"
share_root="$tmpdir/forwarding-install-root"
bin_root="$tmpdir/forwarding-bin"
stable_command="$bin_root/codex-loops"
proof_log="$tmpdir/installer-call"

wait_for_file() {
  awaited=$1
  label=$2
  attempts=0

  while [ ! -e "$awaited" ]; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 200 ]; then
      echo "timed out waiting for $label: $awaited" >&2
      return 1
    fi
    sleep 0.05
  done
}

cp -R "$archive_stage" "$stage"
cat >"$stage/bin/codex-loops" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >"${CODEX_LOOPS_PROOF_LOG:?}"

if [ -n "${CODEX_LOOPS_PROOF_READY:-}" ]; then
  : >"$CODEX_LOOPS_PROOF_READY"

  while [ ! -e "${CODEX_LOOPS_PROOF_RELEASE:?}" ]; do
    sleep 0.05
  done
fi

test "${CODEX_LOOPS_PROOF_FAIL:-0}" != 1
EOF
chmod 755 "$stage/bin/codex-loops"

CODEX_LOOPS_INSTALL_ROOT="$share_root" \
  CODEX_LOOPS_BIN_ROOT="$bin_root" \
  CODEX_LOOPS_PROOF_LOG="$proof_log" \
  "$stage/install" --codex /proof/codex >/dev/null

test -x "$share_root/$version/bin/codex-loops"
test "$(readlink "$share_root/current")" = "$version"
test "$(readlink "$stable_command")" = "$share_root/current/bin/codex-loops"
test "$(cat "$proof_log")" = "install --codex /proof/codex"

preview_version="${version}-preview"
preview_stage="$tmpdir/codex-loops-$preview_version-test"
cp -R "$stage" "$preview_stage"
printf '%s\n' "$preview_version" >"$preview_stage/VERSION"
if CODEX_LOOPS_INSTALL_ROOT="$share_root" \
  CODEX_LOOPS_BIN_ROOT="$bin_root" \
  CODEX_LOOPS_PROOF_LOG="$proof_log" \
  "$preview_stage/install" --dry-run >/dev/null 2>&1; then
  echo "archive installer accepted a misleading mutating --dry-run mode" >&2
  exit 1
fi
test "$(readlink "$share_root/current")" = "$version"
test ! -e "$share_root/$preview_version"

next_version="${version}-next"
next_stage="$tmpdir/codex-loops-$next_version-test"
cp -R "$stage" "$next_stage"
printf '%s\n' "$next_version" >"$next_stage/VERSION"
if CODEX_LOOPS_INSTALL_ROOT="$share_root" \
  CODEX_LOOPS_BIN_ROOT="$bin_root" \
  CODEX_LOOPS_PROOF_LOG="$proof_log" \
  CODEX_LOOPS_PROOF_FAIL=1 \
  "$next_stage/install" >/dev/null 2>&1; then
  echo "installer did not propagate the inner one-action install failure" >&2
  exit 1
fi
test "$(readlink "$share_root/current")" = "$version"
test "$(readlink "$stable_command")" = "$share_root/current/bin/codex-loops"
test -x "$share_root/$next_version/bin/codex-loops"

mkdir -p "$share_root/.install-lock"
printf '%s\n' "$$" >"$share_root/.install-lock/pid"
if CODEX_LOOPS_INSTALL_ROOT="$share_root" \
  CODEX_LOOPS_BIN_ROOT="$bin_root" \
  CODEX_LOOPS_PROOF_LOG="$proof_log" \
  "$next_stage/install" >/dev/null 2>&1; then
  echo "installer ignored a lock held by a live process" >&2
  exit 1
fi
test "$(readlink "$share_root/current")" = "$version"

printf '%s\n' 99999999 >"$share_root/.install-lock/pid"
CODEX_LOOPS_INSTALL_ROOT="$share_root" \
  CODEX_LOOPS_BIN_ROOT="$bin_root" \
  CODEX_LOOPS_PROOF_LOG="$proof_log" \
  "$next_stage/install" >/dev/null

test -x "$share_root/$version/bin/codex-loops"
test -x "$share_root/$next_version/bin/codex-loops"
test "$(readlink "$share_root/current")" = "$next_version"
test ! -e "$share_root/.install-lock"

incomplete_version="${version}-incomplete"
incomplete_stage="$tmpdir/codex-loops-$incomplete_version-test"
cp -R "$stage" "$incomplete_stage"
printf '%s\n' "$incomplete_version" >"$incomplete_stage/VERSION"
mkdir -p "$share_root/$incomplete_version/bin"
cp "$stage/bin/codex-loops" "$share_root/$incomplete_version/bin/codex-loops"
if CODEX_LOOPS_INSTALL_ROOT="$share_root" \
  CODEX_LOOPS_BIN_ROOT="$bin_root" \
  CODEX_LOOPS_PROOF_LOG="$proof_log" \
  "$incomplete_stage/install" >/dev/null 2>&1; then
  echo "installer activated an incomplete existing immutable bundle" >&2
  exit 1
fi
test "$(readlink "$share_root/current")" = "$next_version"

symlink_version="${version}-symlink"
symlink_stage="$tmpdir/codex-loops-$symlink_version-test"
cp -R "$stage" "$symlink_stage"
printf '%s\n' "$symlink_version" >"$symlink_stage/VERSION"
ln -s "$tmpdir/missing-runtime" "$share_root/$symlink_version"
if CODEX_LOOPS_INSTALL_ROOT="$share_root" \
  CODEX_LOOPS_BIN_ROOT="$bin_root" \
  CODEX_LOOPS_PROOF_LOG="$proof_log" \
  "$symlink_stage/install" >/dev/null 2>&1; then
  echo "installer replaced a version destination symlink" >&2
  exit 1
fi
test -L "$share_root/$symlink_version"
test "$(readlink "$share_root/current")" = "$next_version"

failure_cas_version="${version}-failure-cas"
failure_cas_stage="$tmpdir/codex-loops-$failure_cas_version-test"
failure_cas_ready="$tmpdir/failure-cas-ready"
failure_cas_release="$tmpdir/failure-cas-release"
cp -R "$stage" "$failure_cas_stage"
printf '%s\n' "$failure_cas_version" >"$failure_cas_stage/VERSION"
CODEX_LOOPS_INSTALL_ROOT="$share_root" \
  CODEX_LOOPS_BIN_ROOT="$bin_root" \
  CODEX_LOOPS_PROOF_LOG="$proof_log" \
  CODEX_LOOPS_PROOF_FAIL=1 \
  CODEX_LOOPS_PROOF_READY="$failure_cas_ready" \
  CODEX_LOOPS_PROOF_RELEASE="$failure_cas_release" \
  "$failure_cas_stage/install" >/dev/null 2>&1 &
failure_cas_pid=$!
wait_for_file "$failure_cas_ready" "failure-CAS installer"
rm -f "$share_root/current" "$stable_command"
ln -s external-current "$share_root/current"
ln -s /external/codex-loops "$stable_command"
: >"$failure_cas_release"
failure_cas_status=0
wait "$failure_cas_pid" || failure_cas_status=$?
test "$failure_cas_status" -ne 0
test "$(readlink "$share_root/current")" = external-current
test "$(readlink "$stable_command")" = /external/codex-loops
test -x "$share_root/$failure_cas_version/bin/codex-loops"

rm -f "$share_root/current" "$stable_command"
ln -s "$next_version" "$share_root/current"
ln -s "$share_root/current/bin/codex-loops" "$stable_command"

one_link_version="${version}-one-link-cas"
one_link_stage="$tmpdir/codex-loops-$one_link_version-test"
one_link_ready="$tmpdir/one-link-ready"
one_link_release="$tmpdir/one-link-release"
cp -R "$stage" "$one_link_stage"
printf '%s\n' "$one_link_version" >"$one_link_stage/VERSION"
CODEX_LOOPS_INSTALL_ROOT="$share_root" \
  CODEX_LOOPS_BIN_ROOT="$bin_root" \
  CODEX_LOOPS_PROOF_LOG="$proof_log" \
  CODEX_LOOPS_PROOF_FAIL=1 \
  CODEX_LOOPS_PROOF_READY="$one_link_ready" \
  CODEX_LOOPS_PROOF_RELEASE="$one_link_release" \
  "$one_link_stage/install" >/dev/null 2>&1 &
one_link_pid=$!
wait_for_file "$one_link_ready" "one-link CAS installer"
rm -f "$stable_command"
ln -s /external/one-link "$stable_command"
: >"$one_link_release"
one_link_status=0
wait "$one_link_pid" || one_link_status=$?
test "$one_link_status" -ne 0
test "$(readlink "$share_root/current")" = "$one_link_version"
test "$(readlink "$stable_command")" = /external/one-link
test -x "$share_root/$one_link_version/bin/codex-loops"

rm -f "$share_root/current" "$stable_command"
ln -s "$next_version" "$share_root/current"
ln -s "$share_root/current/bin/codex-loops" "$stable_command"

success_cas_version="${version}-success-cas"
success_cas_stage="$tmpdir/codex-loops-$success_cas_version-test"
success_cas_ready="$tmpdir/success-cas-ready"
success_cas_release="$tmpdir/success-cas-release"
cp -R "$stage" "$success_cas_stage"
printf '%s\n' "$success_cas_version" >"$success_cas_stage/VERSION"
CODEX_LOOPS_INSTALL_ROOT="$share_root" \
  CODEX_LOOPS_BIN_ROOT="$bin_root" \
  CODEX_LOOPS_PROOF_LOG="$proof_log" \
  CODEX_LOOPS_PROOF_READY="$success_cas_ready" \
  CODEX_LOOPS_PROOF_RELEASE="$success_cas_release" \
  "$success_cas_stage/install" >/dev/null 2>&1 &
success_cas_pid=$!
wait_for_file "$success_cas_ready" "success-CAS installer"
rm -f "$share_root/current" "$stable_command"
ln -s external-success "$share_root/current"
ln -s /external/success "$stable_command"
: >"$success_cas_release"
success_cas_status=0
wait "$success_cas_pid" || success_cas_status=$?
test "$success_cas_status" -ne 0
test "$(readlink "$share_root/current")" = external-success
test "$(readlink "$stable_command")" = /external/success
test -x "$share_root/$success_cas_version/bin/codex-loops"

rm -f "$share_root/current" "$stable_command"
ln -s "$next_version" "$share_root/current"
ln -s "$share_root/current/bin/codex-loops" "$stable_command"

interrupt_version="${version}-interrupted"
interrupt_stage="$tmpdir/codex-loops-$interrupt_version-test"
interrupt_ready="$tmpdir/install-interrupt-ready"
interrupt_release="$tmpdir/install-interrupt-release"
cp -R "$stage" "$interrupt_stage"
printf '%s\n' "$interrupt_version" >"$interrupt_stage/VERSION"
CODEX_LOOPS_INSTALL_ROOT="$share_root" \
  CODEX_LOOPS_BIN_ROOT="$bin_root" \
  CODEX_LOOPS_PROOF_LOG="$proof_log" \
  CODEX_LOOPS_PROOF_READY="$interrupt_ready" \
  CODEX_LOOPS_PROOF_RELEASE="$interrupt_release" \
  "$interrupt_stage/install" >/dev/null 2>&1 &
interrupt_pid=$!
wait_for_file "$interrupt_ready" "interrupted installer"
kill -TERM "$interrupt_pid"
: >"$interrupt_release"
interrupt_status=0
wait "$interrupt_pid" || interrupt_status=$?
test "$interrupt_status" -ne 0
test "$(readlink "$share_root/current")" = "$interrupt_version"
test "$(readlink "$stable_command")" = "$share_root/current/bin/codex-loops"
test -x "$share_root/$interrupt_version/bin/codex-loops"
CODEX_LOOPS_INSTALL_ROOT="$share_root" \
  CODEX_LOOPS_BIN_ROOT="$bin_root" \
  CODEX_LOOPS_PROOF_LOG="$proof_log" \
  "$interrupt_stage/install" >/dev/null

concurrent_version="${version}-concurrent"
concurrent_stage="$tmpdir/codex-loops-$concurrent_version-test"
concurrent_ready="$tmpdir/concurrent-ready"
concurrent_release="$tmpdir/concurrent-release"
cp -R "$stage" "$concurrent_stage"
printf '%s\n' "$concurrent_version" >"$concurrent_stage/VERSION"
mkdir -p "$share_root/.install-lock"
rm -f "$share_root/.install-lock/pid"

CODEX_LOOPS_INSTALL_ROOT="$share_root" CODEX_LOOPS_BIN_ROOT="$bin_root" \
  CODEX_LOOPS_PROOF_LOG="$proof_log" CODEX_LOOPS_PROOF_READY="$concurrent_ready" \
  CODEX_LOOPS_PROOF_RELEASE="$concurrent_release" \
  "$concurrent_stage/install" >"$tmpdir/concurrent-one.log" 2>&1 &
concurrent_pid_one=$!
CODEX_LOOPS_INSTALL_ROOT="$share_root" CODEX_LOOPS_BIN_ROOT="$bin_root" \
  CODEX_LOOPS_PROOF_LOG="$proof_log" CODEX_LOOPS_PROOF_READY="$concurrent_ready" \
  CODEX_LOOPS_PROOF_RELEASE="$concurrent_release" \
  "$concurrent_stage/install" >"$tmpdir/concurrent-two.log" 2>&1 &
concurrent_pid_two=$!
if ! wait_for_file "$concurrent_ready" "concurrent stale-lock reclaimer"; then
  sed 's/^/concurrent one: /' "$tmpdir/concurrent-one.log" >&2
  sed 's/^/concurrent two: /' "$tmpdir/concurrent-two.log" >&2
  exit 1
fi
: >"$concurrent_release"
concurrent_status_one=0
concurrent_status_two=0
wait "$concurrent_pid_one" || concurrent_status_one=$?
wait "$concurrent_pid_two" || concurrent_status_two=$?
concurrent_successes=0
if [ "$concurrent_status_one" -eq 0 ]; then concurrent_successes=$((concurrent_successes + 1)); fi
if [ "$concurrent_status_two" -eq 0 ]; then concurrent_successes=$((concurrent_successes + 1)); fi
test "$concurrent_successes" -eq 1
test "$(readlink "$share_root/current")" = "$concurrent_version"
test ! -e "$share_root/.install-lock"
test ! -e "$share_root/.install-lock.reclaim"

mkdir "$share_root/.install-lock.reclaim"
if ! CODEX_LOOPS_INSTALL_ROOT="$share_root" \
  CODEX_LOOPS_BIN_ROOT="$bin_root" \
  CODEX_LOOPS_PROOF_LOG="$proof_log" \
  "$concurrent_stage/install" >"$tmpdir/malformed-reclaim.log" 2>&1; then
  sed 's/^/malformed reclaim: /' "$tmpdir/malformed-reclaim.log" >&2
  exit 1
fi
test ! -e "$share_root/.install-lock.reclaim"

mkdir "$share_root/.install-lock.reclaim"
printf '%s\n' 99999999 >"$share_root/.install-lock.reclaim/pid"
CODEX_LOOPS_INSTALL_ROOT="$share_root" \
  CODEX_LOOPS_BIN_ROOT="$bin_root" \
  CODEX_LOOPS_PROOF_LOG="$proof_log" \
  "$concurrent_stage/install" >/dev/null
test ! -e "$share_root/.install-lock.reclaim"

fake_bin="$tmpdir/fake-bin"
failed_dist="$tmpdir/failed-dist"
test -x "$repo_root/scripts/package-dist.sh"
mkdir -p "$fake_bin"
cat >"$fake_bin/minisign" <<'EOF'
#!/bin/sh
exit 42
EOF
chmod 755 "$fake_bin/minisign"
unsafe_dist="$tmpdir/unsafe-dist"
if PATH="$fake_bin:$PATH" DIST_TARGET=../escape MINISIGN_SECRET_KEY="$tmpdir/key" \
  "$repo_root/scripts/package-dist.sh" "$bundle" "$unsafe_dist" "$version" >/dev/null 2>&1; then
  echo "distribution accepted an unsafe target path component" >&2
  exit 1
fi
test ! -e "$unsafe_dist"
test ! -e "$tmpdir/escape"

if PATH="$fake_bin:$PATH" DIST_TARGET=proof MINISIGN_SECRET_KEY="$tmpdir/key" \
  "$repo_root/scripts/package-dist.sh" "$bundle" "$failed_dist" "$version" >/dev/null 2>&1; then
  echo "distribution unexpectedly succeeded with a failing signer" >&2
  exit 1
fi
test ! -e "$failed_dist/codex-loops-$version-proof.tar.gz"
test ! -e "$failed_dist/codex-loops-$version-proof.tar.gz.sha256"
test ! -e "$failed_dist/codex-loops-$version-proof.tar.gz.minisig"

interrupt_bin="$tmpdir/interrupt-bin"
interrupted_dist="$tmpdir/interrupted-dist"
mkdir -p "$interrupt_bin"
cat >"$interrupt_bin/minisign" <<'EOF'
#!/bin/sh
kill -TERM "$PPID"
sleep 1
exit 0
EOF
chmod 755 "$interrupt_bin/minisign"
if PATH="$interrupt_bin:$PATH" DIST_TARGET=proof MINISIGN_SECRET_KEY="$tmpdir/key" \
  "$repo_root/scripts/package-dist.sh" "$bundle" "$interrupted_dist" "$version" >/dev/null 2>&1; then
  echo "distribution unexpectedly survived interrupted signing" >&2
  exit 1
fi
test ! -e "$interrupted_dist/codex-loops-$version-proof.tar.gz"
test ! -e "$interrupted_dist/codex-loops-$version-proof.tar.gz.sha256"
test ! -e "$interrupted_dist/codex-loops-$version-proof.tar.gz.minisig"
test ! -e "$interrupted_dist/.codex-loops-$version-proof.publish-lock"

preserved_dist="$tmpdir/preserved-dist"
preserved_archive="$preserved_dist/codex-loops-$version-proof.tar.gz"
mkdir -p "$preserved_dist"
printf 'existing archive\n' >"$preserved_archive"
printf 'existing checksum\n' >"$preserved_archive.sha256"
printf 'existing signature\n' >"$preserved_archive.minisig"
if PATH="$fake_bin:$PATH" DIST_TARGET=proof MINISIGN_SECRET_KEY="$tmpdir/key" \
  "$repo_root/scripts/package-dist.sh" "$bundle" "$preserved_dist" "$version" >/dev/null 2>&1; then
  echo "distribution unexpectedly replaced immutable artifacts" >&2
  exit 1
fi
test "$(cat "$preserved_archive")" = "existing archive"
test "$(cat "$preserved_archive.sha256")" = "existing checksum"
test "$(cat "$preserved_archive.minisig")" = "existing signature"

partial_dist="$tmpdir/partial-dist"
partial_archive="$partial_dist/codex-loops-$version-proof.tar.gz"
mkdir -p "$partial_dist"
printf 'partial checksum\n' >"$partial_archive.sha256"
printf 'partial signature\n' >"$partial_archive.minisig"
if PATH="$fake_bin:$PATH" DIST_TARGET=proof MINISIGN_SECRET_KEY="$tmpdir/key" \
  "$repo_root/scripts/package-dist.sh" "$bundle" "$partial_dist" "$version" >/dev/null 2>&1; then
  echo "distribution unexpectedly replaced partial immutable artifacts" >&2
  exit 1
fi
test "$(cat "$partial_archive.sha256")" = "partial checksum"
test "$(cat "$partial_archive.minisig")" = "partial signature"

success_bin="$tmpdir/success-bin"
mkdir -p "$success_bin"
cat >"$success_bin/minisign" <<'EOF'
#!/bin/sh
set -eu
message=
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-m" ]; then
    shift
    message=${1:?}
  fi
  shift
done
printf 'untrusted comment: proof signature\nproof\n' >"${message:?}.minisig"
EOF
chmod 755 "$success_bin/minisign"

symlink_dist="$tmpdir/symlink-publication"
symlink_transaction="$symlink_dist/.codex-loops-$version-symlink.publication"
symlink_target="$tmpdir/publication-symlink-target"
mkdir -p "$symlink_dist" "$symlink_target"
ln -s "$symlink_target" "$symlink_transaction"
if PATH="$success_bin:$PATH" DIST_TARGET=symlink MINISIGN_SECRET_KEY="$tmpdir/key" \
  "$repo_root/scripts/package-dist.sh" "$bundle" "$symlink_dist" "$version" >/dev/null 2>&1; then
  echo "distribution followed a symlink publication transaction" >&2
  exit 1
fi
test -L "$symlink_transaction"
test ! -e "$symlink_target/archive.tar.gz"

relative_dist_parent="$tmpdir/relative-publication"
mkdir -p "$relative_dist_parent"
(
  cd "$relative_dist_parent"
  PATH="$success_bin:$PATH" DIST_TARGET=relative MINISIGN_SECRET_KEY="$tmpdir/key" \
    "$repo_root/scripts/package-dist.sh" "$bundle" output "$version" >/dev/null
)
relative_archive="$relative_dist_parent/output/codex-loops-$version-relative.tar.gz"
test -f "$relative_archive"
test -f "$relative_archive.sha256"
test -f "$relative_archive.minisig"
test ! -e "$relative_dist_parent/output/.codex-loops-$version-relative.publish-lock"

recovery_dist="$tmpdir/recovery-dist"
recovery_archive="$recovery_dist/codex-loops-$version-recovery.tar.gz"
recovery_transaction="$recovery_dist/.codex-loops-$version-recovery.publication"
recovery_lock="$recovery_dist/.codex-loops-$version-recovery.publish-lock"
mkdir -p "$recovery_transaction" "$recovery_lock"
printf '%s\n' 99999999 >"$recovery_lock/pid"
printf 'recoverable archive\n' >"$recovery_transaction/archive.tar.gz"
recovery_hash=$(shasum -a 256 "$recovery_transaction/archive.tar.gz" | awk '{print $1}')
printf '%s  %s\n' "$recovery_hash" "$(basename -- "$recovery_archive")" \
  >"$recovery_transaction/archive.tar.gz.sha256"
printf 'untrusted comment: recovery signature\nproof\n' >"$recovery_transaction/archive.tar.gz.minisig"
: >"$recovery_transaction/ready"
cp "$recovery_transaction/archive.tar.gz.minisig" "$recovery_archive.minisig"
PATH="$success_bin:$PATH" DIST_TARGET=recovery MINISIGN_SECRET_KEY="$tmpdir/key" \
  "$repo_root/scripts/package-dist.sh" "$bundle" "$recovery_dist" "$version" >/dev/null
test "$(cat "$recovery_archive")" = "recoverable archive"
test "$(cat "$recovery_archive.sha256")" = "$recovery_hash  $(basename -- "$recovery_archive")"
test -s "$recovery_archive.minisig"
test ! -e "$recovery_transaction"
test ! -e "$recovery_lock"

formula_artifacts="$tmpdir/formula-artifacts"
formula="$tmpdir/codex-loops-proof.rb"
mkdir -p "$formula_artifacts"

for target in \
  aarch64-apple-darwin \
  x86_64-apple-darwin \
  aarch64-unknown-linux-gnu \
  x86_64-unknown-linux-gnu; do
  archive="$formula_artifacts/codex-loops-$version-$target.tar.gz"
  printf 'archive fixture for %s\n' "$target" >"$archive"
  hash=$(shasum -a 256 "$archive" | awk '{print $1}')
  printf '%s  %s\n' "$hash" "$(basename -- "$archive")" >"$archive.sha256"
  printf 'untrusted comment: proof signature for %s\nproof\n' "$target" >"$archive.minisig"
done

"$repo_root/scripts/write-homebrew-formula.sh" "$formula" "$version" "$formula_artifacts"
ruby -c "$formula" >/dev/null
test "$(grep -c '^      url .*codex-loops-.*\.tar\.gz' "$formula")" = 4
test "$(grep -c '^      sha256 "[0123456789abcdef]\{64\}"' "$formula")" = 4
grep -Fq 'on_macos do' "$formula"
grep -Fq 'on_linux do' "$formula"
grep -Fq 'on_arm do' "$formula"
grep -Fq 'on_intel do' "$formula"
grep -Fq 'system bin/"codex-loops", "install"' "$formula"

for target in \
  aarch64-apple-darwin \
  x86_64-apple-darwin \
  aarch64-unknown-linux-gnu \
  x86_64-unknown-linux-gnu; do
  archive="$formula_artifacts/codex-loops-$version-$target.tar.gz"
  hash=$(shasum -a 256 "$archive" | awk '{print $1}')
  grep -Fq "codex-loops-$version-$target.tar.gz" "$formula"
  grep -Fq "sha256 \"$hash\"" "$formula"
done

missing_artifacts="$tmpdir/formula-artifacts-missing"
missing_formula="$tmpdir/missing-formula.rb"
cp -R "$formula_artifacts" "$missing_artifacts"
rm "$missing_artifacts/codex-loops-$version-x86_64-unknown-linux-gnu.tar.gz.minisig"
if "$repo_root/scripts/write-homebrew-formula.sh" \
  "$missing_formula" "$version" "$missing_artifacts" >/dev/null 2>&1; then
  echo "formula aggregation accepted a missing target signature" >&2
  exit 1
fi
test ! -e "$missing_formula"

tampered_artifacts="$tmpdir/formula-artifacts-tampered"
preserved_formula="$tmpdir/preserved-formula.rb"
cp -R "$formula_artifacts" "$tampered_artifacts"
printf 'tampered\n' >>"$tampered_artifacts/codex-loops-$version-aarch64-apple-darwin.tar.gz"
printf 'preserved formula\n' >"$preserved_formula"
if "$repo_root/scripts/write-homebrew-formula.sh" \
  "$preserved_formula" "$version" "$tampered_artifacts" >/dev/null 2>&1; then
  echo "formula aggregation accepted an archive that failed its checksum" >&2
  exit 1
fi
test "$(cat "$preserved_formula")" = "preserved formula"

printf 'Distribution and versioned bundle install proof passed\n'
