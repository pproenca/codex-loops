mod cli;
mod error;
mod install;
mod lifecycle;
mod mcp;
mod provider;
mod runtime;
mod sandbox;
mod scheduler;

use std::{
    ffi::OsString,
    num::{NonZeroU16, NonZeroU64},
    path::PathBuf,
    process::ExitCode,
};

use clap::{CommandFactory, Parser, Subcommand};

use crate::{
    cli::{
        CliOutput, Endpoint, LogsOptions, RestartOptions, ResumeOptions, RunOptions, ServeOptions,
        StopOptions,
    },
    error::{AppError, AppResult, ExitStatus},
    lifecycle::BindHost,
    scheduler::{Provider, RunId},
};

#[derive(Clone, Copy)]
enum OutputFormat {
    Human,
    Json,
}

impl From<bool> for OutputFormat {
    fn from(json: bool) -> Self {
        if json { Self::Json } else { Self::Human }
    }
}

#[derive(Parser)]
#[command(
    name = "codex-loops",
    version,
    about = "Local workflow scheduler for Codex"
)]
struct App {
    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand)]
enum Command {
    /// Install or verify the Codex binding, user skill, and MCP integration.
    #[command(alias = "setup")]
    Install {
        #[arg(long, conflicts_with = "dry_run")]
        check: bool,
        #[arg(long, conflicts_with = "check")]
        dry_run: bool,
        #[arg(long)]
        json: bool,
        #[arg(long)]
        verbose: bool,
        #[arg(long, value_name = "ABSOLUTE_PATH")]
        codex: Option<PathBuf>,
    },
    /// Validate and start a workflow through the scheduler.
    Run {
        script: PathBuf,
        #[arg(long, value_enum, default_value_t = Provider::Codex)]
        provider: Provider,
        #[arg(long)]
        run_id: Option<RunId>,
        #[arg(long)]
        server: Option<String>,
        #[arg(short, long)]
        open: bool,
        #[arg(long)]
        json: bool,
    },
    /// Run a workflow through MCP in a retained, inspectable Git worktree sandbox.
    SandboxRun {
        script: PathBuf,
        #[arg(long, value_enum, default_value_t = Provider::Codex)]
        provider: Provider,
        #[arg(long)]
        run_id: Option<RunId>,
        #[arg(long, value_name = "DIRECTORY")]
        output: Option<PathBuf>,
        #[arg(long)]
        model: Option<String>,
        #[arg(long, default_value = "1800")]
        timeout_seconds: NonZeroU64,
        #[arg(short, long)]
        open: bool,
        #[arg(long)]
        json: bool,
    },
    /// Stop and remove a retained sandbox run.
    SandboxClean {
        artifact_dir: PathBuf,
        #[arg(long)]
        force: bool,
        #[arg(long)]
        json: bool,
    },
    /// Read the current projection for a workflow run.
    Status {
        run_id: RunId,
        #[arg(long)]
        server: Option<String>,
        #[arg(long)]
        json: bool,
    },
    /// Read durable journal summaries for a workflow run.
    Inspect {
        run_id: RunId,
        #[arg(long)]
        server: Option<String>,
        #[arg(long)]
        json: bool,
    },
    /// Resume an existing workflow run.
    Resume {
        run_id: RunId,
        #[arg(long)]
        script: Option<PathBuf>,
        #[arg(long, value_enum, default_value_t = Provider::Codex)]
        provider: Provider,
        #[arg(long)]
        server: Option<String>,
        #[arg(long)]
        json: bool,
    },
    /// Open a workflow run in the LiveView UI.
    Open {
        run_id: RunId,
        #[arg(long)]
        server: Option<String>,
        #[arg(long)]
        json: bool,
    },
    /// Start or join the managed local scheduler.
    Serve {
        #[arg(long)]
        host: Option<BindHost>,
        #[arg(long)]
        port: Option<NonZeroU16>,
        #[arg(long)]
        journal: Option<PathBuf>,
        #[arg(long)]
        model: Option<String>,
        #[arg(long, conflicts_with = "json")]
        foreground: bool,
        #[arg(long)]
        json: bool,
    },
    /// Stop the managed local scheduler.
    Stop {
        #[arg(long, conflicts_with_all = ["host", "port"])]
        server: Option<String>,
        #[arg(long)]
        host: Option<BindHost>,
        #[arg(long)]
        port: Option<NonZeroU16>,
        #[arg(long)]
        force: bool,
        #[arg(long)]
        json: bool,
    },
    /// Restart the managed scheduler with optional configuration.
    Restart {
        #[arg(long)]
        host: Option<BindHost>,
        #[arg(long)]
        port: Option<NonZeroU16>,
        #[arg(long)]
        journal: Option<PathBuf>,
        #[arg(long)]
        model: Option<String>,
        #[arg(long)]
        json: bool,
    },
    /// Read the managed scheduler log.
    Logs {
        #[arg(long, conflicts_with_all = ["host", "port"])]
        server: Option<String>,
        #[arg(long)]
        host: Option<BindHost>,
        #[arg(long)]
        port: Option<NonZeroU16>,
        #[arg(long, default_value_t = 200)]
        lines: usize,
        #[arg(long)]
        json: bool,
    },
    /// Inspect runtime binding and scheduler health.
    Doctor {
        #[arg(long)]
        json: bool,
    },
    /// Run the MCP server over stdio.
    Mcp {
        #[arg(long)]
        stdio: bool,
    },
    #[command(hide = true)]
    Daemon,
    /// Execute the persisted Codex binding after revalidating its exact version.
    #[command(hide = true)]
    ProviderExec {
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        args: Vec<OsString>,
    },
}

