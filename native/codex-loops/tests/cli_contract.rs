#![allow(clippy::expect_used, clippy::unwrap_used)]

use std::{
    fs,
    io::{Read, Write},
    net::TcpListener,
    process::{Command, Stdio},
    thread,
};

fn fake_scheduler(response_bodies: Vec<String>) -> (String, thread::JoinHandle<Vec<String>>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let handle = thread::spawn(move || {
        response_bodies
            .into_iter()
            .map(|body| {
                let (mut stream, _) = listener.accept().unwrap();
                let mut request = [0_u8; 16_384];
                let read = stream.read(&mut request).unwrap();
                write!(
                    stream,
                    "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                    body.len()
                )
                .unwrap();
                String::from_utf8_lossy(&request[..read]).into_owned()
            })
            .collect()
    });
    (format!("http://{address}"), handle)
}

fn health(version: &str) -> String {
    format!(r#"{{"api_version":"scheduler.v1","data":{{"status":"ok","version":"{version}"}}}}"#)
}

#[cfg(unix)]
fn executable(path: &std::path::Path, body: &str) {
    use std::os::unix::fs::PermissionsExt;
    fs::write(path, body).unwrap();
    let mut permissions = fs::metadata(path).unwrap().permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(path, permissions).unwrap();
}

#[cfg(unix)]
fn runtime_bundle(root: &std::path::Path) {
    let control_plane = root.join("bin/codex-loops");
    let scheduler = root.join("libexec/scheduler/bin/agent_loops");
    let skill = root.join("share/skills/codex-loops/SKILL.md");
    fs::create_dir_all(control_plane.parent().unwrap()).unwrap();
    fs::copy(env!("CARGO_BIN_EXE_codex-loops"), control_plane).unwrap();
    fs::create_dir_all(scheduler.parent().unwrap()).unwrap();
    executable(&scheduler, "#!/bin/sh\nexit 0\n");
    fs::create_dir_all(skill.parent().unwrap()).unwrap();
    fs::write(skill, "---\nname: codex-loops\ndescription: fixture\n---\n").unwrap();
}

#[test]
fn json_mode_keeps_machine_output_structured_and_uses_typed_exit_statuses() {
    let missing = tempfile::tempdir().unwrap().path().join("missing.exs");
    let output = Command::new(env!("CARGO_BIN_EXE_codex-loops"))
        .args(["run", missing.to_str().unwrap(), "--json"])
        .output()
        .expect("run native CLI");

    assert_eq!(output.status.code(), Some(2));
    assert!(output.stdout.is_empty());
    let error: serde_json::Value =
        serde_json::from_slice(&output.stderr).expect("JSON error on stderr");
    assert_eq!(error["ok"], false);
    assert_eq!(error["changed"], false);
    assert_eq!(error["error"]["code"], "script_not_found");
}

#[test]
fn doctor_fails_when_the_packaged_runtime_is_invalid() {
    let root = tempfile::tempdir().unwrap().path().join("missing-runtime");
    let output = Command::new(env!("CARGO_BIN_EXE_codex-loops"))
        .args(["doctor", "--json"])
        .env("CODEX_LOOPS_DEV_BUNDLE", root)
        .output()
        .expect("run doctor");

    assert_eq!(output.status.code(), Some(6));
    assert!(output.stdout.is_empty());
    let error: serde_json::Value =
        serde_json::from_slice(&output.stderr).expect("JSON error on stderr");
    assert_eq!(error["ok"], false);
    assert_eq!(error["error"]["code"], "runtime_invalid");
}

#[test]
fn invalid_scheduler_port_never_falls_back_to_the_default() {
    let output = Command::new(env!("CARGO_BIN_EXE_codex-loops"))
        .args(["doctor", "--json"])
        .env_remove("CODEX_LOOPS_SCHEDULER_URL")
        .env("CODEX_LOOPS_SCHEDULER_PORT", "not-a-port")
        .output()
        .expect("run doctor with invalid port");

    assert_eq!(output.status.code(), Some(2));
    assert!(output.stdout.is_empty());
    let error: serde_json::Value =
        serde_json::from_slice(&output.stderr).expect("JSON error on stderr");
    assert_eq!(error["error"]["code"], "scheduler_port_invalid");
    assert_eq!(error["error"]["details"]["value"], "not-a-port");
}

#[cfg(unix)]
#[test]
fn force_stop_rejects_forged_runtime_identity_without_signaling_the_process() {
    let temp = tempfile::tempdir().unwrap();
    let runtime = temp.path().join("runtime-state");
    fs::create_dir_all(&runtime).unwrap();
    let mut unrelated = Command::new("/bin/sh")
        .args(["-c", "sleep 30"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let pid = unrelated.id();
    fs::write(
        runtime.join("owner.json"),
        serde_json::to_vec(&serde_json::json!({
            "owner_token": "forged",
            "supervisor_pid": pid,
            "scheduler_pid": pid,
            "version": env!("CARGO_PKG_VERSION"),
            "port": 47125,
            "scheduler_root": "sleep",
            "config": {"bind_host": null, "journal": null, "model": null}
        }))
        .unwrap(),
    )
    .unwrap();

    let output = Command::new(env!("CARGO_BIN_EXE_codex-loops"))
        .args(["stop", "--force", "--json"])
        .env("CODEX_LOOPS_RUNTIME_DIR", &runtime)
        .env_remove("CODEX_LOOPS_SCHEDULER_URL")
        .output()
        .unwrap();

    let still_running = unrelated.try_wait().unwrap().is_none();
    let _ = unrelated.kill();
    let _ = unrelated.wait();
    assert!(!output.status.success());
    assert!(still_running, "force-stop signaled an unrelated process");
}

#[cfg(unix)]
#[test]
fn first_install_requires_an_explicit_codex_binding_without_path_discovery() {
    let temp = tempfile::tempdir().unwrap();
    let runtime = temp.path().join("runtime");
    let home = temp.path().join("home");
    runtime_bundle(&runtime);

    let output = Command::new(env!("CARGO_BIN_EXE_codex-loops"))
        .args(["install", "--dry-run", "--json"])
        .env("HOME", &home)
        .env("PATH", "/usr/bin:/bin")
        .env("CODEX_LOOPS_DEV_BUNDLE", &runtime)
        .output()
        .expect("run install without binding");

    assert_eq!(output.status.code(), Some(3));
    let error: serde_json::Value = serde_json::from_slice(&output.stderr).unwrap();
    assert_eq!(error["error"]["code"], "codex_binding_required");
}

#[cfg(unix)]
#[test]
fn provider_exec_fails_closed_when_a_bound_shim_changes_version() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let codex = temp.path().join("codex");
    let binding = home.join(".codex/workflows/codex-binding.json");
    fs::create_dir_all(binding.parent().unwrap()).unwrap();
    executable(&codex, "#!/bin/sh\necho 'codex-cli 1.0.0'\n");
    fs::write(
        &binding,
        format!(
            "{{\"path\":{},\"version\":\"codex-cli 1.0.0\"}}",
            serde_json::to_string(&codex).unwrap()
        ),
    )
    .unwrap();

    let first = Command::new(env!("CARGO_BIN_EXE_codex-loops"))
        .args(["provider-exec", "--version"])
        .env("HOME", &home)
        .output()
        .unwrap();
    assert!(first.status.success());

    executable(&codex, "#!/bin/sh\necho 'codex-cli 2.0.0'\n");
    let changed = Command::new(env!("CARGO_BIN_EXE_codex-loops"))
        .args(["provider-exec", "--version"])
        .env("HOME", &home)
        .output()
        .unwrap();
    assert_eq!(changed.status.code(), Some(127));
    assert!(String::from_utf8_lossy(&changed.stderr).contains("changed after it was bound"));
}

#[cfg(unix)]
#[test]
fn install_dry_run_plans_direct_mcp_and_user_skill_without_a_plugin() {
    let temp = tempfile::tempdir().unwrap();
    let runtime = temp.path().join("runtime");
    let home = temp.path().join("home");
    let codex = temp.path().join("codex");
    runtime_bundle(&runtime);
    executable(
        &codex,
        r#"#!/bin/sh
set -eu
case "$*" in
  "--version") echo "codex-cli 9.9.9" ;;
  "mcp list --help") echo "--json" ;;
  "mcp add --help") echo "-- COMMAND" ;;
  "mcp list --json") echo '[]' ;;
  *) echo "unexpected fake codex invocation: $*" >&2; exit 9 ;;
