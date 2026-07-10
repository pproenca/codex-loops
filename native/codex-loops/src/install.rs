use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::{
    error::{ChangeState, ErrorContext, InstallError, InstallResult},
    runtime::{Bundle, CodexBinding, binding_path},
};

type AppError = InstallError;
type AppResult<T> = InstallResult<T>;

const MCP_NAME: &str = "codex-loops";
const SKILL_VERSION_FILE: &str = ".codex-loops-version";

mod skill;

use skill::{install_skill, skill_destination, skill_matches};

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Install,
    Check,
    DryRun,
}

impl std::fmt::Display for Mode {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(match self {
            Self::Install => "install",
            Self::Check => "check",
            Self::DryRun => "dry_run",
        })
    }
}

pub struct Options {
    pub mode: Mode,
    pub verbose: bool,
    pub codex: Option<PathBuf>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum Action {
    BindCodex,
    InstallSkill,
    AddMcp,
    ReplaceMcp { previous: McpRegistration },
}

impl Action {
    fn name(&self) -> &'static str {
        match self {
            Self::BindCodex => "bind_codex",
            Self::InstallSkill => "install_skill",
            Self::AddMcp => "add_mcp",
            Self::ReplaceMcp { .. } => "replace_mcp",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct McpRegistration {
    command: String,
    args: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct ListedMcp {
    name: String,
    transport: McpTransport,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct McpTransport {
    #[serde(rename = "type")]
    kind: String,
    command: Option<String>,
    #[serde(default)]
    args: Vec<String>,
}

struct State {
    binding: Option<CodexBinding>,
    skill_current: bool,
    mcp: Option<ListedMcp>,
}

struct ExecutionContext<'a> {
    bundle: &'a Bundle,
    codex: &'a CodexBinding,
    binding_path: &'a Path,
    skill_destination: &'a Path,
    integration_command: &'a Path,
}

struct RegistrationRequest<'a> {
    codex: &'a Path,
    registration: &'a McpRegistration,
    changed: ChangeState,
    step: &'static str,
}

struct CommandRequest<'a> {
    program: &'a Path,
    args: &'a [&'a str],
    changed: ChangeState,
    step: &'static str,
}

struct McpReplacement<'a> {
    codex: &'a Path,
    integration_command: &'a Path,
    previous: &'a McpRegistration,
    changed: ChangeState,
}

