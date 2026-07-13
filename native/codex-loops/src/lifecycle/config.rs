use std::{
    fmt::{Display, Formatter},
    net::{IpAddr, SocketAddr, TcpListener},
    path::PathBuf,
    str::FromStr,
};

use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::json;

use crate::{
    error::{AppError, AppResult, ExitStatus},
    scheduler::SchedulerClient,
};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BindHost(String);

impl BindHost {
    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub fn connect_host(&self) -> &str {
        match self.0.as_str() {
            "0.0.0.0" => "127.0.0.1",
            "::" => "::1",
            host => host,
        }
    }

    pub async fn validate_available(&self) -> AppResult<()> {
        let host = self.clone();
        super::blocking("validate the scheduler bind address", move || {
            host.validate_available_blocking()
        })
        .await
    }

    fn validate_available_blocking(&self) -> AppResult<()> {
        let ip = match self.0.as_str() {
            "localhost" => IpAddr::from([127, 0, 0, 1]),
            host => host.parse::<IpAddr>().map_err(|error| {
                AppError::new(
                    ExitStatus::Usage,
                    "bind_host_invalid",
                    "--host must be an IPv4/IPv6 address or localhost.",
                )
                .details(json!({"host": host, "reason": error.to_string()}))
            })?,
        };
        TcpListener::bind(SocketAddr::new(ip, 0))
            .map(drop)
            .map_err(|error| {
                AppError::new(
                    ExitStatus::Usage,
                    "bind_host_unavailable",
                    "--host is not an address assigned to this machine.",
                )
                .details(json!({"host": self.0, "reason": error.to_string()}))
            })
    }
}

impl FromStr for BindHost {
    type Err = AppError;

    fn from_str(host: &str) -> Result<Self, Self::Err> {
        if host == "localhost" || host.parse::<IpAddr>().is_ok() {
            Ok(Self(host.to_owned()))
        } else {
            Err(AppError::new(
                ExitStatus::Usage,
                "bind_host_invalid",
                "--host must be an IPv4/IPv6 address or localhost.",
            )
            .details(json!({"host": host})))
        }
    }
}

impl Display for BindHost {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl Serialize for BindHost {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&self.0)
    }
}

impl<'de> Deserialize<'de> for BindHost {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        String::deserialize(deserializer)?
            .parse()
            .map_err(serde::de::Error::custom)
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(transparent)]
pub struct AbsolutePath(PathBuf);

impl AbsolutePath {
    pub async fn resolve(path: PathBuf) -> AppResult<Self> {
        if path.is_absolute() {
            return Ok(Self(path));
        }
        super::blocking("resolve the current working directory", move || {
            let current = std::env::current_dir().map_err(|error| {
                AppError::new(
                    ExitStatus::Runtime,
                    "working_directory_invalid",
                    "Could not resolve the current working directory.",
                )
                .details(json!({"reason": error.to_string()}))
            })?;
            Ok(Self(current.join(path)))
        })
        .await
    }

    pub fn as_path(&self) -> &std::path::Path {
        &self.0
    }
}

impl<'de> Deserialize<'de> for AbsolutePath {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let path = PathBuf::deserialize(deserializer)?;
        if path.is_absolute() {
            Ok(Self(path))
        } else {
            Err(serde::de::Error::custom("path must be absolute"))
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct StartOptions {
    pub bind_host: Option<BindHost>,
    pub journal: Option<AbsolutePath>,
    pub model: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SchedulerConfig {
    pub bind_host: BindHost,
    pub journal: Option<AbsolutePath>,
    pub model: Option<String>,
}

impl SchedulerConfig {
    pub(super) fn resolve(client: &SchedulerClient, options: StartOptions) -> AppResult<Self> {
        let bind_host = match options.bind_host {
            Some(host) => host,
            None => client
                .base_url()
                .host_str()
                .ok_or_else(|| {
                    AppError::new(
                        ExitStatus::Usage,
                        "scheduler_url_invalid",
                        "Scheduler URL has no host.",
                    )
                })?
                .trim_matches(['[', ']'])
                .parse()?,
        };
        Ok(Self {
            bind_host,
            journal: options.journal,
            model: options.model,
        })
    }

    pub(super) fn conflicts_with(&self, requested: &StartOptions) -> bool {
        requested
            .bind_host
            .as_ref()
            .is_some_and(|value| value != &self.bind_host)
            || requested
                .journal
                .as_ref()
                .is_some_and(|value| self.journal.as_ref() != Some(value))
            || requested
                .model
                .as_ref()
                .is_some_and(|value| self.model.as_ref() != Some(value))
    }
}
