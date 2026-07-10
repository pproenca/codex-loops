use std::{
    env,
    path::{Path, PathBuf},
    process::Command,
};

use anyhow::{Context, Result, bail};
use serde_json::{Value, json};

use crate::error::{AppError, AppResult};

const MARKETPLACE: &str = "codex-loops";
const MARKETPLACE_SOURCE: &str = "pproenca/codex-loops";
const PLUGIN_ID: &str = "codex-loops@codex-loops";

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Install,
    Check,
    DryRun,
}

pub struct Options {
    pub mode: Mode,
    pub verbose: bool,
}

pub fn run(options: Options) -> AppResult<Value> {
    let runtime = runtime().map_err(|error| {
        AppError::new(6, "runtime_invalid", error.to_string())
            .next_steps(["Run `brew reinstall pproenca/codex-loops/codex-loops`."])
    })?;
    let codex = which::which("codex").map_err(|_| {
        AppError::new(3, "codex_missing", "Codex CLI was not found on PATH.")
            .next_steps(["Run `brew install --cask codex`."])
    })?;
    let codex_version = text_command(&codex, &["--version"]).map_err(|error| {
        AppError::new(3, "codex_incompatible", error.to_string()).step("codex_preflight")
    })?;
    check_capabilities(&codex).map_err(|error| {
        AppError::new(3, "codex_incompatible", error.to_string())
            .step("codex_preflight")
            .next_steps(["Run `codex update`."])
    })?;
    let initial = state(&codex).map_err(|error| codex_command_error(error, false, "state_read"))?;
    let actions =
        plan(&initial).map_err(|error| AppError::new(4, "install_conflict", error.to_string()))?;

    if options.mode == Mode::Check && !actions.is_empty() {
        return Err(
            AppError::new(1, "state_missing", "Codex Loops is not fully installed.")
                .details(json!({"plan": actions})),
        );
    }

    let mut changed = false;
    if options.mode == Mode::Install {
        for action in &actions {
            for args in action_commands(action) {
                command(&codex, &args)
                    .map_err(|error| codex_command_error(error, changed, command_step(&args)))?;
                changed = true;
            }
        }
    }

    let final_state = if options.mode == Mode::Install {
        state(&codex).map_err(|error| codex_command_error(error, changed, "state_verify"))?
    } else {
        initial
    };
    if options.mode != Mode::DryRun {
        let remaining = plan(&final_state).map_err(|error| {
            AppError::new(4, "install_conflict", error.to_string()).changed(changed)
        })?;
        if !remaining.is_empty() {
            return Err(AppError::new(
                6,
                "verification_failed",
                "Codex Loops installation could not be verified.",
            )
            .details(json!({"plan": remaining}))
            .changed(changed)
            .step("verification"));
        }
        verify_launcher(&final_state, &runtime).map_err(|error| {
            AppError::new(6, "launcher_discovery_failed", error.to_string())
                .changed(changed)
                .step("launcher_verify")
        })?;
    }

    let commands: Vec<String> = actions
        .iter()
        .flat_map(|action| action_commands(action))
        .map(|args| format!("codex {}", args.join(" ")))
        .collect();
    Ok(json!({
        "ok": true,
        "command": "install",
        "changed": changed,
        "mode": match options.mode { Mode::Install => "install", Mode::Check => "check", Mode::DryRun => "dry_run" },
        "runtime": runtime,
        "codex": {"path": codex, "version": codex_version.trim()},
        "marketplace": marketplace_result(final_state.get("marketplace")),
        "plugin": plugin_result(final_state.get("plugin")),
        "plan": actions,
        "commands": if options.verbose || options.mode == Mode::DryRun { Value::Array(commands.into_iter().map(Value::String).collect()) } else { Value::Null },
        "next_steps": ["Open a new Codex task and ask: Use the codex-loops skill."]
    }))
}

fn codex_command_error(error: anyhow::Error, changed: bool, step: &str) -> AppError {
    AppError::new(
        5,
        "codex_command_failed",
        "Codex command failed unexpectedly.",
    )
    .details(json!({"reason": error.to_string()}))
    .changed(changed)
    .step(step)
}

fn command_step(args: &[&str]) -> &'static str {
    match args {
        ["plugin", "marketplace", "remove", ..] => "marketplace_remove",
        ["plugin", "marketplace", "add", ..] => "marketplace_add",
        ["plugin", "add", ..] => "plugin_install",
        _ => "codex_command",
    }
}