pub fn run(options: Options) -> AppResult<Value> {
    let bundle = Bundle::installed()?;
    let integration_command = bundle.integration_command();
    let binding_path = binding_path()?;
    let codex = select_codex(options.codex.as_deref(), &binding_path)?;
    check_capabilities(&codex.path)?;
    let skill_destination = skill_destination()?;
    let initial = read_state(
        &codex.path,
        &binding_path,
        &bundle.skill,
        &skill_destination,
    )?;
    let actions = plan(&initial, &codex, &integration_command)?;

    if options.mode == Mode::Check && !actions.is_empty() {
        return Err(
            AppError::new(1, "state_missing", "Codex Loops is not fully installed.")
                .details(json!({"plan": action_names(&actions)})),
        );
    }

    let mut changed = ChangeState::Unchanged;
    if options.mode == Mode::Install {
        let context = ExecutionContext {
            bundle: &bundle,
            codex: &codex,
            binding_path: &binding_path,
            skill_destination: &skill_destination,
            integration_command: &integration_command,
        };
        for action in &actions {
            execute(action, &context, changed)?;
            changed = changed.after_success();
        }

        let final_state = read_state(
            &codex.path,
            &binding_path,
            &bundle.skill,
            &skill_destination,
        )?;
        let remaining = plan(&final_state, &codex, &integration_command)?;
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
        "changed": changed.as_bool(),
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
        Some(path) => Ok(CodexBinding::probe(path)?),
        None if binding_path.is_file() => Ok(CodexBinding::load(binding_path)?),
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

fn read_state(
    codex: &Path,
    binding_path: &Path,
    skill_source: &Path,
    skill_destination: &Path,
) -> AppResult<State> {
    Ok(State {
        binding: read_stored_binding(binding_path),
        skill_current: skill_matches(skill_source, skill_destination),
        mcp: read_mcp(codex)?,
    })
}

fn read_stored_binding(path: &Path) -> Option<CodexBinding> {
    fs::read(path)
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
}

fn read_mcp(codex: &Path) -> AppResult<Option<ListedMcp>> {
    let output = Command::new(codex)
        .args(["mcp", "list", "--json"])
        .output()
        .map_err(|error| {
            codex_command_error(error.to_string(), ChangeState::Unchanged, "mcp_read")
        })?;
    if !output.status.success() {
        return Err(codex_command_error(
            String::from_utf8_lossy(&output.stderr).trim().to_owned(),
            ChangeState::Unchanged,
            "mcp_read",
        ));
    }
    let servers: Vec<ListedMcp> = serde_json::from_slice(&output.stdout).map_err(|error| {
        codex_command_error(
            format!("Codex returned invalid MCP JSON: {error}"),
            ChangeState::Unchanged,
            "mcp_read",
        )
    })?;
    Ok(servers.into_iter().find(|server| server.name == MCP_NAME))
}

fn plan(state: &State, codex: &CodexBinding, integration_command: &Path) -> AppResult<Vec<Action>> {
    let mut actions = Vec::new();
    if state.binding.as_ref() != Some(codex) {
        actions.push(Action::BindCodex);
    }
    if !state.skill_current {
        actions.push(Action::InstallSkill);
    }
    match state.mcp.as_ref() {
        None => actions.push(Action::AddMcp),
        Some(mcp) if !mcp_matches(mcp, integration_command) => {
            actions.push(Action::ReplaceMcp {
                previous: restorable_mcp(mcp)?,
            });
        }
        Some(_mcp) => {}
    }
    Ok(actions)
}

fn mcp_matches(value: &ListedMcp, control_plane: &Path) -> bool {
    value.transport.kind == "stdio"
        && value.transport.command.as_deref() == control_plane.to_str()
        && value.transport.args == ["mcp"]
}

fn execute(action: &Action, context: &ExecutionContext<'_>, changed: ChangeState) -> AppResult<()> {
    match action {
        Action::BindCodex => Ok(context.codex.persist(context.binding_path)?),
        Action::InstallSkill => install_skill(&context.bundle.skill, context.skill_destination),
        Action::AddMcp => add_mcp(&context.codex.path, context.integration_command, changed),
        Action::ReplaceMcp { previous } => replace_mcp(McpReplacement {
            codex: &context.codex.path,
            integration_command: context.integration_command,
            previous,
            changed,
        }),
    }
}

fn restorable_mcp(value: &ListedMcp) -> AppResult<McpRegistration> {
    let command = value
        .transport
        .command
        .as_deref()
        .filter(|command| !command.is_empty())
        .ok_or_else(|| {
            AppError::new(
                5,
                "mcp_registration_not_restorable",
                "The existing Codex Loops MCP registration cannot be replaced safely.",
            )
            .details(json!({"registration": value}))
        })?;
    Ok(McpRegistration {
        command: command.to_owned(),
        args: value.transport.args.clone(),
    })
}

fn replace_mcp(replacement: McpReplacement<'_>) -> AppResult<()> {
    run_command(CommandRequest {
        program: replacement.codex,
        args: &["mcp", "remove", MCP_NAME],
        changed: replacement.changed,
        step: "mcp_remove",
    })?;
    if let Err(add_error) = add_mcp(
        replacement.codex,
        replacement.integration_command,
        ChangeState::Changed,
    ) {
        return match add_registration(RegistrationRequest {
            codex: replacement.codex,
            registration: replacement.previous,
            changed: ChangeState::Changed,
            step: "mcp_restore",
        }) {
            Ok(()) => Err(add_error.changed(replacement.changed)),
            Err(restore_error) => Err(AppError::new(
                5,
                "mcp_rollback_failed",
                "Codex Loops could not restore the previous MCP registration.",
            )
            .details(json!({
                "replacement_error": add_error.diagnostic(),
                "restore_error": restore_error.diagnostic()
            }))
            .changed(ChangeState::Changed)
            .step("mcp_restore")),
        };
    }
    Ok(())
}

fn add_mcp(codex: &Path, control_plane: &Path, changed: ChangeState) -> AppResult<()> {
    let command = control_plane.to_str().ok_or_else(|| {
        AppError::new(
            6,
            "runtime_invalid",
            "The control-plane path is not valid UTF-8.",
        )
    })?;
    let registration = McpRegistration {
        command: command.to_owned(),
        args: vec!["mcp".into()],
    };
    add_registration(RegistrationRequest {
        codex,
        registration: &registration,
        changed,
        step: "mcp_add",
    })
}

fn add_registration(request: RegistrationRequest<'_>) -> AppResult<()> {
    let output = Command::new(request.codex)
        .args(["mcp", "add", MCP_NAME, "--", &request.registration.command])
        .args(&request.registration.args)
        .output()
        .map_err(|error| codex_command_error(error.to_string(), request.changed, request.step))?;
    if output.status.success() {
        Ok(())
    } else {
        Err(codex_command_error(
            format!(
                "mcp add exited {}: {}",
                output.status,
                String::from_utf8_lossy(&output.stderr).trim()
            ),
            request.changed,
            request.step,
        ))
    }
}

fn run_command(request: CommandRequest<'_>) -> AppResult<()> {
    let output = Command::new(request.program)
        .args(request.args)
        .output()
        .map_err(|error| codex_command_error(error.to_string(), request.changed, request.step))?;
    if output.status.success() {
        Ok(())
    } else {
        Err(codex_command_error(
            format!(
                "{} exited {}: {}",
                request.args.join(" "),
                output.status,
                String::from_utf8_lossy(&output.stderr).trim()
            ),
            request.changed,
            request.step,
        ))
    }
}

fn text_command(program: &Path, args: &[&str], step: &'static str) -> AppResult<String> {
    let output = Command::new(program)
        .args(args)
        .output()
        .map_err(|error| codex_command_error(error.to_string(), ChangeState::Unchanged, step))?;
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
            ChangeState::Unchanged,
            step,
        ))
    }
}

