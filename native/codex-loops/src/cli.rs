mod output;
mod script;

pub use output::{
    BrowserOutcome, CliOutput, DoctorCodex, DoctorOutput, LogsOutput, OpenOutput, RestartOutput,
    RunOutput, RunState, ServeDisposition, ServeOutput, StopOutput,
};
pub use script::ResolvedWorkflowScript;

use std::{
    num::{NonZeroU16, NonZeroU64},
    path::{Path, PathBuf},
    process::Stdio,
    sync::atomic::{AtomicU64, Ordering},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use serde_json::json;
use tokio::{process::Command, time::timeout};

use crate::{
    error::{AppError, AppResult, ExitStatus},
    install,
    lifecycle::{self, AbsolutePath, BindHost, SchedulerConfig, StartOptions, StopMode},
    runtime::Runtime,
    scheduler::{
        HealthState, Provider, ResumeRequest, RunId, SchedulerClient, StartRequest, local_url,
    },
};

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

pub struct RunOptions {
    pub script: PathBuf,
    pub provider: Provider,
    pub run_id: Option<RunId>,
    pub server: Option<String>,
    pub open_mode: OpenMode,
}

pub struct ServeOptions {
    pub host: Option<BindHost>,
    pub port: Option<NonZeroU16>,
    pub journal: Option<PathBuf>,
    pub model: Option<String>,
    pub mode: ServeMode,
}

pub struct StopOptions {
    pub endpoint: Endpoint,
    pub mode: StopMode,
}

pub struct RestartOptions {
    pub host: Option<BindHost>,
    pub port: Option<NonZeroU16>,
    pub journal: Option<PathBuf>,
    pub model: Option<String>,
}

pub struct LogsOptions {
    pub endpoint: Endpoint,
    pub lines: usize,
}

pub enum Endpoint {
    Environment,
    Server(String),
    Local {
        host: Option<BindHost>,
        port: Option<NonZeroU16>,
    },
}

pub struct ResumeOptions {
    pub run_id: RunId,
    pub script: Option<PathBuf>,
    pub provider: Provider,
    pub server: Option<String>,
}

#[derive(Clone, Copy)]
enum BindSource {
    Default,
    Override,
}

struct LocalTarget {
    host: BindHost,
    port: NonZeroU16,
    client: SchedulerClient,
    bind_source: BindSource,
}

pub async fn run_workflow(options: RunOptions) -> AppResult<CliOutput> {
    let script = ResolvedWorkflowScript::resolve(&options.script).await?;
    let client = client(options.server)?;
    require_shared_filesystem(&client)?;
    let scheduler = lifecycle::ensure_ready(&client).await?;
    client.validate(script.as_str()).await?;
    let run_id = match options.run_id {
        Some(run_id) => run_id,
        None => default_run_id(script.as_path())?,
    };
    let request = StartRequest {
        script_path: script.into_string(),
        run_id: Some(run_id),
        provider: Some(options.provider),
        budget: None,
    };
    let started = client.start(&request).await?;
    let StartRequest {
        script_path,
        run_id: Some(run_id),
        provider: Some(provider),
        ..
    } = request
    else {
        return Err(cli_invariant(
            "A CLI start request lost its required fields.",
        ));
    };
    let ui_url = client.ui_url(&run_id);
    let browser = match options.open_mode {
        OpenMode::Skip => BrowserOutcome::Skipped,
        OpenMode::Open => match open_url(&ui_url).await {
            Ok(()) => BrowserOutcome::Opened,
            Err(error) => BrowserOutcome::Failed {
                warning: format!("Run started, but the browser could not be opened: {error}"),
            },
        },
    };
    Ok(CliOutput::Run(RunOutput {
        script_path: PathBuf::from(script_path),
        workflow_name: started.data.workflow_name,
        run_id,
        provider,
        state: started.data.state.map(RunState::try_from).transpose()?,
        ui_url,
        browser,
        scheduler,
        server_url: client.base_url().clone(),
    }))
}

pub async fn serve(options: ServeOptions) -> AppResult<CliOutput> {
    let LocalTarget {
        host,
        port,
        client,
        bind_source: _,
    } = local_target(options.host, options.port)?;
    host.validate_available().await?;
    let start_options = StartOptions {
        bind_host: Some(host),
        journal: requested_journal(options.journal).await?,
        model: requested_model(options.model)?,
    };
    let server_url = client.base_url().clone();
    match options.mode {
        ServeMode::Foreground => {
            match client.health_state().await {
                HealthState::Compatible(_) => {
                    return Err(AppError::new(
                        ExitStatus::Usage,
                        "scheduler_already_running",
                        "Codex Loops is already running; stop it before using --foreground.",
                    ));
                }
                HealthState::Incompatible { found, envelope } => {
                    return Err(incompatible_scheduler(found, envelope));
                }
                HealthState::Unreachable { .. } => {}
            }
            eprintln!("Codex Loops foreground scheduler starting at {server_url}");
            let host = start_options
                .bind_host
                .as_ref()
                .ok_or_else(|| cli_invariant("Foreground serve has no bind host."))?
                .clone();
            lifecycle::run_foreground(client, start_options).await?;
            Ok(CliOutput::Serve(ServeOutput {
                server_url,
                host,
                port,
                disposition: ServeDisposition::ForegroundStopped,
            }))
        }
        ServeMode::Background => {
            let disposition = lifecycle::ensure_ready_with(&client, &start_options).await?;
            let StartOptions {
                bind_host: Some(host),
                ..
            } = start_options
            else {
                return Err(cli_invariant("Background serve has no bind host."));
            };
            Ok(CliOutput::Serve(ServeOutput {
                server_url,
                host,
                port,
                disposition: ServeDisposition::Background(disposition),
            }))
        }
    }
}

pub async fn restart(options: RestartOptions) -> AppResult<CliOutput> {
    let LocalTarget {
        host,
        port,
        client,
        bind_source,
    } = local_target(options.host, options.port)?;
    let active = lifecycle::configuration(&client).await?;
    let (active_host, active_journal, active_model) = match active {
        Some(SchedulerConfig {
            bind_host,
            journal,
            model,
        }) => (Some(bind_host), journal, model),
        None => (None, None, None),
    };
    let bind_host = match bind_source {
        BindSource::Override => host,
        BindSource::Default => active_host.unwrap_or(host),
    };
    let journal = match requested_journal(options.journal).await? {
        Some(journal) => Some(journal),
        None => active_journal,
    };
    let model = requested_model(options.model)?.or(active_model);
    bind_host.validate_available().await?;
    let start_options = StartOptions {
        bind_host: Some(bind_host),
        journal,
        model,
    };
    let previous = lifecycle::stop(&client, StopMode::Graceful).await?;
    lifecycle::ensure_ready_with(&client, &start_options).await?;
    let StartOptions {
        bind_host: Some(host),
        ..
    } = start_options
    else {
        return Err(cli_invariant("Restart has no bind host."));
    };
    Ok(CliOutput::Restart(RestartOutput {
        server_url: client.base_url().clone(),
        host,
        port,
        previous,
    }))
}

pub async fn logs(options: LogsOptions) -> AppResult<CliOutput> {
    let client = endpoint(options.endpoint)?;
    let output = lifecycle::read_logs(&client, options.lines).await?;
    Ok(CliOutput::Logs(LogsOutput {
        server_url: client.base_url().clone(),
        requested_lines: options.lines,
        output,
    }))
}

pub async fn stop(options: StopOptions) -> AppResult<CliOutput> {
    let client = endpoint(options.endpoint)?;
    let disposition = lifecycle::stop(&client, options.mode).await?;
    Ok(CliOutput::Stop(StopOutput {
        server_url: client.base_url().clone(),
        disposition,
    }))
}

pub async fn status(run_id: RunId, server: Option<String>) -> AppResult<CliOutput> {
    let client = client(server)?;
    lifecycle::ensure_ready(&client).await?;
    Ok(CliOutput::Scheduler(
        client.status(&run_id).await?.into_wire_value()?,
    ))
}

pub async fn inspect(run_id: RunId, server: Option<String>) -> AppResult<CliOutput> {
    let client = client(server)?;
    lifecycle::ensure_ready(&client).await?;
    Ok(CliOutput::Scheduler(
        client.inspect(&run_id).await?.into_wire_value()?,
    ))
}

pub async fn resume(options: ResumeOptions) -> AppResult<CliOutput> {
    let client = client(options.server)?;
    if options.script.is_some() {
        require_shared_filesystem(&client)?;
    }
    let script = match options.script {
        Some(path) => Some(ResolvedWorkflowScript::resolve(&path).await?),
        None => None,
    };
    lifecycle::ensure_ready(&client).await?;
    let request = ResumeRequest {
        script_path: script.map(ResolvedWorkflowScript::into_string),
        provider: Some(options.provider),
    };
    Ok(CliOutput::Scheduler(
        client
            .resume(&options.run_id, &request)
            .await?
            .into_wire_value()?,
    ))
}

pub async fn open(run_id: RunId, server: Option<String>) -> AppResult<CliOutput> {
    let client = client(server)?;
    lifecycle::ensure_ready(&client).await?;
    client.status(&run_id).await?;
    let ui_url = client.ui_url(&run_id);
    open_url(&ui_url).await?;
    Ok(CliOutput::Open(OpenOutput { run_id, ui_url }))
}

pub async fn doctor() -> AppResult<CliOutput> {
    let client = SchedulerClient::from_env()?;
    let runtime = blocking("inspect the installed runtime", Runtime::installed).await?;
    let Runtime { bundle, codex } = runtime;
    let scheduler_bin = bundle.scheduler();
    let runtime_root = bundle.into_root();
    let crate::runtime::CodexBinding {
        path: codex_path,
        version: codex_version,
    } = codex;
    match client.health_state().await {
        HealthState::Compatible(scheduler_health) => Ok(CliOutput::Doctor(DoctorOutput {
            scheduler_bin,
            scheduler_url: client.base_url().clone(),
            scheduler_health,
            runtime_root,
            codex: DoctorCodex {
                path: codex_path,
                version: codex_version,
            },
        })),
        HealthState::Incompatible { found, envelope } => {
            Err(incompatible_scheduler(found, envelope))
        }
        HealthState::Unreachable { reason } => Err(AppError::new(
            ExitStatus::Unsatisfied,
            "scheduler_stopped",
            "Codex Loops is installed, but the scheduler is not running.",
        )
        .details(json!({
            "scheduler_bin": scheduler_bin,
            "scheduler_url": client.base_url().as_str(),
            "reason": reason
        }))
        .next_steps(["Run `codex-loops serve` or start a workflow."])),
    }
}

pub async fn install(options: install::Options) -> AppResult<CliOutput> {
    blocking("install Codex Loops", move || install::run(options))
        .await
        .map(CliOutput::Install)
}

fn default_run_id(script: &Path) -> AppResult<RunId> {
    static COUNTER: AtomicU64 = AtomicU64::new(0);

    let base = script
        .file_stem()
        .and_then(|value| value.to_str())
        .ok_or_else(|| {
            AppError::new(
                ExitStatus::Usage,
                "script_path_invalid",
                "Workflow script name must be valid UTF-8.",
            )
            .details(json!({"script_path": script}))
        })?;
    let normalized: String = base
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
    let name = normalized.trim_matches('-');
    let name = if name.is_empty() { "run" } else { name };
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
    RunId::new(format!(
        "{name}-{nanos:x}-{:x}-{:x}",
        std::process::id(),
        COUNTER.fetch_add(1, Ordering::Relaxed)
    ))
}

fn client(server: Option<String>) -> AppResult<SchedulerClient> {
    match server {
        Some(server) => SchedulerClient::new(&server),
        None => SchedulerClient::from_env(),
    }
}

fn local_target(
    explicit_host: Option<BindHost>,
    explicit_port: Option<NonZeroU16>,
) -> AppResult<LocalTarget> {
    let (host, bind_source) = match explicit_host {
        Some(host) => (host, BindSource::Override),
        None => match optional_env("CODEX_LOOPS_SCHEDULER_HOST")? {
            Some(host) => (host.parse()?, BindSource::Override),
            None => ("127.0.0.1".parse()?, BindSource::Default),
        },
    };
    let port = match explicit_port {
        Some(port) => port,
        None => match optional_env("CODEX_LOOPS_SCHEDULER_PORT")? {
            Some(port) => parse_port(&port)?,
            None => NonZeroU16::new(47_125)
                .ok_or_else(|| cli_invariant("The default scheduler port is zero."))?,
        },
    };
    let client = SchedulerClient::managed(&local_url(host.connect_host(), port))?;
    Ok(LocalTarget {
        host,
        port,
        client,
        bind_source,
    })
}

fn endpoint(endpoint: Endpoint) -> AppResult<SchedulerClient> {
    match endpoint {
        Endpoint::Environment => SchedulerClient::from_env(),
        Endpoint::Server(server) => SchedulerClient::new(&server),
        Endpoint::Local { host, port } => local_target(host, port).map(|target| target.client),
    }
}

async fn requested_journal(explicit: Option<PathBuf>) -> AppResult<Option<AbsolutePath>> {
    let path = match explicit {
        Some(path) => Some(path),
        None => optional_env("CODEX_LOOPS_JOURNAL_PATH")?.map(PathBuf::from),
    };
    match path {
        Some(path) => AbsolutePath::resolve(path).await.map(Some),
        None => Ok(None),
    }
}

fn requested_model(explicit: Option<String>) -> AppResult<Option<String>> {
    match explicit {
        Some(model) => Ok(Some(model)),
        None => optional_env("CODEX_LOOPS_CODEX_MODEL"),
    }
}

fn parse_port(port: &str) -> AppResult<NonZeroU16> {
    port.parse::<NonZeroU16>().map_err(|error| {
        AppError::new(
            ExitStatus::Usage,
            "scheduler_port_invalid",
            "CODEX_LOOPS_SCHEDULER_PORT must be a valid nonzero TCP port.",
        )
        .details(json!({"value": port, "reason": error.to_string()}))
    })
}

async fn open_url(url: &url::Url) -> AppResult<()> {
    let (program, prefix): (String, &'static [&'static str]) =
        match optional_env("CODEX_LOOPS_OPEN_BIN")? {
            Some(program) => (program, &[]),
            None if cfg!(target_os = "macos") => ("open".into(), &[]),
            None if cfg!(target_os = "windows") => {
                ("rundll32".into(), &["url.dll,FileProtocolHandler"])
            }
            None => ("xdg-open".into(), &[]),
        };
    let timeout_ms = match optional_env("CODEX_LOOPS_OPEN_TIMEOUT_MS")? {
        Some(value) => value.parse::<NonZeroU64>().map_err(|error| {
            AppError::new(
                ExitStatus::Usage,
                "open_timeout_invalid",
                "CODEX_LOOPS_OPEN_TIMEOUT_MS must be a positive integer.",
            )
            .details(json!({"value": value, "reason": error.to_string()}))
        })?,
        None => NonZeroU64::new(10_000)
            .ok_or_else(|| cli_invariant("The default browser timeout is zero."))?,
    };
    let mut command = Command::new(&program);
    command
        .args(prefix)
        .arg(url.as_str())
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    let mut child = command.spawn().map_err(|error| {
        AppError::new(
            ExitStatus::Command,
            "open_failed",
            format!("Could not start browser opener `{program}`."),
        )
        .details(json!({"program": program, "reason": error.to_string()}))
    })?;
    let status = match timeout(Duration::from_millis(timeout_ms.get()), child.wait()).await {
        Ok(status) => status.map_err(|error| {
            AppError::new(
                ExitStatus::Command,
                "open_failed",
                "Could not wait for the browser opener.",
            )
            .details(json!({"program": program, "reason": error.to_string()}))
        })?,
        Err(_elapsed) => {
            let cleanup_error = child.kill().await.err().map(|error| error.to_string());
            return Err(AppError::new(
                ExitStatus::Command,
                "open_timeout",
                "The browser opener did not exit before the timeout.",
            )
            .details(json!({
                "program": program,
                "timeout_ms": timeout_ms,
                "cleanup_error": cleanup_error
            })));
        }
    };
    if status.success() {
        Ok(())
    } else {
        Err(AppError::new(
            ExitStatus::Command,
            "open_failed",
            format!("Browser opener `{program}` exited with {status}."),
        ))
    }
}

