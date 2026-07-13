use std::{path::Path, process::Stdio, time::Duration};

use serde_json::{Value, json};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader, Lines},
    process::{Child, ChildStdin, ChildStdout, Command},
    time::timeout,
};

use crate::error::{AppError, AppResult, ExitStatus};

pub(super) struct SpawnOptions<'a> {
    pub executable: &'a Path,
    pub worktree: &'a Path,
    pub home: &'a Path,
    pub transcript: &'a Path,
    pub stderr: &'a Path,
    pub port: u16,
}

pub(super) struct McpClient {
    child: Child,
    stdin: ChildStdin,
    stdout: Lines<BufReader<ChildStdout>>,
    transcript: tokio::fs::File,
    next_id: u64,
}

impl McpClient {
    pub async fn spawn(options: SpawnOptions<'_>) -> AppResult<Self> {
        let stderr = std::fs::File::create(options.stderr).map_err(|error| {
            AppError::new(
                ExitStatus::Runtime,
                "sandbox_artifact_failed",
                "Could not create the sandbox MCP stderr artifact.",
            )
            .details(json!({"path": options.stderr, "reason": error.to_string()}))
        })?;
        let mut command = mcp_command(&options);
        command.stderr(Stdio::from(stderr));
        let mut child = command.spawn().map_err(|error| {
            AppError::new(
                ExitStatus::Command,
                "sandbox_mcp_start_failed",
                "Could not start the sandbox MCP server.",
            )
            .details(json!({"executable": options.executable, "reason": error.to_string()}))
        })?;
        let stdin = child.stdin.take().ok_or_else(|| {
            AppError::new(
                ExitStatus::Runtime,
                "sandbox_mcp_invariant",
                "The sandbox MCP process has no stdin pipe.",
            )
        })?;
        let stdout = child.stdout.take().ok_or_else(|| {
            AppError::new(
                ExitStatus::Runtime,
                "sandbox_mcp_invariant",
                "The sandbox MCP process has no stdout pipe.",
            )
        })?;
        let transcript = tokio::fs::File::create(options.transcript)
            .await
            .map_err(|error| {
                AppError::new(
                    ExitStatus::Runtime,
                    "sandbox_artifact_failed",
                    "Could not create the sandbox MCP transcript.",
                )
                .details(json!({"path": options.transcript, "reason": error.to_string()}))
            })?;
        Ok(Self {
            child,
            stdin,
            stdout: BufReader::new(stdout).lines(),
            transcript,
            next_id: 1,
        })
    }

    pub async fn initialize(&mut self) -> AppResult<Value> {
        let result = self
            .request(
                "initialize",
                json!({
                    "protocolVersion": "2024-11-05",
                    "capabilities": {},
                    "clientInfo": {"name": "codex-loops-sandbox", "version": env!("CARGO_PKG_VERSION")}
                }),
            )
            .await?;
        self.notify("notifications/initialized", json!({})).await?;
        Ok(result)
    }

    pub async fn list_tools(&mut self) -> AppResult<Value> {
        self.request("tools/list", json!({})).await
    }

    pub async fn call_tool(&mut self, name: &str, arguments: Value) -> AppResult<Value> {
        let result = self
            .request("tools/call", json!({"name": name, "arguments": arguments}))
            .await?;
        if result.get("isError").and_then(Value::as_bool) == Some(true) {
            return Err(AppError::new(
                ExitStatus::Runtime,
                "sandbox_mcp_tool_failed",
                format!("The sandbox MCP tool `{name}` returned an error."),
            )
            .details(result));
        }
        if let Some(content) = result.get("structuredContent") {
            return Ok(content.clone());
        }
        let text = result
            .get("content")
            .and_then(Value::as_array)
            .and_then(|content| content.first())
            .and_then(|content| content.get("text"))
            .and_then(Value::as_str)
            .ok_or_else(|| {
                AppError::new(
                    ExitStatus::Runtime,
                    "sandbox_mcp_response_invalid",
                    format!("The sandbox MCP tool `{name}` returned no structured payload."),
                )
                .details(result.clone())
            })?;
        serde_json::from_str(text).map_err(|error| {
            AppError::new(
                ExitStatus::Runtime,
                "sandbox_mcp_response_invalid",
                format!("The sandbox MCP tool `{name}` returned invalid JSON content."),
            )
            .details(json!({"reason": error.to_string(), "content": text}))
        })
    }

