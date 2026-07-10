use std::{
    fs,
    io::{Read, Write},
    net::TcpListener,
    process::Command,
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
        .env("CODEX_LOOPS_RUNTIME_ROOT", root)
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
fn source_checkout_discovers_the_built_scheduler_without_installation_environment() {
    let checkout = tempfile::tempdir().unwrap();
    fs::write(checkout.path().join("mix.exs"), "source checkout").unwrap();
    fs::create_dir_all(checkout.path().join("native/codex-loops")).unwrap();
    fs::write(
        checkout.path().join("native/codex-loops/Cargo.toml"),
        "source checkout",
    )
    .unwrap();
    let scheduler = checkout
        .path()
        .join("_build/prod/rel/agent_loops/bin/agent_loops");
    fs::create_dir_all(scheduler.parent().unwrap()).unwrap();
    fs::write(&scheduler, "source checkout scheduler").unwrap();

    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let server = format!("http://{}", listener.local_addr().unwrap());
    drop(listener);

    let output = Command::new(env!("CARGO_BIN_EXE_codex-loops"))
        .args(["doctor", "--json"])
        .current_dir(checkout.path())
        .env_remove("CODEX_LOOPS_SCHEDULER_BIN")
        .env_remove("CODEX_LOOPS_RUNTIME_ROOT")
        .env("CODEX_LOOPS_SCHEDULER_URL", server)
        .output()
        .expect("run doctor from source checkout");

    assert_eq!(output.status.code(), Some(1));
    assert!(output.stdout.is_empty());
    let error: serde_json::Value =
        serde_json::from_slice(&output.stderr).expect("JSON error on stderr");
    assert_eq!(error["error"]["code"], "scheduler_stopped");
    assert_eq!(
        error["error"]["details"]["scheduler_bin"],
        scheduler.canonicalize().unwrap().to_string_lossy().as_ref()
    );
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
fn install_dry_run_prints_the_plan_and_resolved_runtime() {
    let temp = tempfile::tempdir().unwrap();
    let bin = temp.path().join("bin");
    let runtime = temp.path().join("runtime");
    fs::create_dir_all(&bin).unwrap();
    fs::create_dir_all(runtime.join("scheduler/bin")).unwrap();
    fs::create_dir_all(runtime.join("mcp")).unwrap();
    executable(
        &bin.join("codex"),
        r#"#!/bin/sh
set -eu
case "$*" in
  "--version") echo "codex-cli 1.0" ;;
  "plugin marketplace add --help"|"plugin add --help"|"plugin marketplace list --help"|"plugin list --help") echo "--json" ;;
  "plugin marketplace list --json") echo '{"marketplaces":[]}' ;;
  "plugin list --json") echo '{"installed":[]}' ;;
  *) echo "unexpected fake codex invocation: $*" >&2; exit 9 ;;
esac
"#,
    );
    executable(
        &runtime.join("scheduler/bin/agent_loops"),
        "#!/bin/sh\nexit 0\n",
    );
    executable(
        &runtime.join("mcp/codex-loops-mcp"),
        "#!/bin/sh\necho 'codex-loops-mcp 0.2.7'\n",
    );

    let output = Command::new(env!("CARGO_BIN_EXE_codex-loops"))
        .args(["install", "--dry-run", "--verbose"])
        .env("PATH", &bin)
        .env("CODEX_LOOPS_RUNTIME_ROOT", &runtime)
        .output()
        .expect("run install dry-run");

    assert!(
        output.status.success(),
        "install failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains("Codex Loops installation plan:"));
    assert!(stdout.contains("codex plugin marketplace add pproenca/codex-loops"));
    assert!(stdout.contains("codex plugin add codex-loops@codex-loops --json"));
    assert!(stdout.contains("Runtime:"));
    assert!(stdout.contains("Scheduler:"));
    assert!(stdout.contains("MCP:"));
    assert!(stdout.contains("Plugin: not installed"));
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
