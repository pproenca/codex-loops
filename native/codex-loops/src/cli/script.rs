use std::path::{Path, PathBuf};

use serde_json::json;

use crate::error::{AppError, AppResult, ExitStatus};

#[derive(Debug, PartialEq, Eq)]
pub struct ResolvedWorkflowScript {
    script_path: Box<str>,
    workspace_root: Box<str>,
}

pub struct ResolvedWorkflowLocation {
    pub script_path: String,
    pub workspace_root: String,
}

impl ResolvedWorkflowScript {
    pub async fn resolve(path: &Path) -> AppResult<Self> {
        Self::resolve_from(path, None).await
    }

    pub async fn resolve_from(path: &Path, workspace_root: Option<&Path>) -> AppResult<Self> {
        let canonical_workspace_root = match workspace_root {
            Some(root) => Some(resolve_workspace_root(root).await?),
            None => None,
        };
        let candidate = if path.is_absolute() {
            path.to_path_buf()
        } else if let Some(root) = &canonical_workspace_root {
            root.join(path)
        } else {
            PathBuf::from(path)
        };
        let resolved = tokio::fs::canonicalize(&candidate).await.map_err(|error| {
            AppError::new(
                ExitStatus::Usage,
                "script_not_found",
                format!("Workflow script does not exist: {}", candidate.display()),
            )
            .details(json!({"script_path": candidate, "reason": error.to_string()}))
        })?;
        let metadata = tokio::fs::metadata(&resolved).await.map_err(|error| {
            AppError::new(
                ExitStatus::Usage,
                "script_not_found",
                format!("Workflow script does not exist: {}", resolved.display()),
            )
            .details(json!({"script_path": resolved, "reason": error.to_string()}))
        })?;
        if !metadata.is_file() {
            return Err(AppError::new(
                ExitStatus::Usage,
                "script_not_found",
                format!("Workflow script is not a file: {}", resolved.display()),
            ));
        }
        let workspace_root = match canonical_workspace_root {
            Some(root) if resolved.starts_with(&root) => root,
            Some(root) => {
                return Err(AppError::new(
                    ExitStatus::Usage,
                    "script_outside_workspace",
                    "Workflow script resolves outside the supplied workspace root.",
                )
                .details(json!({"script_path": resolved, "workspace_root": root})));
            }
            None => inferred_workspace_root(&resolved).await?,
        };
        let script_path = path_text(
            resolved,
            "script_path_invalid",
            "Workflow script path must be valid UTF-8.",
        )?;
        let workspace_root = path_text(
            workspace_root,
            "workspace_root_invalid",
            "Workflow workspace root must be valid UTF-8.",
        )?;
        Ok(Self {
            script_path: script_path.into_boxed_str(),
            workspace_root: workspace_root.into_boxed_str(),
        })
    }

    pub fn as_str(&self) -> &str {
        &self.script_path
    }

    pub fn as_path(&self) -> &Path {
        Path::new(self.as_str())
    }

    #[cfg(test)]
    pub fn workspace_root(&self) -> &Path {
        Path::new(&*self.workspace_root)
    }

    pub fn into_location(self) -> ResolvedWorkflowLocation {
        ResolvedWorkflowLocation {
            script_path: self.script_path.into(),
            workspace_root: self.workspace_root.into(),
        }
    }
}

async fn resolve_workspace_root(root: &Path) -> AppResult<PathBuf> {
    if !root.is_absolute() {
        return Err(AppError::new(
            ExitStatus::Usage,
            "workspace_root_invalid",
            "Workflow workspace root must be an absolute path.",
        )
        .details(json!({"workspace_root": root})));
    }
    let resolved = tokio::fs::canonicalize(root).await.map_err(|error| {
        AppError::new(
            ExitStatus::Usage,
            "workspace_root_unavailable",
            "Workflow workspace root does not exist.",
        )
        .details(json!({"workspace_root": root, "reason": error.to_string()}))
    })?;
    let metadata = tokio::fs::metadata(&resolved).await.map_err(|error| {
        AppError::new(
            ExitStatus::Usage,
            "workspace_root_unavailable",
            "Workflow workspace root could not be inspected.",
        )
        .details(json!({"workspace_root": resolved, "reason": error.to_string()}))
    })?;
    if metadata.is_dir() {
        Ok(resolved)
    } else {
        Err(AppError::new(
            ExitStatus::Usage,
            "workspace_root_invalid",
            "Workflow workspace root is not a directory.",
        )
        .details(json!({"workspace_root": resolved})))
    }
}

async fn inferred_workspace_root(script_path: &Path) -> AppResult<PathBuf> {
    if let Some(root) = conventional_workspace_root(script_path) {
        return Ok(root);
    }

    let current = std::env::current_dir().map_err(|error| {
        AppError::new(
            ExitStatus::Runtime,
            "working_directory_invalid",
            "Could not resolve the current working directory.",
        )
        .details(json!({"reason": error.to_string()}))
    })?;
    let current = tokio::fs::canonicalize(&current).await.map_err(|error| {
        AppError::new(
            ExitStatus::Runtime,
            "working_directory_invalid",
            "Could not canonicalize the current working directory.",
        )
        .details(json!({"working_directory": current, "reason": error.to_string()}))
    })?;
    if script_path.starts_with(&current) {
        return Ok(current);
    }
    script_path.parent().map(Path::to_path_buf).ok_or_else(|| {
        AppError::new(
            ExitStatus::Runtime,
            "script_path_invalid",
            "Workflow script path has no parent directory.",
        )
        .details(json!({"script_path": script_path}))
    })
}

