use std::{fmt::Display, ops::Deref};

use serde_json::{Value, json};

pub type AppResult<T> = Result<T, AppError>;
pub type RuntimeResult<T> = Result<T, RuntimeError>;
pub type SchedulerResult<T> = Result<T, SchedulerError>;
pub type LifecycleResult<T> = Result<T, LifecycleError>;
pub type InstallResult<T> = Result<T, InstallError>;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChangeState {
    Unchanged,
    Changed,
}

impl From<bool> for ChangeState {
    fn from(changed: bool) -> Self {
        if changed {
            Self::Changed
        } else {
            Self::Unchanged
        }
    }
}

impl Display for ChangeState {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(match self {
            Self::Unchanged => "unchanged",
            Self::Changed => "changed",
        })
    }
}

#[derive(Debug, Clone)]
pub struct ErrorReport {
    pub status: u8,
    pub code: Box<str>,
    pub message: Box<str>,
    pub details: Box<Value>,
    pub changed: bool,
    pub step: Option<Box<str>>,
    pub next_steps: Box<[Box<str>]>,
    pub mcp_api_version: Box<str>,
}

impl ErrorReport {
    fn new(status: u8, code: impl Into<String>, message: impl Into<String>) -> Self {
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

    fn cli_envelope(&self) -> Value {
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

    fn mcp_envelope(&self) -> Value {
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

impl Display for ErrorReport {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for ErrorReport {}

macro_rules! report_error {
    ($name:ident) => {
        #[derive(Debug, Clone)]
        pub struct $name(ErrorReport);

        #[allow(dead_code)]
        impl $name {
            pub fn new(status: u8, code: impl Into<String>, message: impl Into<String>) -> Self {
                Self(ErrorReport::new(status, code, message))
            }

            pub fn details(mut self, details: Value) -> Self {
                self.0.details = Box::new(details);
                self
            }

            pub fn changed(mut self, state: ChangeState) -> Self {
                self.0.changed = matches!(state, ChangeState::Changed);
                self
            }

            pub fn step(mut self, step: impl Into<String>) -> Self {
                self.0.step = Some(step.into().into_boxed_str());
                self
            }

            pub fn next_steps(
                mut self,
                next_steps: impl IntoIterator<Item = impl Into<String>>,
            ) -> Self {
                self.0.next_steps = next_steps
                    .into_iter()
                    .map(|value| value.into().into_boxed_str())
                    .collect();
                self
            }

            pub fn mcp_api_version(mut self, version: impl Into<String>) -> Self {
                self.0.mcp_api_version = version.into().into_boxed_str();
                self
            }

            pub fn cli_envelope(&self) -> Value {
                self.0.cli_envelope()
            }

            pub fn mcp_envelope(&self) -> Value {
                self.0.mcp_envelope()
            }

            fn into_report(self) -> ErrorReport {
                self.0
            }
        }

        impl Deref for $name {
            type Target = ErrorReport;

            fn deref(&self) -> &Self::Target {
                &self.0
            }
        }

        impl Display for $name {
            fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                Display::fmt(&self.0, formatter)
            }
        }

        impl std::error::Error for $name {}
    };
}

report_error!(AppError);
report_error!(RuntimeError);
report_error!(SchedulerError);
report_error!(LifecycleError);
report_error!(InstallError);

macro_rules! convert_error {
    ($source:ident => $target:ident) => {
        impl From<$source> for $target {
            fn from(error: $source) -> Self {
                Self(error.into_report())
            }
        }
    };
}

convert_error!(RuntimeError => AppError);
convert_error!(SchedulerError => AppError);
convert_error!(LifecycleError => AppError);
convert_error!(InstallError => AppError);
convert_error!(RuntimeError => LifecycleError);
convert_error!(SchedulerError => LifecycleError);
convert_error!(RuntimeError => InstallError);

impl From<anyhow::Error> for AppError {
    fn from(error: anyhow::Error) -> Self {
        Self::new(6, "runtime_error", error.to_string())
    }
}
