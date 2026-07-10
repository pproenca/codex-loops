use std::{
    net::{IpAddr, SocketAddr, TcpListener},
    path::PathBuf,
    process::Command,
    sync::atomic::{AtomicU64, Ordering},
    time::{SystemTime, UNIX_EPOCH},
};

use anyhow::Context;
use serde_json::{Value, json};

use crate::{
    error::{CliError, CliResult, ErrorContext},
    install,
    lifecycle::{self, StartOptions, StopMode},
    runtime::Runtime,
    scheduler::{HealthState, ResumeRequest, RunId, SchedulerClient, StartRequest, local_url},
};

type AppError = CliError;
type AppResult<T> = CliResult<T>;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OpenMode {
    Skip,
    Open,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ServeMode {
    Background,
    Foreground,
}

struct LocalTarget {
    host: String,
    port: u16,
    client: SchedulerClient,
}

pub async fn run_workflow(
    script: PathBuf,
    provider: String,
    run_id: Option<String>,
    server: Option<String>,
    open_mode: OpenMode,
) -> AppResult<Value> {
    let script = resolve_script(&script)?;
    let client = match server {
        Some(server) => SchedulerClient::new(&server)?,
        None => SchedulerClient::from_env()?,
    };
    require_shared_filesystem(&client)?;
    let scheduler_started = lifecycle::ensure_ready(&client).await?;
    let script_path = script.to_string_lossy();
    client.validate(&script_path).await?;
    let run_id = RunId::new(run_id.unwrap_or_else(|| default_run_id(&script)))?;
    let started = client
        .start(&StartRequest {
            script_path: script_path.into_owned(),
            run_id: Some(run_id.clone()),
            provider: Some(provider.clone()),
            budget: None,
        })
        .await?;
    let ui_url = client.ui_url(&run_id);
    let mut warning = Value::Null;
    let mut opened = false;
    if open_mode == OpenMode::Open {
        match open_url(&ui_url) {
            Ok(()) => opened = true,
            Err(error) => {
                warning = Value::String(format!(
                    "Run started, but the browser could not be opened: {error}"
                ))
            }
        }
    }
    Ok(json!({
        "ok": true, "command": "run", "script_path": script, "workflow_name": started.data.workflow_name,
        "run_id": run_id, "provider": provider, "state": started.data.state, "ui_url": ui_url,
        "opened": opened, "warning": warning, "scheduler_started": scheduler_started,
        "server_url": client.base_url().as_str()
    }))
}

pub async fn serve(
    host: Option<String>,
    port: Option<u16>,
    journal: Option<String>,
    model: Option<String>,
    serve_mode: ServeMode,
) -> AppResult<Value> {
    let LocalTarget { host, port, client } = local_target(host, port)?;
    validate_bind_host(&host)?;
    let options = StartOptions {
        bind_host: Some(host.clone()),
        journal: option_or_env(journal, "CODEX_LOOPS_JOURNAL_PATH")
            .map(resolve_output_path)
            .transpose()?,
        model: option_or_env(model, "CODEX_LOOPS_CODEX_MODEL"),
    };
    if serve_mode == ServeMode::Foreground {
        if matches!(client.health_state().await, HealthState::Compatible(_)) {
            return Err(AppError::new(
                2,
                "scheduler_already_running",
                "Codex Loops is already running; stop it before using --foreground.",
            ));
        }
        eprintln!(
            "Codex Loops foreground scheduler starting at {}",
            client.base_url()
        );
        lifecycle::run_foreground(client.clone(), options).await?;
        return Ok(json!({
            "ok": true, "command": "serve", "server_url": client.base_url().as_str(),
            "host": host, "port": port, "state": "stopped", "started": true,
            "foreground": true
        }));
    }
    let started = lifecycle::ensure_ready_with(&client, &options).await?;
    Ok(
        json!({"ok": true, "command": "serve", "server_url": client.base_url().as_str(), "host": host, "port": port, "state": "running", "started": started}),
    )
}

pub async fn restart(
    host: Option<String>,
    port: Option<u16>,
    journal: Option<String>,
    model: Option<String>,
) -> AppResult<Value> {
    let inherit_bind = host.is_none()
        && std::env::var("CODEX_LOOPS_SCHEDULER_HOST")
            .ok()
            .filter(|value| !value.is_empty())
            .is_none();
    let LocalTarget { host, port, client } = local_target(host, port)?;
    validate_bind_host(&host)?;
    let previous = lifecycle::configuration(&client)?.unwrap_or_default();
    let stopped = lifecycle::stop(&client, StopMode::Graceful).await?;
    let options = StartOptions {
        bind_host: if inherit_bind {
            previous.bind_host.or_else(|| Some(host.clone()))
        } else {
            Some(host.clone())
        },
        journal: match option_or_env(journal, "CODEX_LOOPS_JOURNAL_PATH") {
            Some(journal) => Some(resolve_output_path(journal)?),
            None => previous.journal,
        },
        model: option_or_env(model, "CODEX_LOOPS_CODEX_MODEL").or(previous.model),
    };
    lifecycle::ensure_ready_with(&client, &options).await?;
    Ok(json!({
        "ok": true, "command": "restart", "server_url": client.base_url().as_str(),
        "host": options.bind_host, "port": port, "state": "running", "stopped": stopped,
        "started": true
    }))
}

pub fn logs(
    server: Option<String>,
    host: Option<String>,
    port: Option<u16>,
    lines: usize,
) -> AppResult<Value> {
    let client = match server {
        Some(server) => SchedulerClient::new(&server)?,
        None if host.is_none()
            && port.is_none()
            && std::env::var("CODEX_LOOPS_SCHEDULER_URL").is_ok() =>
        {
            SchedulerClient::from_env()?
        }
        None => local_target(host, port)?.client,
    };
    let output = lifecycle::read_logs(&client, lines)?;
    Ok(json!({
        "ok": true, "command": "logs", "server_url": client.base_url().as_str(),
        "lines": lines, "output": output
    }))
}

pub async fn stop(
    server: Option<String>,
    host: Option<String>,
    port: Option<u16>,
    mode: StopMode,
) -> AppResult<Value> {
    let client = match server {
        Some(server) => SchedulerClient::new(&server)?,
        None if host.is_none()
            && port.is_none()
            && std::env::var("CODEX_LOOPS_SCHEDULER_URL").is_ok() =>
        {
            SchedulerClient::from_env()?
        }
        None => local_target(host, port)?.client,
    };
    let stopped = lifecycle::stop(&client, mode).await?;
    Ok(
        json!({"ok": true, "command": "stop", "server_url": client.base_url().as_str(), "state": "stopped", "stopped": stopped}),
    )
}

pub async fn status(run_id: String, server: Option<String>) -> AppResult<Value> {
    let run_id = RunId::new(run_id)?;
    let client = client(server)?;
    lifecycle::ensure_ready(&client).await?;
    Ok(client.status(&run_id).await?.into_wire_value()?)
}

pub async fn inspect(run_id: String, server: Option<String>) -> AppResult<Value> {
    let run_id = RunId::new(run_id)?;
    let client = client(server)?;
    lifecycle::ensure_ready(&client).await?;
    Ok(client.inspect(&run_id).await?.into_wire_value()?)
}

pub async fn resume(
    run_id: String,
    script: Option<PathBuf>,
    provider: String,
    server: Option<String>,
) -> AppResult<Value> {
    let run_id = RunId::new(run_id)?;
    let client = client(server)?;
    if script.is_some() {
        require_shared_filesystem(&client)?;
    }
    lifecycle::ensure_ready(&client).await?;
    let script = script.map(|path| resolve_script(&path)).transpose()?;
    let request = ResumeRequest {
        script_path: script.map(|path| path.to_string_lossy().into_owned()),
        provider: Some(provider),
    };
    Ok(client.resume(&run_id, &request).await?.into_wire_value()?)
}

pub async fn open(run_id: String, server: Option<String>) -> AppResult<Value> {
    let run_id = RunId::new(run_id)?;
    let client = client(server)?;
    lifecycle::ensure_ready(&client).await?;
    client.status(&run_id).await?;
    let url = client.ui_url(&run_id);
    open_url(&url)?;
    Ok(json!({"ok": true, "command": "open", "run_id": run_id, "ui_url": url, "opened": true}))
}

pub async fn doctor() -> AppResult<Value> {
    let client = SchedulerClient::from_env()?;
    let runtime = Runtime::installed()?;
    let scheduler = &runtime.bundle.scheduler;
    match client.health_state().await {
        HealthState::Compatible(health) => Ok(json!({
            "ok": true, "command": "doctor", "version": env!("CARGO_PKG_VERSION"),
            "scheduler_bin": scheduler, "scheduler_url": client.base_url().as_str(),
            "scheduler_state": "running", "scheduler_health": health,
            "runtime_root": runtime.bundle.root,
            "codex": {"path": runtime.codex.path, "version": runtime.codex.version}
        })),
        HealthState::Incompatible { found, envelope } => Err(AppError::new(
            6,
            "scheduler_version_mismatch",
            format!("A scheduler from another Codex Loops version is running: {found}."),
        )
        .details(json!({"expected": env!("CARGO_PKG_VERSION"), "found": found, "health": envelope}))),
        HealthState::Unreachable { reason } => Err(AppError::new(
            1,
            "scheduler_stopped",
            "Codex Loops is installed, but the scheduler is not running.",
        )
        .details(json!({"scheduler_bin": scheduler, "scheduler_url": client.base_url().as_str(), "reason": reason}))
        .next_steps(["Run `codex-loops serve` or start a workflow."])),
    }
}

pub fn install(options: install::Options) -> AppResult<Value> {
    Ok(install::run(options)?)
}

fn default_run_id(script: &std::path::Path) -> String {
    static COUNTER: AtomicU64 = AtomicU64::new(0);

    let base = script
        .file_stem()
        .and_then(|value| value.to_str())
        .unwrap_or("run");
    let name: String = base
        .to_ascii_lowercase()
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || matches!(character, '-' | '_') {
                character
            } else {
                '-'
            }
        })
        .collect();
    let name = name.trim_matches('-');
    let name = if name.is_empty() { "run" } else { name };
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let pid = std::process::id();
    let sequence = COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("{name}-{nanos:x}-{pid:x}-{sequence:x}")
}

