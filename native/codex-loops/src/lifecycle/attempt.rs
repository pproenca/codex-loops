use super::*;

pub(super) struct StartAttempt {
    pub owner_token: String,
    marker: PathBuf,
    marker_lock: File,
}

impl StartAttempt {
    pub(super) fn new(client: &SchedulerClient) -> AppResult<Self> {
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
