use super::*;

pub(super) struct SupervisionRequest {
    pub client: SchedulerClient,
    pub options: StartOptions,
    pub output_mode: OutputMode,
    pub owner_token: String,
}

pub(super) async fn supervise(request: SupervisionRequest) -> AppResult<()> {
    let SupervisionRequest {
        client,
        options,
        output_mode,
        owner_token,
    } = request;
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
                if started_at.elapsed() >= Duration::from_secs(30) { backoff = Duration::from_millis(100); }
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