fn client(server: Option<String>) -> AppResult<SchedulerClient> {
    Ok(match server {
        Some(server) => SchedulerClient::new(&server),
        None => SchedulerClient::from_env(),
    }?)
}

fn local_target(host: Option<String>, port: Option<u16>) -> AppResult<LocalTarget> {
    let host = host
        .or_else(|| std::env::var("CODEX_LOOPS_SCHEDULER_HOST").ok())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "127.0.0.1".into());
    let port = match port {
        Some(port) => port,
        None => std::env::var("CODEX_LOOPS_SCHEDULER_PORT")
            .ok()
            .filter(|value| !value.is_empty())
            .map(|value| {
                value.parse::<u16>().map_err(|error| {
                    AppError::new(
                        2,
                        "scheduler_port_invalid",
                        "CODEX_LOOPS_SCHEDULER_PORT must be a valid TCP port.",
                    )
                    .details(json!({"value": value, "reason": error.to_string()}))
                })
            })
            .transpose()?
            .unwrap_or(47_125),
    };
    let connect_host = if host == "0.0.0.0" {
        "127.0.0.1"
    } else if host == "::" {
        "::1"
    } else {
        host.as_str()
    };
    let client = SchedulerClient::managed(&local_url(connect_host, port))?;
    Ok(LocalTarget { host, port, client })
}