fn runtime() -> Result<Value> {
    let root = env::var("CODEX_LOOPS_RUNTIME_ROOT")
        .context("CODEX_LOOPS_RUNTIME_ROOT is not set; reinstall Codex Loops")?;
    let root = PathBuf::from(root)
        .canonicalize()
        .context("Codex Loops runtime root does not exist")?;
    let scheduler = root.join("scheduler/bin/agent_loops");
    let mcp = root.join("mcp/codex-loops-mcp");
    if !scheduler.is_file() || !mcp.is_file() {
        bail!("Codex Loops runtime files are missing; reinstall the Homebrew package");
    }
    let version = text_command(&mcp, &["--version"])?;
    if version.trim() != format!("codex-loops-mcp {}", env!("CARGO_PKG_VERSION")) {
        bail!("Codex Loops runtime is incompatible: {}", version.trim());
    }
    Ok(
        json!({"root": root, "scheduler": scheduler, "mcp": mcp, "version": env!("CARGO_PKG_VERSION")}),
    )
}

fn check_capabilities(codex: &Path) -> Result<()> {
    for args in [
        ["plugin", "marketplace", "add", "--help"].as_slice(),
        ["plugin", "add", "--help"].as_slice(),
        ["plugin", "marketplace", "list", "--help"].as_slice(),
        ["plugin", "list", "--help"].as_slice(),
    ] {
        let output = text_command(codex, args).context("This Codex CLI does not support plugin marketplace installation. Update Codex, then rerun: codex update")?;
        if !output.contains("--json") {
            bail!(
                "This Codex CLI does not support plugin marketplace installation. Update Codex, then rerun: codex update"
            );
        }
    }
    Ok(())
}

fn state(codex: &Path) -> Result<Value> {
    let marketplaces = json_command(codex, &["plugin", "marketplace", "list", "--json"])?;
    let plugins = json_command(codex, &["plugin", "list", "--json"])?;
    let marketplace = marketplaces
        .get("marketplaces")
        .and_then(Value::as_array)
        .and_then(|items| {
            items
                .iter()
                .find(|item| item.get("name").and_then(Value::as_str) == Some(MARKETPLACE))
        })
        .cloned()
        .unwrap_or(Value::Null);
    let plugin = plugins
        .get("installed")
        .and_then(Value::as_array)
        .and_then(|items| {
            items
                .iter()
                .find(|item| item.get("pluginId").and_then(Value::as_str) == Some(PLUGIN_ID))
        })
        .cloned()
        .unwrap_or(Value::Null);
    Ok(json!({"marketplace": marketplace, "plugin": plugin}))
}

fn plan(state: &Value) -> Result<Vec<String>> {
    let marketplace = state.get("marketplace").filter(|value| !value.is_null());
    let plugin = state.get("plugin").filter(|value| !value.is_null());
    let marketplace_action = match marketplace {
        None => Some("add_marketplace"),
        Some(value) => {
            let source = marketplace_source(value);
            if !expected_source(&source) {
                bail!("Codex marketplace {MARKETPLACE} is owned by a conflicting source: {source}");
            }
            if marketplace_ref(value).as_deref() == Some(&format!("v{}", env!("CARGO_PKG_VERSION")))
            {
                None
            } else {
                Some("replace_marketplace")
            }
        }
    };
    let plugin_action = match plugin {
        None => Some("install_plugin"),
        Some(value) => {
            if value.get("marketplaceName").and_then(Value::as_str) != Some(MARKETPLACE) {
                bail!("Codex Loops plugin is installed from a conflicting marketplace");
            }
            if marketplace_action.is_some()
                || value.get("version").and_then(Value::as_str) != Some(env!("CARGO_PKG_VERSION"))
                || value.get("installed").and_then(Value::as_bool) != Some(true)
                || value.get("enabled").and_then(Value::as_bool) != Some(true)
            {
                Some("install_plugin")
            } else {
                None
            }
        }
    };
    Ok([marketplace_action, plugin_action]
        .into_iter()
        .flatten()
        .map(str::to_owned)
        .collect())
}

fn action_commands(action: &str) -> Vec<Vec<&'static str>> {
    match action {
        "add_marketplace" => vec![vec![
            "plugin",
            "marketplace",
            "add",
            MARKETPLACE_SOURCE,
            "--ref",
            release_ref(),
            "--json",
        ]],
        "replace_marketplace" => vec![
            vec!["plugin", "marketplace", "remove", MARKETPLACE, "--json"],
            vec![
                "plugin",
                "marketplace",
                "add",
                MARKETPLACE_SOURCE,
                "--ref",
                release_ref(),
                "--json",
            ],
        ],
        "install_plugin" => vec![vec!["plugin", "add", PLUGIN_ID, "--json"]],
        _ => vec![],
    }
}

fn release_ref() -> &'static str {
    concat!("v", env!("CARGO_PKG_VERSION"))
}

