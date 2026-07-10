use serde::{Deserialize, Deserializer, Serialize};
use serde_json::{Value, json};

use crate::error::{SchedulerError, SchedulerResult};

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(transparent)]
pub struct RunId(String);

impl RunId {
    pub fn new(value: impl Into<String>) -> SchedulerResult<Self> {
        let value = value.into();
        let mut characters = value.chars();
        let valid = characters
            .next()
            .is_some_and(|character| character.is_ascii_alphanumeric())
            && characters.all(|character| {
                character.is_ascii_alphanumeric() || matches!(character, '_' | '.' | ':' | '-')
            });
        if valid {
            Ok(Self(value))
        } else {
            Err(SchedulerError::new(
                2,
                "run_id_invalid",
                "Run ID must start with an ASCII letter or digit and contain only route-safe characters.",
            ))
        }
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl<'de> Deserialize<'de> for RunId {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Self::new(String::deserialize(deserializer)?).map_err(serde::de::Error::custom)
    }
}

#[derive(Debug, Serialize, Deserialize)]
pub struct SchedulerResponse<T> {
    pub(super) api_version: String,
    pub data: T,
}

impl<T: Serialize> SchedulerResponse<T> {
    pub fn into_wire_value(self) -> SchedulerResult<Value> {
        serde_json::to_value(self)
            .map_err(|error| SchedulerError::new(6, "scheduler_response", error.to_string()))
    }
}

#[derive(Debug, Default, Serialize, Deserialize)]
pub struct SchedulerDocument {
    #[serde(flatten)]
    fields: serde_json::Map<String, Value>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct StartData {
    pub workflow_name: Option<String>,
    pub state: Option<String>,
    #[serde(flatten)]
    fields: serde_json::Map<String, Value>,
}

#[derive(Debug, Serialize, Deserialize)]
pub(super) struct HealthEnvelope {
    pub api_version: String,
    pub data: HealthData,
}

#[derive(Debug, Serialize, Deserialize)]
pub(super) struct HealthData {
    pub status: String,
    pub version: String,
}

#[derive(Debug, Serialize)]
pub struct StartRequest {
    pub script_path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub run_id: Option<RunId>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub provider: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub budget: Option<u64>,
}

#[derive(Debug, Serialize)]
pub struct ResumeRequest {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub script_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub provider: Option<String>,
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
    pub fn into_value(self) -> Value {
        serde_json::to_value(self).unwrap_or_else(|error| json!({"api_version": "scheduler.v1", "error": {"code": "serialization_failed", "message": error.to_string()}}))
    }
}