fn codex_command_error(reason: String, changed: ChangeState, step: &'static str) -> AppError {
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
            Action::ReplaceMcp { .. } => format!(
                "codex mcp remove {MCP_NAME} && codex mcp add {MCP_NAME} -- {} mcp",
                integration_command.display()
            ),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    fn fake_codex(body: &str) -> tempfile::TempDir {
        use std::os::unix::fs::PermissionsExt;

        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("codex");
        fs::write(&path, format!("#!/bin/sh\nset -eu\n{body}\n")).unwrap();
        let mut permissions = fs::metadata(&path).unwrap().permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(path, permissions).unwrap();
        root
    }

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
            skill_current: false,
            mcp: None,
        };
        assert_eq!(
            plan(&state, &binding(), Path::new("/runtime/bin/codex-loops")).unwrap(),
            [Action::BindCodex, Action::InstallSkill, Action::AddMcp]
        );
    }

    #[test]
    fn matching_direct_state_is_idempotent() {
        let runtime = bundle();
        let codex = binding();
        let state = State {
            binding: Some(codex.clone()),
            skill_current: true,
            mcp: Some(ListedMcp {
                name: MCP_NAME.into(),
                transport: McpTransport {
                    kind: "stdio".into(),
                    command: Some(runtime.control_plane.to_string_lossy().into_owned()),
                    args: vec!["mcp".into()],
                },
            }),
        };
        assert!(
            plan(&state, &codex, Path::new("/runtime/bin/codex-loops"))
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn skill_integrity_requires_the_packaged_content_not_only_the_version_marker() {
        let source = tempfile::tempdir().unwrap();
        let destination = tempfile::tempdir().unwrap();
        fs::write(source.path().join("SKILL.md"), "expected").unwrap();
        fs::write(
            destination.path().join(SKILL_VERSION_FILE),
            env!("CARGO_PKG_VERSION"),
        )
        .unwrap();

        assert!(!skill_matches(source.path(), destination.path()));

        fs::write(destination.path().join("SKILL.md"), "expected").unwrap();
        assert!(skill_matches(source.path(), destination.path()));
    }

    #[cfg(unix)]
    #[test]
    fn new_mcp_add_failure_preserves_unchanged_state() {
        let root = fake_codex("echo failed >&2; exit 7");
        let error = add_mcp(
            &root.path().join("codex"),
            Path::new("/new/codex-loops"),
            ChangeState::Unchanged,
        )
        .unwrap_err();

        assert_eq!(error.code(), "codex_command_failed");
        assert_eq!(error.diagnostic()["changed"], false);
    }

    #[cfg(unix)]
    #[test]
    fn mcp_replacement_reports_failed_rollback() {
        let root = fake_codex(
            r#"case "$1 $2" in
  "mcp remove") exit 0 ;;
  "mcp add") echo failed >&2; exit 7 ;;
esac"#,
        );
        let previous = McpRegistration {
            command: "/old/codex-loops".into(),
            args: vec!["mcp".into()],
        };
        let error = replace_mcp(McpReplacement {
            codex: &root.path().join("codex"),
            integration_command: Path::new("/new/codex-loops"),
            previous: &previous,
            changed: ChangeState::Unchanged,
        })
        .unwrap_err();

        assert_eq!(error.code(), "mcp_rollback_failed");
        assert_eq!(error.diagnostic()["changed"], true);
    }

    #[cfg(unix)]
    #[test]
    fn mcp_replacement_succeeds_when_new_registration_is_added() {
        let root = fake_codex("exit 0");
        let previous = McpRegistration {
            command: "/old/codex-loops".into(),
            args: vec!["mcp".into()],
        };

        replace_mcp(McpReplacement {
            codex: &root.path().join("codex"),
            integration_command: Path::new("/new/codex-loops"),
            previous: &previous,
            changed: ChangeState::Unchanged,
        })
        .unwrap();
    }
}