fn verify_launcher(state: &Value, runtime: &Value) -> Result<()> {
    let plugin = state
        .get("plugin")
        .context("installed plugin state is missing")?;
    let marketplace = state
        .get("marketplace")
        .context("marketplace state is missing")?;
    let launcher = plugin
        .pointer("/source/path")
        .and_then(Value::as_str)
        .map(|path| PathBuf::from(path).join("mcp/codex-loops-mcp"))
        .or_else(|| {
            marketplace
                .get("root")
                .and_then(Value::as_str)
                .map(|path| PathBuf::from(path).join("plugins/codex-loops/mcp/codex-loops-mcp"))
        })
        .context("installed plugin launcher path could not be resolved")?;
    let root = runtime
        .get("root")
        .and_then(Value::as_str)
        .context("runtime root is missing")?;
    let output = Command::new(&launcher)
        .arg("--version")
        .env("CODEX_LOOPS_RUNTIME_ROOT", root)
        .output()
        .with_context(|| format!("could not execute plugin launcher {}", launcher.display()))?;
    if !output.status.success()
        || String::from_utf8_lossy(&output.stdout).trim()
            != format!("codex-loops-mcp {}", env!("CARGO_PKG_VERSION"))
    {
        bail!("the installed Codex Loops plugin could not discover this runtime");
    }
    Ok(())
}

fn marketplace_source(value: &Value) -> String {
    value
        .pointer("/marketplaceSource/source")
        .or_else(|| value.get("source"))
        .and_then(Value::as_str)
        .unwrap_or("unknown")
        .to_owned()
}

fn marketplace_ref(value: &Value) -> Option<String> {
    value
        .pointer("/marketplaceSource/ref")
        .or_else(|| value.pointer("/marketplaceSource/refName"))
        .or_else(|| value.get("ref"))
        .and_then(Value::as_str)
        .map(str::to_owned)
}

fn expected_source(source: &str) -> bool {
    source
        .trim()
        .trim_start_matches("https://github.com/")
        .trim_start_matches("git@github.com:")
        .trim_end_matches(".git")
        == MARKETPLACE_SOURCE
}

fn marketplace_result(value: Option<&Value>) -> Value {
    match value.filter(|value| !value.is_null()) {
        Some(value) => {
            json!({"name": value.get("name"), "source": marketplace_source(value), "ref": marketplace_ref(value)})
        }
        None => Value::Null,
    }
}

fn plugin_result(value: Option<&Value>) -> Value {
    match value.filter(|value| !value.is_null()) {
        Some(value) => {
            json!({"id": value.get("pluginId"), "installed": value.get("installed") == Some(&Value::Bool(true)), "enabled": value.get("enabled") == Some(&Value::Bool(true)), "version": value.get("version")})
        }
        None => Value::Null,
    }
}

fn json_command(program: &Path, args: &[&str]) -> Result<Value> {
    let text = text_command(program, args)?;
    serde_json::from_str(&text)
        .with_context(|| format!("Codex command returned invalid JSON: {}", args.join(" ")))
}

fn command(program: &Path, args: &[&str]) -> Result<()> {
    text_command(program, args).map(|_| ())
}

fn text_command(program: &Path, args: &[&str]) -> Result<String> {
    let output = Command::new(program)
        .args(args)
        .output()
        .with_context(|| format!("could not execute {}", program.display()))?;
    if !output.status.success() {
        bail!(
            "Codex command failed: {} (exit {}): {}",
            args.join(" "),
            output.status,
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn marketplace(source: &str, release: &str) -> Value {
        json!({"name": MARKETPLACE, "marketplaceSource": {"source": source, "ref": release}})
    }

    fn plugin() -> Value {
        json!({"pluginId": PLUGIN_ID, "marketplaceName": MARKETPLACE, "version": env!("CARGO_PKG_VERSION"), "installed": true, "enabled": true})
    }

    #[test]
    fn desired_install_state_has_no_plan() {
        let state = json!({"marketplace": marketplace(MARKETPLACE_SOURCE, release_ref()), "plugin": plugin()});
        assert!(plan(&state).unwrap().is_empty());
    }

    #[test]
    fn missing_state_has_deterministic_plan() {
        let state = json!({"marketplace": null, "plugin": null});
        assert_eq!(plan(&state).unwrap(), ["add_marketplace", "install_plugin"]);
    }

    #[test]
    fn conflicting_marketplace_fails_closed() {
        let state =
            json!({"marketplace": marketplace("someone/else", release_ref()), "plugin": null});
        assert!(
            plan(&state)
                .unwrap_err()
                .to_string()
                .contains("conflicting source")
        );
    }

    #[test]
    fn partial_install_failures_report_the_mutation_and_exact_step() {
        let error = codex_command_error(anyhow::anyhow!("fixture failed"), true, "plugin_install");
        assert_eq!(error.status, 5);
        assert_eq!(error.code.as_ref(), "codex_command_failed");
        assert!(error.changed);
        assert_eq!(error.step.as_deref(), Some("plugin_install"));
        assert!(
            error.details["reason"]
                .as_str()
                .unwrap()
                .contains("fixture failed")
        );
    }
}
