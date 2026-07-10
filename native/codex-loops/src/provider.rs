use std::{ffi::OsString, process::ExitCode};

use crate::runtime;

pub fn exec(args: Vec<OsString>) -> ExitCode {
    let binding = match runtime::CodexBinding::load(&match runtime::binding_path() {
        Ok(path) => path,
        Err(error) => {
            eprintln!("{error}");
            return ExitCode::from(127);
        }
    }) {
        Ok(binding) => binding,
        Err(error) => {
            eprintln!("{error}");
            return ExitCode::from(127);
        }
    };

    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        let error = std::process::Command::new(binding.path).args(args).exec();
        eprintln!("Could not execute the configured Codex command: {error}");
        ExitCode::from(127)
    }
    #[cfg(not(unix))]
    {
        match std::process::Command::new(binding.path).args(args).status() {
            Ok(status) => ExitCode::from(status.code().unwrap_or(1) as u8),
            Err(error) => {
                eprintln!("Could not execute the configured Codex command: {error}");
                ExitCode::from(127)
            }
        }
    }
}