    pub async fn close(mut self) -> AppResult<()> {
        self.stdin.shutdown().await.map_err(|error| {
            AppError::new(
                ExitStatus::Runtime,
                "sandbox_mcp_shutdown_failed",
                "Could not close the sandbox MCP input stream.",
            )
            .details(json!({"reason": error.to_string()}))
        })?;
        drop(self.stdin);
        let status = match timeout(Duration::from_secs(30), self.child.wait()).await {
            Ok(result) => result.map_err(|error| {
                AppError::new(
                    ExitStatus::Runtime,
                    "sandbox_mcp_shutdown_failed",
                    "Could not wait for the sandbox MCP process.",
                )
                .details(json!({"reason": error.to_string()}))
            })?,
            Err(_elapsed) => {
                self.child.kill().await.map_err(|error| {
                    AppError::new(
                        ExitStatus::Runtime,
                        "sandbox_mcp_shutdown_failed",
                        "The sandbox MCP process did not exit and could not be terminated.",
                    )
                    .details(json!({"reason": error.to_string()}))
                })?;
                return Err(AppError::new(
                    ExitStatus::Runtime,
                    "sandbox_mcp_shutdown_failed",
                    "The sandbox MCP process did not exit after its input closed.",
                ));
            }
        };
        if status.success() {
            Ok(())
        } else {
            Err(AppError::new(
                ExitStatus::Runtime,
                "sandbox_mcp_shutdown_failed",
                format!("The sandbox MCP process exited with {status}."),
            ))
        }
    }

    async fn request(&mut self, method: &str, params: Value) -> AppResult<Value> {
        let request_id = self.next_id;
        self.next_id += 1;
        self.send(&json!({
            "jsonrpc": "2.0",
            "id": request_id,
            "method": method,
            "params": params
        }))
        .await?;
        self.receive(request_id).await
    }

    async fn notify(&mut self, method: &str, params: Value) -> AppResult<()> {
        self.send(&json!({"jsonrpc": "2.0", "method": method, "params": params}))
            .await
    }

    async fn send(&mut self, message: &Value) -> AppResult<()> {
        let line = serde_json::to_vec(message).map_err(|error| {
            AppError::new(
                ExitStatus::Runtime,
                "sandbox_mcp_request_invalid",
                "Could not encode a sandbox MCP request.",
            )
            .details(json!({"reason": error.to_string()}))
        })?;
        self.transcript
            .write_all(
                serde_json::to_string(&json!({"direction": "out", "message": message}))
                    .map_err(|error| {
                        AppError::new(
                            ExitStatus::Runtime,
                            "sandbox_artifact_failed",
                            "Could not encode the sandbox MCP transcript.",
                        )
                        .details(json!({"reason": error.to_string()}))
                    })?
                    .as_bytes(),
            )
            .await
            .map_err(transcript_error)?;
        self.transcript
            .write_all(b"\n")
            .await
            .map_err(transcript_error)?;
        self.transcript.flush().await.map_err(transcript_error)?;
        self.stdin.write_all(&line).await.map_err(mcp_write_error)?;
        self.stdin.write_all(b"\n").await.map_err(mcp_write_error)?;
        self.stdin.flush().await.map_err(mcp_write_error)
    }

