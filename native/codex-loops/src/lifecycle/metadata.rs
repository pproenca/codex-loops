use super::*;

pub(super) fn read_metadata(client: &SchedulerClient) -> AppResult<Option<RuntimeMetadata>> {
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

pub(super) fn validate_metadata(
    client: &SchedulerClient,
    metadata: &RuntimeMetadata,
) -> AppResult<()> {
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

pub(super) fn write_metadata(
    client: &SchedulerClient,
    metadata: &RuntimeMetadata,
) -> AppResult<()> {
    let path = metadata_path(client)?;
    let temp = path.with_extension("json.tmp");
    let bytes = serde_json::to_vec(metadata)
        .map_err(|error| AppError::new(6, "scheduler_metadata_invalid", error.to_string()))?;
    fs::write(&temp, bytes).map_err(io_error("scheduler_metadata_invalid"))?;
    fs::rename(&temp, &path).map_err(io_error("scheduler_metadata_invalid"))
}

pub(super) fn remove_stale_metadata(client: &SchedulerClient) -> AppResult<()> {
    match fs::remove_file(metadata_path(client)?) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(io_error("scheduler_metadata_invalid")(error)),
    }
}