pub fn require_shared_filesystem(client: &SchedulerClient) -> AppResult<()> {
    let shared = optional_env("CODEX_LOOPS_SHARED_FILESYSTEM")?;
    if client.is_local() || shared.as_deref() == Some("1") {
        Ok(())
    } else {
        Err(AppError::new(
            ExitStatus::Usage,
            "remote_scheduler_requires_shared_filesystem",
            "Workflow paths can be sent to a remote scheduler only when both processes share the same filesystem.",
        )
        .details(json!({"server": client.base_url().as_str()}))
        .next_steps(["Set CODEX_LOOPS_SHARED_FILESYSTEM=1 only when absolute paths are shared."]))
    }
}

fn optional_env(key: &'static str) -> AppResult<Option<String>> {
    match std::env::var(key) {
        Ok(value) if value.is_empty() => Ok(None),
        Ok(value) => Ok(Some(value)),
        Err(std::env::VarError::NotPresent) => Ok(None),
        Err(std::env::VarError::NotUnicode(value)) => Err(AppError::new(
            ExitStatus::Usage,
            "environment_invalid",
            format!("{key} must be valid UTF-8."),
        )
        .details(json!({"value": value.to_string_lossy()}))),
    }
}

fn incompatible_scheduler(found: Option<String>, envelope: serde_json::Value) -> AppError {
    let message = match found.as_deref() {
        Some(found) => format!("A scheduler from another Codex Loops version is running: {found}."),
        None => "The configured endpoint is not a compatible Codex Loops scheduler.".into(),
    };
    AppError::new(ExitStatus::Runtime, "scheduler_version_mismatch", message).details(json!({
        "expected": env!("CARGO_PKG_VERSION"),
        "found": found,
        "health": envelope
    }))
}