esac
"#,
    );

    let output = Command::new(env!("CARGO_BIN_EXE_codex-loops"))
        .args([
            "install",
            "--dry-run",
            "--codex",
            codex.to_str().unwrap(),
            "--json",
        ])
        .env("HOME", &home)
        .env("CODEX_LOOPS_DEV_BUNDLE", &runtime)
        .output()
        .expect("run direct install dry-run");

    assert!(
        output.status.success(),
        "install failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let result: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(
        result["plan"],
        serde_json::json!(["bind_codex", "install_skill", "add_mcp"])
    );
    assert_eq!(
        result["runtime"]["root"],
        runtime.to_string_lossy().as_ref()
    );
    assert_eq!(result["codex"]["path"], codex.to_string_lossy().as_ref());
    assert!(result["plugin"].is_null());
}

#[cfg(unix)]
#[test]
fn install_converges_direct_mcp_binding_and_skill_idempotently() {
    let temp = tempfile::tempdir().unwrap();
    let runtime = temp.path().join("runtime");
    let home = temp.path().join("home");
    let codex = temp.path().join("codex");
    let mcp_state = temp.path().join("mcp.json");
    runtime_bundle(&runtime);
    executable(
        &codex,
        &format!(
            r#"#!/bin/sh
set -eu
state='{}'
case "$*" in
  "--version") echo "codex-cli 9.9.9" ;;
  "mcp list --help") echo "--json" ;;
  "mcp add --help") echo "-- COMMAND" ;;
  "mcp list --json") if [ -f "$state" ]; then printf '['; cat "$state"; printf ']\n'; else echo '[]'; fi ;;
  "mcp add codex-loops -- "*)
    printf '{{"name":"codex-loops","transport":{{"type":"stdio","command":"%s","args":["mcp"]}}}}\n' "$5" > "$state"
    ;;
  "mcp remove codex-loops") rm -f "$state" ;;
  *) echo "unexpected fake codex invocation: $*" >&2; exit 9 ;;
