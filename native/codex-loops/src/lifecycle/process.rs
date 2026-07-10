use super::*;

pub(super) fn verified_scheduler_root(metadata: &RuntimeMetadata) -> AppResult<PathBuf> {
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
    let installed = scheduler_release_root()?;
    if root != installed || metadata.version != env!("CARGO_PKG_VERSION") {
        return Err(AppError::new(
            6,
            "scheduler_metadata_invalid",
            "The recorded scheduler does not belong to this installed runtime version.",
        )
        .details(json!({
            "recorded_root": root,
            "installed_root": installed,
            "recorded_version": metadata.version,
            "installed_version": env!("CARGO_PKG_VERSION")
        })));
    }
    let launcher = root.join("bin/agent_loops");
    let release = root.join("releases").join(&metadata.version);
    if !launcher.is_file() || !release.is_dir() {
        return Err(AppError::new(
            6,
            "scheduler_metadata_invalid",
            "The recorded process does not identify a complete scheduler runtime.",
        )
        .details(json!({"scheduler_root": root, "version": metadata.version, "launcher": launcher, "release": release})));
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
    let executable = process_executable(pid)?;
    if scheduler_executable_matches(&executable, &root) {
        Ok(VerifiedSchedulerProcess { pid })
    } else {
        Err(AppError::new(
            6,
            "scheduler_owner_unknown",
            "Refusing to force-stop a process that is not the packaged scheduler.",
        )
        .details(json!({"scheduler_pid": pid, "executable": executable})))
    }
}

#[cfg(target_os = "linux")]
fn process_executable(pid: u32) -> AppResult<PathBuf> {
    fs::read_link(format!("/proc/{pid}/exe"))
        .and_then(fs::canonicalize)
        .map_err(io_error("scheduler_process_check_failed"))
}

#[cfg(target_os = "macos")]
fn process_executable(pid: u32) -> AppResult<PathBuf> {
    const BUFFER_SIZE: usize = 4_096;
    let mut buffer = [0_u8; BUFFER_SIZE];
    #[link(name = "proc")]
    unsafe extern "C" {
        fn proc_pidpath(pid: libc::c_int, buffer: *mut libc::c_void, size: u32) -> libc::c_int;
    }
    let length = unsafe {
        proc_pidpath(
            pid as libc::c_int,
            buffer.as_mut_ptr().cast(),
            BUFFER_SIZE as u32,
        )
    };
    if length <= 0 {
        return Err(AppError::new(
            6,
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
            6,
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
fn process_executable(pid: u32) -> AppResult<PathBuf> {
    Err(AppError::new(
        6,
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
