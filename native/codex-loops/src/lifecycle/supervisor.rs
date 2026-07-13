use super::*;

pub(super) struct SupervisionRequest {
    pub client: SchedulerClient,
    pub config: SchedulerConfig,
    pub output_mode: OutputMode,
    pub owner_token: OwnerToken,
}

pub(super) async fn supervise(request: SupervisionRequest) -> AppResult<()> {
    let SupervisionRequest {
        client,
        config,
        output_mode,
        owner_token,
    } = request;
    let runtime_dir = runtime_dir(&client)?;
    let Some(_owner_lock) = blocking("acquire the scheduler owner lease", move || {
        acquire_owner_lock(runtime_dir.as_path())
    })
    .await?
    else {
        return Ok(());
    };
    // The advisory lock is the cross-process ownership proof. It intentionally
    // remains held for the entire supervision loop and is released when this
    // function returns and the File is dropped.
    remove_stale_metadata(&client).await?;

    let scheduler_root = blocking("resolve the packaged scheduler runtime", || {
        scheduler_release_root()
    })
    .await?;
    let mut metadata = RuntimeMetadata::new(
        owner_token,
        scheduler_port(&client)?,
        scheduler_root,
        config,
    )?;
    write_metadata(&client, &metadata).await?;

    let mut backoff = Duration::from_millis(100);
    loop {
        let started_at = Instant::now();
        let mut child = match spawn_scheduler(&client, &metadata.config, output_mode).await {
            Ok(child) => child,
            Err(error) => {
                remove_stale_metadata(&client).await?;
                return Err(error);
            }
        };
        metadata.scheduler_pid = child.id().and_then(std::num::NonZeroU32::new);
        let publication = match metadata.scheduler_pid {
            Some(_pid) => write_metadata(&client, &metadata).await,
            None => Err(AppError::new(
                ExitStatus::Runtime,
                "scheduler_start_failed",
                "The scheduler process has no valid process ID.",
            )),
        };
        publish_metadata(&mut child, publication).await?;

        tokio::select! {
            status = child.wait() => {
                let status = status.map_err(|error| AppError::new(ExitStatus::Runtime, "scheduler_wait_failed", error.to_string()))?;
                metadata.scheduler_pid = None;
                write_metadata(&client, &metadata).await?;
                eprintln!("Codex Loops scheduler exited unexpectedly with {status}; restarting in {} ms.", backoff.as_millis());
                if started_at.elapsed() >= Duration::from_secs(30) { backoff = Duration::from_millis(100); }
            }
            signal_result = termination_signal() => {
                signal_result?;
                terminate_child(&mut child).await?;
                remove_stale_metadata(&client).await?;
                return Ok(());
            }
        }

        tokio::select! {
            _ = sleep(backoff) => {}
            signal_result = termination_signal() => {
                signal_result?;
                remove_stale_metadata(&client).await?;
                return Ok(());
            }
        }
        backoff = (backoff * 2).min(Duration::from_secs(5));
    }
}

fn acquire_owner_lock(runtime_dir: &Path) -> AppResult<Option<File>> {
    fs::create_dir_all(runtime_dir).map_err(io_error("scheduler_runtime_invalid"))?;
    let owner_lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(runtime_dir.join("owner.lock"))
        .map_err(io_error("scheduler_runtime_invalid"))?;
    match owner_lock.try_lock_exclusive() {
        Ok(()) => Ok(Some(owner_lock)),
        Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => Ok(None),
        Err(error) => Err(io_error("scheduler_runtime_invalid")(error)),
    }
}
