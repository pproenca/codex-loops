use std::{
    env,
    fs::{self, File, OpenOptions},
    path::{Path, PathBuf},
    process::Stdio,
    sync::atomic::{AtomicU64, Ordering},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use fs2::FileExt;
use serde_json::json;
use tokio::{
    process::{Child, Command},
    time::{Instant, sleep},
};

use crate::{
    error::{AppError, AppResult, ExitStatus},
    scheduler::{HealthState, SchedulerClient},
};

mod attempt;
mod config;
mod metadata;
mod ownership;
mod process;
mod shutdown;
mod spawn;
mod supervisor;

use attempt::StartAttempt;
pub use config::{AbsolutePath, BindHost, SchedulerConfig, StartOptions};
use metadata::*;
use ownership::*;
use process::*;
use shutdown::*;
use spawn::*;
use supervisor::{SupervisionRequest, supervise};

async fn blocking<T, F>(operation: &'static str, task: F) -> AppResult<T>
where
    T: Send + 'static,
    F: FnOnce() -> AppResult<T> + Send + 'static,
{
    tokio::task::spawn_blocking(task).await.map_err(|error| {
        AppError::new(
            ExitStatus::Runtime,
            "scheduler_blocking_task_failed",
            format!("Could not {operation}."),
        )
        .details(json!({"reason": error.to_string()}))
    })?
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StopMode {
    Graceful,
    Force,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StartDisposition {
    Started,
    AlreadyRunning,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StopDisposition {
    Stopped,
    NotRunning,
}

pub async fn ensure_ready(client: &SchedulerClient) -> AppResult<StartDisposition> {
    ensure_ready_with(client, &StartOptions::default()).await
}

pub async fn ensure_ready_with(
    client: &SchedulerClient,
    options: &StartOptions,
) -> AppResult<StartDisposition> {
    match client.health_state().await {
        HealthState::Compatible(_) if client.is_managed() => {
            return ready_result(client, options, None).await;
        }
        HealthState::Compatible(_) => return Ok(StartDisposition::AlreadyRunning),
        HealthState::Incompatible { found, envelope } => {
            return Err(version_mismatch(found.as_deref(), envelope));
        }
        HealthState::Unreachable { .. } => {}
    }
    if !client.is_managed() {
        return Err(external_unavailable(client));
    }
    if !client.is_local() && options.bind_host.is_none() {
        return Err(AppError::new(
            ExitStatus::Runtime,
            "scheduler_unavailable",
            "The configured scheduler is unreachable and cannot be started locally.",
        )
        .details(json!({"server": client.base_url().as_str()})));
    }

    let attempt = StartAttempt::new(client).await?;
    let result = match spawn_supervisor(client, options, &attempt.owner_token).await {
        Ok(()) => wait_for_start(client, options, &attempt).await,
        Err(error) => Err(error),
    };
    let cleanup = attempt.finish().await;
    match (result, cleanup) {
        (Ok(started), Ok(())) => Ok(started),
        (Err(error), Ok(())) => Err(error),
        (Ok(_started), Err(error)) => Err(error),
        (Err(start_error), Err(cleanup_error)) => Err(AppError::new(
            ExitStatus::Runtime,
            "scheduler_attempt_cleanup_failed",
            "Scheduler startup failed and its startup lease could not be cleaned up.",
        )
        .details(json!({
            "startup_error": start_error.diagnostic(),
            "cleanup_error": cleanup_error.diagnostic()
        }))),
    }
}

async fn wait_for_start(
    client: &SchedulerClient,
    options: &StartOptions,
    attempt: &StartAttempt,
) -> AppResult<StartDisposition> {
    let timeout = match env::var("CODEX_LOOPS_SCHEDULER_START_TIMEOUT_MS") {
        Ok(value) => value
            .parse::<u64>()
            .ok()
            .filter(|value| *value > 0)
            .ok_or_else(|| {
                AppError::new(
                    ExitStatus::Usage,
                    "scheduler_start_timeout_invalid",
                    "CODEX_LOOPS_SCHEDULER_START_TIMEOUT_MS must be a positive integer.",
                )
                .details(json!({"value": value}))
            })?,
        Err(env::VarError::NotPresent) => 10_000,
        Err(env::VarError::NotUnicode(value)) => {
            return Err(AppError::new(
                ExitStatus::Usage,
                "scheduler_start_timeout_invalid",
                "CODEX_LOOPS_SCHEDULER_START_TIMEOUT_MS must be valid UTF-8.",
            )
            .details(json!({"value": value.to_string_lossy()})));
        }
    };
    let deadline = Instant::now() + Duration::from_millis(timeout);
    while Instant::now() < deadline {
        if let Some(metadata) = read_metadata(client).await?
            && attempt_is_live(client, &metadata.owner_token).await?
            && metadata.config.conflicts_with(options)
        {
            return Err(configuration_conflict(
                client,
                options,
                Some(&metadata.config),
            ));
        }
        match client.health_state().await {
            HealthState::Compatible(_) => {
                return ready_result(client, options, Some(&attempt.owner_token)).await;
            }
            HealthState::Incompatible { found: None, .. }
                if attempt_is_live(client, &attempt.owner_token).await? =>
            {
                sleep(Duration::from_millis(100)).await;
            }
            HealthState::Incompatible { found, envelope } => {
                return Err(version_mismatch(found.as_deref(), envelope));
            }
            HealthState::Unreachable { .. } => sleep(Duration::from_millis(100)).await,
        }
    }
    let log = log_path(client)?;
    let cleanup_error = match read_metadata(client).await? {
        Some(metadata) if metadata.owner_token == attempt.owner_token => {
            stop(client, StopMode::Graceful)
                .await
                .err()
                .map(|error| error.diagnostic())
        }
        Some(_) | None => None,
    };
    Err(AppError::new(
        ExitStatus::Runtime,
        "scheduler_start_failed",
        "The scheduler did not become healthy after start.",
    )
    .details(
        json!({"server": client.base_url().as_str(), "log": log, "cleanup_error": cleanup_error}),
    ))
}

async fn ready_result(
    client: &SchedulerClient,
    requested: &StartOptions,
    owner_token: Option<&OwnerToken>,
) -> AppResult<StartDisposition> {
    let metadata = if owner_token.is_some() {
        Some(await_metadata(client).await?)
    } else {
        read_metadata(client).await?
    };
    if !owner_lock_is_held(client).await? {
        if let Some(metadata) = &metadata
            && let Some(pid) = metadata.scheduler_pid
            && process_is_alive(pid)?
            && validate_scheduler_process(metadata).await.is_ok()
        {
            return Err(orphaned_error(client, metadata));
        }
        return Err(owner_unknown_error(client));
    }
    let Some(metadata) = metadata else {
        if has_explicit_configuration(requested) {
            return Err(configuration_conflict(client, requested, None));
        }
        return Ok(StartDisposition::AlreadyRunning);
    };
    if metadata.config.conflicts_with(requested) {
        return Err(configuration_conflict(
            client,
            requested,
            Some(&metadata.config),
        ));
    }
    Ok(
        if owner_token.is_some_and(|token| token == &metadata.owner_token) {
            StartDisposition::Started
        } else {
            StartDisposition::AlreadyRunning
        },
    )
}

async fn attempt_is_live(client: &SchedulerClient, owner_token: &OwnerToken) -> AppResult<bool> {
    marker_is_live(
        runtime_dir(client)?
            .join("attempts")
            .join(owner_token.as_str()),
    )
    .await
}

async fn marker_is_live(path: PathBuf) -> AppResult<bool> {
    blocking("inspect a scheduler startup lease", move || {
        let marker = match OpenOptions::new().read(true).write(true).open(&path) {
            Ok(marker) => marker,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
            Err(error) => return Err(io_error("scheduler_runtime_invalid")(error)),
        };
        match marker.try_lock_exclusive() {
            Ok(()) => {
                FileExt::unlock(&marker).map_err(io_error("scheduler_runtime_invalid"))?;
                match fs::remove_file(path) {
                    Ok(()) => {}
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                    Err(error) => return Err(io_error("scheduler_runtime_invalid")(error)),
                }
                Ok(false)
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => Ok(true),
            Err(error) => Err(io_error("scheduler_runtime_invalid")(error)),
        }
    })
    .await
}

fn has_explicit_configuration(options: &StartOptions) -> bool {
    options.bind_host.is_some() || options.journal.is_some() || options.model.is_some()
}

fn configuration_conflict(
    client: &SchedulerClient,
    requested: &StartOptions,
    active: Option<&SchedulerConfig>,
) -> AppError {
    AppError::new(
        ExitStatus::Usage,
        "scheduler_configuration_conflict",
        "A scheduler is already running with different lifecycle configuration.",
    )
    .details(json!({
        "server": client.base_url().as_str(),
        "requested": requested,
        "active": active
    }))
    .next_steps(["Use the active configuration or stop the scheduler before reconfiguring it."])
}

fn new_owner_token() -> AppResult<OwnerToken> {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
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
    format!(
        "{}-{nanos}-{}",
        std::process::id(),
        COUNTER.fetch_add(1, Ordering::Relaxed)
    )
    .parse()
}

pub async fn stop(client: &SchedulerClient, mode: StopMode) -> AppResult<StopDisposition> {
    require_managed(client)?;
    let reachable = !matches!(client.health_state().await, HealthState::Unreachable { .. });
    if !owner_lock_is_held(client).await? {
        let metadata = read_metadata(client).await?;
        if mode == StopMode::Force && metadata.is_some() {
            return force_stop(client).await;
        }
        if let Some(metadata) = metadata {
            if let Some(pid) = metadata.scheduler_pid
                && process_is_alive(pid)?
                && validate_scheduler_process(&metadata).await.is_ok()
            {
                return Err(orphaned_error(client, &metadata));
            }
            remove_stale_metadata(client).await?;
        }
        return if reachable {
            Err(owner_unknown_error(client))
        } else {
            Ok(StopDisposition::NotRunning)
        };
    }
    let metadata = await_metadata(client).await?;
    signal_process(metadata.supervisor_pid, libc::SIGTERM)?;
    for _ in 0..100 {
        if matches!(client.health_state().await, HealthState::Unreachable { .. })
            && !owner_lock_is_held(client).await?
        {
            remove_stale_metadata(client).await?;
            return Ok(StopDisposition::Stopped);
        }
        sleep(Duration::from_millis(100)).await;
    }
    Err(AppError::new(
        ExitStatus::Runtime,
        "scheduler_stop_failed",
        "The scheduler did not stop after SIGTERM.",
    )
    .details(
        json!({"supervisor_pid": metadata.supervisor_pid, "server": client.base_url().as_str()}),
    ))
}

fn orphaned_error(client: &SchedulerClient, metadata: &RuntimeMetadata) -> AppError {
    AppError::new(
        ExitStatus::Runtime,
        "scheduler_orphaned",
        "The scheduler is running but its native supervisor is gone.",
    )
    .details(json!({
        "server": client.base_url().as_str(),
        "scheduler_pid": metadata.scheduler_pid
    }))
    .next_steps(["Run `codex-loops stop --force` to stop the verified orphan."])
}

fn owner_unknown_error(client: &SchedulerClient) -> AppError {
    AppError::new(
        ExitStatus::Runtime,
        "scheduler_owner_unknown",
        "The scheduler is reachable but no live Codex Loops supervisor owns it.",
    )
    .details(json!({"server": client.base_url().as_str()}))
    .next_steps(["Stop the external scheduler with the process manager that started it."])
}

async fn force_stop(client: &SchedulerClient) -> AppResult<StopDisposition> {
    let metadata = read_metadata(client).await?.ok_or_else(|| {
        AppError::new(
            ExitStatus::Runtime,
            "scheduler_owner_unknown",
            "No Codex Loops metadata is available for a safe forced stop.",
        )
        .details(json!({"server": client.base_url().as_str()}))
    })?;
    let verified = validate_scheduler_process(&metadata).await?;
    signal_process(verified.pid, libc::SIGTERM)?;
    for _ in 0..100 {
        if !process_is_alive(verified.pid)?
            && matches!(client.health_state().await, HealthState::Unreachable { .. })
        {
            remove_stale_metadata(client).await?;
            return Ok(StopDisposition::Stopped);
        }
        sleep(Duration::from_millis(100)).await;
    }
    Err(AppError::new(
        ExitStatus::Runtime,
        "scheduler_stop_failed",
        "The orphaned scheduler did not stop after SIGTERM.",
    ))
}

#[cfg(unix)]
fn process_is_alive(pid: std::num::NonZeroU32) -> AppResult<bool> {
    Ok(unsafe { libc::kill(pid.get() as i32, 0) == 0 })
}

#[cfg(not(unix))]
fn process_is_alive(pid: std::num::NonZeroU32) -> AppResult<bool> {
    Err(AppError::new(
        ExitStatus::Runtime,
        "scheduler_process_check_unsupported",
        "Scheduler process liveness checks are not supported on this platform.",
    )
    .details(json!({"scheduler_pid": pid})))
}

async fn await_metadata(client: &SchedulerClient) -> AppResult<RuntimeMetadata> {
    for _ in 0..40 {
        if let Some(metadata) = read_metadata(client).await? {
            return Ok(metadata);
        }
        sleep(Duration::from_millis(50)).await;
    }
    Err(AppError::new(
        ExitStatus::Runtime,
        "scheduler_owner_unknown",
        "A Codex Loops supervisor holds the owner lock but did not publish valid metadata.",
    )
    .details(json!({"server": client.base_url().as_str()})))
}

pub async fn run_supervisor() -> AppResult<()> {
    let client = SchedulerClient::managed_from_env()?;
    let journal = match env::var_os("CODEX_LOOPS_JOURNAL_PATH") {
        Some(path) => Some(AbsolutePath::resolve(PathBuf::from(path)).await?),
        None => None,
    };
    let options = StartOptions {
        bind_host: optional_env("CODEX_LOOPS_BIND_HOST")?
            .map(|host| host.parse())
            .transpose()?,
        journal,
        model: optional_env("CODEX_LOOPS_CODEX_MODEL")?,
    };
    let owner_token = match optional_env("CODEX_LOOPS_OWNER_TOKEN")? {
        Some(token) => token.parse()?,
        None => new_owner_token()?,
    };
    let config = SchedulerConfig::resolve(&client, options)?;
    supervise(SupervisionRequest {
        client,
        config,
        output_mode: OutputMode::Background,
        owner_token,
    })
    .await
}

pub async fn run_foreground(client: SchedulerClient, options: StartOptions) -> AppResult<()> {
    let config = SchedulerConfig::resolve(&client, options)?;
    supervise(SupervisionRequest {
        client,
        config,
        output_mode: OutputMode::Foreground,
        owner_token: new_owner_token()?,
    })
    .await
}

pub async fn read_logs(client: &SchedulerClient, lines: usize) -> AppResult<String> {
    require_managed(client)?;
    let path = log_path(client)?;
    let content = tokio::fs::read_to_string(&path).await.map_err(|error| {
        AppError::new(
            ExitStatus::Unsatisfied,
            "scheduler_log_unavailable",
            "Scheduler log is not available.",
        )
        .details(json!({"path": path, "reason": error.to_string()}))
    })?;
    let skip = content.lines().count().saturating_sub(lines);
    let mut output = content.lines().skip(skip).collect::<Vec<_>>().join("\n");
    if !output.is_empty() {
        output.push('\n');
    }
    Ok(output)
}

pub async fn configuration(client: &SchedulerClient) -> AppResult<Option<SchedulerConfig>> {
    require_managed(client)?;
    read_metadata(client)
        .await
        .map(|metadata| metadata.map(|metadata| metadata.config))
}

fn optional_env(key: &'static str) -> AppResult<Option<String>> {
    match env::var(key) {
        Ok(value) if value.is_empty() => Ok(None),
        Ok(value) => Ok(Some(value)),
        Err(env::VarError::NotPresent) => Ok(None),
        Err(env::VarError::NotUnicode(value)) => Err(AppError::new(
            ExitStatus::Usage,
            "scheduler_environment_invalid",
            format!("{key} must be valid UTF-8."),
        )
        .details(json!({"value": value.to_string_lossy()}))),
    }
}

fn require_managed(client: &SchedulerClient) -> AppResult<()> {
    if client.is_managed() {
        Ok(())
    } else {
        Err(AppError::new(
            ExitStatus::Runtime,
            "scheduler_externally_managed",
            "The configured scheduler is owned by an external process manager.",
        )
        .details(json!({"server": client.base_url().as_str()}))
        .next_steps(["Use the external scheduler's process manager for lifecycle and logs."]))
    }
}

fn external_unavailable(client: &SchedulerClient) -> AppError {
    AppError::new(
        ExitStatus::Runtime,
        "scheduler_unavailable",
        "The configured external scheduler is unreachable and cannot be started locally.",
    )
    .details(json!({"server": client.base_url().as_str()}))
}

fn version_mismatch(found: Option<&str>, envelope: serde_json::Value) -> AppError {
    let message = match found {
        Some(found) => format!(
            "A scheduler from another Codex Loops version is already running (control plane {}, scheduler {found}).",
            env!("CARGO_PKG_VERSION")
        ),
        None => "The configured endpoint did not return a compatible Codex Loops scheduler health response."
            .to_owned(),
    };
    AppError::new(ExitStatus::Runtime, "scheduler_version_mismatch", message)
        .details(json!({"expected": env!("CARGO_PKG_VERSION"), "found": found, "health": envelope}))
        .next_steps([
            "Let active runs finish, then run `codex-loops stop`.",
            "Rerun the original command to start the matching scheduler.",
        ])
}

fn io_error(code: &'static str) -> impl FnOnce(std::io::Error) -> AppError {
    move |error| AppError::new(ExitStatus::Runtime, code, error.to_string())
}
