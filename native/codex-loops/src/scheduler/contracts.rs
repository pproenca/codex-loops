use std::{fmt, str::FromStr};

use clap::ValueEnum;
use schemars::JsonSchema;
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::{Value, json};

use crate::error::{AppError, AppResult, ExitStatus};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize, JsonSchema, ValueEnum)]
#[serde(rename_all = "lowercase")]
pub enum Provider {
    Mock,
    Codex,
}

impl fmt::Display for Provider {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::Mock => "mock",
            Self::Codex => "codex",
        })
    }
}

impl FromStr for Provider {
    type Err = AppError;

    fn from_str(value: &str) -> AppResult<Self> {
        if value == "mock" {
            Ok(Self::Mock)
        } else if value == "codex" {
            Ok(Self::Codex)
        } else {
            Err(AppError::new(
                ExitStatus::Usage,
                "provider_invalid",
                "Provider must be either `mock` or `codex`.",
            )
            .details(json!({"provider": value})))
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, JsonSchema)]
#[serde(transparent)]
pub struct RunId(
    #[schemars(length(min = 1), regex(pattern = r"^[A-Za-z0-9][A-Za-z0-9_.:-]*$"))] Box<str>,
);

impl RunId {
    pub fn new(value: impl Into<String>) -> AppResult<Self> {
        let value = value.into();
        let mut characters = value.chars();
        let valid = characters
            .next()
            .is_some_and(|character| character.is_ascii_alphanumeric())
            && characters.all(|character| {
                character.is_ascii_alphanumeric() || matches!(character, '_' | '.' | ':' | '-')
            });
        if valid {
            Ok(Self(value.into_boxed_str()))
        } else {
            Err(AppError::new(
                ExitStatus::Usage,
                "run_id_invalid",
                "Run ID must start with an ASCII letter or digit and contain only route-safe characters.",
            )
            .details(json!({"run_id": value})))
        }
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl FromStr for RunId {
    type Err = AppError;

    fn from_str(value: &str) -> AppResult<Self> {
        Self::new(value)
    }
}

impl<'de> Deserialize<'de> for RunId {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Self::new(String::deserialize(deserializer)?).map_err(serde::de::Error::custom)
    }
}

#[derive(Debug, Serialize, Deserialize)]
pub struct SchedulerResponse<T> {
    pub api_version: String,
    pub data: T,
}

impl<T: Serialize> SchedulerResponse<T> {
    pub fn into_wire_value(self) -> AppResult<Value> {
        scheduler_wire_value(self)
    }
}

#[derive(Debug, Default, Serialize, Deserialize)]
pub struct SchedulerDocument {
    #[serde(flatten)]
    pub fields: serde_json::Map<String, Value>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct StartData {
    pub workflow_name: Option<String>,
    pub state: Option<String>,
    #[serde(flatten)]
    pub fields: serde_json::Map<String, Value>,
}

#[derive(Debug, Deserialize)]
pub(super) struct HealthEnvelope {
    pub api_version: String,
    pub data: HealthData,
}

#[derive(Debug, Deserialize)]
pub(super) struct HealthData {
    pub status: String,
    pub version: String,
}

#[derive(Debug, Serialize)]
pub struct StartRequest {
    pub script_path: String,
    pub workspace_root: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub run_id: Option<RunId>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub provider: Option<Provider>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub budget: Option<u64>,
}

#[derive(Debug, Serialize)]
pub struct ResumeRequest {
    #[serde(flatten)]
    pub workflow: Option<WorkflowLocationRequest>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub provider: Option<Provider>,
}

#[derive(Debug, Serialize)]
pub struct WorkflowLocationRequest {
    pub script_path: String,
    pub workspace_root: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub(super) struct SchedulerFailureEnvelope {
    pub api_version: String,
    pub error: SchedulerFailure,
}

#[derive(Debug, Serialize, Deserialize)]
pub(super) struct SchedulerFailure {
    pub code: String,
    pub message: String,
    #[serde(default)]
    pub details: Value,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(untagged)]
pub(super) enum SchedulerEnvelope<T> {
    Success(SchedulerResponse<T>),
    Failure(SchedulerFailureEnvelope),
}

impl<T: Serialize> SchedulerEnvelope<T> {
    pub fn api_version(&self) -> &str {
        match self {
            Self::Success(envelope) => &envelope.api_version,
            Self::Failure(envelope) => &envelope.api_version,
        }
    }
    pub fn into_wire_value(self) -> AppResult<Value> {
        scheduler_wire_value(self)
    }
}

fn scheduler_wire_value(value: impl Serialize) -> AppResult<Value> {
    serde_json::to_value(value).map_err(|error| {
        AppError::scheduler(ExitStatus::Runtime, "scheduler_response", error.to_string())
    })
}
