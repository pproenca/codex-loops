use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};

use serde_json::{Value, json};

use crate::{
    error::{AppError, AppResult},
    runtime::{Bundle, CodexBinding, binding_path},
};

const MCP_NAME: &str = "codex-loops";
const SKILL_VERSION_FILE: &str = ".codex-loops-version";

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Install,
    Check,
    DryRun,
}

pub struct Options {
    pub mode: Mode,
    pub verbose: bool,
    pub codex: Option<PathBuf>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Action {
    BindCodex,
    InstallSkill,
    AddMcp,
    ReplaceMcp,
}

impl Action {
    fn name(self) -> &'static str {
        match self {
            Self::BindCodex => "bind_codex",
            Self::InstallSkill => "install_skill",
            Self::AddMcp => "add_mcp",
            Self::ReplaceMcp => "replace_mcp",
        }
    }
}

struct State {
    binding: Option<CodexBinding>,
    skill_version: Option<String>,
    mcp: Option<Value>,
}

pub fn run(options: Options) -> AppResult<Value> {
    let bundle = Bundle::installed()?;
    let integration_command = bundle.integration_command();
    let binding_path = binding_path()?;
    let codex = select_codex(options.codex.as_deref(), &binding_path)?;
    check_capabilities(&codex.path)?;
    let skill_destination = skill_destination()?;
    let initial = read_state(&codex.path, &binding_path, &skill_destination)?;
    let actions = plan(&initial, &codex, &integration_command);

    if options.mode == Mode::Check && !actions.is_empty() {
        return Err(
            AppError::new(1, "state_missing", "Codex Loops is not fully installed.")
                .details(json!({"plan": action_names(&actions)})),
        );
    }

    let mut changed = false;
    if options.mode == Mode::Install {
        for action in &actions {
            execute(
                *action,
                &bundle,
                &codex,
                &binding_path,
                &skill_destination,
                &integration_command,
                changed,
            )?;
            changed = true;
        }

        let final_state = read_state(&codex.path, &binding_path, &skill_destination)?;
        let remaining = plan(&final_state, &codex, &integration_command);
        if !remaining.is_empty() {
            return Err(AppError::new(
                6,
                "verification_failed",
                "Codex Loops installation could not be verified.",
            )
            .details(json!({"plan": action_names(&remaining)}))
            .changed(changed)
            .step("verification"));
        }
    }

    let commands = if options.verbose || options.mode == Mode::DryRun {
        action_commands(&actions, &codex, &integration_command)
    } else {
        Vec::new()
    };

    Ok(json!({
        "ok": true,
        "command": "install",
        "changed": changed,
        "mode": match options.mode {
            Mode::Install => "install",
            Mode::Check => "check",
            Mode::DryRun => "dry_run",
        },
        "runtime": {
            "root": bundle.root,
            "control_plane": bundle.control_plane,
            "scheduler": bundle.scheduler,
            "skill": bundle.skill,
        },
        "codex": {"path": codex.path, "version": codex.version},
        "skill": {"path": skill_destination, "version": env!("CARGO_PKG_VERSION")},
        "mcp": {"name": MCP_NAME, "command": integration_command, "args": ["mcp"]},
        "plugin": Value::Null,
        "plan": action_names(&actions),
        "commands": commands,
        "next_steps": ["Restart Codex, then ask: Use the codex-loops skill."],
    }))
}

fn select_codex(explicit: Option<&Path>, binding_path: &Path) -> AppResult<CodexBinding> {
    match explicit {
        Some(path) => CodexBinding::probe(path),
        None if binding_path.is_file() => CodexBinding::load(binding_path),
        None => Err(AppError::new(
            3,
            "codex_binding_required",
            "The first installation requires an explicit Codex CLI binding.",
        )
        .next_steps([
            "Run `codex-loops install --codex /absolute/path/to/codex` with the exact command you want this runtime to use.",
        ])),
    }
}

fn check_capabilities(codex: &Path) -> AppResult<()> {
    let list_help = text_command(codex, &["mcp", "list", "--help"], "codex_preflight")?;
    let add_help = text_command(codex, &["mcp", "add", "--help"], "codex_preflight")?;
    if !list_help.contains("--json") || !add_help.contains("--") {
        return Err(AppError::new(
            3,
            "codex_incompatible",
            "The selected Codex CLI does not support direct MCP registration.",
        )
        .next_steps([
            "Select a newer CLI with `codex-loops install --codex /absolute/path/to/codex`.",
        ]));
    }
    Ok(())
}

