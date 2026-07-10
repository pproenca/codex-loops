use super::*;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum OutputMode {
    Background,
    Foreground,
}

pub(super) async fn supervise(
    client: SchedulerClient,
    options: StartOptions,
    output_mode: OutputMode,
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
        let mut child = match spawn_scheduler(&client, &options, output_mode).await {
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
    output_mode: OutputMode,
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
    match output_mode {
        OutputMode::Foreground => {
            command.stdout(Stdio::inherit()).stderr(Stdio::inherit());
        }
        OutputMode::Background => {
            let log = open_log(&runtime_dir.join("scheduler.log"))?;
            let error_log = log.try_clone().map_err(io_error("scheduler_log_failed"))?;
            command
                .stdout(Stdio::from(log))
                .stderr(Stdio::from(error_log));
        }
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

pub(super) fn scheduler_command(release: &Path, runtime_dir: &Path) -> Command {
    let mut command = Command::new(release);
    command
        .arg("start")
        .kill_on_drop(true)
        .current_dir(runtime_dir);
    command
}

pub(super) async fn terminate_child(child: &mut Child) -> AppResult<()> {
    terminate_child_with_timeout(child, Duration::from_secs(5)).await
}

pub(super) async fn terminate_child_with_timeout(
    child: &mut Child,
    timeout: Duration,
) -> AppResult<()> {
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

pub(super) async fn publish_metadata(
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

pub(super) async fn spawn_supervisor(
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

pub(super) fn signal_process(pid: u32, signal: i32) -> AppResult<()> {
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
