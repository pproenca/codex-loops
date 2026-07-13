use std::path::Path;

use serde_json::{Value, json};
use tokio::process::Command;

use crate::error::{AppError, AppResult, ExitStatus};

pub(super) struct SchedulerSpawnOptions<'a> {
    pub executable: &'a Path,
    pub worktree: &'a Path,
    pub home: &'a Path,
    pub codex_home: &'a Path,
    pub runtime: &'a Path,
    pub journal: &'a Path,
    pub port: u16,
    pub model: Option<&'a str>,
    pub inherit_access_token: bool,
}

pub(super) async fn start_scheduler(options: SchedulerSpawnOptions<'_>) -> AppResult<Value> {
    let executable = options.executable.to_path_buf();
    let mut command = scheduler_command(&options);
    let output = command.output().await.map_err(|error| {
        AppError::new(
            ExitStatus::Command,
            "sandbox_scheduler_start_failed",
            "Could not start the isolated sandbox scheduler.",
        )
        .details(json!({"executable": executable, "reason": error.to_string()}))
    })?;
    if !output.status.success() {
        return Err(AppError::new(
            ExitStatus::Command,
            "sandbox_scheduler_start_failed",
            "Could not start the isolated sandbox scheduler.",
        )
        .details(json!({
            "status": output.status.code(),
            "stderr": String::from_utf8_lossy(&output.stderr),
            "stdout": String::from_utf8_lossy(&output.stdout)
        })));
    }
    serde_json::from_slice(&output.stdout).map_err(|error| {
        AppError::new(
            ExitStatus::Runtime,
            "sandbox_scheduler_start_failed",
            "The sandbox scheduler start command returned invalid JSON.",
        )
        .details(json!({
            "reason": error.to_string(),
            "stdout": String::from_utf8_lossy(&output.stdout)
        }))
    })
}

fn scheduler_command(options: &SchedulerSpawnOptions<'_>) -> Command {
    let mut command = Command::new(options.executable);
    command
        .arg("serve")
        .arg("--host")
        .arg("127.0.0.1")
        .arg("--port")
        .arg(options.port.to_string())
        .arg("--journal")
        .arg(options.journal)
        .arg("--json")
        .current_dir(options.worktree)
        .env("HOME", options.home)
        .env("CODEX_HOME", options.codex_home)
        .env("CODEX_LOOPS_RUNTIME_DIR", options.runtime)
        .env("CODEX_LOOPS_SCHEDULER_HOST", "127.0.0.1")
        .env("CODEX_LOOPS_SCHEDULER_PORT", options.port.to_string())
        .env("CODEX_LOOPS_JOURNAL_PATH", options.journal)
        .env("CODEX_LOOPS_CODEX_SANDBOX", "workspace-write")
        .env("CODEX_LOOPS_CODEX_WORKDIR", options.worktree)
        .env_remove("CODEX_LOOPS_SCHEDULER_URL");
    if !options.inherit_access_token {
        command.env_remove("CODEX_ACCESS_TOKEN");
    }
    if let Some(model) = options.model {
        command.arg("--model").arg(model);
        command.env("CODEX_LOOPS_CODEX_MODEL", model);
    }
    command
}

#[cfg(test)]
mod tests {
    use std::{collections::BTreeMap, ffi::OsStr};

    use super::*;

    #[test]
    fn sandbox_scheduler_command_owns_its_isolated_runtime() {
        let root = tempfile::tempdir().unwrap();
        let home = root.path().join("home");
        let codex_home = home.join("codex-home");
        let options = SchedulerSpawnOptions {
            executable: Path::new("/opt/codex-loops"),
            worktree: &root.path().join("repo"),
            home: &home,
            codex_home: &codex_home,
            runtime: &root.path().join("runtime"),
            journal: &root.path().join("journal.sqlite"),
            port: 47_125,
            model: Some("proof-model"),
            inherit_access_token: false,
        };

        let command = scheduler_command(&options);
        let command = command.as_std();
        let args: Vec<_> = command.get_args().collect();
        let env: BTreeMap<_, _> = command.get_envs().collect();

        assert_eq!(command.get_current_dir(), Some(options.worktree));
        assert_eq!(
            args,
            [
                "serve",
                "--host",
                "127.0.0.1",
                "--port",
                "47125",
                "--journal",
                options.journal.to_str().unwrap(),
                "--json",
                "--model",
                "proof-model"
            ]
        );
        assert_eq!(
            env.get(OsStr::new("CODEX_LOOPS_RUNTIME_DIR")),
            Some(&Some(options.runtime.as_os_str()))
        );
        assert_eq!(
            env.get(OsStr::new("CODEX_LOOPS_JOURNAL_PATH")),
            Some(&Some(options.journal.as_os_str()))
        );
        assert_eq!(
            env.get(OsStr::new("CODEX_LOOPS_SCHEDULER_URL")),
            Some(&None)
        );
        assert_eq!(
            env.get(OsStr::new("CODEX_HOME")),
            Some(&Some(codex_home.as_os_str()))
        );
        assert!(codex_home.starts_with(&home));
        assert_eq!(env.get(OsStr::new("CODEX_ACCESS_TOKEN")), Some(&None));
    }

    #[test]
    fn token_authenticated_scheduler_inherits_the_existing_token_without_copying_it() {
        let root = tempfile::tempdir().unwrap();
        let home = root.path().join("home");
        let options = SchedulerSpawnOptions {
            executable: Path::new("/opt/codex-loops"),
            worktree: &root.path().join("repo"),
            home: &home,
            codex_home: &home.join("codex-home"),
            runtime: &root.path().join("runtime"),
            journal: &root.path().join("journal.sqlite"),
            port: 47_125,
            model: None,
            inherit_access_token: true,
        };

        let command = scheduler_command(&options);
        let env: BTreeMap<_, _> = command.as_std().get_envs().collect();

        assert!(!env.contains_key(OsStr::new("CODEX_ACCESS_TOKEN")));
    }
}
