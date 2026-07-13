use std::{
    fmt::{Display, Formatter},
    num::NonZeroU16,
    path::PathBuf,
};

use serde::Serialize;
use serde_json::Value;
use url::Url;

use crate::{
    error::{AppError, AppResult, ChangeState, ExitStatus},
    install::{InstallOutput, Mode},
    lifecycle::{BindHost, StartDisposition, StopDisposition},
    sandbox,
    scheduler::{Provider, RunId},
};

#[derive(Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum RunState {
    Accepted,
    Pending,
    Running,
    Completed,
    Failed,
}

impl TryFrom<String> for RunState {
    type Error = AppError;

    fn try_from(state: String) -> AppResult<Self> {
        if state == "accepted" {
            Ok(Self::Accepted)
        } else if state == "pending" {
            Ok(Self::Pending)
        } else if state == "running" {
            Ok(Self::Running)
        } else if state == "completed" {
            Ok(Self::Completed)
        } else if state == "failed" {
            Ok(Self::Failed)
        } else {
            Err(AppError::new(
                ExitStatus::Runtime,
                "scheduler_state_invalid",
                "The scheduler returned an unknown workflow state.",
            )
            .details(serde_json::json!({"state": state})))
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum BrowserOutcome {
    Skipped,
    Opened,
    Failed { warning: String },
}

impl BrowserOutcome {
    fn wire(&self) -> (bool, Option<&str>) {
        match self {
            Self::Skipped => (false, None),
            Self::Opened => (true, None),
            Self::Failed { warning } => (false, Some(warning)),
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum ServeDisposition {
    Background(StartDisposition),
    ForegroundStopped,
}

#[derive(Debug)]
pub struct RunOutput {
    pub script_path: PathBuf,
    pub workflow_name: Option<String>,
    pub run_id: RunId,
    pub provider: Provider,
    pub state: Option<RunState>,
    pub ui_url: Url,
    pub browser: BrowserOutcome,
    pub scheduler: StartDisposition,
    pub server_url: Url,
}

#[derive(Debug)]
pub struct ServeOutput {
    pub server_url: Url,
    pub host: BindHost,
    pub port: NonZeroU16,
    pub disposition: ServeDisposition,
}

#[derive(Debug)]
pub struct StopOutput {
    pub server_url: Url,
    pub disposition: StopDisposition,
}

#[derive(Debug)]
pub struct RestartOutput {
    pub server_url: Url,
    pub host: BindHost,
    pub port: NonZeroU16,
    pub previous: StopDisposition,
}

#[derive(Debug)]
pub struct LogsOutput {
    pub server_url: Url,
    pub requested_lines: usize,
    pub output: String,
}

#[derive(Debug)]
pub struct OpenOutput {
    pub run_id: RunId,
    pub ui_url: Url,
}

#[derive(Debug, Serialize)]
pub struct DoctorCodex {
    pub path: PathBuf,
    pub version: String,
}

#[derive(Debug)]
pub struct DoctorOutput {
    pub scheduler_bin: PathBuf,
    pub scheduler_url: Url,
    pub scheduler_health: Value,
    pub runtime_root: PathBuf,
    pub codex: DoctorCodex,
}

#[derive(Debug)]
pub enum CliOutput {
    Run(RunOutput),
    Serve(ServeOutput),
    Stop(StopOutput),
    Restart(RestartOutput),
    Logs(LogsOutput),
    Install(InstallOutput),
    Open(OpenOutput),
    Doctor(DoctorOutput),
    SandboxRun(sandbox::RunOutput),
    SandboxClean(sandbox::CleanOutput),
    Scheduler(Value),
}

impl CliOutput {
    pub fn into_json(self) -> AppResult<Value> {
        match self {
            Self::Run(output) => run_json(output),
            Self::Serve(output) => serve_json(output),
            Self::Stop(output) => success(
                "stop",
                StopWire {
                    server_url: output.server_url.as_str(),
                    state: "stopped",
                    stopped: matches!(output.disposition, StopDisposition::Stopped),
                },
            ),
            Self::Restart(output) => success(
                "restart",
                RestartWire {
                    server_url: output.server_url.as_str(),
                    host: &output.host,
                    port: output.port,
                    state: "running",
                    stopped: matches!(output.previous, StopDisposition::Stopped),
                    started: true,
                },
            ),
            Self::Logs(output) => success(
                "logs",
                LogsWire {
                    server_url: output.server_url.as_str(),
                    lines: output.requested_lines,
                    output: &output.output,
                },
            ),
            Self::Install(output) => success("install", output),
            Self::Open(output) => success(
                "open",
                OpenWire {
                    run_id: &output.run_id,
                    ui_url: output.ui_url.as_str(),
                    opened: true,
                },
            ),
            Self::Doctor(output) => success(
                "doctor",
                DoctorWire {
                    version: env!("CARGO_PKG_VERSION"),
                    scheduler_bin: &output.scheduler_bin,
                    scheduler_url: output.scheduler_url.as_str(),
                    scheduler_state: "running",
                    scheduler_health: &output.scheduler_health,
                    runtime_root: &output.runtime_root,
                    codex: &output.codex,
                },
            ),
            Self::SandboxRun(output) => {
                let (opened, warning) = output.browser.wire();
                success(
                    "sandbox-run",
                    SandboxRunWire {
                        artifact_dir: &output.artifact_dir,
                        worktree: &output.worktree,
                        journal: &output.journal,
                        transcript: &output.transcript,
                        run_id: &output.run_id,
                        provider: output.provider,
                        state: &output.state,
                        ui_url: output.ui_url.as_str(),
                        opened,
                        warning,
                    },
                )
            }
            Self::SandboxClean(output) => success(
                "sandbox-clean",
                SandboxCleanWire {
                    artifact_dir: &output.artifact_dir,
                    worktree: &output.worktree,
                    scheduler_stopped: output.scheduler_stopped,
                    removed: true,
                },
            ),
            Self::Scheduler(envelope) => Ok(envelope),
        }
    }
}

fn run_json(output: RunOutput) -> AppResult<Value> {
    let (opened, warning) = output.browser.wire();
    success(
        "run",
        RunWire {
            script_path: &output.script_path,
            workflow_name: output.workflow_name.as_deref(),
            run_id: &output.run_id,
            provider: output.provider,
            state: output.state.as_ref(),
            ui_url: output.ui_url.as_str(),
            opened,
            warning,
            scheduler_started: matches!(output.scheduler, StartDisposition::Started),
            server_url: output.server_url.as_str(),
        },
    )
}

fn serve_json(output: ServeOutput) -> AppResult<Value> {
    match &output.disposition {
        ServeDisposition::Background(startup) => success(
            "serve",
            ServeWire {
                server_url: output.server_url.as_str(),
                host: &output.host,
                port: output.port,
                state: "running",
                started: matches!(startup, StartDisposition::Started),
                foreground: None,
            },
        ),
        ServeDisposition::ForegroundStopped => success(
            "serve",
            ServeWire {
                server_url: output.server_url.as_str(),
                host: &output.host,
                port: output.port,
                state: "stopped",
                started: true,
                foreground: Some(true),
            },
        ),
    }
}

fn success(payload_command: &'static str, payload: impl Serialize) -> AppResult<Value> {
    let serialized = serde_json::to_value(payload).map_err(|error| {
        AppError::new(
            ExitStatus::Runtime,
            "cli_output_serialization",
            "Could not serialize the command result.",
        )
        .details(serde_json::json!({"command": payload_command, "reason": error.to_string()}))
    })?;
    let Value::Object(mut fields) = serialized else {
        return Err(AppError::new(
            ExitStatus::Runtime,
            "cli_output_shape",
            "A command result did not serialize as a JSON object.",
        )
        .details(serde_json::json!({"command": payload_command})));
    };
    fields.insert("command".into(), Value::String(payload_command.into()));
    fields.insert("ok".into(), Value::Bool(true));
    Ok(Value::Object(fields))
}

#[derive(Serialize)]
struct RunWire<'a> {
    script_path: &'a PathBuf,
    workflow_name: Option<&'a str>,
    run_id: &'a RunId,
    provider: Provider,
    state: Option<&'a RunState>,
    ui_url: &'a str,
    opened: bool,
    warning: Option<&'a str>,
    scheduler_started: bool,
    server_url: &'a str,
}

#[derive(Serialize)]
struct ServeWire<'a> {
    server_url: &'a str,
    host: &'a BindHost,
    port: NonZeroU16,
    state: &'static str,
    started: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    foreground: Option<bool>,
}

#[derive(Serialize)]
struct StopWire<'a> {
    server_url: &'a str,
    state: &'static str,
    stopped: bool,
}

#[derive(Serialize)]
struct RestartWire<'a> {
    server_url: &'a str,
    host: &'a BindHost,
    port: NonZeroU16,
    state: &'static str,
    stopped: bool,
    started: bool,
}

#[derive(Serialize)]
struct LogsWire<'a> {
    server_url: &'a str,
    lines: usize,
    output: &'a str,
}

#[derive(Serialize)]
struct OpenWire<'a> {
    run_id: &'a RunId,
    ui_url: &'a str,
    opened: bool,
}

