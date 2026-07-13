use std::path::Path;

use serde_json::{Value, json};
use tokio::process::Command;

use crate::{
    error::{AppError, AppResult, ExitStatus},
    runtime::Runtime,
};

use super::artifact::Manifest;

pub(super) async fn stop_scheduler(manifest: &Manifest, artifact_dir: &Path) -> AppResult<bool> {
    let runtime = Runtime::installed()?;
    let output = Command::new(runtime.bundle.control_plane())
        .arg("stop")
        .arg("--host")
        .arg("127.0.0.1")
        .arg("--port")
        .arg(manifest.port.to_string())
        .arg("--json")
        .env("HOME", artifact_dir.join("home"))
        .env("CODEX_LOOPS_RUNTIME_DIR", &manifest.runtime_dir)
        .env("CODEX_LOOPS_SCHEDULER_HOST", "127.0.0.1")
        .env("CODEX_LOOPS_SCHEDULER_PORT", manifest.port.to_string())
        .env_remove("CODEX_LOOPS_SCHEDULER_URL")
        .output()
        .await
        .map_err(|error| {
            AppError::new(
                ExitStatus::Command,
                "sandbox_cleanup_failed",
                "Could not start the sandbox scheduler cleanup command.",
            )
            .details(json!({"reason": error.to_string()}))
        })?;
    if !output.status.success() {
        return Err(AppError::new(
            ExitStatus::Command,
            "sandbox_cleanup_failed",
            "Could not stop the sandbox scheduler before removing its artifacts.",
        )
        .details(json!({
            "status": output.status.code(),
            "stderr": String::from_utf8_lossy(&output.stderr)
        })));
    }
    let response: Value = serde_json::from_slice(&output.stdout).map_err(|error| {
        AppError::new(
            ExitStatus::Runtime,
            "sandbox_cleanup_failed",
            "The sandbox scheduler cleanup command returned invalid JSON.",
        )
        .details(json!({"reason": error.to_string()}))
    })?;
    Ok(response.get("stopped").and_then(Value::as_bool) == Some(true))
}
