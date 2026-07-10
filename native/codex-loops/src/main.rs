mod cli;
mod error;
mod install;
mod lifecycle;
mod mcp;
mod runtime;
mod scheduler;

use std::{ffi::OsString, path::PathBuf, process::ExitCode};

use clap::{CommandFactory, Parser, Subcommand};
use serde_json::Value;

use crate::error::AppResult;

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
    /// Install or verify the Codex plugin and runtime integration.
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
        #[arg(long, default_value = "codex", value_parser = ["codex", "mock"])]
        provider: String,
        #[arg(long)]
        run_id: Option<String>,
        #[arg(long)]
        server: Option<String>,
        #[arg(short, long)]
        open: bool,
        #[arg(long)]
        json: bool,
    },
    /// Read the current projection for a workflow run.
    Status {
        run_id: String,
        #[arg(long)]
        server: Option<String>,
        #[arg(long)]
        json: bool,
    },
    /// Read durable journal summaries for a workflow run.
    Inspect {
        run_id: String,
        #[arg(long)]
        server: Option<String>,
        #[arg(long)]
        json: bool,
    },
    /// Resume an existing workflow run.
    Resume {
        run_id: String,
        #[arg(long)]
        script: Option<PathBuf>,
        #[arg(long, default_value = "codex", value_parser = ["codex", "mock"])]
        provider: String,
        #[arg(long)]
        server: Option<String>,
        #[arg(long)]
        json: bool,
    },
    /// Open a workflow run in the LiveView UI.
    Open {
        run_id: String,
        #[arg(long)]
        server: Option<String>,
        #[arg(long)]
        json: bool,
    },
    /// Start or discover the managed local scheduler.
    Serve {
        #[arg(long)]
        host: Option<String>,
        #[arg(long)]
        port: Option<u16>,
        #[arg(long)]
        journal: Option<String>,
        #[arg(long)]
        model: Option<String>,
        #[arg(long, conflicts_with = "json")]
        foreground: bool,
        #[arg(long)]
        json: bool,
    },
    /// Stop the managed local scheduler.
    Stop {
        #[arg(long)]
        server: Option<String>,
        #[arg(long)]
        host: Option<String>,
        #[arg(long)]
        port: Option<u16>,
        #[arg(long)]
        force: bool,
        #[arg(long)]
        json: bool,
    },
    /// Restart the managed scheduler with optional configuration.
    Restart {
        #[arg(long)]
        host: Option<String>,
        #[arg(long)]
        port: Option<u16>,
        #[arg(long)]
        journal: Option<String>,
        #[arg(long)]
        model: Option<String>,
        #[arg(long)]
        json: bool,
    },
    /// Read the managed scheduler log.
    Logs {
        #[arg(long)]
        server: Option<String>,
        #[arg(long)]
        host: Option<String>,
        #[arg(long)]
        port: Option<u16>,
        #[arg(long, default_value_t = 200)]
        lines: usize,
        #[arg(long)]
        json: bool,
    },
    /// Inspect runtime discovery and scheduler health.
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

#[tokio::main]
async fn main() -> ExitCode {
    let app = App::parse();
    match app.command {
        Some(Command::Mcp { stdio: _ }) => exit_silent(mcp::run().await),
        Some(Command::Daemon) => exit_silent(lifecycle::run_supervisor().await),
        Some(Command::ProviderExec { args }) => provider_exec(args),
        Some(Command::Run {
            script,
            provider,
            run_id,
            server,
            open,
            json,
        }) => {
            let result = cli::run_workflow(script, provider, run_id, server, open).await;
            exit_value(result, json)
        }
        Some(Command::Serve {
            host,
            port,
            journal,
            model,
            foreground,
            json,
        }) => exit_value(
            cli::serve(host, port, journal, model, foreground).await,
            json,
        ),
        Some(Command::Stop {
            server,
            host,
            port,
            force,
            json,
        }) => exit_value(cli::stop(server, host, port, force).await, json),
        Some(Command::Restart {
            host,
            port,
            journal,
            model,
            json,
        }) => exit_value(cli::restart(host, port, journal, model).await, json),
        Some(Command::Logs {
            server,
            host,
            port,
            lines,
            json,
        }) => exit_value(cli::logs(server, host, port, lines), json),
        Some(Command::Status {
            run_id,
            server,
            json,
        }) => exit_value(cli::status(run_id, server).await, json),
        Some(Command::Inspect {
            run_id,
            server,
            json,
        }) => exit_value(cli::inspect(run_id, server).await, json),
        Some(Command::Resume {
            run_id,
            script,
            provider,
            server,
            json,
        }) => exit_value(cli::resume(run_id, script, provider, server).await, json),
        Some(Command::Open {
            run_id,
            server,
            json,
        }) => exit_value(cli::open(run_id, server).await, json),
        Some(Command::Doctor { json }) => exit_value(cli::doctor().await, json),
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
                }),
                json,
            )
        }
        None => {
            let mut command = App::command();
            if let Err(error) = command.print_help() {
                eprintln!("{error}");
                return ExitCode::FAILURE;
            }
            println!();
            ExitCode::SUCCESS
        }
    }
}

