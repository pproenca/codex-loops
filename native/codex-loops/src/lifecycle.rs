use std::{
    env,
    fs::{self, File, OpenOptions},
    path::{Path, PathBuf},
    process::Stdio,
    sync::atomic::{AtomicU64, Ordering},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use fs2::FileExt;
use serde::{Deserialize, Serialize};
use serde_json::json;
use tokio::{
    process::{Child, Command},
    time::{Instant, sleep},
};

use crate::{
    error::{AppError, AppResult},
    runtime::Runtime,
    scheduler::{HealthState, SchedulerClient},
};

#[derive(Clone, Default, Serialize, Deserialize)]
pub struct StartOptions {
    pub bind_host: Option<String>,
    pub journal: Option<String>,
    pub model: Option<String>,
}

#[derive(Serialize, Deserialize)]
struct RuntimeMetadata {
    owner_token: String,
    supervisor_pid: u32,
    scheduler_pid: Option<u32>,
    version: String,
    port: u16,
    scheduler_root: String,
    config: StartOptions,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct VerifiedSchedulerProcess {
    pid: u32,
}

struct StartAttempt {
    owner_token: String,
    marker: PathBuf,
    marker_lock: File,
}

impl StartAttempt {
    fn new(client: &SchedulerClient) -> AppResult<Self> {
        let owner_token = new_owner_token();
        let directory = runtime_dir(client)?.join("attempts");
        fs::create_dir_all(&directory).map_err(io_error("scheduler_runtime_invalid"))?;
        let marker = directory.join(&owner_token);
        let marker_lock = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(&marker)
            .map_err(io_error("scheduler_runtime_invalid"))?;
        marker_lock
            .try_lock_exclusive()
            .map_err(io_error("scheduler_runtime_invalid"))?;
        Ok(Self {
            owner_token,
            marker,
            marker_lock,
        })
    }
}

impl Drop for StartAttempt {
    fn drop(&mut self) {
        let _ = FileExt::unlock(&self.marker_lock);
        let _ = fs::remove_file(&self.marker);
    }
}

pub async fn ensure_ready(client: &SchedulerClient) -> AppResult<bool> {
    ensure_ready_with(client, &StartOptions::default()).await
}

pub async fn ensure_ready_with(
    client: &SchedulerClient,
    options: &StartOptions,
) -> AppResult<bool> {
    match client.health_state().await {
        HealthState::Compatible(_) if client.is_managed() => {
            return ready_result(client, options, None).await;
        }
        HealthState::Compatible(_) => return Ok(false),
        HealthState::Incompatible { found, envelope } => {
            return Err(version_mismatch(&found, envelope));
        }
        HealthState::Unreachable { .. } => {}
    }
    if !client.is_managed() {
        return Err(external_unavailable(client));
    }
    if !client.is_local() && options.bind_host.is_none() {
        return Err(AppError::new(
            6,
            "scheduler_unavailable",
            "The configured scheduler is unreachable and cannot be started locally.",
        )
        .details(json!({"server": client.base_url().as_str()})));
    }

    let attempt = StartAttempt::new(client)?;
    spawn_supervisor(client, options, &attempt.owner_token).await?;
    let timeout = env::var("CODEX_LOOPS_SCHEDULER_START_TIMEOUT_MS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(10_000);
    let deadline = Instant::now() + Duration::from_millis(timeout);
    while Instant::now() < deadline {
        if let Some(metadata) = read_metadata(client)?
            && attempt_is_live(client, &metadata.owner_token)?
            && configuration_conflicts(options, &metadata.config)
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
            HealthState::Incompatible { found, .. }
                if found == "unknown" && attempt_is_live(client, &attempt.owner_token)? =>
            {
                sleep(Duration::from_millis(100)).await;
            }
            HealthState::Incompatible { found, envelope } => {
                return Err(version_mismatch(&found, envelope));
            }
            HealthState::Unreachable { .. } => sleep(Duration::from_millis(100)).await,
        }
    }
    let log = log_path(client)?;
    let cleanup_error = match read_metadata(client)? {
        Some(metadata) if metadata.owner_token == attempt.owner_token => stop(client, false)
            .await
            .err()
            .map(|error| error.cli_envelope()),
        _ => None,
    };
    Err(AppError::new(
        6,
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
    owner_token: Option<&str>,
) -> AppResult<bool> {
    let metadata = if owner_token.is_some() {
        Some(await_metadata(client).await?)
    } else {
        read_metadata(client)?
    };
    if !owner_lock_is_held(client)? {
        if let Some(metadata) = &metadata
            && metadata.scheduler_pid.is_some_and(process_is_alive)
            && validate_metadata(client, metadata).is_ok()
            && validate_scheduler_process(metadata).is_ok()
        {
            return Err(orphaned_error(client, metadata));
        }
        return Err(owner_unknown_error(client));
    }
    let Some(metadata) = metadata else {
        if has_explicit_configuration(requested) {
            return Err(configuration_conflict(client, requested, None));
        }
        return Ok(false);
    };
    if configuration_conflicts(requested, &metadata.config) {
        return Err(configuration_conflict(
            client,
            requested,
            Some(&metadata.config),
        ));
    }
    Ok(owner_token.is_some_and(|token| token == metadata.owner_token))
}

fn attempt_is_live(client: &SchedulerClient, owner_token: &str) -> AppResult<bool> {
    marker_is_live(&runtime_dir(client)?.join("attempts").join(owner_token))
}

fn marker_is_live(path: &Path) -> AppResult<bool> {
    let marker = match OpenOptions::new().read(true).write(true).open(path) {
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
}

fn has_explicit_configuration(options: &StartOptions) -> bool {
    options.bind_host.is_some() || options.journal.is_some() || options.model.is_some()
}

fn configuration_conflicts(requested: &StartOptions, active: &StartOptions) -> bool {
    requested
        .bind_host
        .as_ref()
        .is_some_and(|value| active.bind_host.as_ref() != Some(value))
        || requested
            .journal
            .as_ref()
            .is_some_and(|value| active.journal.as_ref() != Some(value))
        || requested
            .model
            .as_ref()
            .is_some_and(|value| active.model.as_ref() != Some(value))
}

fn configuration_conflict(
    client: &SchedulerClient,
    requested: &StartOptions,
    active: Option<&StartOptions>,
) -> AppError {
    AppError::new(
        2,
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

fn new_owner_token() -> String {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    format!(
        "{}-{nanos}-{}",
        std::process::id(),
        COUNTER.fetch_add(1, Ordering::Relaxed)
    )
}

pub async fn stop(client: &SchedulerClient, force: bool) -> AppResult<bool> {
    require_managed(client)?;
    let reachable = !matches!(client.health_state().await, HealthState::Unreachable { .. });
    if !owner_lock_is_held(client)? {
        let metadata = read_metadata(client)?;
        if force && metadata.is_some() {
            return force_stop(client).await;
        }
        if let Some(metadata) = metadata {
            if metadata.scheduler_pid.is_some_and(process_is_alive)
                && validate_metadata(client, &metadata).is_ok()
                && validate_scheduler_process(&metadata).is_ok()
            {
                return Err(orphaned_error(client, &metadata));
            }
            remove_stale_metadata(client)?;
        }
        return if reachable {
            Err(owner_unknown_error(client))
        } else {
            Ok(false)
        };
    }
    let metadata = await_metadata(client).await?;
    validate_metadata(client, &metadata)?;
    signal_process(metadata.supervisor_pid, libc::SIGTERM)?;
    for _ in 0..100 {
        if matches!(client.health_state().await, HealthState::Unreachable { .. })
            && !owner_lock_is_held(client)?
        {
            remove_stale_metadata(client)?;
            return Ok(true);
        }
        sleep(Duration::from_millis(100)).await;
    }
    Err(AppError::new(
        6,
        "scheduler_stop_failed",
        "The scheduler did not stop after SIGTERM.",
    )
    .details(
        json!({"supervisor_pid": metadata.supervisor_pid, "server": client.base_url().as_str()}),
    ))
}

fn orphaned_error(client: &SchedulerClient, metadata: &RuntimeMetadata) -> AppError {
    AppError::new(
        6,
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
        6,
        "scheduler_owner_unknown",
        "The scheduler is reachable but no live Codex Loops supervisor owns it.",
    )
    .details(json!({"server": client.base_url().as_str()}))
    .next_steps(["Stop the external scheduler with the process manager that started it."])
}

async fn force_stop(client: &SchedulerClient) -> AppResult<bool> {
    let metadata = read_metadata(client)?.ok_or_else(|| {
        AppError::new(
            6,
            "scheduler_owner_unknown",
            "No Codex Loops metadata is available for a safe forced stop.",
        )
        .details(json!({"server": client.base_url().as_str()}))
    })?;
    validate_metadata(client, &metadata)?;
    let verified = validate_scheduler_process(&metadata)?;
    signal_process(verified.pid, libc::SIGTERM)?;
    for _ in 0..100 {
        if !process_is_alive(verified.pid)
            && matches!(client.health_state().await, HealthState::Unreachable { .. })
        {
            remove_stale_metadata(client)?;
            return Ok(true);
        }
        sleep(Duration::from_millis(100)).await;
    }
    Err(AppError::new(
        6,
        "scheduler_stop_failed",
        "The orphaned scheduler did not stop after SIGTERM.",
    ))
}

#[cfg(unix)]
fn process_is_alive(pid: u32) -> bool {
    unsafe { libc::kill(pid as i32, 0) == 0 }
}

#[cfg(not(unix))]
fn process_is_alive(_pid: u32) -> bool {
    false
}

async fn await_metadata(client: &SchedulerClient) -> AppResult<RuntimeMetadata> {
    for _ in 0..40 {
        if let Some(metadata) = read_metadata(client)? {
            return Ok(metadata);
        }
        sleep(Duration::from_millis(50)).await;
    }
    Err(AppError::new(
        6,
        "scheduler_owner_unknown",
        "A Codex Loops supervisor holds the owner lock but did not publish valid metadata.",
    )
    .details(json!({"server": client.base_url().as_str()})))
}

pub async fn run_supervisor() -> AppResult<()> {
    let client = SchedulerClient::managed_from_env()?;
    let options = StartOptions {
        bind_host: env::var("CODEX_LOOPS_BIND_HOST").ok(),
        journal: env::var("CODEX_LOOPS_JOURNAL_PATH").ok(),
        model: env::var("CODEX_LOOPS_CODEX_MODEL").ok(),
    };
    let owner_token = env::var("CODEX_LOOPS_OWNER_TOKEN").unwrap_or_else(|_| new_owner_token());
    supervise(client, options, false, owner_token).await
}

pub async fn run_foreground(client: SchedulerClient, options: StartOptions) -> AppResult<()> {
    supervise(client, options, true, new_owner_token()).await
}

async fn supervise(
    client: SchedulerClient,
    options: StartOptions,
    foreground: bool,
    owner_token: String,
) -> AppResult<()> {
    let runtime_dir = runtime_dir(&client)?;
    fs::create_dir_all(&runtime_dir).map_err(io_error("scheduler_runtime_invalid"))?;
    let lock_path = runtime_dir.join("owner.lock");
    let owner_lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(&lock_path)
        .map_err(io_error("scheduler_runtime_invalid"))?;
    if let Err(error) = owner_lock.try_lock_exclusive() {
        return if error.kind() == std::io::ErrorKind::WouldBlock {
            Ok(())
        } else {
            Err(io_error("scheduler_runtime_invalid")(error))
        };
    }
    remove_stale_metadata(&client)?;

    let mut metadata = RuntimeMetadata {
        owner_token,
        supervisor_pid: std::process::id(),
        scheduler_pid: None,
        version: env!("CARGO_PKG_VERSION").into(),
        port: scheduler_port(&client)?,
        scheduler_root: scheduler_release_root()?.to_string_lossy().into_owned(),
        config: options.clone(),
    };
    write_metadata(&client, &metadata)?;

    let mut backoff = Duration::from_millis(100);
    loop {
        let started_at = Instant::now();
        let mut child = match spawn_scheduler(&client, &options, foreground).await {
            Ok(child) => child,
            Err(error) => {
                remove_stale_metadata(&client)?;
                return Err(error);
            }
        };
        metadata.scheduler_pid = child.id();
        publish_metadata(&mut child, || write_metadata(&client, &metadata)).await?;

        tokio::select! {
            status = child.wait() => {
                let status = status.map_err(|error| AppError::new(6, "scheduler_wait_failed", error.to_string()))?;
                metadata.scheduler_pid = None;
                write_metadata(&client, &metadata)?;
                eprintln!("Codex Loops scheduler exited unexpectedly with {status}; restarting in {} ms.", backoff.as_millis());
                if started_at.elapsed() >= Duration::from_secs(30) {
                    backoff = Duration::from_millis(100);
                }
            }
            signal_result = termination_signal() => {
                signal_result?;
                terminate_child(&mut child).await?;
                remove_stale_metadata(&client)?;
                return Ok(());
            }
        }

        tokio::select! {
            _ = sleep(backoff) => {}
            signal_result = termination_signal() => {
                signal_result?;
                remove_stale_metadata(&client)?;
                return Ok(());
            }
        }
        backoff = (backoff * 2).min(Duration::from_secs(5));
    }
}

async fn spawn_scheduler(
    client: &SchedulerClient,
    options: &StartOptions,
    foreground: bool,
) -> AppResult<Child> {
    let runtime_dir = runtime_dir(client)?;
    let runtime = Runtime::installed()?;
    let release = runtime.bundle.scheduler;
    let port = scheduler_port(client)?;
    let bind_host = options
        .bind_host
        .clone()
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| {
            client
                .base_url()
                .host_str()
                .unwrap_or("127.0.0.1")
                .trim_matches(['[', ']'])
                .into()
        });
    let mut command = scheduler_command(&release, &runtime_dir);
    command
        .env("CODEX_LOOPS_SERVER", "1")
        .env("CODEX_LOOPS_HOST", bind_host)
        .env("CODEX_LOOPS_PORT", port.to_string())
        .env("PORT", port.to_string())
        .env("RELEASE_DISTRIBUTION", "none")
        .env("RELEASE_TMP", runtime_dir.join("release"))
        .env("CODEX_LOOPS_CODEX_BIN", runtime.bundle.control_plane)
        .env_remove("CODEX_LOOPS_INTERNAL_DAEMON")
        .env_remove("ROOTDIR")
        .env_remove("BINDIR")
        .env_remove("RELEASE_ROOT")
        .env_remove("RELEASE_SYS_CONFIG");
    if foreground {
        command.stdout(Stdio::inherit()).stderr(Stdio::inherit());
    } else {
        let log = open_log(&runtime_dir.join("scheduler.log"))?;
        let error_log = log.try_clone().map_err(io_error("scheduler_log_failed"))?;
        command
            .stdout(Stdio::from(log))
            .stderr(Stdio::from(error_log));
    }
    if let Some(journal) = &options.journal {
        command.env("CODEX_LOOPS_JOURNAL_PATH", journal);
    }
    if let Some(model) = &options.model {
        command.env("CODEX_LOOPS_CODEX_MODEL", model);
    }
    command.spawn().map_err(|error| {
        AppError::new(
            6,
            "scheduler_start_failed",
            "Could not start the scheduler release.",
        )
        .details(json!({"release": release, "reason": error.to_string()}))
    })
}

fn scheduler_command(release: &Path, runtime_dir: &Path) -> Command {
    let mut command = Command::new(release);
    command
        .arg("start")
        .kill_on_drop(true)
        // Source-checkout releases are replaced in place by `make release`.
        // Keeping a live BEAM's cwd inside that tree leaves it pointing at an
        // unlinked directory and makes subsequent Port.open calls fail with
        // :enoent. Runtime state is stable across release replacement.
        .current_dir(runtime_dir);
    command
}

async fn terminate_child(child: &mut Child) -> AppResult<()> {
    terminate_child_with_timeout(child, Duration::from_secs(5)).await
}

async fn terminate_child_with_timeout(child: &mut Child, timeout: Duration) -> AppResult<()> {
    if let Some(pid) = child.id() {
        let _ = signal_process(pid, libc::SIGTERM);
    }
    match tokio::time::timeout(timeout, child.wait()).await {
        Ok(Ok(_status)) => Ok(()),
        Ok(Err(wait_error)) => {
            let kill_error = child.start_kill().err().map(|error| error.to_string());
            let final_wait_error = child.wait().await.err().map(|error| error.to_string());
            Err(AppError::new(
                6,
                "scheduler_wait_failed",
                "Could not observe scheduler termination reliably.",
            )
            .details(json!({
                "wait_error": wait_error.to_string(),
                "kill_error": kill_error,
                "final_wait_error": final_wait_error
            })))
        }
        Err(_elapsed) => {
            child.start_kill().map_err(|error| {
                AppError::new(
                    6,
                    "scheduler_kill_failed",
                    "The scheduler ignored SIGTERM and could not be killed.",
                )
                .details(json!({"reason": error.to_string()}))
            })?;
            child.wait().await.map_err(|error| {
                AppError::new(
                    6,
                    "scheduler_wait_failed",
                    "Could not wait for the killed scheduler process.",
                )
                .details(json!({"reason": error.to_string()}))
            })?;
            Ok(())
        }
    }
}

async fn publish_metadata(
    child: &mut Child,
    writer: impl FnOnce() -> AppResult<()>,
) -> AppResult<()> {
    if let Err(error) = writer() {
        if let Err(cleanup_error) = terminate_child(child).await {
            return Err(AppError::new(
                6,
                "scheduler_cleanup_failed",
                "Scheduler startup failed and its child cleanup also failed.",
            )
            .details(json!({
                "startup_error": error.cli_envelope(),
                "cleanup_error": cleanup_error.cli_envelope()
            })));
        }
        return Err(error);
    }
    Ok(())
}

async fn spawn_supervisor(
    client: &SchedulerClient,
    options: &StartOptions,
    owner_token: &str,
) -> AppResult<()> {
    let executable = env::current_exe().map_err(io_error("runtime_invalid"))?;
    let log = open_log(&log_path(client)?)?;
    let error_log = log.try_clone().map_err(io_error("scheduler_log_failed"))?;
    let mut command = Command::new(executable);
    command
        .arg("daemon")
        .env("CODEX_LOOPS_INTERNAL_DAEMON", "1")
        .env("CODEX_LOOPS_OWNER_TOKEN", owner_token)
        .env("CODEX_LOOPS_SCHEDULER_URL", client.base_url().as_str())
        .env("CODEX_LOOPS_RUNTIME_DIR", runtime_dir(client)?)
        .stdin(Stdio::null())
        .stdout(Stdio::from(log))
        .stderr(Stdio::from(error_log));
    if let Some(bind_host) = &options.bind_host {
        command.env("CODEX_LOOPS_BIND_HOST", bind_host);
    }
    if let Some(journal) = &options.journal {
        command.env("CODEX_LOOPS_JOURNAL_PATH", journal);
    }
    if let Some(model) = &options.model {
        command.env("CODEX_LOOPS_CODEX_MODEL", model);
    }
    command.spawn().map_err(|error| {
        AppError::new(
            6,
            "scheduler_start_failed",
            "Could not start the scheduler supervisor.",
        )
        .details(json!({"reason": error.to_string()}))
    })?;
    Ok(())
}

pub fn read_logs(client: &SchedulerClient, lines: usize) -> AppResult<String> {
    require_managed(client)?;
    let path = log_path(client)?;
    let content = fs::read_to_string(&path).map_err(|error| {
        AppError::new(
            1,
            "scheduler_log_unavailable",
            "Scheduler log is not available.",
        )
        .details(json!({"path": path, "reason": error.to_string()}))
    })?;
    let selected: Vec<_> = content.lines().rev().take(lines).collect();
    let mut output = selected.into_iter().rev().collect::<Vec<_>>().join("\n");
    if !output.is_empty() {
        output.push('\n');
    }
    Ok(output)
}

pub fn configuration(client: &SchedulerClient) -> AppResult<Option<StartOptions>> {
    require_managed(client)?;
    read_metadata(client).map(|metadata| metadata.map(|metadata| metadata.config))
}

fn require_managed(client: &SchedulerClient) -> AppResult<()> {
    if client.is_managed() {
        Ok(())
    } else {
        Err(AppError::new(
            6,
            "scheduler_externally_managed",
            "The configured scheduler is owned by an external process manager.",
        )
        .details(json!({"server": client.base_url().as_str()}))
        .next_steps(["Use the external scheduler's process manager for lifecycle and logs."]))
    }
}

fn external_unavailable(client: &SchedulerClient) -> AppError {
    AppError::new(
        6,
        "scheduler_unavailable",
        "The configured external scheduler is unreachable and cannot be started locally.",
    )
    .details(json!({"server": client.base_url().as_str()}))
}

fn runtime_dir(client: &SchedulerClient) -> AppResult<PathBuf> {
    if let Ok(path) = env::var("CODEX_LOOPS_RUNTIME_DIR")
        && !path.is_empty()
    {
        return Ok(PathBuf::from(path));
    }
    let home =
        env::var("HOME").map_err(|_| AppError::new(6, "runtime_invalid", "HOME is not set."))?;
    Ok(PathBuf::from(home)
        .join(".codex/workflows/runtime")
        .join(runtime_key(client)?))
}

fn runtime_key(client: &SchedulerClient) -> AppResult<String> {
    let host = client.base_url().host_str().unwrap_or("local");
    let host: String = host
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || matches!(character, '.' | '-') {
                character
            } else {
                '_'
            }
        })
        .collect();
    Ok(format!("{host}-{}", scheduler_port(client)?))
}

fn scheduler_port(client: &SchedulerClient) -> AppResult<u16> {
    client
        .base_url()
        .port_or_known_default()
        .ok_or_else(|| AppError::new(2, "scheduler_url_invalid", "Scheduler URL has no port."))
}

fn metadata_path(client: &SchedulerClient) -> AppResult<PathBuf> {
    Ok(runtime_dir(client)?.join("owner.json"))
}

fn log_path(client: &SchedulerClient) -> AppResult<PathBuf> {
    Ok(runtime_dir(client)?.join("scheduler.log"))
}

fn owner_lock_is_held(client: &SchedulerClient) -> AppResult<bool> {
    let runtime_dir = runtime_dir(client)?;
    if !runtime_dir.is_dir() {
        return Ok(false);
    }
    owner_lock_is_held_at(&runtime_dir.join("owner.lock"))
}

fn owner_lock_is_held_at(path: &Path) -> AppResult<bool> {
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(path)
        .map_err(io_error("scheduler_metadata_invalid"))?;
    match lock.try_lock_exclusive() {
        Ok(()) => {
            FileExt::unlock(&lock).map_err(io_error("scheduler_metadata_invalid"))?;
            Ok(false)
        }
        Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => Ok(true),
        Err(error) => Err(io_error("scheduler_metadata_invalid")(error)),
    }
}

fn read_metadata(client: &SchedulerClient) -> AppResult<Option<RuntimeMetadata>> {
    let path = metadata_path(client)?;
    match fs::read(&path) {
        Ok(bytes) => serde_json::from_slice(&bytes).map(Some).map_err(|error| {
            AppError::new(
                6,
                "scheduler_metadata_invalid",
                "Scheduler owner metadata is invalid.",
            )
            .details(json!({"path": path, "reason": error.to_string()}))
        }),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(io_error("scheduler_metadata_invalid")(error)),
    }
}

fn validate_metadata(client: &SchedulerClient, metadata: &RuntimeMetadata) -> AppResult<()> {
    let expected_port = scheduler_port(client)?;
    if metadata.supervisor_pid == 0
        || metadata.port != expected_port
        || verified_scheduler_root(metadata).is_err()
    {
        Err(AppError::new(
            6,
            "scheduler_metadata_invalid",
            "Scheduler owner metadata does not match the configured endpoint.",
        )
        .details(json!({
            "expected_port": expected_port,
            "metadata_port": metadata.port,
            "supervisor_pid": metadata.supervisor_pid,
            "scheduler_root": metadata.scheduler_root
        })))
    } else {
        Ok(())
    }
}

fn verified_scheduler_root(metadata: &RuntimeMetadata) -> AppResult<PathBuf> {
    let recorded = Path::new(&metadata.scheduler_root);
    if !recorded.is_absolute() {
        return Err(AppError::new(
            6,
            "scheduler_metadata_invalid",
            "Scheduler metadata does not contain an absolute runtime identity.",
        )
        .details(json!({"scheduler_root": recorded})));
    }
    let root = recorded.canonicalize().map_err(|error| {
        AppError::new(
            6,
            "scheduler_metadata_invalid",
            "The recorded scheduler runtime no longer exists.",
        )
        .details(json!({"scheduler_root": recorded, "reason": error.to_string()}))
    })?;
    let launcher = root.join("bin/agent_loops");
    let release = root.join("releases").join(&metadata.version);
    if !launcher.is_file() || !release.is_dir() {
        return Err(AppError::new(
            6,
            "scheduler_metadata_invalid",
            "The recorded process does not identify a complete scheduler runtime.",
        )
        .details(json!({
            "scheduler_root": root,
            "version": metadata.version,
            "launcher": launcher,
            "release": release
        })));
    }
    Ok(root)
}

#[cfg(unix)]
fn validate_scheduler_process(metadata: &RuntimeMetadata) -> AppResult<VerifiedSchedulerProcess> {
    let pid = metadata.scheduler_pid.ok_or_else(|| {
        AppError::new(
            6,
            "scheduler_owner_unknown",
            "Scheduler metadata has no active child process.",
        )
    })?;
    let root = verified_scheduler_root(metadata)?;
    let output = std::process::Command::new("ps")
        .args(["-p", &pid.to_string(), "-o", "command="])
        .output()
        .map_err(io_error("scheduler_process_check_failed"))?;
    let command = String::from_utf8_lossy(&output.stdout);
    let runtime_prefix = format!("{}/", root.display());
    if output.status.success() && command.contains(&runtime_prefix) {
        Ok(VerifiedSchedulerProcess { pid })
    } else {
        Err(AppError::new(
            6,
            "scheduler_owner_unknown",
            "Refusing to force-stop a process that is not the packaged scheduler.",
        )
        .details(json!({"scheduler_pid": pid, "command": command.trim()})))
    }
}

#[cfg(not(unix))]
fn validate_scheduler_process(metadata: &RuntimeMetadata) -> AppResult<VerifiedSchedulerProcess> {
    Err(AppError::new(
        6,
        "force_stop_unsupported",
        "Safe forced stop is not supported on this platform.",
    )
    .details(json!({"scheduler_pid": metadata.scheduler_pid})))
}

fn scheduler_release_root() -> AppResult<PathBuf> {
    Runtime::installed()?
        .bundle
        .scheduler_root()
        .canonicalize()
        .ok()
        .ok_or_else(|| AppError::new(6, "runtime_invalid", "Scheduler release path is invalid."))
}

fn write_metadata(client: &SchedulerClient, metadata: &RuntimeMetadata) -> AppResult<()> {
    let path = metadata_path(client)?;
    let temp = path.with_extension("json.tmp");
    let bytes = serde_json::to_vec(metadata)
        .map_err(|error| AppError::new(6, "scheduler_metadata_invalid", error.to_string()))?;
    fs::write(&temp, bytes).map_err(io_error("scheduler_metadata_invalid"))?;
    fs::rename(&temp, &path).map_err(io_error("scheduler_metadata_invalid"))
}

fn remove_stale_metadata(client: &SchedulerClient) -> AppResult<()> {
    match fs::remove_file(metadata_path(client)?) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(io_error("scheduler_metadata_invalid")(error)),
    }
}

fn open_log(path: &Path) -> AppResult<File> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(io_error("scheduler_log_failed"))?;
    }
    OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(io_error("scheduler_log_failed"))
}

fn signal_process(pid: u32, signal: i32) -> AppResult<()> {
    let result = unsafe { libc::kill(pid as i32, signal) };
    if result == 0 {
        Ok(())
    } else {
        Err(AppError::new(
            6,
            "scheduler_stop_failed",
            "Could not signal scheduler supervisor.",
        )
        .details(json!({"pid": pid, "reason": std::io::Error::last_os_error().to_string()})))
    }
}

#[cfg(unix)]
async fn termination_signal() -> AppResult<()> {
    use tokio::signal::unix::{SignalKind, signal};
    let mut terminate =
        signal(SignalKind::terminate()).map_err(io_error("scheduler_signal_failed"))?;
    let mut interrupt =
        signal(SignalKind::interrupt()).map_err(io_error("scheduler_signal_failed"))?;
    tokio::select! {
        _ = terminate.recv() => Ok(()),
        _ = interrupt.recv() => Ok(()),
    }
}

#[cfg(not(unix))]
async fn termination_signal() -> AppResult<()> {
    signal::ctrl_c()
        .await
        .map_err(io_error("scheduler_signal_failed"))
}

fn version_mismatch(found: &str, envelope: serde_json::Value) -> AppError {
    AppError::new(
        6,
        "scheduler_version_mismatch",
        format!("A scheduler from another Codex Loops version is already running (control plane {}, scheduler {found}).", env!("CARGO_PKG_VERSION")),
    )
    .details(json!({"expected": env!("CARGO_PKG_VERSION"), "found": found, "health": envelope}))
    .next_steps([
        "Let active runs finish, then run `codex-loops stop`.",
        "Rerun the original command to start the matching scheduler.",
    ])
}

fn io_error(code: &'static str) -> impl FnOnce(std::io::Error) -> AppError {
    move |error| AppError::new(6, code, error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn runtime_metadata_is_outside_the_packaged_release() {
        let client = SchedulerClient::new("http://127.0.0.1:49123").unwrap();
        let path = runtime_dir(&client).unwrap();
        assert!(path.ends_with(".codex/workflows/runtime/127.0.0.1-49123"));
    }

    #[test]
    fn scheduler_process_runs_from_the_stable_runtime_directory() {
        let root = tempfile::tempdir().unwrap();
        let release = root.path().join("release/bin/agent_loops");
        let runtime = root.path().join("runtime");
        let command = scheduler_command(&release, &runtime);

        assert_eq!(command.as_std().get_current_dir(), Some(runtime.as_path()));
        assert_ne!(command.as_std().get_current_dir(), release.parent());
    }

    #[test]
    fn a_stale_metadata_file_is_not_treated_as_a_live_owner() {
        let root = tempfile::tempdir().unwrap();
        let lock_path = root.path().join("owner.lock");
        File::create(&lock_path).unwrap();
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .open(&lock_path)
            .unwrap();
        lock.try_lock_exclusive().unwrap();
        assert!(owner_lock_is_held_at(&lock_path).unwrap());
        FileExt::unlock(&lock).unwrap();
        assert!(!owner_lock_is_held_at(&lock_path).unwrap());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn metadata_failure_terminates_the_spawned_scheduler() {
        let mut child = Command::new("/bin/sh")
            .args(["-c", "sleep 30"])
            .kill_on_drop(true)
            .spawn()
            .unwrap();
        let pid = child.id().unwrap();
        let error = publish_metadata(&mut child, || {
            Err(AppError::new(
                6,
                "scheduler_metadata_invalid",
                "fixture failure",
            ))
        })
        .await
        .unwrap_err();
        assert_eq!(error.code.as_ref(), "scheduler_metadata_invalid");
        assert_eq!(unsafe { libc::kill(pid as i32, 0) }, -1);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn stubborn_scheduler_is_killed_after_the_graceful_shutdown_deadline() {
        let mut child = Command::new("/bin/sh")
            .args(["-c", "trap '' TERM; while :; do sleep 1; done"])
            .kill_on_drop(true)
            .spawn()
            .unwrap();
        let pid = child.id().unwrap();

        terminate_child_with_timeout(&mut child, Duration::from_millis(50))
            .await
            .unwrap();

        assert_eq!(unsafe { libc::kill(pid as i32, 0) }, -1);
    }

    #[test]
    fn attempt_liveness_is_advisory_lock_backed_and_prunes_stale_markers() {
        let root = tempfile::tempdir().unwrap();
        let stale = root.path().join("stale");
        File::create(&stale).unwrap();
        assert!(!marker_is_live(&stale).unwrap());
        assert!(!stale.exists());

        let live = root.path().join("live");
        let lock = File::create(&live).unwrap();
        lock.try_lock_exclusive().unwrap();
        assert!(marker_is_live(&live).unwrap());
        FileExt::unlock(&lock).unwrap();
        assert!(!marker_is_live(&live).unwrap());
        assert!(!live.exists());
    }
}
