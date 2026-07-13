use std::fmt::{Display, Formatter};

use serde_json::{Value, json};

pub type AppResult<T> = Result<T, AppError>;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum ExitStatus {
    Unsatisfied = 1,
    Usage = 2,
    Prerequisite = 3,
    Conflict = 4,
    Command = 5,
    Runtime = 6,
}

impl From<ExitStatus> for u8 {
    fn from(status: ExitStatus) -> Self {
        status as Self
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChangeState {
    Unchanged,
    Changed,
}

impl ChangeState {
    pub fn is_changed(self) -> bool {
        matches!(self, Self::Changed)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ErrorOrigin {
    ControlPlane,
    Scheduler,
}

#[derive(Debug)]
pub struct AppError {
    status: ExitStatus,
    code: Box<str>,
    message: Box<str>,
    details: Box<Value>,
    changed: ChangeState,
    step: Option<Box<str>>,
    next_steps: Box<[Box<str>]>,
    origin: ErrorOrigin,
}

pub(crate) struct ErrorReport {
    pub message: String,
    pub details: Value,
}

impl AppError {
    pub fn new(status: ExitStatus, code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            status,
            code: code.into().into_boxed_str(),
            message: message.into().into_boxed_str(),
            details: Box::new(Value::Null),
            changed: ChangeState::Unchanged,
            step: None,
            next_steps: Box::new([]),
            origin: ErrorOrigin::ControlPlane,
        }
    }

    pub fn scheduler(
        status: ExitStatus,
        code: impl Into<String>,
        message: impl Into<String>,
    ) -> Self {
        Self {
            origin: ErrorOrigin::Scheduler,
            ..Self::new(status, code, message)
        }
    }

    pub fn details(mut self, details: Value) -> Self {
        self.details = Box::new(details);
        self
    }

    pub fn changed(mut self, changed: ChangeState) -> Self {
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

    pub fn diagnostic(&self) -> Value {
        json!({
            "code": &self.code,
            "message": &self.message,
            "details": &self.details,
            "changed": self.changed.is_changed(),
            "step": &self.step
        })
    }

    pub fn cli_envelope(&self) -> Value {
        json!({
            "ok": false,
            "changed": self.changed.is_changed(),
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
        let api_version = match self.origin {
            ErrorOrigin::ControlPlane => "codex-loops.mcp.v1",
            ErrorOrigin::Scheduler => "scheduler.v1",
        };
        json!({
            "api_version": api_version,
            "error": {
                "code": &self.code,
                "message": &self.message,
                "details": &self.details
            }
        })
    }

    pub fn status(&self) -> ExitStatus {
        self.status
    }

    #[cfg(test)]
    pub fn code(&self) -> &str {
        &self.code
    }

    pub fn next_steps_ref(&self) -> &[Box<str>] {
        &self.next_steps
    }

    #[cfg(test)]
    pub fn details_ref(&self) -> &Value {
        &self.details
    }

    pub(crate) fn into_report(self) -> ErrorReport {
        ErrorReport {
            message: self.message.into(),
            details: *self.details,
        }
    }
}

impl Display for AppError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for AppError {}