    async fn receive(&mut self, request_id: u64) -> AppResult<Value> {
        loop {
            let line = self.stdout.next_line().await.map_err(|error| {
                AppError::new(
                    ExitStatus::Runtime,
                    "sandbox_mcp_response_invalid",
                    "Could not read a sandbox MCP response.",
                )
                .details(json!({"reason": error.to_string()}))
            })?;
            let line = line.ok_or_else(|| {
                AppError::new(
                    ExitStatus::Runtime,
                    "sandbox_mcp_exited",
                    "The sandbox MCP process exited before responding.",
                )
            })?;
            let response: Value = serde_json::from_str(&line).map_err(|error| {
                AppError::new(
                    ExitStatus::Runtime,
                    "sandbox_mcp_response_invalid",
                    "The sandbox MCP process emitted non-JSON stdout.",
                )
                .details(json!({"line": line, "reason": error.to_string()}))
            })?;
            let transcript = serde_json::to_string(
                &json!({"direction": "in", "message": response}),
            )
            .map_err(|error| {
                AppError::new(
                    ExitStatus::Runtime,
                    "sandbox_artifact_failed",
                    "Could not encode the sandbox MCP transcript.",
                )
                .details(json!({"reason": error.to_string()}))
            })?;
            self.transcript
                .write_all(transcript.as_bytes())
                .await
                .map_err(transcript_error)?;
            self.transcript
                .write_all(b"\n")
                .await
                .map_err(transcript_error)?;
            self.transcript.flush().await.map_err(transcript_error)?;
            if response.get("id").and_then(Value::as_u64) != Some(request_id) {
                continue;
            }
            if let Some(error) = response.get("error") {
                return Err(AppError::new(
                    ExitStatus::Runtime,
                    "sandbox_mcp_request_failed",
                    "The sandbox MCP server rejected a protocol request.",
                )
                .details(error.clone()));
            }
            return response.get("result").cloned().ok_or_else(|| {
                AppError::new(
                    ExitStatus::Runtime,
                    "sandbox_mcp_response_invalid",
                    "The sandbox MCP response contained no result.",
                )
                .details(response)
            });
        }
    }
}

fn mcp_command(options: &SpawnOptions<'_>) -> Command {
    let mut command = Command::new(options.executable);
    command
        .arg("mcp")
        .current_dir(options.worktree)
        .env("HOME", options.home)
        .env("CODEX_LOOPS_SCHEDULER_HOST", "127.0.0.1")
        .env("CODEX_LOOPS_SCHEDULER_PORT", options.port.to_string())
        .env("CODEX_LOOPS_WORKSPACE_ROOT", options.worktree)
        .env_remove("CODEX_HOME")
        .env_remove("CODEX_ACCESS_TOKEN")
        .env_remove("CODEX_LOOPS_RUNTIME_DIR")
        .env_remove("CODEX_LOOPS_JOURNAL_PATH")
        .env_remove("CODEX_LOOPS_CODEX_SANDBOX")
        .env_remove("CODEX_LOOPS_CODEX_WORKDIR")
        .env_remove("CODEX_LOOPS_CODEX_MODEL")
        .env_remove("CODEX_LOOPS_SCHEDULER_URL")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .kill_on_drop(true);
    command
}

fn transcript_error(error: std::io::Error) -> AppError {
    AppError::new(
        ExitStatus::Runtime,
        "sandbox_artifact_failed",
        "Could not write the sandbox MCP transcript.",
    )
    .details(json!({"reason": error.to_string()}))
}

fn mcp_write_error(error: std::io::Error) -> AppError {
    AppError::new(
        ExitStatus::Runtime,
        "sandbox_mcp_write_failed",
        "Could not write to the sandbox MCP process.",
    )
    .details(json!({"reason": error.to_string()}))
}

#[cfg(test)]
mod tests {
    use std::{collections::BTreeMap, ffi::OsStr};

    use super::*;

    #[test]
    fn mcp_has_only_transport_and_workspace_authority() {
        let root = tempfile::tempdir().unwrap();
        let home = root.path().join("home");
        let options = SpawnOptions {
            executable: Path::new("/opt/codex-loops"),
            worktree: &root.path().join("repo"),
            home: &home,
            transcript: &root.path().join("mcp-transcript.jsonl"),
            stderr: &root.path().join("mcp-stderr.log"),
            port: 47_125,
        };

        let command = mcp_command(&options);
        let env: BTreeMap<_, _> = command.as_std().get_envs().collect();

        assert_eq!(
            env.get(OsStr::new("CODEX_LOOPS_WORKSPACE_ROOT")),
            Some(&Some(options.worktree.as_os_str()))
        );
        for removed in [
            "CODEX_HOME",
            "CODEX_ACCESS_TOKEN",
            "CODEX_LOOPS_RUNTIME_DIR",
            "CODEX_LOOPS_JOURNAL_PATH",
            "CODEX_LOOPS_CODEX_SANDBOX",
            "CODEX_LOOPS_CODEX_WORKDIR",
            "CODEX_LOOPS_CODEX_MODEL",
            "CODEX_LOOPS_SCHEDULER_URL",
        ] {
            assert_eq!(env.get(OsStr::new(removed)), Some(&None));
        }
    }
}
