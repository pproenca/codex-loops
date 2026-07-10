use super::*;

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
            Err(AppError::new(6, "scheduler_wait_failed", "Could not observe scheduler termination reliably.")
                .details(json!({"wait_error": wait_error.to_string(), "kill_error": kill_error, "final_wait_error": final_wait_error})))
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
pub(super) async fn termination_signal() -> AppResult<()> {
    use tokio::signal::unix::{SignalKind, signal};
    let mut terminate =
        signal(SignalKind::terminate()).map_err(io_error("scheduler_signal_failed"))?;
    let mut interrupt =
        signal(SignalKind::interrupt()).map_err(io_error("scheduler_signal_failed"))?;
    tokio::select! { _ = terminate.recv() => Ok(()), _ = interrupt.recv() => Ok(()) }
}

#[cfg(not(unix))]
pub(super) async fn termination_signal() -> AppResult<()> {
    signal::ctrl_c()
        .await
        .map_err(io_error("scheduler_signal_failed"))
}

#[cfg(test)]
mod tests {
    use super::*;

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
}
