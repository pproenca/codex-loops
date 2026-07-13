#![allow(clippy::expect_used, clippy::unwrap_used)]

use std::{
    fs,
    io::{Read, Write},
    net::{SocketAddr, TcpListener, TcpStream},
    path::Path,
    process::{Command, Stdio},
    thread,
};

struct ToolInvocation<'a> {
    port: u16,
    runtime_dir: &'a Path,
    name: &'a str,
    arguments: serde_json::Value,
}

fn health(version: &str) -> String {
    format!(r#"{{"api_version":"scheduler.v1","data":{{"status":"ok","version":"{version}"}}}}"#)
}

fn fake_scheduler(response_bodies: Vec<String>) -> (SocketAddr, thread::JoinHandle<Vec<String>>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let handle = thread::spawn(move || {
        response_bodies
            .into_iter()
            .map(|body| {
                let (mut stream, _) = listener.accept().unwrap();
                let request = read_request(&mut stream);
                write!(
                    stream,
                    "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                    body.len()
                )
                .unwrap();
                String::from_utf8(request).unwrap()
            })
            .collect()
    });
    (address, handle)
}

fn read_request(stream: &mut TcpStream) -> Vec<u8> {
    let mut request = Vec::new();
    let mut buffer = [0_u8; 4_096];
    loop {
        let read = stream.read(&mut buffer).unwrap();
        assert_ne!(read, 0, "client closed before completing HTTP request");
        request.extend_from_slice(&buffer[..read]);
        let Some(header_end) = request
            .windows(4)
            .position(|window| window == b"\r\n\r\n")
            .map(|position| position + 4)
        else {
            continue;
        };
        let headers = String::from_utf8_lossy(&request[..header_end]);
        let content_length = headers
            .lines()
            .find_map(|line| {
                let (name, value) = line.split_once(':')?;
                name.eq_ignore_ascii_case("content-length")
                    .then(|| value.trim().parse::<usize>().unwrap())
            })
            .unwrap_or(0);
        if request.len() >= header_end + content_length {
            return request;
        }
    }
}

fn request_body(request: &str) -> serde_json::Value {
    let (_, body) = request.split_once("\r\n\r\n").unwrap();
    serde_json::from_str(body).unwrap()
}

fn invoke_tool(invocation: ToolInvocation<'_>) -> serde_json::Value {
    let mut child = Command::new(env!("CARGO_BIN_EXE_codex-loops"))
        .args(["mcp", "--stdio"])
        .env_remove("CODEX_LOOPS_SCHEDULER_URL")
        .env("CODEX_LOOPS_SCHEDULER_HOST", "127.0.0.1")
        .env("CODEX_LOOPS_SCHEDULER_PORT", invocation.port.to_string())
        .env("CODEX_LOOPS_RUNTIME_DIR", invocation.runtime_dir)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    for frame in [
        serde_json::json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "stdio-test", "version": "1"}
            }
        }),
        serde_json::json!({
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
            "params": {}
        }),
        serde_json::json!({
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": {"name": invocation.name, "arguments": invocation.arguments}
        }),
    ] {
        writeln!(stdin, "{frame}").unwrap();
    }
    drop(stdin);

    let output = child.wait_with_output().unwrap();
    assert!(
        output.status.success(),
        "MCP server failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str::<serde_json::Value>(line).unwrap())
        .find(|frame| frame.get("id") == Some(&serde_json::json!(2)))
        .unwrap()
}

fn probe_health(address: SocketAddr) {
    let mut stream = TcpStream::connect(address).unwrap();
    write!(
        stream,
        "GET /api/health HTTP/1.1\r\nhost: {address}\r\nconnection: close\r\n\r\n"
    )
    .unwrap();
    let mut response = String::new();
    stream.read_to_string(&mut response).unwrap();
    assert!(response.starts_with("HTTP/1.1 200 OK"));
}

#[test]
fn mcp_stdout_contains_only_json_rpc_frames() {
    let mut child = Command::new(env!("CARGO_BIN_EXE_codex-loops"))
        .args(["mcp", "--stdio"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn MCP server");

    let mut stdin = child.stdin.take().expect("MCP stdin");
    for frame in [
        serde_json::json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "stdio-test", "version": "1"}
            }
        }),
        serde_json::json!({
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
            "params": {}
        }),
        serde_json::json!({
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
            "params": {}
        }),
    ] {
        writeln!(stdin, "{frame}").expect("write MCP frame");
    }
    drop(stdin);

    let output = child.wait_with_output().expect("wait for MCP server");
    assert!(
        output.status.success(),
        "MCP server failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8(output.stdout).expect("UTF-8 MCP output");
    let frames: Vec<_> = stdout.lines().filter(|line| !line.is_empty()).collect();
    assert_eq!(frames.len(), 2, "unexpected MCP stdout: {stdout:?}");
    for frame in frames {
        let value: serde_json::Value = serde_json::from_str(frame)
            .unwrap_or_else(|error| panic!("non-JSON MCP stdout {frame:?}: {error}"));
        assert_eq!(
            value.get("jsonrpc").and_then(|value| value.as_str()),
            Some("2.0")
        );
    }
}

