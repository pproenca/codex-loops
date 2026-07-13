use std::{
    env,
    io::ErrorKind,
    path::{Path, PathBuf},
};

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

use serde_json::json;

use crate::error::{AppError, AppResult, ExitStatus};

#[derive(Debug)]
pub(super) enum Authentication {
    NotRequired,
    File(PathBuf),
    AccessToken,
}

impl Authentication {
    pub async fn required(source_codex_home: &Path) -> AppResult<Self> {
        Self::required_with_access_token(
            source_codex_home,
            env::var_os("CODEX_ACCESS_TOKEN").is_some_and(|value| !value.is_empty()),
        )
        .await
    }

    async fn required_with_access_token(
        source_codex_home: &Path,
        access_token_available: bool,
    ) -> AppResult<Self> {
        if access_token_available {
            return Ok(Self::AccessToken);
        }

        #[cfg(unix)]
        if let Some(source) = valid_file_auth(source_codex_home).await? {
            return Ok(Self::File(source));
        }

        #[cfg(not(unix))]
        if tokio::fs::symlink_metadata(source_codex_home.join("auth.json"))
            .await
            .is_ok()
        {
            return Err(AppError::new(
                ExitStatus::Prerequisite,
                "sandbox_auth_unsupported",
                "File-based sandbox authentication links are supported only on Unix.",
            )
            .next_steps(["Set CODEX_ACCESS_TOKEN for this sandbox run."]));
        }

        Err(AppError::new(
            ExitStatus::Prerequisite,
            "sandbox_auth_unavailable",
            "The config-isolated sandbox has no reusable Codex authentication.",
        )
        .details(json!({"source_codex_home": source_codex_home}))
        .next_steps([
            "Use file-based Codex authentication at CODEX_HOME/auth.json or set CODEX_ACCESS_TOKEN.",
            "Keyring-only credentials cannot be reused because Codex namespaces them by CODEX_HOME.",
        ]))
    }
}

pub(super) struct IsolatedCodexHome(PathBuf);

impl IsolatedCodexHome {
    pub async fn prepare(artifact_home: &Path, authentication: &Authentication) -> AppResult<Self> {
        let path = artifact_home.join("codex-home");
        tokio::fs::create_dir_all(&path).await.map_err(|error| {
            AppError::new(
                ExitStatus::Runtime,
                "sandbox_artifact_failed",
                "Could not create the isolated Codex home directory.",
            )
            .details(json!({"path": path, "reason": error.to_string()}))
        })?;
        secure_directory(&path).await?;
        match authentication {
            Authentication::File(source) => link_file_credentials(source, &path).await?,
            Authentication::NotRequired | Authentication::AccessToken => {}
        }
        Ok(Self(path))
    }

    pub fn as_path(&self) -> &Path {
        &self.0
    }
}

#[cfg(unix)]
async fn valid_file_auth(source_codex_home: &Path) -> AppResult<Option<PathBuf>> {
    let source = source_codex_home.join("auth.json");
    let source_metadata = match tokio::fs::symlink_metadata(&source).await {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(invalid_source_auth(&source, error.to_string())),
    };
    let valid = if source_metadata.file_type().is_symlink() {
        tokio::fs::metadata(&source)
            .await
            .map_err(|error| invalid_source_auth(&source, error.to_string()))?
            .is_file()
    } else {
        source_metadata.is_file()
    };
    if valid {
        Ok(Some(source))
    } else {
        Err(invalid_source_auth(
            &source,
            "auth.json must be a regular file or a symbolic link to a regular file",
        ))
    }
}

#[cfg(unix)]
async fn link_file_credentials(source: &Path, isolated_home: &Path) -> AppResult<()> {
    let link = isolated_home.join("auth.json");
    tokio::fs::symlink(source, &link).await.map_err(|error| {
        AppError::new(
            ExitStatus::Runtime,
            "sandbox_auth_link_failed",
            "Could not link file-based Codex authentication into the isolated sandbox home.",
        )
        .details(json!({
            "source": source,
            "link": link,
            "reason": error.to_string()
        }))
    })
}

#[cfg(not(unix))]
async fn link_file_credentials(_source: &Path, _isolated_home: &Path) -> AppResult<()> {
    Err(AppError::new(
        ExitStatus::Prerequisite,
        "sandbox_auth_unsupported",
        "File-based sandbox authentication links are supported only on Unix.",
    ))
}

#[cfg(unix)]
async fn secure_directory(path: &Path) -> AppResult<()> {
    tokio::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))
        .await
        .map_err(|error| {
            AppError::new(
                ExitStatus::Runtime,
                "sandbox_artifact_failed",
                "Could not restrict the isolated Codex home directory.",
            )
            .details(json!({"path": path, "reason": error.to_string()}))
        })
}

#[cfg(not(unix))]
async fn secure_directory(_path: &Path) -> AppResult<()> {
    Ok(())
}

#[cfg(unix)]
fn invalid_source_auth(source: &Path, reason: impl Into<String>) -> AppError {
    AppError::new(
        ExitStatus::Prerequisite,
        "sandbox_auth_invalid",
        "The source Codex auth.json is not a regular file.",
    )
    .details(json!({"source": source, "reason": reason.into()}))
}

