use std::fmt::{Display, Formatter};

use serde_json::{Value, json};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChangeState {
    Unchanged,
    Changed,
}

impl ChangeState {
    pub fn after_success(self) -> Self {
        Self::Changed
    }

    pub fn as_bool(self) -> bool {
        matches!(self, Self::Changed)
    }
}

#[derive(Debug, Clone)]
pub struct Failure {
    status: u8,
    code: Box<str>,
    message: Box<str>,
    details: Box<Value>,
    changed: ChangeState,
    step: Option<Box<str>>,
    next_steps: Box<[Box<str>]>,
}

impl Failure {
    fn new(status: u8, code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            status,
            code: code.into().into_boxed_str(),
            message: message.into().into_boxed_str(),
            details: Box::new(Value::Null),
            changed: ChangeState::Unchanged,
            step: None,
            next_steps: Box::new([]),
        }
    }
}

pub trait ErrorContext: Sized {
    fn failure(&self) -> &Failure;
    fn failure_mut(&mut self) -> &mut Failure;
    fn into_failure(self) -> Failure;

    fn details(mut self, details: Value) -> Self {
        self.failure_mut().details = Box::new(details);
        self
    }

    fn changed(mut self, state: ChangeState) -> Self {
        self.failure_mut().changed = state;
        self
    }

    fn step(mut self, step: impl Into<String>) -> Self {
        self.failure_mut().step = Some(step.into().into_boxed_str());
        self
    }

    fn next_steps(mut self, next_steps: impl IntoIterator<Item = impl Into<String>>) -> Self {
        self.failure_mut().next_steps = next_steps
            .into_iter()
            .map(|value| value.into().into_boxed_str())
            .collect();
        self
    }

    fn diagnostic(&self) -> Value {
        let failure = self.failure();
        json!({
            "code": &failure.code,
            "message": &failure.message,
            "details": &failure.details,
            "changed": failure.changed.as_bool(),
            "step": &failure.step
        })
    }

    #[cfg(test)]
    fn status(&self) -> u8 {
        self.failure().status
    }

    #[cfg(test)]
    fn code(&self) -> &str {
        &self.failure().code
    }
}

macro_rules! error_context {
    ($name:ident { $($variant:ident),+ $(,)? }) => {
        impl ErrorContext for $name {
            fn failure(&self) -> &Failure {
                match self { $(Self::$variant(failure) => failure),+ }
            }

            fn failure_mut(&mut self) -> &mut Failure {
                match self { $(Self::$variant(failure) => failure),+ }
            }

            fn into_failure(self) -> Failure {
                match self { $(Self::$variant(failure) => failure),+ }
            }
        }

        impl Display for $name {
            fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
                formatter.write_str(&self.failure().message)
            }
        }

        impl std::error::Error for $name {}
    };
}

pub type RuntimeResult<T> = Result<T, RuntimeError>;

#[derive(Debug, Clone)]
pub enum RuntimeError {
    Binding(Failure),
    Bundle(Failure),
    Environment(Failure),
    Operation(Failure),
}

impl RuntimeError {
    pub fn new(status: u8, code: impl Into<String>, message: impl Into<String>) -> Self {
        let failure = Failure::new(status, code, message);
        match failure.code.as_ref() {
            code if code.starts_with("codex_binding") => Self::Binding(failure),
            "runtime_invalid" => Self::Bundle(failure),
            code if code.contains("environment") => Self::Environment(failure),
            _ => Self::Operation(failure),
        }
    }
}

error_context!(RuntimeError {
    Binding,
    Bundle,
    Environment,
    Operation
});

pub type SchedulerResult<T> = Result<T, SchedulerError>;

#[derive(Debug, Clone)]
pub enum SchedulerError {
    InvalidRunId(Failure),
    Configuration(Failure),
    Transport(Failure),
    Protocol(Failure),
    ApiFailure(Failure),
}

impl SchedulerError {
    pub fn new(status: u8, code: impl Into<String>, message: impl Into<String>) -> Self {
        let failure = Failure::new(status, code, message);
        match failure.code.as_ref() {
            "run_id_invalid" => Self::InvalidRunId(failure),
            code if code.contains("url") || code.contains("port") => Self::Configuration(failure),
            "scheduler_unavailable" | "http_client_failed" => Self::Transport(failure),
            code if code.starts_with("scheduler_response") || code.contains("request_invalid") => {
                Self::Protocol(failure)
            }
            _ => Self::ApiFailure(failure),
        }
    }
}

error_context!(SchedulerError {
    InvalidRunId,
    Configuration,
    Transport,
    Protocol,
    ApiFailure,
});

pub type LifecycleResult<T> = Result<T, LifecycleError>;

#[derive(Debug, Clone)]
pub enum LifecycleError {
    Ownership(Failure),
    Configuration(Failure),
    Startup(Failure),
    Shutdown(Failure),
    Supervision(Failure),
    Runtime(Failure),
    Scheduler(Failure),
}

impl LifecycleError {
    pub fn new(status: u8, code: impl Into<String>, message: impl Into<String>) -> Self {
        let failure = Failure::new(status, code, message);
        match failure.code.as_ref() {
            code if code.contains("owner")
                || code.contains("metadata")
                || code.contains("orphan") =>
            {
                Self::Ownership(failure)
            }
            code if code.contains("configuration") || code.contains("externally_managed") => {
                Self::Configuration(failure)
            }
            code if code.contains("start") => Self::Startup(failure),
            code if code.contains("stop") || code.contains("kill") => Self::Shutdown(failure),
            _ => Self::Supervision(failure),
        }
    }
}