fn option_or_env(value: Option<String>, key: &str) -> Option<String> {
    value.or_else(|| std::env::var(key).ok().filter(|value| !value.is_empty()))
}

fn validate_bind_host(host: &str) -> AppResult<()> {
    let ip = if host == "localhost" {
        IpAddr::from([127, 0, 0, 1])
    } else {
        host.parse::<IpAddr>().map_err(|error| {
            AppError::new(
                2,
                "bind_host_invalid",
                "--host must be an IPv4/IPv6 address or localhost.",
            )
            .details(json!({"host": host, "reason": error.to_string()}))
        })?
    };
    TcpListener::bind(SocketAddr::new(ip, 0))
        .map(drop)
        .map_err(|error| {
            AppError::new(
                2,
                "bind_host_unavailable",
                "--host is not an address assigned to this machine.",
            )
            .details(json!({"host": host, "reason": error.to_string()}))
        })
}

fn open_url(url: &str) -> AppResult<()> {
    let command = std::env::var("CODEX_LOOPS_OPEN_BIN").unwrap_or_else(|_| {
        if cfg!(target_os = "macos") {
            "open".into()
        } else {
            "xdg-open".into()
        }
    });
    let status = Command::new(&command)
        .arg(url)
        .status()
        .with_context(|| format!("{command} was not found on PATH"))
        .map_err(AppError::from)?;
    if !status.success() {
        return Err(AppError::new(
            6,
            "open_failed",
            format!("{command} exited with {status}"),
        ));
    }
    Ok(())
}