#[derive(Serialize)]
struct DoctorWire<'a> {
    version: &'static str,
    scheduler_bin: &'a PathBuf,
    scheduler_url: &'a str,
    scheduler_state: &'static str,
    scheduler_health: &'a Value,
    runtime_root: &'a PathBuf,
    codex: &'a DoctorCodex,
}

#[derive(Serialize)]
struct SandboxRunWire<'a> {
    artifact_dir: &'a PathBuf,
    worktree: &'a PathBuf,
    journal: &'a PathBuf,
    transcript: &'a PathBuf,
    run_id: &'a RunId,
    provider: Provider,
    state: &'a str,
    ui_url: &'a str,
    opened: bool,
    warning: Option<&'a str>,
}

#[derive(Serialize)]
struct SandboxCleanWire<'a> {
    artifact_dir: &'a PathBuf,
    worktree: &'a PathBuf,
    scheduler_stopped: bool,
    removed: bool,
}

impl Display for CliOutput {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Run(output) => display_run(formatter, output),
            Self::Serve(output) => display_serve(formatter, output),
            Self::Stop(output) => match &output.disposition {
                StopDisposition::Stopped => formatter.write_str("Codex Loops stopped."),
                StopDisposition::NotRunning => formatter.write_str("Codex Loops is not running."),
            },
            Self::Restart(output) => {
                write!(formatter, "Codex Loops restarted at {}", output.server_url)
            }
            Self::Logs(output) => formatter.write_str(&output.output),
            Self::Install(output) => display_install(formatter, output),
            Self::Open(output) => write!(formatter, "Opened {}", output.ui_url),
            Self::Doctor(output) => write!(
                formatter,
                "Codex Loops {}\nScheduler: running\nURL: {}",
                env!("CARGO_PKG_VERSION"),
                output.scheduler_url
            ),
            Self::SandboxRun(output) => {
                writeln!(
                    formatter,
                    "Sandbox run completed: {}",
                    output.run_id.as_str()
                )?;
                writeln!(formatter, "Artifacts: {}", output.artifact_dir.display())?;
                writeln!(formatter, "Worktree: {}", output.worktree.display())?;
                writeln!(formatter, "UI: {}", output.ui_url)?;
                write!(
                    formatter,
                    "Cleanup: codex-loops sandbox-clean {}",
                    output.artifact_dir.display()
                )?;
                match &output.browser {
                    BrowserOutcome::Skipped => Ok(()),
                    BrowserOutcome::Opened => write!(formatter, "\nOpened in your browser."),
                    BrowserOutcome::Failed { warning } => write!(formatter, "\n{warning}"),
                }
            }
            Self::SandboxClean(output) => write!(
                formatter,
                "Removed sandbox {} (worktree {}).",
                output.artifact_dir.display(),
                output.worktree.display()
            ),
            Self::Scheduler(envelope) => {
                let pretty = serde_json::to_string_pretty(envelope).map_err(|_| std::fmt::Error)?;
                formatter.write_str(&pretty)
            }
        }
    }
}

