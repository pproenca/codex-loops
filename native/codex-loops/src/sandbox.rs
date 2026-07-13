mod artifact;
mod cleanup;
mod git;
mod mcp_client;

use std::{
    env,
    net::TcpListener,
    num::NonZeroU64,
    path::{Path, PathBuf},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use serde_json::{Value, json};
use tokio::time::{Instant, sleep};
use url::Url;

use crate::{
    cli::{BrowserOutcome, OpenMode},
    error::{AppError, AppResult, ExitStatus},
    runtime::Runtime,
    scheduler::{Provider, RunId},
};

use self::{
    artifact::{
        MANIFEST_FORMAT, Manifest, persist_binding, prepare_layout, read_manifest,
        validate_manifest, write_json, write_snapshot,
    },
    cleanup::stop_scheduler,
    git::RemoveMode,
    mcp_client::{McpClient, SpawnOptions},
};

pub struct RunOptions {
    pub script: PathBuf,
    pub provider: Provider,
    pub run_id: Option<RunId>,
    pub output_dir: Option<PathBuf>,
    pub model: Option<String>,
    pub timeout_seconds: NonZeroU64,
    pub open_mode: OpenMode,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CleanMode {
    PreserveDirty,
    Force,
}

pub struct CleanOptions {
    pub artifact_dir: PathBuf,
    pub mode: CleanMode,
}

#[derive(Debug)]
pub struct RunOutput {
    pub artifact_dir: PathBuf,
    pub worktree: PathBuf,
    pub journal: PathBuf,
    pub transcript: PathBuf,
    pub run_id: RunId,
    pub provider: Provider,
    pub state: String,
    pub ui_url: Url,
    pub browser: BrowserOutcome,
}

#[derive(Debug)]
pub struct CleanOutput {
    pub artifact_dir: PathBuf,
    pub worktree: PathBuf,
    pub scheduler_stopped: bool,
}

pub async fn run(options: RunOptions) -> AppResult<RunOutput> {
    let repository = git::discover(&options.script).await?;
    let run_id = match options.run_id {
        Some(run_id) => run_id,
        None => sandbox_run_id(&options.script)?,
    };
    let runtime = Runtime::installed()?;
    let original_home = home_dir()?;
    let codex_home = env::var_os("CODEX_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| original_home.join(".codex"));
    let layout = prepare_layout(options.output_dir.as_deref(), &run_id, &original_home).await?;
    persist_binding(&runtime.codex, &layout.home)?;
    let port = reserve_port()?;
    let server_url = Url::parse(&format!("http://127.0.0.1:{port}/")).map_err(|error| {
        AppError::new(
            ExitStatus::Runtime,
            "sandbox_url_invalid",
            "Could not construct the sandbox scheduler URL.",
        )
        .details(json!({"port": port, "reason": error.to_string()}))
    })?;
    git::add_detached(&repository, &layout.worktree).await?;
    let script_path = layout.worktree.join(&repository.script_relative);
    if !script_path.is_file() {
        return Err(AppError::new(
            ExitStatus::Runtime,
            "sandbox_script_invariant",
            "The committed workflow script is missing from the detached worktree.",
        )
        .details(json!({
            "script_path": options.script,
            "worktree_script_path": script_path,
            "artifact_dir": layout.artifact_dir
        })));
    }
    let mut manifest = Manifest {
        format: MANIFEST_FORMAT.into(),
        version: env!("CARGO_PKG_VERSION").into(),
        artifact_dir: layout.artifact_dir.clone(),
        repository: repository.root.clone(),
        worktree: layout.worktree.clone(),
        script_path: script_path.clone(),
        runtime_dir: layout.runtime.clone(),
        journal_path: layout.journal.clone(),
        transcript_path: layout.transcript.clone(),
        run_id: run_id.as_str().into(),
        provider: options.provider,
        model: options.model.clone(),
        port,
        server_url: server_url.to_string(),
        state: "prepared".into(),
        codex_path: runtime.codex.path().to_path_buf(),
        codex_version: runtime.codex.version().into(),
    };
    write_json(&layout.artifact_dir.join("manifest.json"), &manifest).await?;

    let mut client = McpClient::spawn(SpawnOptions {
        executable: &runtime.bundle.control_plane(),
        worktree: &layout.worktree,
        home: &layout.home,
        codex_home: &codex_home,
        runtime: &layout.runtime,
        journal: &layout.journal,
        transcript: &layout.transcript,
        stderr: &layout.artifact_dir.join("mcp-stderr.log"),
        port,
        model: options.model.as_deref(),
    })
    .await?;

    let initialize = client.initialize().await?;
    write_json(&layout.artifact_dir.join("initialize.json"), &initialize).await?;
    let tools = client.list_tools().await?;
    assert_tool_catalog(&tools)?;
    write_json(&layout.artifact_dir.join("tools.json"), &tools).await?;
    let validation = client
        .call_tool("workflow_validate", json!({"script_path": script_path}))
        .await?;
    write_json(&layout.artifact_dir.join("validation.json"), &validation).await?;
    let started = client
        .call_tool(
            "workflow_start",
            json!({
                "script_path": script_path,
                "run_id": run_id.as_str(),
                "provider": options.provider.to_string()
            }),
        )
        .await?;
    write_json(&layout.artifact_dir.join("start.json"), &started).await?;
    manifest.state = "accepted".into();
    write_json(&layout.artifact_dir.join("manifest.json"), &manifest).await?;

    let opened = client
        .call_tool("workflow_open_ui", json!({"run_id": run_id.as_str()}))
        .await?;
    write_json(&layout.artifact_dir.join("open-ui.json"), &opened).await?;
    let ui_url = open_url(&opened)?;
    let browser = match options.open_mode {
        OpenMode::Skip => BrowserOutcome::Skipped,
        OpenMode::Open => match crate::cli::open_url(&ui_url).await {
            Ok(()) => BrowserOutcome::Opened,
            Err(error) => BrowserOutcome::Failed {
                warning: format!("Sandbox created, but the browser could not be opened: {error}"),
            },
        },
    };

    let status = poll_terminal(&mut client, &run_id, options.timeout_seconds).await?;
    write_json(&layout.artifact_dir.join("status.json"), &status).await?;
    let state = workflow_state(&status)?.to_owned();
    let inspected = client
        .call_tool("workflow_inspect", json!({"run_id": run_id.as_str()}))
        .await?;
    write_json(&layout.artifact_dir.join("inspect.json"), &inspected).await?;
    client.close().await?;

    let snapshot = git::snapshot(&layout.worktree).await?;
    write_snapshot(&layout, &snapshot).await?;
    manifest.state.clone_from(&state);
    write_json(&layout.artifact_dir.join("manifest.json"), &manifest).await?;

    if state != "completed" {
        return Err(AppError::new(
            ExitStatus::Unsatisfied,
            "sandbox_workflow_failed",
            format!("The sandbox workflow reached terminal state `{state}`."),
        )
        .details(json!({
            "artifact_dir": layout.artifact_dir,
            "run_id": run_id.as_str(),
            "state": state
        }))
        .next_steps(["Inspect status.json, inspect.json, mcp-transcript.jsonl, and scheduler.log in the sandbox artifact directory."]));
    }

    Ok(RunOutput {
        artifact_dir: layout.artifact_dir,
        worktree: layout.worktree,
        journal: layout.journal,
        transcript: layout.transcript,
        run_id,
        provider: options.provider,
        state,
        ui_url,
        browser,
    })
}

pub async fn clean(options: CleanOptions) -> AppResult<CleanOutput> {
    let artifact_dir = tokio::fs::canonicalize(&options.artifact_dir)
        .await
        .map_err(|error| {
            AppError::new(
                ExitStatus::Usage,
                "sandbox_not_found",
                "The sandbox artifact directory does not exist.",
            )
            .details(json!({"artifact_dir": options.artifact_dir, "reason": error.to_string()}))
        })?;
    let manifest = read_manifest(&artifact_dir.join("manifest.json")).await?;
    validate_manifest(&manifest, &artifact_dir)?;
    let snapshot = git::snapshot(&manifest.worktree).await?;
    if !snapshot.status.trim().is_empty() && matches!(options.mode, CleanMode::PreserveDirty) {
        return Err(AppError::new(
            ExitStatus::Conflict,
            "sandbox_worktree_dirty",
            "The sandbox worktree contains changes and was not removed.",
        )
        .details(json!({
            "artifact_dir": artifact_dir,
            "worktree": manifest.worktree,
            "status": snapshot.status
        }))
        .next_steps([
            "Inspect or preserve the changes, then rerun `sandbox-clean --force` to discard them.",
        ]));
    }
    let scheduler_stopped = stop_scheduler(&manifest, &artifact_dir).await?;
    let remove_mode = match options.mode {
        CleanMode::PreserveDirty => RemoveMode::PreserveDirty,
        CleanMode::Force => RemoveMode::Force,
    };
    git::remove(&manifest.repository, &manifest.worktree, remove_mode).await?;
    let output = CleanOutput {
        artifact_dir: artifact_dir.clone(),
        worktree: manifest.worktree,
        scheduler_stopped,
    };
    tokio::fs::remove_dir_all(&artifact_dir)
        .await
        .map_err(|error| {
            AppError::new(
                ExitStatus::Runtime,
                "sandbox_cleanup_failed",
                "The worktree was removed, but the sandbox artifacts could not be deleted.",
            )
            .details(json!({"artifact_dir": artifact_dir, "reason": error.to_string()}))
        })?;
    Ok(output)
}

fn reserve_port() -> AppResult<u16> {
    let listener = TcpListener::bind(("127.0.0.1", 0)).map_err(|error| {
        AppError::new(
            ExitStatus::Runtime,
            "sandbox_port_unavailable",
            "Could not reserve a loopback port for the sandbox scheduler.",
        )
        .details(json!({"reason": error.to_string()}))
    })?;
    listener
        .local_addr()
        .map(|address| address.port())
        .map_err(|error| {
            AppError::new(
                ExitStatus::Runtime,
                "sandbox_port_unavailable",
                "Could not read the reserved sandbox scheduler port.",
            )
            .details(json!({"reason": error.to_string()}))
        })
}

fn sandbox_run_id(script: &Path) -> AppResult<RunId> {
    let stem = script
        .file_stem()
        .and_then(|value| value.to_str())
        .ok_or_else(|| {
            AppError::new(
                ExitStatus::Usage,
                "sandbox_script_invalid",
                "The sandbox workflow filename must be valid UTF-8.",
            )
            .details(json!({"script_path": script}))
        })?;
    let name: String = stem
        .chars()
        .map(|character| {
            let character = character.to_ascii_lowercase();
            if character.is_ascii_alphanumeric() || matches!(character, '-' | '_') {
                character
            } else {
                '-'
            }
        })
        .collect();
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|error| {
            AppError::new(
                ExitStatus::Runtime,
                "system_clock_invalid",
                "The system clock is earlier than the Unix epoch.",
            )
            .details(json!({"reason": error.to_string()}))
        })?
        .as_nanos();
    RunId::new(format!("sandbox:{}:{nanos:x}", name.trim_matches('-')))
}

fn home_dir() -> AppResult<PathBuf> {
    let home = env::var_os("HOME").ok_or_else(|| {
        AppError::new(
            ExitStatus::Runtime,
            "sandbox_home_missing",
            "HOME must be set to create a sandbox run.",
        )
    })?;
    let home = PathBuf::from(home);
    if home.is_absolute() {
        Ok(home)
    } else {
        Err(AppError::new(
            ExitStatus::Runtime,
            "sandbox_home_invalid",
            "HOME must be absolute to create a sandbox run.",
        )
        .details(json!({"home": home})))
    }
}

fn assert_tool_catalog(tools: &Value) -> AppResult<()> {
    let names = tools
        .get("tools")
        .and_then(Value::as_array)
        .map(|tools| {
            tools
                .iter()
                .filter_map(|tool| tool.get("name").and_then(Value::as_str))
                .collect::<Vec<_>>()
        })
        .ok_or_else(|| {
            AppError::new(
                ExitStatus::Runtime,
                "sandbox_mcp_tools_invalid",
                "The sandbox MCP server returned an invalid tool catalog.",
            )
            .details(tools.clone())
        })?;
    let required = [
        "workflow_validate",
        "workflow_start",
        "workflow_status",
        "workflow_inspect",
        "workflow_open_ui",
    ];
    if required.iter().all(|required| names.contains(required)) {
        Ok(())
    } else {
        Err(AppError::new(
            ExitStatus::Runtime,
            "sandbox_mcp_tools_invalid",
            "The sandbox MCP server did not advertise the required workflow tools.",
        )
        .details(json!({"required": required, "found": names})))
    }
}

async fn poll_terminal(
    client: &mut McpClient,
    run_id: &RunId,
    timeout_seconds: NonZeroU64,
) -> AppResult<Value> {
    let deadline = Instant::now() + Duration::from_secs(timeout_seconds.get());
    loop {
        let status = client
            .call_tool("workflow_status", json!({"run_id": run_id.as_str()}))
            .await?;
        match workflow_state(&status)? {
            "completed" | "failed" | "cancelled" | "outcome_unknown" => return Ok(status),
            "accepted" | "pending" | "running" => {}
            state => {
                return Err(AppError::new(
                    ExitStatus::Runtime,
                    "sandbox_workflow_state_invalid",
                    "The sandbox scheduler returned an unknown workflow state.",
                )
                .details(json!({"state": state, "status": status})));
            }
        }
        if Instant::now() >= deadline {
            return Err(AppError::new(
                ExitStatus::Unsatisfied,
                "sandbox_workflow_timeout",
                "The sandbox workflow did not reach a terminal state before the timeout.",
            )
            .details(json!({
                "run_id": run_id.as_str(),
                "timeout_seconds": timeout_seconds.get(),
                "last_status": status
            })));
        }
        sleep(Duration::from_secs(1)).await;
    }
}

fn workflow_state(status: &Value) -> AppResult<&str> {
    status
        .pointer("/data/state")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            AppError::new(
                ExitStatus::Runtime,
                "sandbox_workflow_status_invalid",
                "The sandbox workflow status contained no state.",
            )
            .details(status.clone())
        })
}

