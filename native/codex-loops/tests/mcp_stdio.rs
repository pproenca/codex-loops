use std::{
    io::Write,
    process::{Command, Stdio},
};

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