fn display_run(formatter: &mut Formatter<'_>, output: &RunOutput) -> std::fmt::Result {
    if matches!(output.scheduler, StartDisposition::Started) {
        writeln!(formatter, "Codex Loops started at {}", output.server_url)?;
    }
    writeln!(formatter, "Run accepted: {}", output.run_id.as_str())?;
    writeln!(formatter, "Provider: {}", output.provider)?;
    write!(formatter, "UI: {}", output.ui_url)?;
    match &output.browser {
        BrowserOutcome::Skipped => Ok(()),
        BrowserOutcome::Opened => write!(formatter, "\nOpened in your browser."),
        BrowserOutcome::Failed { warning } => write!(formatter, "\n{warning}"),
    }
}

fn display_serve(formatter: &mut Formatter<'_>, output: &ServeOutput) -> std::fmt::Result {
    match &output.disposition {
        ServeDisposition::Background(StartDisposition::Started) => {
            write!(formatter, "Codex Loops started at {}", output.server_url)
        }
        ServeDisposition::Background(StartDisposition::AlreadyRunning) => {
            write!(
                formatter,
                "Codex Loops already running at {}",
                output.server_url
            )
        }
        ServeDisposition::ForegroundStopped => write!(
            formatter,
            "Codex Loops foreground scheduler stopped at {}",
            output.server_url
        ),
    }
}

