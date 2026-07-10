use super::*;

pub(super) fn runtime_dir(client: &SchedulerClient) -> AppResult<PathBuf> {
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

pub(super) fn scheduler_port(client: &SchedulerClient) -> AppResult<u16> {
    client
        .base_url()
        .port_or_known_default()
        .ok_or_else(|| AppError::new(2, "scheduler_url_invalid", "Scheduler URL has no port."))
}

pub(super) fn metadata_path(client: &SchedulerClient) -> AppResult<PathBuf> {
    Ok(runtime_dir(client)?.join("owner.json"))
}

pub(super) fn log_path(client: &SchedulerClient) -> AppResult<PathBuf> {
    Ok(runtime_dir(client)?.join("scheduler.log"))
}

pub(super) fn owner_lock_is_held(client: &SchedulerClient) -> AppResult<bool> {
    let runtime_dir = runtime_dir(client)?;
    if !runtime_dir.is_dir() {
        return Ok(false);
    }
    owner_lock_is_held_at(&runtime_dir.join("owner.lock"))
}

pub(super) fn owner_lock_is_held_at(path: &Path) -> AppResult<bool> {
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
pub(super) fn validate_scheduler_process(
    metadata: &RuntimeMetadata,
) -> AppResult<VerifiedSchedulerProcess> {
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
pub(super) fn validate_scheduler_process(
    metadata: &RuntimeMetadata,
) -> AppResult<VerifiedSchedulerProcess> {
    Err(AppError::new(
        6,
        "force_stop_unsupported",
        "Safe forced stop is not supported on this platform.",
    )
    .details(json!({"scheduler_pid": metadata.scheduler_pid})))
}

pub(super) fn scheduler_release_root() -> AppResult<PathBuf> {
    Runtime::installed()?
        .bundle
        .scheduler_root()
        .canonicalize()
        .ok()
        .ok_or_else(|| AppError::new(6, "runtime_invalid", "Scheduler release path is invalid."))
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

pub(super) fn open_log(path: &Path) -> AppResult<File> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(io_error("scheduler_log_failed"))?;
    }
    OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(io_error("scheduler_log_failed"))
}