pub fn resolve_script(path: &std::path::Path) -> AppResult<PathBuf> {
    resolve_script_from(path, None)
}

pub fn resolve_script_from(
    path: &std::path::Path,
    workspace_root: Option<&std::path::Path>,
) -> AppResult<PathBuf> {
    let candidate = if path.is_absolute() {
        path.to_path_buf()
    } else if let Some(root) = workspace_root {
        root.join(path)
    } else {
        path.to_path_buf()
    };
    let path = candidate.canonicalize().map_err(|error| {
        AppError::new(
            2,
            "script_not_found",
            format!("Workflow script does not exist: {}", candidate.display()),
        )
        .details(json!({"script_path": candidate, "reason": error.to_string()}))
    })?;
    if path.is_file() {
        Ok(path)
    } else {
        Err(AppError::new(
            2,
            "script_not_found",
            format!("Workflow script does not exist: {}", path.display()),
        ))
    }
}

fn resolve_output_path(path: String) -> AppResult<String> {
    let path = PathBuf::from(path);
    let absolute = if path.is_absolute() {
        path
    } else {
        std::env::current_dir()
            .map_err(|error| AppError::new(6, "working_directory_invalid", error.to_string()))?
            .join(path)
    };
    Ok(absolute.to_string_lossy().into_owned())
}

pub fn require_shared_filesystem(client: &SchedulerClient) -> AppResult<()> {
    if client.is_local() || std::env::var("CODEX_LOOPS_SHARED_FILESYSTEM").as_deref() == Ok("1") {
        Ok(())
    } else {
        Err(AppError::new(
            2,
            "remote_scheduler_requires_shared_filesystem",
            "Workflow paths can be sent to a remote scheduler only when both processes share the same filesystem.",
        )
        .details(json!({"server": client.base_url().as_str()}))
        .next_steps(["Set CODEX_LOOPS_SHARED_FILESYSTEM=1 only when absolute paths are shared."]))
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use super::*;

    #[test]
    fn generated_run_ids_are_route_safe_and_named_for_the_script() {
        let id = default_run_id(std::path::Path::new("My workflow!.exs"));
        assert!(id.starts_with("my-workflow-"));
        assert!(
            id.chars().all(
                |character| character.is_ascii_alphanumeric() || matches!(character, '-' | '_')
            )
        );
    }

    #[test]
    fn generated_run_ids_are_unique_within_one_process_burst() {
        let ids: BTreeSet<_> = (0..1_024)
            .map(|_| default_run_id(std::path::Path::new("burst.exs")))
            .collect();

        assert_eq!(ids.len(), 1_024);
    }

    #[test]
    fn relative_scripts_can_be_resolved_from_an_mcp_workspace_root() {
        let root = tempfile::tempdir().unwrap();
        let directory = root.path().join(".codex/workflows");
        std::fs::create_dir_all(&directory).unwrap();
        let script = directory.join("review.exs");
        std::fs::write(&script, "use Workflow").unwrap();
        assert_eq!(
            resolve_script_from(
                std::path::Path::new(".codex/workflows/review.exs"),
                Some(root.path())
            )
            .unwrap(),
            script.canonicalize().unwrap()
        );
    }
}
