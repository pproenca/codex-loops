use super::*;

pub(super) struct StartAttempt {
    pub owner_token: OwnerToken,
    marker: PathBuf,
    marker_lock: File,
}

impl StartAttempt {
    pub(super) async fn new(client: &SchedulerClient) -> AppResult<Self> {
        let owner_token = new_owner_token()?;
        let directory = runtime_dir(client)?.join("attempts");
        let marker = directory.join(owner_token.as_str());
        blocking("create a scheduler startup lease", move || {
            fs::create_dir_all(&directory).map_err(io_error("scheduler_runtime_invalid"))?;
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
        })
        .await
    }

    pub(super) async fn finish(self) -> AppResult<()> {
        blocking("release the scheduler startup lease", move || {
            FileExt::unlock(&self.marker_lock).map_err(io_error("scheduler_runtime_invalid"))?;
            match fs::remove_file(&self.marker) {
                Ok(()) => Ok(()),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
                Err(error) => Err(io_error("scheduler_runtime_invalid")(error)),
            }
        })
        .await
    }
}
