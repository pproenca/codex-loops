use std::fmt::{Display, Formatter};

use serde_json::{Value, json};

pub type AppResult<T> = Result<T, AppError>;

#[derive(Debug, Clone)]
pub struct AppError {
    pub status: u8,
    pub code: Box<str>,
    pub message: Box<str>,
    pub details: Box<Value>,
    pub changed: bool,
    pub step: Option<Box<str>>,
    pub next_steps: Box<[Box<str>]>,
    pub mcp_api_version: Box<str>,
}

impl AppError {
    pub fn new(status: u8, code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            status,
            code: code.into().into_boxed_str(),
            message: message.into().into_boxed_str(),
            details: Box::new(Value::Null),
            changed: false,
            step: None,
            next_steps: Box::new([]),
            mcp_api_version: "codex-loops.mcp.v1".into(),
        }
    }

    pub fn details(mut self, details: Value) -> Self {
        self.details = Box::new(details);
        self
    }

    pub fn changed(mut self, changed: bool) -> Self {
        self.changed = changed;
        self
    }

    pub fn step(mut self, step: impl Into<String>) -> Self {
        self.step = Some(step.into().into_boxed_str());
        self
    }

    pub fn next_steps(mut self, next_steps: impl IntoIterator<Item = impl Into<String>>) -> Self {
        self.next_steps = next_steps
            .into_iter()
            .map(|value| value.into().into_boxed_str())
            .collect();
        self
    }

    pub fn mcp_api_version(mut self, version: impl Into<String>) -> Self {
        self.mcp_api_version = version.into().into_boxed_str();
        self
    }

    pub fn cli_envelope(&self) -> Value {
        json!({
            "ok": false,
            "changed": self.changed,
            "error": {
                "code": &self.code,
                "message": &self.message,
                "details": &self.details,
                "step": &self.step
            },
            "next_steps": &self.next_steps
        })
    }

    pub fn mcp_envelope(&self) -> Value {
        json!({
            "api_version": &self.mcp_api_version,
            "error": {
                "code": &self.code,
                "message": &self.message,
                "details": &self.details
            }
        })
    }
}

impl Display for AppError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for AppError {}

impl From<anyhow::Error> for AppError {
    fn from(error: anyhow::Error) -> Self {
        AppError::new(6, "runtime_error", error.to_string())
    }
}