fn read_state(codex: &Path, binding_path: &Path, skill_destination: &Path) -> AppResult<State> {
    Ok(State {
        binding: read_stored_binding(binding_path),
        skill_version: fs::read_to_string(skill_destination.join(SKILL_VERSION_FILE))
            .ok()
            .map(|value| value.trim().to_owned()),
        mcp: read_mcp(codex)?,
    })
}

fn read_stored_binding(path: &Path) -> Option<CodexBinding> {
    fs::read(path)
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
}

fn read_mcp(codex: &Path) -> AppResult<Option<Value>> {
    let output = Command::new(codex)
        .args(["mcp", "list", "--json"])
        .output()
        .map_err(|error| codex_command_error(error.to_string(), false, "mcp_read"))?;
    if !output.status.success() {
        return Err(codex_command_error(
            String::from_utf8_lossy(&output.stderr).trim().to_owned(),
            false,
            "mcp_read",
        ));
    }
    let servers: Vec<Value> = serde_json::from_slice(&output.stdout).map_err(|error| {
        codex_command_error(
            format!("Codex returned invalid MCP JSON: {error}"),
            false,
            "mcp_read",
        )
    })?;
    Ok(servers
        .into_iter()
        .find(|server| server.get("name").and_then(Value::as_str) == Some(MCP_NAME)))
}

fn plan(state: &State, codex: &CodexBinding, integration_command: &Path) -> Vec<Action> {
    let mut actions = Vec::new();
    if state.binding.as_ref() != Some(codex) {
        actions.push(Action::BindCodex);
    }
    if state.skill_version.as_deref() != Some(env!("CARGO_PKG_VERSION")) {
        actions.push(Action::InstallSkill);
    }
    match state.mcp.as_ref() {
        None => actions.push(Action::AddMcp),
        Some(mcp) if !mcp_matches(mcp, integration_command) => actions.push(Action::ReplaceMcp),
        Some(_mcp) => {}
    }
    actions
}

fn mcp_matches(value: &Value, control_plane: &Path) -> bool {
    value.pointer("/transport/type").and_then(Value::as_str) == Some("stdio")
        && value.pointer("/transport/command").and_then(Value::as_str) == control_plane.to_str()
        && value.pointer("/transport/args") == Some(&json!(["mcp"]))
}

fn execute(
    action: Action,
    bundle: &Bundle,
    codex: &CodexBinding,
    binding_path: &Path,
    skill_destination: &Path,
    integration_command: &Path,
    changed: bool,
) -> AppResult<()> {
    match action {
        Action::BindCodex => codex.persist(binding_path),
        Action::InstallSkill => install_skill(&bundle.skill, skill_destination),
        Action::AddMcp => add_mcp(&codex.path, integration_command, changed),
        Action::ReplaceMcp => {
            run_command(
                &codex.path,
                &["mcp", "remove", MCP_NAME],
                changed,
                "mcp_remove",
            )?;
            add_mcp(&codex.path, integration_command, true)
        }
    }
}

fn add_mcp(codex: &Path, control_plane: &Path, changed: bool) -> AppResult<()> {
    let command = control_plane.to_str().ok_or_else(|| {
        AppError::new(
            6,
            "runtime_invalid",
            "The control-plane path is not valid UTF-8.",
        )
    })?;
    run_command(
        codex,
        &["mcp", "add", MCP_NAME, "--", command, "mcp"],
        changed,
        "mcp_add",
    )
}

fn install_skill(source: &Path, destination: &Path) -> AppResult<()> {
    let parent = destination.parent().ok_or_else(|| {
        AppError::new(
            6,
            "skill_install_failed",
            "The user skill path has no parent.",
        )
    })?;
    fs::create_dir_all(parent).map_err(skill_error)?;
    let temp = parent.join(format!(".codex-loops-{}.tmp", std::process::id()));
    let backup = parent.join(format!(".codex-loops-{}.old", std::process::id()));
    let _ = fs::remove_dir_all(&temp);
    let _ = fs::remove_dir_all(&backup);
    copy_dir(source, &temp)?;
    fs::write(temp.join(SKILL_VERSION_FILE), env!("CARGO_PKG_VERSION")).map_err(skill_error)?;
    if destination.exists() {
        fs::rename(destination, &backup).map_err(skill_error)?;
    }
    if let Err(error) = fs::rename(&temp, destination) {
        if backup.exists() {
            let _ = fs::rename(&backup, destination);
        }
        return Err(skill_error(error));
    }
    let _ = fs::remove_dir_all(backup);
    Ok(())
}

