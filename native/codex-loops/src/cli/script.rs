use std::path::{Path, PathBuf};

use serde::Serialize;
use serde_json::json;

use crate::error::{AppError, AppResult, ExitStatus};

#[derive(Debug, PartialEq, Eq, Serialize)]
#[serde(transparent)]
pub struct ResolvedWorkflowScript(Box<str>);

impl ResolvedWorkflowScript {
    pub async fn resolve(path: &Path) -> AppResult<Self> {
        Self::resolve_from(path, None).await
    }

    pub async fn resolve_from(path: &Path, workspace_root: Option<&Path>) -> AppResult<Self> {
        let candidate = if path.is_absolute() {
            path.to_path_buf()
        } else if let Some(root) = workspace_root {
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
        let path = resolved.into_os_string().into_string().map_err(|path| {
            AppError::new(
                ExitStatus::Usage,
                "script_path_invalid",
                "Workflow script path must be valid UTF-8.",
            )
            .details(json!({"script_path": path.to_string_lossy()}))
        })?;
        Ok(Self(path.into_boxed_str()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub fn as_path(&self) -> &Path {
        Path::new(self.as_str())
    }

    pub fn into_string(self) -> String {
        self.0.into()
    }
}
