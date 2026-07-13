use std::{
    num::{NonZeroU16, NonZeroU32},
    path::PathBuf,
    str::FromStr,
};

use serde::{Deserialize, Deserializer, Serialize, Serializer};

use super::*;

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(transparent)]
pub(super) struct OwnerToken(Box<str>);

impl OwnerToken {
    pub(super) fn as_str(&self) -> &str {
        &self.0
    }
}

impl FromStr for OwnerToken {
    type Err = AppError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        let valid = !value.is_empty()
            && value.chars().all(|character| {
                character.is_ascii_alphanumeric() || matches!(character, '-' | '_')
            });
        if valid {
            Ok(Self(value.into()))
        } else {
            Err(AppError::new(
                ExitStatus::Runtime,
                "scheduler_owner_invalid",
                "Scheduler owner token is not path-safe.",
            )
            .details(json!({"owner_token": value})))
        }
    }
}

impl<'de> Deserialize<'de> for OwnerToken {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        String::deserialize(deserializer)?
            .parse()
            .map_err(serde::de::Error::custom)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct PackageVersion;

impl Serialize for PackageVersion {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(env!("CARGO_PKG_VERSION"))
    }
}

impl<'de> Deserialize<'de> for PackageVersion {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let version = String::deserialize(deserializer)?;
        if version == env!("CARGO_PKG_VERSION") {
            Ok(Self)
        } else {
            Err(serde::de::Error::custom(format!(
                "expected Codex Loops {}, found {version}",
                env!("CARGO_PKG_VERSION")
            )))
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(transparent)]
pub(super) struct VerifiedSchedulerRoot(PathBuf);

impl VerifiedSchedulerRoot {
    pub(super) fn from_verified(path: PathBuf) -> Self {
        Self(path)
    }

    pub(super) fn as_path(&self) -> &std::path::Path {
        &self.0
    }
}

#[derive(Debug, Serialize)]
pub(super) struct RuntimeMetadata {
    pub owner_token: OwnerToken,
    pub supervisor_pid: NonZeroU32,
    pub scheduler_pid: Option<NonZeroU32>,
    version: PackageVersion,
    pub port: NonZeroU16,
    pub scheduler_root: VerifiedSchedulerRoot,
    pub config: SchedulerConfig,
}

#[derive(Debug, Deserialize)]
struct StoredRuntimeMetadata {
    owner_token: OwnerToken,
    supervisor_pid: NonZeroU32,
    scheduler_pid: Option<NonZeroU32>,
    version: PackageVersion,
    port: NonZeroU16,
    scheduler_root: PathBuf,
    config: SchedulerConfig,
}

impl RuntimeMetadata {
    pub(super) fn new(
        owner_token: OwnerToken,
        port: NonZeroU16,
        scheduler_root: VerifiedSchedulerRoot,
        config: SchedulerConfig,
    ) -> AppResult<Self> {
        let supervisor_pid = NonZeroU32::new(std::process::id()).ok_or_else(|| {
            AppError::new(
                ExitStatus::Runtime,
                "scheduler_process_check_failed",
                "The scheduler supervisor has an invalid process ID.",
            )
        })?;
        Ok(Self {
            owner_token,
            supervisor_pid,
            scheduler_pid: None,
            version: PackageVersion,
            port,
            scheduler_root,
            config,
        })
    }
}

pub(super) async fn read_metadata(client: &SchedulerClient) -> AppResult<Option<RuntimeMetadata>> {
    let path = metadata_path(client)?;
    let bytes = match tokio::fs::read(&path).await {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(io_error("scheduler_metadata_invalid")(error)),
    };
    let metadata: StoredRuntimeMetadata = serde_json::from_slice(&bytes).map_err(|error| {
        AppError::new(
            ExitStatus::Runtime,
            "scheduler_metadata_invalid",
            "Scheduler owner metadata is invalid.",
        )
        .details(json!({"path": path, "reason": error.to_string()}))
    })?;
    let client = client.clone();
    blocking("validate scheduler owner metadata", move || {
        validate_metadata(&client, metadata).map(Some)
    })
    .await
}

fn validate_metadata(
    client: &SchedulerClient,
    metadata: StoredRuntimeMetadata,
) -> AppResult<RuntimeMetadata> {
    let expected_port = scheduler_port(client)?;
    if metadata.port != expected_port {
        return Err(AppError::new(
            ExitStatus::Runtime,
            "scheduler_metadata_invalid",
            "Scheduler owner metadata does not match the configured endpoint.",
        )
        .details(json!({
            "expected_port": expected_port,
            "metadata_port": metadata.port,
            "supervisor_pid": metadata.supervisor_pid,
            "scheduler_root": metadata.scheduler_root
        })));
    }
    let StoredRuntimeMetadata {
        owner_token,
        supervisor_pid,
        scheduler_pid,
        version,
        port,
        scheduler_root,
        config,
    } = metadata;
    Ok(RuntimeMetadata {
        owner_token,
        supervisor_pid,
        scheduler_pid,
        version,
        port,
        scheduler_root: verified_scheduler_root(&scheduler_root)?,
        config,
    })
}

pub(super) async fn write_metadata(
    client: &SchedulerClient,
    metadata: &RuntimeMetadata,
) -> AppResult<()> {
    let path = metadata_path(client)?;
    let temp = path.with_extension("json.tmp");
    let bytes = serde_json::to_vec(metadata).map_err(|error| {
        AppError::new(
            ExitStatus::Runtime,
            "scheduler_metadata_invalid",
            "Could not encode scheduler owner metadata.",
        )
        .details(json!({"reason": error.to_string()}))
    })?;
    tokio::fs::write(&temp, bytes)
        .await
        .map_err(io_error("scheduler_metadata_invalid"))?;
    tokio::fs::rename(&temp, &path)
        .await
        .map_err(io_error("scheduler_metadata_invalid"))
}

pub(super) async fn remove_stale_metadata(client: &SchedulerClient) -> AppResult<()> {
    match tokio::fs::remove_file(metadata_path(client)?).await {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(io_error("scheduler_metadata_invalid")(error)),
    }
}