fn cli_invariant(message: &'static str) -> AppError {
    AppError::new(ExitStatus::Runtime, "cli_invariant", message)
}

async fn blocking<T, F>(operation: &'static str, task: F) -> AppResult<T>
where
    T: Send + 'static,
    F: FnOnce() -> AppResult<T> + Send + 'static,
{
    tokio::task::spawn_blocking(task).await.map_err(|error| {
        AppError::new(
            ExitStatus::Runtime,
            "cli_blocking_task_failed",
            format!("Could not {operation}."),
        )
        .details(json!({"reason": error.to_string()}))
    })?
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use super::*;

    #[test]
    fn generated_run_ids_are_route_safe_and_named_for_the_script() -> AppResult<()> {
        let id = default_run_id(Path::new("My workflow!.exs"))?;
        assert!(id.as_str().starts_with("my-workflow-"));
        assert!(id.as_str().chars().all(|character| {
            character.is_ascii_alphanumeric() || matches!(character, '-' | '_')
        }));
        Ok(())
    }

    #[test]
    fn generated_run_ids_are_unique_within_one_process_burst() -> AppResult<()> {
        let ids = (0..1_024)
            .map(|_| default_run_id(Path::new("burst.exs")).map(|id| id.as_str().to_owned()))
            .collect::<AppResult<BTreeSet<_>>>()?;

        assert_eq!(ids.len(), 1_024);
        Ok(())
    }

    #[tokio::test]
    async fn relative_scripts_resolve_from_an_mcp_workspace_root() -> AppResult<()> {
        let root = tempfile::tempdir().map_err(|error| {
            AppError::new(ExitStatus::Runtime, "test_setup_failed", error.to_string())
        })?;
        let directory = root.path().join(".codex/workflows");
        tokio::fs::create_dir_all(&directory)
            .await
            .map_err(|error| {
                AppError::new(ExitStatus::Runtime, "test_setup_failed", error.to_string())
            })?;
        let script = directory.join("review.exs");
        tokio::fs::write(&script, "use Workflow")
            .await
            .map_err(|error| {
                AppError::new(ExitStatus::Runtime, "test_setup_failed", error.to_string())
            })?;
        let resolved = ResolvedWorkflowScript::resolve_from(
            Path::new(".codex/workflows/review.exs"),
            Some(root.path()),
        )
        .await?;

        let canonical = tokio::fs::canonicalize(script).await.map_err(|error| {
            AppError::new(ExitStatus::Runtime, "test_setup_failed", error.to_string())
        })?;
        assert_eq!(resolved.as_path(), canonical);
        Ok(())
    }
}