esac
"#,
            mcp_state.display()
        ),
    );

    let first = Command::new(env!("CARGO_BIN_EXE_codex-loops"))
        .args(["install", "--codex", codex.to_str().unwrap(), "--json"])
        .env("HOME", &home)
        .env("CODEX_LOOPS_DEV_BUNDLE", &runtime)
        .output()
        .expect("install direct integration");
    assert!(
        first.status.success(),
        "install failed: {}",
        String::from_utf8_lossy(&first.stderr)
    );
    let first: serde_json::Value = serde_json::from_slice(&first.stdout).unwrap();
    assert_eq!(first["changed"], true);
    assert!(home.join(".codex/workflows/codex-binding.json").is_file());
    assert!(home.join(".agents/skills/codex-loops/SKILL.md").is_file());
    assert!(mcp_state.is_file());

    let check = Command::new(env!("CARGO_BIN_EXE_codex-loops"))
        .args(["install", "--check", "--json"])
        .env("HOME", &home)
        .env("CODEX_LOOPS_DEV_BUNDLE", &runtime)
        .output()
        .expect("check direct integration");
    assert!(
        check.status.success(),
        "check failed: {}",
        String::from_utf8_lossy(&check.stderr)
    );
    let check: serde_json::Value = serde_json::from_slice(&check.stdout).unwrap();
    assert_eq!(check["changed"], false);
    assert_eq!(check["plan"], serde_json::json!([]));

    let installed_skill = home.join(".agents/skills/codex-loops/SKILL.md");
    fs::remove_file(&installed_skill).unwrap();
    let partial = Command::new(env!("CARGO_BIN_EXE_codex-loops"))
        .args(["install", "--check", "--json"])
        .env("HOME", &home)
        .env("CODEX_LOOPS_DEV_BUNDLE", &runtime)
        .output()
        .unwrap();
    assert_eq!(partial.status.code(), Some(1));
    let partial: serde_json::Value = serde_json::from_slice(&partial.stderr).unwrap();
    assert_eq!(
        partial["error"]["details"]["plan"],
        serde_json::json!(["install_skill"])
    );

    let recovered = Command::new(env!("CARGO_BIN_EXE_codex-loops"))
        .args(["install", "--json"])
        .env("HOME", &home)
        .env("CODEX_LOOPS_DEV_BUNDLE", &runtime)
        .output()
        .unwrap();
    assert!(recovered.status.success());
    assert!(installed_skill.is_file());

    fs::write(&installed_skill, "corrupt").unwrap();
    let corrupt = Command::new(env!("CARGO_BIN_EXE_codex-loops"))
        .args(["install", "--check", "--json"])
        .env("HOME", &home)
        .env("CODEX_LOOPS_DEV_BUNDLE", &runtime)
        .output()
        .unwrap();
    assert_eq!(corrupt.status.code(), Some(1));
    let corrupt: serde_json::Value = serde_json::from_slice(&corrupt.stderr).unwrap();
    assert_eq!(
        corrupt["error"]["details"]["plan"],
        serde_json::json!(["install_skill"])
    );

    let recovered = Command::new(env!("CARGO_BIN_EXE_codex-loops"))
        .args(["install", "--json"])
        .env("HOME", &home)
        .env("CODEX_LOOPS_DEV_BUNDLE", &runtime)
        .output()
        .unwrap();
    assert!(recovered.status.success());
    assert_ne!(fs::read_to_string(installed_skill).unwrap(), "corrupt");

    fs::write(
        home.join(".agents/skills/codex-loops/SKILL.md"),
        "corrupt-again",
    )
    .unwrap();
    let rollback = Command::new(env!("CARGO_BIN_EXE_codex-loops"))
        .args(["install", "--json"])
        .env("HOME", &home)
        .env("CODEX_LOOPS_DEV_BUNDLE", &runtime)
        .env("CODEX_LOOPS_TEST_SKILL_COMMIT_FAILURE", "rollback")
        .output()
        .unwrap();
    assert_eq!(rollback.status.code(), Some(6));
    let rollback: serde_json::Value = serde_json::from_slice(&rollback.stderr).unwrap();
    assert_eq!(rollback["error"]["code"], "skill_rollback_failed");
    assert_eq!(rollback["changed"], true);
    assert_eq!(rollback["error"]["step"], "skill_restore");
}

