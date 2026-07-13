use std::num::NonZeroU32;

use super::*;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct VerifiedSchedulerProcess {
    pub pid: NonZeroU32,
}

pub(super) fn verified_scheduler_root(recorded: &Path) -> AppResult<VerifiedSchedulerRoot> {
    if !recorded.is_absolute() {
        return Err(AppError::new(
            ExitStatus::Runtime,
            "scheduler_metadata_invalid",
            "Scheduler metadata does not contain an absolute runtime identity.",
        )
        .details(json!({"scheduler_root": recorded})));
    }
    let root = recorded.canonicalize().map_err(|error| {
        AppError::new(
            ExitStatus::Runtime,
            "scheduler_metadata_invalid",
            "The recorded scheduler runtime no longer exists.",
        )
        .details(json!({"scheduler_root": recorded, "reason": error.to_string()}))
    })?;
    let installed = scheduler_release_root()?;
    if root != installed.as_path() {
        return Err(AppError::new(
            ExitStatus::Runtime,
            "scheduler_metadata_invalid",
            "The recorded scheduler does not belong to this installed runtime version.",
        )
        .details(json!({
            "recorded_root": root,
            "installed_root": installed,
            "installed_version": env!("CARGO_PKG_VERSION")
        })));
    }
    let launcher = root.join("bin/agent_loops");
    let release = root.join("releases").join(env!("CARGO_PKG_VERSION"));
    if !launcher.is_file() || !release.is_dir() {
        return Err(AppError::new(
            ExitStatus::Runtime,
            "scheduler_metadata_invalid",
            "The recorded process does not identify a complete scheduler runtime.",
        )
        .details(json!({
            "scheduler_root": root,
            "version": env!("CARGO_PKG_VERSION"),
            "launcher": launcher,
            "release": release
        })));
    }
    Ok(VerifiedSchedulerRoot::from_verified(root))
}

#[cfg(unix)]
pub(super) async fn validate_scheduler_process(
    metadata: &RuntimeMetadata,
) -> AppResult<VerifiedSchedulerProcess> {
    let pid = metadata.scheduler_pid.ok_or_else(|| {
        AppError::new(
            ExitStatus::Runtime,
            "scheduler_owner_unknown",
            "Scheduler metadata has no active child process.",
        )
    })?;
    let root = metadata.scheduler_root.clone();
    blocking("verify the scheduler process identity", move || {
        let executable = process_executable(pid)?;
        if scheduler_executable_matches(&executable, root.as_path()) {
            Ok(VerifiedSchedulerProcess { pid })
        } else {
            Err(AppError::new(
                ExitStatus::Runtime,
                "scheduler_owner_unknown",
                "Refusing to force-stop a process that is not the packaged scheduler.",
            )
            .details(json!({"scheduler_pid": pid, "executable": executable})))
        }
    })
    .await
}

#[cfg(target_os = "linux")]
fn process_executable(pid: NonZeroU32) -> AppResult<PathBuf> {
    fs::read_link(format!("/proc/{pid}/exe"))
        .and_then(fs::canonicalize)
        .map_err(io_error("scheduler_process_check_failed"))
}

#[cfg(target_os = "macos")]
fn process_executable(pid: NonZeroU32) -> AppResult<PathBuf> {
    const BUFFER_SIZE: usize = 4_096;
    let mut buffer = [0_u8; BUFFER_SIZE];
    #[link(name = "proc")]
    unsafe extern "C" {
        fn proc_pidpath(pid: libc::c_int, buffer: *mut libc::c_void, size: u32) -> libc::c_int;
    }
    let length = unsafe {
        proc_pidpath(
            pid.get() as libc::c_int,
            buffer.as_mut_ptr().cast(),
            BUFFER_SIZE as u32,
        )
    };
    if length <= 0 {
        return Err(AppError::new(
            ExitStatus::Runtime,
            "scheduler_process_check_failed",
            "Could not resolve the scheduler process executable.",
        )
        .details(json!({"scheduler_pid": pid})));
    }
    let path_length = buffer[..length as usize]
        .iter()
        .position(|byte| *byte == 0)
        .unwrap_or(length as usize);
    let path = std::str::from_utf8(&buffer[..path_length]).map_err(|error| {
        AppError::new(
            ExitStatus::Runtime,
            "scheduler_process_check_failed",
            "The scheduler executable path is not valid UTF-8.",
        )
        .details(json!({"scheduler_pid": pid, "reason": error.to_string()}))
    })?;
    PathBuf::from(path)
        .canonicalize()
        .map_err(io_error("scheduler_process_check_failed"))
}

#[cfg(all(unix, not(any(target_os = "linux", target_os = "macos"))))]
fn process_executable(pid: NonZeroU32) -> AppResult<PathBuf> {
    Err(AppError::new(
        ExitStatus::Runtime,
        "force_stop_unsupported",
        "Safe forced stop is not supported on this Unix platform.",
    )
    .details(json!({"scheduler_pid": pid})))
}

#[cfg(unix)]
fn scheduler_executable_matches(executable: &Path, root: &Path) -> bool {
    let Ok(relative) = executable.strip_prefix(root) else {
        return false;
    };
    let components: Vec<_> = relative
        .components()
        .map(|component| component.as_os_str().to_string_lossy())
        .collect();
    matches!(components.as_slice(), [bin, launcher] if bin == "bin" && launcher == "agent_loops")
        || matches!(components.as_slice(), [erts, bin, beam] if erts.starts_with("erts-") && bin == "bin" && beam == "beam.smp")
}

#[cfg(not(unix))]
pub(super) async fn validate_scheduler_process(
    metadata: &RuntimeMetadata,
) -> AppResult<VerifiedSchedulerProcess> {
    Err(AppError::new(
        ExitStatus::Runtime,
        "force_stop_unsupported",
        "Safe forced stop is not supported on this platform.",
    )
    .details(json!({"scheduler_pid": metadata.scheduler_pid})))
}

pub(super) fn scheduler_release_root() -> AppResult<VerifiedSchedulerRoot> {
    let root = crate::runtime::Bundle::installed()?
        .scheduler_root()
        .canonicalize()
        .map_err(|error| {
            AppError::new(
                ExitStatus::Runtime,
                "runtime_invalid",
                "Scheduler release path is invalid.",
            )
            .details(json!({"reason": error.to_string()}))
        })?;
    Ok(VerifiedSchedulerRoot::from_verified(root))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    #[test]
    fn executable_identity_requires_a_known_exact_runtime_path() {
        let root = Path::new("/opt/codex-loops/libexec/scheduler");
        assert!(scheduler_executable_matches(
            Path::new("/opt/codex-loops/libexec/scheduler/erts-15.2/bin/beam.smp"),
            root
        ));
        assert!(!scheduler_executable_matches(
            Path::new("/tmp/prefix-opt/codex-loops/libexec/scheduler/erts-15.2/bin/beam.smp"),
            root
        ));
        assert!(!scheduler_executable_matches(
            Path::new("/opt/codex-loops/libexec/scheduler/bin/not-agent_loops"),
            root
        ));
    }
}