fn provider_exec(args: Vec<OsString>) -> ExitCode {
    let binding = match runtime::CodexBinding::load(&match runtime::binding_path() {
        Ok(path) => path,
        Err(error) => {
            eprintln!("{error}");
            return ExitCode::from(127);
        }
    }) {
        Ok(binding) => binding,
        Err(error) => {
            eprintln!("{error}");
            return ExitCode::from(127);
        }
    };

    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        let error = std::process::Command::new(binding.path).args(args).exec();
        eprintln!("Could not execute the configured Codex command: {error}");
        ExitCode::from(127)
    }
    #[cfg(not(unix))]
    {
        match std::process::Command::new(binding.path).args(args).status() {
            Ok(status) => ExitCode::from(status.code().unwrap_or(1) as u8),
            Err(error) => {
                eprintln!("Could not execute the configured Codex command: {error}");
                ExitCode::from(127)
            }
        }
    }
}

fn exit_value(result: AppResult<Value>, json: bool) -> ExitCode {
    match result {
        Ok(value) => {
            if json {
                println!("{value}");
            } else {
                print_human(&value);
            }
            ExitCode::SUCCESS
        }
        Err(error) => {
            if json {
                eprintln!("{}", error.cli_envelope());
            } else {
                eprintln!("{error}");
                for next_step in &error.next_steps {
                    eprintln!("  {next_step}");
                }
            }
            ExitCode::from(error.status)
        }
    }
}

fn exit_silent(result: AppResult<()>) -> ExitCode {
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("{error}");
            ExitCode::from(error.status)
        }
    }
}

fn print_human(value: &Value) {
    match value.get("command").and_then(Value::as_str) {
        Some("run") => {
            if value["scheduler_started"] == Value::Bool(true) {
                println!(
                    "Codex Loops started at {}",
                    value["server_url"].as_str().unwrap_or("unknown")
                );
            }
            println!(
                "Run accepted: {}",
                value["run_id"].as_str().unwrap_or("unknown")
            );
            println!(
                "Provider: {}",
                value["provider"].as_str().unwrap_or("unknown")
            );
            println!("UI: {}", value["ui_url"].as_str().unwrap_or("unknown"));
            if value["opened"] == Value::Bool(true) {
                println!("Opened in your browser.");
            }
            if let Some(warning) = value["warning"].as_str() {
                println!("{warning}");
            }
        }
        Some("serve") => println!(
            "Codex Loops {} at {}",
            if value["started"] == Value::Bool(true) {
                "started"
            } else {
                "already running"
            },
            value["server_url"].as_str().unwrap_or("unknown")
        ),
        Some("stop") => println!(
            "{}",
            if value["stopped"] == Value::Bool(true) {
                "Codex Loops stopped."
            } else {
                "Codex Loops is not running."
            }
        ),
        Some("restart") => println!(
            "Codex Loops restarted at {}",
            value["server_url"].as_str().unwrap_or("unknown")
        ),
        Some("logs") => print!("{}", value["output"].as_str().unwrap_or("")),
        Some("install") => {
            let mode = value["mode"].as_str().unwrap_or("install");
            if mode == "dry_run" {
                println!("Codex Loops installation plan:");
            } else {
                println!(
                    "Codex Loops is {}.",
                    if value["changed"] == Value::Bool(true) {
                        "installed"
                    } else {
                        "ready"
                    }
                );
            }
            for command in value["commands"].as_array().into_iter().flatten() {
                if let Some(command) = command.as_str() {
                    println!("  {command}");
                }
            }
            if value["plan"].as_array().is_some_and(Vec::is_empty) && mode == "dry_run" {
                println!("  No changes required.");
            }
            if let Some(root) = value.pointer("/runtime/root").and_then(Value::as_str) {
                println!("Runtime: {root}");
            }
            if let Some(scheduler) = value.pointer("/runtime/scheduler").and_then(Value::as_str) {
                println!("Scheduler: {scheduler}");
            }
            if let Some(control_plane) = value
                .pointer("/runtime/control_plane")
                .and_then(Value::as_str)
            {
                println!("Control plane: {control_plane}");
            }
            if let Some(codex) = value.pointer("/codex/path").and_then(Value::as_str) {
                println!("Codex: {codex}");
            }
            if let Some(skill) = value.pointer("/skill/path").and_then(Value::as_str) {
                println!("Skill: {skill}");
            }
            if let Some(mcp) = value.pointer("/mcp/name").and_then(Value::as_str) {
                println!("MCP: {mcp}");
            }
            if let Some(next) = value.pointer("/next_steps/0").and_then(Value::as_str) {
                println!("Next: {next}");
            }
        }
        Some("open") => println!("Opened {}", value["ui_url"].as_str().unwrap_or("unknown")),
        Some("doctor") => {
            println!(
                "Codex Loops {}",
                value["version"].as_str().unwrap_or("unknown")
            );
            println!(
                "Scheduler: {}",
                value["scheduler_state"].as_str().unwrap_or("unknown")
            );
            println!(
                "URL: {}",
                value["scheduler_url"].as_str().unwrap_or("unknown")
            );
        }
        None if value.get("api_version").is_some() => {
            println!(
                "{}",
                serde_json::to_string_pretty(value).unwrap_or_else(|_| value.to_string())
            );
        }
        _ => {
            println!(
                "Codex Loops is {}.",
                if value["changed"] == Value::Bool(true) {
                    "installed"
                } else {
                    "ready"
                }
            );
            if let Some(root) = value.pointer("/runtime/root").and_then(Value::as_str) {
                println!("Runtime: {root}");
            }
            if let Some(next) = value.pointer("/next_steps/0").and_then(Value::as_str) {
                println!("Next: {next}");
            }
        }
    }
}
