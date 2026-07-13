use std::{
    env,
    path::{Path, PathBuf},
};

use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::{
    error::{AppError, AppResult, ExitStatus},
    runtime::CodexBinding,
    scheduler::{Provider, RunId},
};

use super::git::WorktreeSnapshot;

pub(super) const MANIFEST_FORMAT: &str = "codex-loops.sandbox.v1";

pub(super) struct Layout {
    pub artifact_dir: PathBuf,
    pub worktree: PathBuf,
    pub home: PathBuf,
    pub runtime: PathBuf,
    pub journal: PathBuf,
    pub transcript: PathBuf,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Manifest {
    pub format: String,
    pub version: String,
    pub artifact_dir: PathBuf,
    pub repository: PathBuf,
    pub worktree: PathBuf,
    pub script_path: PathBuf,
    pub runtime_dir: PathBuf,
    pub journal_path: PathBuf,
    pub transcript_path: PathBuf,
    pub run_id: String,
    pub provider: Provider,
    pub model: Option<String>,
    pub port: u16,
    pub server_url: String,
    pub state: String,
    pub codex_path: PathBuf,
    pub codex_version: String,
}

pub(super) async fn prepare_layout(
    output_dir: Option<&Path>,
    run_id: &RunId,
    home: &Path,
) -> AppResult<Layout> {
    let requested = output_dir.map(Path::to_path_buf).unwrap_or_else(|| {
        home.join(".codex/workflows/sandbox-runs")
            .join(run_id.as_str())
    });
    let requested = if requested.is_absolute() {
        requested
    } else {
        env::current_dir()
            .map_err(|error| {
                AppError::new(
                    ExitStatus::Runtime,
                    "sandbox_path_invalid",
                    "Could not resolve the current directory for the sandbox output.",
                )
                .details(json!({"reason": error.to_string()}))
            })?
            .join(requested)
    };
    if tokio::fs::try_exists(&requested).await.map_err(|error| {
        AppError::new(
            ExitStatus::Runtime,
            "sandbox_path_invalid",
            "Could not inspect the requested sandbox output directory.",
        )
        .details(json!({"artifact_dir": requested, "reason": error.to_string()}))
    })? {
        return Err(AppError::new(
            ExitStatus::Conflict,
            "sandbox_exists",
            "The requested sandbox artifact directory already exists.",
        )
        .details(json!({"artifact_dir": requested}))
        .next_steps(["Choose a different --output directory or clean the existing sandbox."]));
    }
    tokio::fs::create_dir_all(&requested)
        .await
        .map_err(|error| {
            AppError::new(
                ExitStatus::Runtime,
                "sandbox_artifact_failed",
                "Could not create the sandbox artifact directory.",
            )
            .details(json!({"artifact_dir": requested, "reason": error.to_string()}))
        })?;
    let artifact_dir = tokio::fs::canonicalize(&requested).await.map_err(|error| {
        AppError::new(
            ExitStatus::Runtime,
            "sandbox_path_invalid",
            "Could not resolve the sandbox artifact directory.",
        )
        .details(json!({"artifact_dir": requested, "reason": error.to_string()}))
    })?;
    let home = artifact_dir.join("home");
    let runtime = artifact_dir.join("runtime");
    tokio::fs::create_dir_all(&home).await.map_err(|error| {
        AppError::new(
            ExitStatus::Runtime,
            "sandbox_artifact_failed",
            "Could not create the isolated sandbox home directory.",
        )
        .details(json!({"path": home, "reason": error.to_string()}))
    })?;
    tokio::fs::create_dir_all(&runtime).await.map_err(|error| {
        AppError::new(
            ExitStatus::Runtime,
            "sandbox_artifact_failed",
            "Could not create the isolated scheduler runtime directory.",
        )
        .details(json!({"path": runtime, "reason": error.to_string()}))
    })?;
    Ok(Layout {
        worktree: artifact_dir.join("repo"),
        home,
        runtime,
        journal: artifact_dir.join("journal.sqlite"),
        transcript: artifact_dir.join("mcp-transcript.jsonl"),
        artifact_dir,
    })
}

pub(super) fn persist_binding(binding: &CodexBinding, home: &Path) -> AppResult<()> {
    binding.persist(&home.join(".codex/workflows/codex-binding.json"))
}

pub(super) async fn write_snapshot(layout: &Layout, snapshot: &WorktreeSnapshot) -> AppResult<()> {
    write_text(
        &layout.artifact_dir.join("git-status.txt"),
        &snapshot.status,
    )
    .await?;
    write_text(&layout.artifact_dir.join("git-diff.patch"), &snapshot.diff).await
}

pub(super) async fn write_json(path: &Path, value: &impl Serialize) -> AppResult<()> {
    let bytes = serde_json::to_vec_pretty(value).map_err(|error| {
        AppError::new(
            ExitStatus::Runtime,
            "sandbox_artifact_failed",
            "Could not encode a sandbox JSON artifact.",
        )
        .details(json!({"path": path, "reason": error.to_string()}))
    })?;
    tokio::fs::write(path, bytes).await.map_err(|error| {
        AppError::new(
            ExitStatus::Runtime,
            "sandbox_artifact_failed",
            "Could not write a sandbox JSON artifact.",
        )
        .details(json!({"path": path, "reason": error.to_string()}))
    })
}

pub(super) async fn read_manifest(path: &Path) -> AppResult<Manifest> {
    let bytes = tokio::fs::read(path).await.map_err(|error| {
        AppError::new(
            ExitStatus::Usage,
            "sandbox_manifest_invalid",
            "Could not read the sandbox manifest.",
        )
        .details(json!({"path": path, "reason": error.to_string()}))
    })?;
    serde_json::from_slice(&bytes).map_err(|error| {
        AppError::new(
            ExitStatus::Usage,
            "sandbox_manifest_invalid",
            "The sandbox manifest is invalid.",
        )
        .details(json!({"path": path, "reason": error.to_string()}))
    })
}

pub(super) fn validate_manifest(manifest: &Manifest, artifact_dir: &Path) -> AppResult<()> {
    if manifest.format != MANIFEST_FORMAT
        || manifest.artifact_dir != artifact_dir
        || !manifest.worktree.starts_with(artifact_dir)
        || !manifest.runtime_dir.starts_with(artifact_dir)
        || !manifest.journal_path.starts_with(artifact_dir)
        || !manifest.transcript_path.starts_with(artifact_dir)
    {
        return Err(AppError::new(
            ExitStatus::Usage,
            "sandbox_manifest_invalid",
            "The sandbox manifest does not describe a safely removable artifact directory.",
        )
        .details(json!({"artifact_dir": artifact_dir, "manifest": manifest})));
    }
    Ok(())
}

async fn write_text(path: &Path, value: &str) -> AppResult<()> {
    tokio::fs::write(path, value).await.map_err(|error| {
        AppError::new(
            ExitStatus::Runtime,
            "sandbox_artifact_failed",
            "Could not write a sandbox text artifact.",
        )
        .details(json!({"path": path, "reason": error.to_string()}))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn manifest(root: &Path) -> Manifest {
        Manifest {
            format: MANIFEST_FORMAT.into(),
            version: "0.0.0".into(),
            artifact_dir: root.to_path_buf(),
            repository: root.join("source"),
            worktree: root.join("repo"),
            script_path: root.join("repo/.codex/workflows/smoke.exs"),
            runtime_dir: root.join("runtime"),
            journal_path: root.join("journal.sqlite"),
            transcript_path: root.join("mcp-transcript.jsonl"),
            run_id: "sandbox:smoke:1".into(),
            provider: Provider::Mock,
            model: None,
            port: 49_123,
            server_url: "http://127.0.0.1:49123/".into(),
            state: "completed".into(),
            codex_path: root.join("codex"),
            codex_version: "codex-cli 0.0.0".into(),
        }
    }

    #[test]
    fn cleanup_manifest_paths_must_stay_inside_the_artifact_root() {
        let root = Path::new("/tmp/codex-loops-sandbox-test");
        let valid = manifest(root);
        assert!(validate_manifest(&valid, root).is_ok());

        let mut escaped = manifest(root);
        escaped.worktree = PathBuf::from("/tmp/unrelated-worktree");
        let error = validate_manifest(&escaped, root);
        assert!(matches!(error, Err(error) if error.code() == "sandbox_manifest_invalid"));
    }
}