#[test]
fn mcp_tool_calls_are_http_only_and_leave_the_scheduler_running() {
    let temp = tempfile::tempdir().unwrap();
    let runtime_dir = temp.path().join("runtime");
    let (address, server) = fake_scheduler(vec![
        health(env!("CARGO_PKG_VERSION")),
        r#"{"api_version":"scheduler.v1","data":{"runId":"run-1","state":"running"}}"#.into(),
        health(env!("CARGO_PKG_VERSION")),
    ]);

    let response = invoke_tool(ToolInvocation {
        port: address.port(),
        runtime_dir: &runtime_dir,
        name: "workflow_status",
        arguments: serde_json::json!({"run_id": "run-1"}),
    });

    assert_eq!(
        response.pointer("/result/structuredContent/data/runId"),
        Some(&serde_json::json!("run-1"))
    );
    assert!(!runtime_dir.exists(), "MCP created native lifecycle state");
    probe_health(address);
    let requests = server.join().unwrap();
    assert!(requests[0].starts_with("GET /api/health "));
    assert!(requests[1].starts_with("GET /api/runs/run-1 "));
    assert!(requests[2].starts_with("GET /api/health "));
    assert!(
        requests
            .iter()
            .all(|request| !request.starts_with("POST /api/stop "))
    );
}

#[test]
fn mcp_start_sends_the_canonical_script_and_workspace_root_over_http() {
    let temp = tempfile::tempdir().unwrap();
    let workflow = temp.path().join("workflow.exs");
    fs::write(&workflow, "workflow \"test\" do\nend\n").unwrap();
    let runtime_dir = temp.path().join("runtime");
    let canonical_workflow = fs::canonicalize(&workflow).unwrap();
    let canonical_root = fs::canonicalize(temp.path()).unwrap();
    let (address, server) = fake_scheduler(vec![
        health(env!("CARGO_PKG_VERSION")),
        r#"{"api_version":"scheduler.v1","data":{"runId":"run-1","state":"running"}}"#.into(),
    ]);

    let response = invoke_tool(ToolInvocation {
        port: address.port(),
        runtime_dir: &runtime_dir,
        name: "workflow_start",
        arguments: serde_json::json!({
            "script_path": workflow,
            "run_id": "run-1",
            "provider": "mock"
        }),
    });

    assert_eq!(
        response.pointer("/result/structuredContent/data/runId"),
        Some(&serde_json::json!("run-1"))
    );
    assert!(!runtime_dir.exists(), "MCP created native lifecycle state");
    let requests = server.join().unwrap();
    assert!(requests[0].starts_with("GET /api/health "));
    assert!(requests[1].starts_with("POST /api/runs "));
    assert_eq!(
        request_body(&requests[1]),
        serde_json::json!({
            "script_path": canonical_workflow,
            "workspace_root": canonical_root,
            "run_id": "run-1",
            "provider": "mock"
        })
    );
}

#[test]
fn mcp_rejects_an_incompatible_scheduler_without_lifecycle_state() {
    let temp = tempfile::tempdir().unwrap();
    let runtime_dir = temp.path().join("runtime");
    let (address, server) = fake_scheduler(vec![health("9.9.9")]);

    let response = invoke_tool(ToolInvocation {
        port: address.port(),
        runtime_dir: &runtime_dir,
        name: "workflow_status",
        arguments: serde_json::json!({"run_id": "run-1"}),
    });

    assert_eq!(
        response.pointer("/result/structuredContent/error/code"),
        Some(&serde_json::json!("scheduler_version_mismatch"))
    );
    assert!(!runtime_dir.exists(), "MCP created native lifecycle state");
    let requests = server.join().unwrap();
    assert_eq!(requests.len(), 1);
    assert!(requests[0].starts_with("GET /api/health "));
}

#[test]
fn mcp_unavailable_error_directs_users_to_explicit_serve() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    drop(listener);
    let temp = tempfile::tempdir().unwrap();
    let runtime_dir = temp.path().join("runtime");

    let response = invoke_tool(ToolInvocation {
        port,
        runtime_dir: &runtime_dir,
        name: "workflow_status",
        arguments: serde_json::json!({"run_id": "run-1"}),
    });

    assert_eq!(
        response.pointer("/result/structuredContent/error/code"),
        Some(&serde_json::json!("scheduler_unavailable"))
    );
    assert!(
        response
            .pointer("/result/structuredContent/error/message")
            .and_then(serde_json::Value::as_str)
            .is_some_and(|message| message.contains("codex-loops serve"))
    );
    assert!(!runtime_dir.exists(), "MCP created native lifecycle state");
    assert!(!fs::exists(runtime_dir.join("owner.json")).unwrap());
}