impl Command {
    fn output_format(&self) -> OutputFormat {
        match self {
            Self::Install { json, .. }
            | Self::Run { json, .. }
            | Self::SandboxRun { json, .. }
            | Self::SandboxClean { json, .. }
            | Self::Status { json, .. }
            | Self::Inspect { json, .. }
            | Self::Resume { json, .. }
            | Self::Open { json, .. }
            | Self::Serve { json, .. }
            | Self::Stop { json, .. }
            | Self::Restart { json, .. }
            | Self::Logs { json, .. }
            | Self::Doctor { json } => (*json).into(),
            Self::Mcp { .. } | Self::Daemon | Self::ProviderExec { .. } => OutputFormat::Human,
        }
    }
}

fn main() -> ExitCode {
    match App::parse().command {
        Some(Command::ProviderExec { args }) => provider::exec(args),
        command => start_runtime(command),
    }
}

fn start_runtime(command: Option<Command>) -> ExitCode {
    let output = command
        .as_ref()
        .map_or(OutputFormat::Human, Command::output_format);
    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(error) => {
            return report_error(
                AppError::new(
                    ExitStatus::Runtime,
                    "async_runtime_unavailable",
                    "Could not start the Codex Loops async runtime.",
                )
                .details(serde_json::json!({"reason": error.to_string()})),
                output,
            );
        }
    };
    runtime.block_on(run(command))
}

