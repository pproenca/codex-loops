use std::{
    ffi::OsString,
    path::{Path, PathBuf},
};

use serde_json::json;
use tokio::process::Command;

use crate::error::{AppError, AppResult, ExitStatus};

pub(super) struct Repository {
    pub root: PathBuf,
    pub script_relative: PathBuf,
}

pub(super) struct WorktreeSnapshot {
    pub status: String,
    pub diff: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum RemoveMode {
    PreserveDirty,
    Force,
}

struct GitOutput {
    stdout: String,
}

pub(super) async fn discover(script: &Path) -> AppResult<Repository> {
    let script = tokio::fs::canonicalize(script).await.map_err(|error| {
        AppError::new(
            ExitStatus::Usage,
            "sandbox_script_not_found",
            "The sandbox workflow script does not exist.",
        )
        .details(json!({"script_path": script, "reason": error.to_string()}))
    })?;
    let parent = script.parent().ok_or_else(|| {
        AppError::new(
            ExitStatus::Usage,
            "sandbox_script_invalid",
            "The sandbox workflow script has no parent directory.",
        )
        .details(json!({"script_path": script}))
    })?;
    let output = git(parent, vec!["rev-parse".into(), "--show-toplevel".into()]).await?;
    let root = PathBuf::from(output.stdout.trim());
    let root = tokio::fs::canonicalize(&root).await.map_err(|error| {
        AppError::new(
            ExitStatus::Runtime,
            "sandbox_repository_invalid",
            "Git returned a repository root that could not be resolved.",
        )
        .details(json!({"repository": root, "reason": error.to_string()}))
    })?;
    let script_relative = script.strip_prefix(&root).map_err(|error| {
        AppError::new(
            ExitStatus::Usage,
            "sandbox_script_outside_repository",
            "The workflow script must be inside its Git repository.",
        )
        .details(json!({
            "repository": root,
            "script_path": script,
            "reason": error.to_string()
        }))
    })?;
    let status = git(
        &root,
        vec![
            "status".into(),
            "--porcelain=v1".into(),
            "--".into(),
            script_relative.as_os_str().to_owned(),
        ],
    )
    .await?;
    if !status.stdout.trim().is_empty() {
        return Err(AppError::new(
            ExitStatus::Conflict,
            "sandbox_script_uncommitted",
            "The sandbox workflow script must be committed before creating a detached worktree.",
        )
        .details(json!({
            "repository": root,
            "script_path": script,
            "status": status.stdout
        }))
        .next_steps(["Commit the workflow script, then rerun `sandbox-run`."]));
    }
    Ok(Repository {
        root,
        script_relative: script_relative.to_path_buf(),
    })
}

pub(super) async fn add_detached(repository: &Repository, worktree: &Path) -> AppResult<()> {
    git(
        &repository.root,
        vec![
            "worktree".into(),
            "add".into(),
            "--detach".into(),
            worktree.as_os_str().to_owned(),
            "HEAD".into(),
        ],
    )
    .await
    .map(|_output| ())
}

pub(super) async fn snapshot(worktree: &Path) -> AppResult<WorktreeSnapshot> {
    let status = git(
        worktree,
        vec![
            "status".into(),
            "--porcelain=v1".into(),
            "--untracked-files=all".into(),
        ],
    )
    .await?;
    let diff = git(
        worktree,
        vec![
            "diff".into(),
            "--binary".into(),
            "--no-ext-diff".into(),
            "HEAD".into(),
        ],
    )
    .await?;
    Ok(WorktreeSnapshot {
        status: status.stdout,
        diff: diff.stdout,
    })
}

pub(super) async fn remove(repository: &Path, worktree: &Path, mode: RemoveMode) -> AppResult<()> {
    let mut args = vec!["worktree".into(), "remove".into()];
    match mode {
        RemoveMode::PreserveDirty => {}
        RemoveMode::Force => args.push("--force".into()),
    }
    args.push(worktree.as_os_str().to_owned());
    git(repository, args).await.map(|_output| ())
}

async fn git(directory: &Path, args: Vec<OsString>) -> AppResult<GitOutput> {
    let output = Command::new("git")
        .arg("-C")
        .arg(directory)
        .args(&args)
        .output()
        .await
        .map_err(|error| {
            AppError::new(
                ExitStatus::Command,
                "sandbox_git_failed",
                "Could not start Git while preparing the sandbox.",
            )
            .details(json!({
                "directory": directory,
                "arguments": args,
                "reason": error.to_string()
            }))
        })?;
    let stdout = String::from_utf8(output.stdout).map_err(|error| {
        AppError::new(
            ExitStatus::Runtime,
            "sandbox_git_output_invalid",
            "Git returned output that was not valid UTF-8.",
        )
        .details(json!({"reason": error.to_string()}))
    })?;
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_owned();
    if output.status.success() {
        Ok(GitOutput { stdout })
    } else {
        Err(AppError::new(
            ExitStatus::Command,
            "sandbox_git_failed",
            "Git could not prepare or inspect the sandbox worktree.",
        )
        .details(json!({
            "directory": directory,
            "arguments": args,
            "status": output.status.code(),
            "stderr": stderr
        })))
    }
}