#[cfg(unix)]
#[test]
fn failed_mcp_replacement_restores_the_previous_registration() {
    let temp = tempfile::tempdir().unwrap();
    let runtime = temp.path().join("runtime");
    let home = temp.path().join("home");
    let codex = temp.path().join("codex");
    let mcp_state = temp.path().join("mcp.json");
    runtime_bundle(&runtime);
    fs::write(
        &mcp_state,
        r#"{"name":"codex-loops","transport":{"type":"stdio","command":"/old/codex-loops","args":["mcp"]}}"#,
    )
    .unwrap();
    executable(
        &codex,
        &format!(
            r#"#!/bin/sh
set -eu
state='{}'
case "$*" in
  "--version") echo "codex-cli 9.9.9" ;;
  "mcp list --help") echo "--json" ;;
  "mcp add --help") echo "-- COMMAND" ;;
  "mcp list --json") printf '['; cat "$state"; printf ']\n' ;;
  "mcp remove codex-loops") rm -f "$state" ;;
  "mcp add codex-loops -- /old/codex-loops mcp")
    printf '%s\n' '{{"name":"codex-loops","transport":{{"type":"stdio","command":"/old/codex-loops","args":["mcp"]}}}}' > "$state"
    ;;
  "mcp add codex-loops -- "*) echo "replacement failed" >&2; exit 7 ;;
  *) echo "unexpected fake codex invocation: $*" >&2; exit 9 ;;
esac
"#,
            mcp_state.display()
        ),
    );

    let output = Command::new(env!("CARGO_BIN_EXE_codex-loops"))
        .args(["install", "--codex", codex.to_str().unwrap(), "--json"])
        .env("HOME", &home)
        .env("CODEX_LOOPS_DEV_BUNDLE", &runtime)
        .output()
        .unwrap();

    assert_eq!(output.status.code(), Some(5));
    let error: serde_json::Value = serde_json::from_slice(&output.stderr).unwrap();
    assert_eq!(error["error"]["code"], "codex_command_failed");
    let restored: serde_json::Value =
        serde_json::from_slice(&fs::read(&mcp_state).unwrap()).unwrap();
    assert_eq!(
        restored
            .pointer("/transport/command")
            .and_then(|value| value.as_str()),
        Some("/old/codex-loops")
    );
}

