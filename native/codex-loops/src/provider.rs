use std::{
    ffi::OsString,
    path::Path,
    process::{Command, ExitCode},
};

use crate::{
    error::{AppError, AppResult, ExitStatus},
    runtime::{self, CodexBinding},
};

const PROVIDER_UNAVAILABLE: u8 = 127;

pub fn exec(args: Vec<OsString>) -> ExitCode {
    match execute(args) {
        Ok(exit_code) => exit_code,
        Err(error) => {
            eprintln!("{error}");
            ExitCode::from(PROVIDER_UNAVAILABLE)
        }
    }
}

fn execute(args: Vec<OsString>) -> AppResult<ExitCode> {
    let binding_path = runtime::binding_path()?;
    let binding = CodexBinding::load(&binding_path)?;

    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        let error = Command::new(binding.path()).args(args).exec();
        Err(command_error(binding.path(), &error))
    }
    #[cfg(not(unix))]
    {
        let status = Command::new(binding.path())
            .args(args)
            .status()
            .map_err(|error| command_error(binding.path(), &error))?;
        Ok(status
            .code()
            .and_then(|code| u8::try_from(code).ok())
            .map_or(ExitCode::FAILURE, ExitCode::from))
    }
}

fn command_error(path: &Path, error: &std::io::Error) -> AppError {
    AppError::new(
        ExitStatus::Command,
        "codex_command_failed",
        "Could not execute the configured Codex command.",
    )
    .details(serde_json::json!({"path": path, "reason": error.to_string()}))
    .next_steps(["Rerun `codex-loops install --codex /absolute/path/to/codex`."])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn execution_failure_is_a_typed_command_error() {
        let error = command_error(
            Path::new("/missing/codex"),
            &std::io::Error::from(std::io::ErrorKind::NotFound),
        );

        assert_eq!(error.status(), ExitStatus::Command);
        assert_eq!(error.code(), "codex_command_failed");
    }
}