fn display_install(formatter: &mut Formatter<'_>, output: &InstallOutput) -> std::fmt::Result {
    match output.mode {
        Mode::DryRun => writeln!(formatter, "Codex Loops installation plan:")?,
        Mode::Install | Mode::Check => writeln!(
            formatter,
            "Codex Loops is {}.",
            match output.changed {
                ChangeState::Changed => "installed",
                ChangeState::Unchanged => "ready",
            }
        )?,
    }
    for command in &output.commands {
        writeln!(formatter, "  {command}")?;
    }
    if matches!(output.mode, Mode::DryRun) && output.plan.is_empty() {
        writeln!(formatter, "  No changes required.")?;
    }
    writeln!(formatter, "Runtime: {}", output.runtime.root.display())?;
    writeln!(
        formatter,
        "Scheduler: {}",
        output.runtime.scheduler.display()
    )?;
    writeln!(
        formatter,
        "Control plane: {}",
        output.runtime.control_plane.display()
    )?;
    writeln!(formatter, "Codex: {}", output.codex.path.display())?;
    writeln!(formatter, "Skill: {}", output.skill.path.display())?;
    writeln!(formatter, "MCP: {}", output.mcp.name)?;
    write!(formatter, "Next: {}", output.next_steps[0])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_url() -> AppResult<Url> {
        Url::parse("http://127.0.0.1:47125/").map_err(|error| {
            AppError::new(ExitStatus::Runtime, "test_url_invalid", error.to_string())
        })
    }

    fn test_port() -> AppResult<NonZeroU16> {
        NonZeroU16::new(47_125).ok_or_else(|| {
            AppError::new(
                ExitStatus::Runtime,
                "test_port_invalid",
                "The test port must be nonzero.",
            )
        })
    }

    fn test_host() -> AppResult<BindHost> {
        "127.0.0.1".parse()
    }

    fn run_output(browser: BrowserOutcome) -> AppResult<CliOutput> {
        Ok(CliOutput::Run(RunOutput {
            script_path: PathBuf::from("/tmp/review.exs"),
            workflow_name: Some("review".into()),
            run_id: RunId::new("review-1")?,
            provider: Provider::Mock,
            state: Some(RunState::Running),
            ui_url: Url::parse("http://127.0.0.1:47125/runs/review-1").map_err(|error| {
                AppError::new(ExitStatus::Runtime, "test_url_invalid", error.to_string())
            })?,
            browser,
            scheduler: StartDisposition::Started,
            server_url: test_url()?,
        }))
    }

    #[test]
    fn browser_outcomes_cannot_serialize_contradictory_fields() -> AppResult<()> {
        let skipped = run_output(BrowserOutcome::Skipped)?.into_json()?;
        assert_eq!(skipped["opened"], false);
        assert_eq!(skipped["warning"], Value::Null);

        let opened = run_output(BrowserOutcome::Opened)?.into_json()?;
        assert_eq!(opened["opened"], true);
        assert_eq!(opened["warning"], Value::Null);

        let failed = run_output(BrowserOutcome::Failed {
            warning: "browser unavailable".into(),
        })?
        .into_json()?;
        assert_eq!(failed["opened"], false);
        assert_eq!(failed["warning"], "browser unavailable");
        Ok(())
    }

    #[test]
    fn lifecycle_dispositions_derive_the_legacy_wire_flags() -> AppResult<()> {
        let serve = CliOutput::Serve(ServeOutput {
            server_url: test_url()?,
            host: test_host()?,
            port: test_port()?,
            disposition: ServeDisposition::Background(StartDisposition::AlreadyRunning),
        })
        .into_json()?;
        assert_eq!(serve["state"], "running");
        assert_eq!(serve["started"], false);
        assert!(serve.get("foreground").is_none());

        let stop = CliOutput::Stop(StopOutput {
            server_url: test_url()?,
            disposition: StopDisposition::NotRunning,
        })
        .into_json()?;
        assert_eq!(stop["state"], "stopped");
        assert_eq!(stop["stopped"], false);
        Ok(())
    }

    #[test]
    fn scheduler_envelopes_pass_through_without_cli_tags() -> AppResult<()> {
        let envelope = serde_json::json!({
            "api_version": "scheduler.v1",
            "data": {"run_id": "review-1", "state": "running"}
        });
        let actual = CliOutput::Scheduler(envelope).into_json()?;
        assert_eq!(actual["api_version"], "scheduler.v1");
        assert!(actual.get("ok").is_none());
        assert!(actual.get("command").is_none());
        Ok(())
    }

    #[test]
    fn human_output_is_driven_by_variants() -> AppResult<()> {
        let run = run_output(BrowserOutcome::Opened)?;
        let rendered = format!("{run}");
        assert!(rendered.contains("Run accepted: review-1"));
        assert!(rendered.contains("Provider: mock"));
        assert!(rendered.contains("Opened in your browser."));
        Ok(())
    }

    #[test]
    fn run_states_reject_unknown_protocol_values() {
        let error = RunState::try_from("waiting_forever".to_owned());
        assert!(matches!(error, Err(error) if error.code() == "scheduler_state_invalid"));
    }
}