fn open_url(opened: &Value) -> AppResult<Url> {
    let raw = opened
        .pointer("/data/open_url")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            AppError::new(
                ExitStatus::Runtime,
                "sandbox_open_ui_invalid",
                "The sandbox MCP open-UI response contained no URL.",
            )
            .details(opened.clone())
        })?;
    Url::parse(raw).map_err(|error| {
        AppError::new(
            ExitStatus::Runtime,
            "sandbox_open_ui_invalid",
            "The sandbox MCP open-UI response contained an invalid URL.",
        )
        .details(json!({"url": raw, "reason": error.to_string()}))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generated_sandbox_run_ids_are_route_safe() -> AppResult<()> {
        let run_id = sandbox_run_id(Path::new("Review workflow!.exs"))?;
        assert!(run_id.as_str().starts_with("sandbox:review-workflow:"));
        Ok(())
    }

    #[test]
    fn sandbox_requires_the_complete_mcp_tool_catalog() {
        let complete = json!({
            "tools": [
                {"name": "workflow_validate"},
                {"name": "workflow_start"},
                {"name": "workflow_status"},
                {"name": "workflow_inspect"},
                {"name": "workflow_open_ui"}
            ]
        });
        assert!(assert_tool_catalog(&complete).is_ok());

        let incomplete = json!({"tools": [{"name": "workflow_status"}]});
        let error = assert_tool_catalog(&incomplete);
        assert!(matches!(error, Err(error) if error.code() == "sandbox_mcp_tools_invalid"));
    }
}
