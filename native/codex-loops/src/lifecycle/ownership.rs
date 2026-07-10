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
}