error_context!(LifecycleError {
    Ownership,
    Configuration,
    Startup,
    Shutdown,
    Supervision,
    Runtime,
    Scheduler,
});

pub type InstallResult<T> = Result<T, InstallError>;

#[derive(Debug, Clone)]
pub enum InstallError {
    State(Failure),
    Preflight(Failure),
    SkillTransaction(Failure),
    McpTransaction(Failure),
    Verification(Failure),
    Runtime(Failure),
}

impl InstallError {
    pub fn new(status: u8, code: impl Into<String>, message: impl Into<String>) -> Self {
        let failure = Failure::new(status, code, message);
        match failure.code.as_ref() {
            "state_missing" => Self::State(failure),
            code if code.contains("codex") && !code.contains("command") => Self::Preflight(failure),
            code if code.contains("skill") => Self::SkillTransaction(failure),
            code if code.contains("mcp") || code == "codex_command_failed" => {
                Self::McpTransaction(failure)
            }
            "verification_failed" => Self::Verification(failure),
            _ => Self::Runtime(failure),
        }
    }
}

error_context!(InstallError {
    State,
    Preflight,
    SkillTransaction,
    McpTransaction,
    Verification,
    Runtime,
});

pub type CliResult<T> = Result<T, CliError>;

#[derive(Debug, Clone)]
pub enum CliError {
    Input(Failure),
    Operation(Failure),
    Runtime(Failure),
    Lifecycle(Failure),
    Install(Failure),
    Scheduler(Failure),
}

impl CliError {
    pub fn new(status: u8, code: impl Into<String>, message: impl Into<String>) -> Self {
        let failure = Failure::new(status, code, message);
        if failure.status == 2 {
            Self::Input(failure)
        } else {
            Self::Operation(failure)
        }
    }
}

error_context!(CliError {
    Input,
    Operation,
    Runtime,
    Lifecycle,
    Install,
    Scheduler
});

pub type McpResult<T> = Result<T, McpDomainError>;

#[derive(Debug, Clone)]
pub enum McpDomainError {
    InvalidTool(Failure),
    Transport(Failure),
    Execution(Failure),
    Cli(Failure),
    Lifecycle(Failure),
    Scheduler(Failure),
}

impl McpDomainError {
    pub fn new(status: u8, code: impl Into<String>, message: impl Into<String>) -> Self {
        let failure = Failure::new(status, code, message);
        match failure.code.as_ref() {
            "invalid_params" | "unknown_tool" => Self::InvalidTool(failure),
            "mcp_transport_failed" => Self::Transport(failure),
            _ => Self::Execution(failure),
        }
    }
}

error_context!(McpDomainError {
    InvalidTool,
    Transport,
    Execution,
    Cli,
    Lifecycle,
    Scheduler,
});

macro_rules! convert_domain {
    ($source:ident => $target:ident::$variant:ident) => {
        impl From<$source> for $target {
            fn from(error: $source) -> Self {
                Self::$variant(error.into_failure())
            }
        }
    };
}

convert_domain!(RuntimeError => LifecycleError::Runtime);
convert_domain!(SchedulerError => LifecycleError::Scheduler);
convert_domain!(RuntimeError => InstallError::Runtime);
convert_domain!(RuntimeError => CliError::Runtime);
convert_domain!(LifecycleError => CliError::Lifecycle);
convert_domain!(InstallError => CliError::Install);
convert_domain!(SchedulerError => CliError::Scheduler);
convert_domain!(CliError => McpDomainError::Cli);
convert_domain!(LifecycleError => McpDomainError::Lifecycle);
convert_domain!(SchedulerError => McpDomainError::Scheduler);

#[derive(Debug, Clone)]
pub struct AppError {
    failure: Failure,
    mcp_api_version: &'static str,
}

impl AppError {
    pub fn cli_envelope(&self) -> Value {
        json!({
            "ok": false,
            "changed": self.failure.changed.as_bool(),
            "error": {
                "code": &self.failure.code,
                "message": &self.failure.message,
                "details": &self.failure.details,
                "step": &self.failure.step
            },
            "next_steps": &self.failure.next_steps
        })
    }

    pub fn mcp_envelope(&self) -> Value {
        json!({
            "api_version": self.mcp_api_version,
            "error": {
                "code": &self.failure.code,
                "message": &self.failure.message,
                "details": &self.failure.details
            }
        })
    }

    pub fn status(&self) -> u8 {
        self.failure.status
    }

    pub fn next_steps(&self) -> &[Box<str>] {
        &self.failure.next_steps
    }

    pub fn message(&self) -> &str {
        &self.failure.message
    }

    pub fn details(&self) -> &Value {
        &self.failure.details
    }
}

macro_rules! present_domain {
    ($name:ident) => {
        impl From<$name> for AppError {
            fn from(error: $name) -> Self {
                Self {
                    failure: error.into_failure(),
                    mcp_api_version: "codex-loops.mcp.v1",
                }
            }
        }
    };
}

present_domain!(RuntimeError);
present_domain!(LifecycleError);
present_domain!(InstallError);
present_domain!(SchedulerError);
present_domain!(CliError);

impl From<McpDomainError> for AppError {
    fn from(error: McpDomainError) -> Self {
        let mcp_api_version = if matches!(error, McpDomainError::Scheduler(_)) {
            "scheduler.v1"
        } else {
            "codex-loops.mcp.v1"
        };
        Self {
            failure: error.into_failure(),
            mcp_api_version,
        }
    }
}

impl Display for AppError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.failure.message)
    }
}

impl std::error::Error for AppError {}

impl From<anyhow::Error> for CliError {
    fn from(error: anyhow::Error) -> Self {
        Self::new(6, "runtime_error", error.to_string())
    }
}