async fn run(command: Option<Command>) -> ExitCode {
    match command {
        Some(Command::Mcp { stdio: _ }) => exit_silent(mcp::run().await),
        Some(Command::Daemon) => exit_silent(lifecycle::run_supervisor().await),
        Some(Command::ProviderExec { .. }) => report_error(
            AppError::new(
                ExitStatus::Runtime,
                "provider_dispatch_invariant",
                "Provider execution must be dispatched before starting the async runtime.",
            ),
            OutputFormat::Human,
        ),
        Some(Command::Run {
            script,
            provider,
            run_id,
            server,
            open,
            json,
        }) => {
            let open_mode = if open {
                cli::OpenMode::Open
            } else {
                cli::OpenMode::Skip
            };
            exit_value(
                cli::run_workflow(RunOptions {
                    script,
                    provider,
                    run_id,
                    server,
                    open_mode,
                })
                .await,
                json.into(),
            )
        }
        Some(Command::SandboxRun {
            script,
            provider,
            run_id,
            output,
            model,
            timeout_seconds,
            open,
            json,
        }) => {
            let open_mode = if open {
                cli::OpenMode::Open
            } else {
                cli::OpenMode::Skip
            };
            exit_value(
                sandbox::run(sandbox::RunOptions {
                    script,
                    provider,
                    run_id,
                    output_dir: output,
                    model,
                    timeout_seconds,
                    open_mode,
                })
                .await
                .map(CliOutput::SandboxRun),
                json.into(),
            )
        }
        Some(Command::SandboxClean {
            artifact_dir,
            force,
            json,
        }) => {
            let mode = if force {
                sandbox::CleanMode::Force
            } else {
                sandbox::CleanMode::PreserveDirty
            };
            exit_value(
                sandbox::clean(sandbox::CleanOptions { artifact_dir, mode })
                    .await
                    .map(CliOutput::SandboxClean),
                json.into(),
            )
        }
        Some(Command::Serve {
            host,
            port,
            journal,
            model,
            foreground,
            json,
        }) => {
            let mode = if foreground {
                cli::ServeMode::Foreground
            } else {
                cli::ServeMode::Background
            };
            exit_value(
                cli::serve(ServeOptions {
                    host,
                    port,
                    journal,
                    model,
                    mode,
                })
                .await,
                json.into(),
            )
        }
        Some(Command::Stop {
            server,
            host,
            port,
            force,
            json,
        }) => {
            let mode = if force {
                lifecycle::StopMode::Force
            } else {
                lifecycle::StopMode::Graceful
            };
            let endpoint = match server {
                Some(server) => Endpoint::Server(server),
                None if host.is_some() || port.is_some() => Endpoint::Local { host, port },
                None => Endpoint::Environment,
            };
            exit_value(cli::stop(StopOptions { endpoint, mode }).await, json.into())
        }
        Some(Command::Restart {
            host,
            port,
            journal,
            model,
            json,
        }) => exit_value(
            cli::restart(RestartOptions {
                host,
                port,
                journal,
                model,
            })
            .await,
            json.into(),
        ),
        Some(Command::Logs {
            server,
            host,
            port,
            lines,
            json,
        }) => {
            let endpoint = match server {
                Some(server) => Endpoint::Server(server),
                None if host.is_some() || port.is_some() => Endpoint::Local { host, port },
                None => Endpoint::Environment,
            };
            exit_value(
                cli::logs(LogsOptions { endpoint, lines }).await,
                json.into(),
            )
        }
        Some(Command::Status {
            run_id,
            server,
            json,
        }) => exit_value(cli::status(run_id, server).await, json.into()),
        Some(Command::Inspect {
            run_id,
            server,
            json,
        }) => exit_value(cli::inspect(run_id, server).await, json.into()),
        Some(Command::Resume {
            run_id,
            script,
            provider,
            server,
            json,
        }) => exit_value(
            cli::resume(ResumeOptions {
                run_id,
                script,
                provider,
                server,
            })
            .await,
            json.into(),
        ),
        Some(Command::Open {
            run_id,
            server,
            json,
        }) => exit_value(cli::open(run_id, server).await, json.into()),
        Some(Command::Doctor { json }) => exit_value(cli::doctor().await, json.into()),
        Some(Command::Install {
            check,
            dry_run,
            json,
            verbose,
            codex,
        }) => {
            let mode = if check {
                install::Mode::Check
            } else if dry_run {
                install::Mode::DryRun
            } else {
                install::Mode::Install
            };
            exit_value(
                cli::install(install::Options {
                    mode,
                    verbose,
                    codex,
                })
                .await,
                json.into(),
            )
        }
        None => print_help(),
    }
}

fn exit_value(result: AppResult<CliOutput>, output: OutputFormat) -> ExitCode {
    match result {
        Ok(value) => match output {
            OutputFormat::Human => {
                println!("{value}");
                ExitCode::SUCCESS
            }
            OutputFormat::Json => match value.into_json() {
                Ok(value) => {
                    println!("{value}");
                    ExitCode::SUCCESS
                }
                Err(error) => report_error(error, output),
            },
        },
        Err(error) => report_error(error, output),
    }
}

fn exit_silent(result: AppResult<()>) -> ExitCode {
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => report_error(error, OutputFormat::Human),
    }
}

fn report_error(error: AppError, output: OutputFormat) -> ExitCode {
    match output {
        OutputFormat::Human => {
            eprintln!("{error}");
            for next_step in error.next_steps_ref() {
                eprintln!("  {next_step}");
            }
        }
        OutputFormat::Json => eprintln!("{}", error.cli_envelope()),
    }
    ExitCode::from(u8::from(error.status()))
}

fn print_help() -> ExitCode {
    let mut command = App::command();
    if let Err(error) = command.print_help() {
        eprintln!("{error}");
        return ExitCode::FAILURE;
    }
    println!();
    ExitCode::SUCCESS
}