fn conventional_workspace_root(script_path: &Path) -> Option<PathBuf> {
    script_path
        .ancestors()
        .find(|ancestor| {
            ancestor.file_name().is_some_and(|name| name == "workflows")
                && ancestor
                    .parent()
                    .and_then(Path::file_name)
                    .is_some_and(|name| name == ".codex")
        })
        .and_then(|workflows| workflows.parent())
        .and_then(Path::parent)
        .map(Path::to_path_buf)
}

fn path_text(path: PathBuf, code: &'static str, message: &'static str) -> AppResult<String> {
    path.into_os_string().into_string().map_err(|path| {
        AppError::new(ExitStatus::Usage, code, message)
            .details(json!({"path": path.to_string_lossy()}))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn inferred_root_prefers_the_canonical_current_directory() {
        let current = tokio::fs::canonicalize(std::env::current_dir().unwrap())
            .await
            .unwrap();
        let root = tempfile::tempdir_in(&current).unwrap();
        let script = root.path().join("workflow.exs");
        tokio::fs::write(&script, "workflow \"test\" do\nend\n")
            .await
            .unwrap();

        let resolved = ResolvedWorkflowScript::resolve(&script).await.unwrap();

        assert_eq!(resolved.workspace_root(), current);
    }

    #[tokio::test]
    async fn inferred_root_prefers_the_deepest_conventional_workflow_project() {
        let current = tokio::fs::canonicalize(std::env::current_dir().unwrap())
            .await
            .unwrap();
        let outer = tempfile::tempdir_in(&current).unwrap();
        let project = outer.path().join("project");
        let workflow_dir = project.join(".codex/workflows/nested/.codex/workflows");
        tokio::fs::create_dir_all(&workflow_dir).await.unwrap();
        let script = workflow_dir.join("review.exs");
        tokio::fs::write(&script, "workflow \"test\" do\nend\n")
            .await
            .unwrap();

        let resolved = ResolvedWorkflowScript::resolve(&script).await.unwrap();

        assert_eq!(
            resolved.workspace_root(),
            tokio::fs::canonicalize(project.join(".codex/workflows/nested"))
                .await
                .unwrap()
        );
    }

    #[tokio::test]
    async fn inferred_root_falls_back_to_the_script_parent_outside_cwd() {
        let root = tempfile::tempdir().unwrap();
        let script = root.path().join("workflow.exs");
        tokio::fs::write(&script, "workflow \"test\" do\nend\n")
            .await
            .unwrap();
        let canonical_script = tokio::fs::canonicalize(&script).await.unwrap();

        let resolved = ResolvedWorkflowScript::resolve(&script).await.unwrap();

        assert_eq!(
            resolved.workspace_root(),
            canonical_script.parent().unwrap()
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn client_workspace_root_is_canonicalized_through_symlinks() {
        let root = tempfile::tempdir().unwrap();
        let workspace = root.path().join("workspace");
        let linked_workspace = root.path().join("linked-workspace");
        let workflow_dir = workspace.join(".codex/workflows");
        tokio::fs::create_dir_all(&workflow_dir).await.unwrap();
        tokio::fs::write(
            workflow_dir.join("review.exs"),
            "workflow \"test\" do\nend\n",
        )
        .await
        .unwrap();
        std::os::unix::fs::symlink(&workspace, &linked_workspace).unwrap();

        let resolved = ResolvedWorkflowScript::resolve_from(
            Path::new(".codex/workflows/review.exs"),
            Some(&linked_workspace),
        )
        .await
        .unwrap();

        assert_eq!(
            resolved.workspace_root(),
            tokio::fs::canonicalize(workspace).await.unwrap()
        );
    }

    #[tokio::test]
    async fn absolute_script_outside_an_explicit_root_is_rejected() {
        let root = tempfile::tempdir().unwrap();
        let workspace = root.path().join("workspace");
        let outside = root.path().join("outside");
        tokio::fs::create_dir_all(&workspace).await.unwrap();
        tokio::fs::create_dir_all(&outside).await.unwrap();
        let script = outside.join("review.exs");
        tokio::fs::write(&script, "workflow \"test\" do\nend\n")
            .await
            .unwrap();

        let error = ResolvedWorkflowScript::resolve_from(&script, Some(&workspace))
            .await
            .unwrap_err();

        assert_eq!(error.code(), "script_outside_workspace");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn relative_symlink_escape_from_an_explicit_root_is_rejected() {
        let root = tempfile::tempdir().unwrap();
        let workspace = root.path().join("workspace");
        let outside = root.path().join("outside");
        tokio::fs::create_dir_all(&workspace).await.unwrap();
        tokio::fs::create_dir_all(&outside).await.unwrap();
        let outside_script = outside.join("review.exs");
        tokio::fs::write(&outside_script, "workflow \"test\" do\nend\n")
            .await
            .unwrap();
        std::os::unix::fs::symlink(&outside_script, workspace.join("review.exs")).unwrap();

        let error = ResolvedWorkflowScript::resolve_from(Path::new("review.exs"), Some(&workspace))
            .await
            .unwrap_err();

        assert_eq!(error.code(), "script_outside_workspace");
    }
}