#[cfg(test)]
#[cfg(unix)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn isolated_home_links_only_file_authentication_and_cleanup_preserves_source() {
        let root = tempfile::tempdir().unwrap();
        let source_home = root.path().join("source-codex-home");
        let artifact_home = root.path().join("artifact/home");
        tokio::fs::create_dir_all(source_home.join("plugins"))
            .await
            .unwrap();
        tokio::fs::create_dir_all(&artifact_home).await.unwrap();
        let source_auth = source_home.join("auth.json");
        tokio::fs::write(&source_auth, "secret credentials")
            .await
            .unwrap();
        tokio::fs::write(source_home.join("config.toml"), "model = 'user-model'")
            .await
            .unwrap();
        tokio::fs::write(source_home.join("AGENTS.md"), "user instructions")
            .await
            .unwrap();
        let authentication = Authentication::required(&source_home).await.unwrap();

        let isolated = IsolatedCodexHome::prepare(&artifact_home, &authentication)
            .await
            .unwrap();

        let auth_link = isolated.as_path().join("auth.json");
        assert!(
            tokio::fs::symlink_metadata(&auth_link)
                .await
                .unwrap()
                .file_type()
                .is_symlink()
        );
        assert_eq!(tokio::fs::read_link(&auth_link).await.unwrap(), source_auth);
        assert!(!isolated.as_path().join("config.toml").exists());
        assert!(!isolated.as_path().join("plugins").exists());
        assert!(!isolated.as_path().join("AGENTS.md").exists());
        assert_eq!(
            tokio::fs::metadata(isolated.as_path())
                .await
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o700
        );

        tokio::fs::write(&auth_link, "refreshed credentials")
            .await
            .unwrap();
        tokio::fs::remove_dir_all(&artifact_home).await.unwrap();

        assert_eq!(
            tokio::fs::read_to_string(source_home.join("auth.json"))
                .await
                .unwrap(),
            "refreshed credentials"
        );
        assert!(source_home.join("config.toml").is_file());
    }

    #[tokio::test]
    async fn source_auth_symlink_must_resolve_to_a_regular_file() {
        let root = tempfile::tempdir().unwrap();
        let source_home = root.path().join("source-codex-home");
        tokio::fs::create_dir_all(&source_home).await.unwrap();
        let credentials = root.path().join("credentials.json");
        tokio::fs::write(&credentials, "secret credentials")
            .await
            .unwrap();
        tokio::fs::symlink(&credentials, source_home.join("auth.json"))
            .await
            .unwrap();

        assert!(matches!(
            Authentication::required(&source_home).await.unwrap(),
            Authentication::File(_)
        ));

        tokio::fs::remove_file(source_home.join("auth.json"))
            .await
            .unwrap();
        tokio::fs::symlink(
            root.path().join("missing.json"),
            source_home.join("auth.json"),
        )
        .await
        .unwrap();
        let error = Authentication::required(&source_home).await.err().unwrap();

        assert_eq!(error.code(), "sandbox_auth_invalid");
    }

    #[tokio::test]
    async fn non_file_source_auth_is_rejected() {
        let root = tempfile::tempdir().unwrap();
        let source_home = root.path().join("source-codex-home");
        tokio::fs::create_dir_all(source_home.join("auth.json"))
            .await
            .unwrap();

        let error = Authentication::required(&source_home).await.err().unwrap();

        assert_eq!(error.code(), "sandbox_auth_invalid");
    }

    #[tokio::test]
    async fn mock_authentication_does_not_inspect_or_link_source_credentials() {
        let root = tempfile::tempdir().unwrap();
        let source_home = root.path().join("source-codex-home");
        let artifact_home = root.path().join("artifact/home");
        tokio::fs::create_dir_all(source_home.join("auth.json"))
            .await
            .unwrap();
        tokio::fs::create_dir_all(&artifact_home).await.unwrap();

        let isolated = IsolatedCodexHome::prepare(&artifact_home, &Authentication::NotRequired)
            .await
            .unwrap();

        assert!(
            tokio::fs::read_dir(isolated.as_path())
                .await
                .unwrap()
                .next_entry()
                .await
                .unwrap()
                .is_none()
        );
    }

    #[tokio::test]
    async fn access_token_takes_precedence_over_malformed_file_authentication() {
        let root = tempfile::tempdir().unwrap();
        let source_home = root.path().join("source-codex-home");
        tokio::fs::create_dir_all(source_home.join("auth.json"))
            .await
            .unwrap();

        assert!(matches!(
            Authentication::required_with_access_token(&source_home, true)
                .await
                .unwrap(),
            Authentication::AccessToken
        ));
    }

    #[tokio::test]
    async fn missing_file_and_access_token_reports_keyring_isolation_boundary() {
        let root = tempfile::tempdir().unwrap();
        let error = Authentication::required_with_access_token(root.path(), false)
            .await
            .unwrap_err();

        assert_eq!(error.code(), "sandbox_auth_unavailable");
        assert!(
            error
                .next_steps_ref()
                .iter()
                .any(|step| step.contains("CODEX_ACCESS_TOKEN"))
        );
        assert!(
            error
                .next_steps_ref()
                .iter()
                .any(|step| step.contains("Keyring-only"))
        );
    }
}