#[cfg(unix)]
#[test]
fn mcp_replacement_integration_covers_success_and_failed_rollback() {
    let temp = tempfile::tempdir().unwrap();
    let runtime = temp.path().join("runtime");
    let home = temp.path().join("home");
    let codex = temp.path().join("codex");
    let mcp_state = temp.path().join("mcp.json");
    runtime_bundle(&runtime);
    let old = r#"{"name":"codex-loops","transport":{"type":"stdio","command":"/old/codex-loops","args":["mcp"]}}"#;
    fs::write(&mcp_state, old).unwrap();
    executable(
        &codex,
        &format!(
            r#"#!/bin/sh
set -eu
state='{}'
case "$*" in
  "--version") echo "codex-cli 9.9.9" ;;
  "mcp list --help") echo "--json" ;;
  "mcp add --help") echo "-- COMMAND" ;;
  "mcp list --json") printf '['; cat "$state"; printf ']\n' ;;
  "mcp remove codex-loops") rm -f "$state" ;;
  "mcp add codex-loops -- "*)
    if [ "${{FAIL_ADDS:-0}}" = 1 ]; then echo failed >&2; exit 7; fi
    printf '{{"name":"codex-loops","transport":{{"type":"stdio","command":"%s","args":["mcp"]}}}}\n' "$5" > "$state"
    ;;
  *) exit 9 ;;
esac
"#,
            mcp_state.display()
        ),
    );

    let success = Command::new(env!("CARGO_BIN_EXE_codex-loops"))
        .args(["install", "--codex", codex.to_str().unwrap(), "--json"])
        .env("HOME", &home)
        .env("CODEX_LOOPS_DEV_BUNDLE", &runtime)
        .output()
        .unwrap();
    assert!(success.status.success());
    let installed: serde_json::Value =
        serde_json::from_slice(&fs::read(&mcp_state).unwrap()).unwrap();
    assert_eq!(
        installed["transport"]["command"],
        runtime.join("bin/codex-loops").to_string_lossy().as_ref()
    );

    fs::write(&mcp_state, old).unwrap();
    let rollback = Command::new(env!("CARGO_BIN_EXE_codex-loops"))
        .args(["install", "--json"])
        .env("HOME", &home)
        .env("CODEX_LOOPS_DEV_BUNDLE", &runtime)
        .env("FAIL_ADDS", "1")
        .output()
        .unwrap();
    assert_eq!(rollback.status.code(), Some(5));
    let rollback: serde_json::Value = serde_json::from_slice(&rollback.stderr).unwrap();
    assert_eq!(rollback["error"]["code"], "mcp_rollback_failed");
    assert_eq!(rollback["changed"], true);
}

#[test]
fn compatible_external_endpoints_support_read_and_pathless_resume_commands() {
    let cases: &[(&[&str], &str)] = &[
        (&["status", "run-1"], "GET /api/runs/run-1 "),
        (&["inspect", "run-1"], "GET /api/runs/run-1/events "),
        (
            &["resume", "run-1", "--provider", "mock"],
            "POST /api/runs/run-1/resume ",
        ),
    ];
    for (arguments, expected_request) in cases {
        let (server, requests) = fake_scheduler(vec![
            health(env!("CARGO_PKG_VERSION")),
            r#"{"api_version":"scheduler.v1","data":{"run_id":"run-1","state":"running"}}"#.into(),
        ]);
        let output = Command::new(env!("CARGO_BIN_EXE_codex-loops"))
            .args(*arguments)
            .args(["--server", &server, "--json"])
            .output()
            .expect("run command against external scheduler");
        assert!(
            output.status.success(),
            "external command failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        let requests = requests.join().unwrap();
        assert!(requests[0].starts_with("GET /api/health "));
        assert!(requests[1].starts_with(expected_request));
    }
}

#[cfg(unix)]
#[test]
fn compatible_external_endpoint_can_open_a_run_without_local_ownership() {
    let (server, requests) = fake_scheduler(vec![
        health(env!("CARGO_PKG_VERSION")),
        r#"{"api_version":"scheduler.v1","data":{"run_id":"run-1","state":"running"}}"#.into(),
    ]);
    let temp = tempfile::tempdir().unwrap();
    let opener = temp.path().join("open");
    let opened = temp.path().join("opened");
    executable(
        &opener,
        &format!("#!/bin/sh\nprintf '%s' \"$1\" > '{}'\n", opened.display()),
    );
    let output = Command::new(env!("CARGO_BIN_EXE_codex-loops"))
        .args(["open", "run-1", "--server", &server, "--json"])
        .env("CODEX_LOOPS_OPEN_BIN", opener)
        .output()
        .expect("open external scheduler run");
    assert!(
        output.status.success(),
        "external open failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        fs::read_to_string(opened).unwrap(),
        format!("{server}/runs/run-1")
    );
    assert_eq!(requests.join().unwrap().len(), 2);
}

#[test]
fn incompatible_external_scheduler_remains_a_typed_error() {
    let (server, requests) = fake_scheduler(vec![health("9.9.9")]);
    let output = Command::new(env!("CARGO_BIN_EXE_codex-loops"))
        .args(["status", "run-1", "--server", &server, "--json"])
        .output()
        .expect("run command against incompatible scheduler");
    assert_eq!(output.status.code(), Some(6));
    let error: serde_json::Value = serde_json::from_slice(&output.stderr).unwrap();
    assert_eq!(error["error"]["code"], "scheduler_version_mismatch");
    assert_eq!(requests.join().unwrap().len(), 1);
}

#[test]
fn unreachable_external_scheduler_never_attempts_local_ownership() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let server = format!("http://{}", listener.local_addr().unwrap());
    drop(listener);
    let runtime = tempfile::tempdir().unwrap().path().join("runtime");
    let output = Command::new(env!("CARGO_BIN_EXE_codex-loops"))
        .args(["status", "run-1", "--server", &server, "--json"])
        .env("CODEX_LOOPS_RUNTIME_DIR", &runtime)
        .output()
        .expect("run command against unreachable external scheduler");
    assert_eq!(output.status.code(), Some(6));
    let error: serde_json::Value = serde_json::from_slice(&output.stderr).unwrap();
    assert_eq!(error["error"]["code"], "scheduler_unavailable");
    assert!(
        !runtime.exists(),
        "external endpoint created local owner state"
    );
}