fn copy_dir(source: &Path, destination: &Path) -> AppResult<()> {
    fs::create_dir_all(destination).map_err(skill_error)?;
    for entry in fs::read_dir(source).map_err(skill_error)? {
        let entry = entry.map_err(skill_error)?;
        let target = destination.join(entry.file_name());
        if entry.file_type().map_err(skill_error)?.is_dir() {
            copy_dir(&entry.path(), &target)?;
        } else {
            fs::copy(entry.path(), target).map_err(skill_error)?;
        }
    }
    Ok(())
}

fn skill_destination() -> AppResult<PathBuf> {
    let home = std::env::var_os("HOME").ok_or_else(|| {
        AppError::new(
            6,
            "skill_install_failed",
            "HOME is not set; the user skill cannot be installed.",
        )
    })?;
    Ok(PathBuf::from(home).join(".agents/skills/codex-loops"))
}

fn skill_error(error: std::io::Error) -> AppError {
    AppError::new(
        6,
        "skill_install_failed",
        "Codex Loops could not install its user skill.",
    )
    .details(json!({"reason": error.to_string()}))
}

fn run_command(program: &Path, args: &[&str], changed: bool, step: &'static str) -> AppResult<()> {
    let output = Command::new(program)
        .args(args)
        .output()
        .map_err(|error| codex_command_error(error.to_string(), changed, step))?;
    if output.status.success() {
        Ok(())
    } else {
        Err(codex_command_error(
            format!(
                "{} exited {}: {}",
                args.join(" "),
                output.status,
                String::from_utf8_lossy(&output.stderr).trim()
            ),
            changed,
            step,
        ))
    }
}

fn text_command(program: &Path, args: &[&str], step: &'static str) -> AppResult<String> {
    let output = Command::new(program)
        .args(args)
        .output()
        .map_err(|error| codex_command_error(error.to_string(), false, step))?;
    if output.status.success() {
        Ok(String::from_utf8_lossy(&output.stdout).into_owned())
    } else {
        Err(codex_command_error(
            format!(
                "{} exited {}: {}",
                args.join(" "),
                output.status,
                String::from_utf8_lossy(&output.stderr).trim()
            ),
            false,
            step,
        ))
    }
}

fn codex_command_error(reason: String, changed: bool, step: &'static str) -> AppError {
    AppError::new(
        5,
        "codex_command_failed",
        "Codex command failed unexpectedly.",
    )
    .details(json!({"reason": reason}))
    .changed(changed)
    .step(step)
}

fn action_names(actions: &[Action]) -> Vec<&'static str> {
    actions.iter().map(|action| action.name()).collect()
}

fn action_commands(
    actions: &[Action],
    codex: &CodexBinding,
    integration_command: &Path,
) -> Vec<String> {
    actions
        .iter()
        .map(|action| match action {
            Action::BindCodex => format!("bind Codex {}", codex.path.display()),
            Action::InstallSkill => "install user skill ~/.agents/skills/codex-loops".into(),
            Action::AddMcp => format!(
                "codex mcp add {MCP_NAME} -- {} mcp",
                integration_command.display()
            ),
            Action::ReplaceMcp => format!(
                "codex mcp remove {MCP_NAME} && codex mcp add {MCP_NAME} -- {} mcp",
                integration_command.display()
            ),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bundle() -> Bundle {
        Bundle {
            root: "/runtime".into(),
            control_plane: "/runtime/bin/codex-loops".into(),
            scheduler: "/runtime/libexec/scheduler/bin/agent_loops".into(),
            skill: "/runtime/share/skills/codex-loops".into(),
        }
    }

    fn binding() -> CodexBinding {
        CodexBinding {
            path: "/usr/local/bin/codex".into(),
            version: "codex-cli 9.9.9".into(),
        }
    }

    #[test]
    fn missing_install_state_has_one_deterministic_plan() {
        let state = State {
            binding: None,
            skill_version: None,
            mcp: None,
        };
        assert_eq!(
            plan(&state, &binding(), Path::new("/runtime/bin/codex-loops")),
            [Action::BindCodex, Action::InstallSkill, Action::AddMcp]
        );
    }

    #[test]
    fn matching_direct_state_is_idempotent() {
        let runtime = bundle();
        let codex = binding();
        let state = State {
            binding: Some(codex.clone()),
            skill_version: Some(env!("CARGO_PKG_VERSION").into()),
            mcp: Some(json!({
                "transport": {
                    "type": "stdio",
                    "command": runtime.control_plane,
                    "args": ["mcp"]
                }
            })),
        };
        assert!(plan(&state, &codex, Path::new("/runtime/bin/codex-loops")).is_empty());
    }
}
