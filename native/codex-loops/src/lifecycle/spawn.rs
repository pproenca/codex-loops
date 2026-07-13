use super::*;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum OutputMode {
    Background,
    Foreground,
}

pub(super) async fn spawn_scheduler(
    client: &SchedulerClient,
    config: &SchedulerConfig,
    output_mode: OutputMode,
) -> AppResult<Child> {
    let client = client.clone();
    let config = config.clone();
    blocking("start the packaged scheduler", move || {
        spawn_scheduler_blocking(&client, &config, output_mode)
    })
    .await
}

fn spawn_scheduler_blocking(
    client: &SchedulerClient,
    config: &SchedulerConfig,
    output_mode: OutputMode,
) -> AppResult<Child> {
    let runtime_dir = runtime_dir(client)?;
    let bundle = crate::runtime::Bundle::installed()?;
    let release = bundle.scheduler();
    let port = scheduler_port(client)?;
    let mut command = scheduler_command(&release, runtime_dir.as_path());
    command
        .env("CODEX_LOOPS_SERVER", "1")
        .env("CODEX_LOOPS_HOST", config.bind_host.as_str())
        .env("CODEX_LOOPS_PORT", port.to_string())
        .env("PORT", port.to_string())
        .env("RELEASE_DISTRIBUTION", "none")
        .env("RELEASE_TMP", runtime_dir.join("release"))
        .env("CODEX_LOOPS_CODEX_BIN", bundle.control_plane())
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
    if let Some(journal) = &config.journal {
        command.env("CODEX_LOOPS_JOURNAL_PATH", journal.as_path());
    }
    if let Some(model) = &config.model {
        command.env("CODEX_LOOPS_CODEX_MODEL", model);
    }
    command.spawn().map_err(|error| {
        AppError::new(
            ExitStatus::Runtime,
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
        .current_dir(runtime_dir);
    command
}

pub(super) async fn publish_metadata(
    child: &mut Child,
    publication: AppResult<()>,
) -> AppResult<()> {
    if let Err(error) = publication {
        if let Err(cleanup_error) = terminate_child(child).await {
            return Err(AppError::new(ExitStatus::Runtime, "scheduler_cleanup_failed", "Scheduler startup failed and its child cleanup also failed.")
                .details(json!({"startup_error": error.diagnostic(), "cleanup_error": cleanup_error.diagnostic()})));
        }
        return Err(error);
    }
    Ok(())
}

pub(super) async fn spawn_supervisor(
    client: &SchedulerClient,
    options: &StartOptions,
    owner_token: &OwnerToken,
) -> AppResult<()> {
    let client = client.clone();
    let options = options.clone();
    let owner_token = owner_token.clone();
    blocking("start the scheduler supervisor", move || {
        spawn_supervisor_blocking(&client, &options, &owner_token)
    })
    .await
}

fn spawn_supervisor_blocking(
    client: &SchedulerClient,
    options: &StartOptions,
    owner_token: &OwnerToken,
) -> AppResult<()> {
    let executable = env::current_exe().map_err(io_error("runtime_invalid"))?;
    let log = open_log(&log_path(client)?)?;
    let error_log = log.try_clone().map_err(io_error("scheduler_log_failed"))?;
    let runtime_dir = runtime_dir(client)?;
    let mut command = Command::new(executable);
    command
        .arg("daemon")
        .env("CODEX_LOOPS_INTERNAL_DAEMON", "1")
        .env("CODEX_LOOPS_OWNER_TOKEN", owner_token.as_str())
        .env("CODEX_LOOPS_SCHEDULER_URL", client.base_url().as_str())
        .env("CODEX_LOOPS_RUNTIME_DIR", runtime_dir.as_path())
        .stdin(Stdio::null())
        .stdout(Stdio::from(log))
        .stderr(Stdio::from(error_log));
    if let Some(bind_host) = &options.bind_host {
        command.env("CODEX_LOOPS_BIND_HOST", bind_host.as_str());
    }
    if let Some(journal) = &options.journal {
        command.env("CODEX_LOOPS_JOURNAL_PATH", journal.as_path());
    }
    if let Some(model) = &options.model {
        command.env("CODEX_LOOPS_CODEX_MODEL", model);
    }
    command.spawn().map_err(|error| {
        AppError::new(
            ExitStatus::Runtime,
            "scheduler_start_failed",
            "Could not start the scheduler supervisor.",
        )
        .details(json!({"reason": error.to_string()}))
    })?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scheduler_process_runs_from_the_stable_runtime_directory() {
        let root = tempfile::tempdir().unwrap();
        let release = root.path().join("release/bin/agent_loops");
        let runtime = root.path().join("runtime");
        let command = scheduler_command(&release, &runtime);
        assert_eq!(command.as_std().get_current_dir(), Some(runtime.as_path()));
        assert_ne!(command.as_std().get_current_dir(), release.parent());
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
        let error = publish_metadata(
            &mut child,
            Err(AppError::new(
                ExitStatus::Runtime,
                "scheduler_metadata_invalid",
                "fixture failure",
            )),
        )
        .await
        .unwrap_err();
        assert_eq!(error.code(), "scheduler_metadata_invalid");
        assert_eq!(unsafe { libc::kill(pid as i32, 0) }, -1);
    }
}