#[test]
fn external_lifecycle_is_left_to_its_process_manager() {
    let output = Command::new(env!("CARGO_BIN_EXE_codex-loops"))
        .args(["stop", "--server", "http://127.0.0.1:9", "--json"])
        .output()
        .expect("refuse external lifecycle command");
    assert_eq!(output.status.code(), Some(6));
    let error: serde_json::Value = serde_json::from_slice(&output.stderr).unwrap();
    assert_eq!(error["error"]["code"], "scheduler_externally_managed");
}

#[test]
fn path_bearing_remote_commands_require_shared_filesystem_opt_in() {
    let temp = tempfile::tempdir().unwrap();
    let script = temp.path().join("remote.exs");
    fs::write(&script, "use Workflow\n").unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_codex-loops"))
        .args([
            "run",
            script.to_str().unwrap(),
            "--server",
            "http://192.0.2.1:47125",
            "--json",
        ])
        .env_remove("CODEX_LOOPS_SHARED_FILESYSTEM")
        .output()
        .expect("reject unshared remote workflow path");
    assert_eq!(output.status.code(), Some(2));
    let error: serde_json::Value = serde_json::from_slice(&output.stderr).unwrap();
    assert_eq!(
        error["error"]["code"],
        "remote_scheduler_requires_shared_filesystem"
    );
}

#[test]
fn shared_filesystem_opt_in_allows_path_bearing_external_run() {
    let temp = tempfile::tempdir().unwrap();
    let script = temp.path().join("shared.exs");
    fs::write(&script, "use Workflow\n").unwrap();
    let (server, requests) = fake_scheduler(vec![
        health(env!("CARGO_PKG_VERSION")),
        r#"{"api_version":"scheduler.v1","data":{"workflow_name":"shared"}}"#.into(),
        r#"{"api_version":"scheduler.v1","data":{"workflow_name":"shared","state":"running"}}"#
            .into(),
    ]);
    let remote_alias = server.replacen("127.0.0.1", "localhost.", 1);
    let output = Command::new(env!("CARGO_BIN_EXE_codex-loops"))
        .args([
            "run",
            script.to_str().unwrap(),
            "--provider",
            "mock",
            "--server",
            &remote_alias,
            "--json",
        ])
        .env("CODEX_LOOPS_SHARED_FILESYSTEM", "1")
        .output()
        .expect("run shared path against external scheduler");
    assert!(
        output.status.success(),
        "shared external run failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let requests = requests.join().unwrap();
    assert!(requests[0].starts_with("GET /api/health "));
    assert!(requests[1].starts_with("POST /api/workflows/validate "));
    assert!(requests[2].starts_with("POST /api/runs "));
}
