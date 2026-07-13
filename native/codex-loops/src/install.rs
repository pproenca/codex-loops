use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    process::Command,
};

use serde::{Deserialize, Serialize, Serializer};
use serde_json::json;

use crate::{
    error::{AppError, AppResult, ChangeState, ExitStatus},
    runtime::{Bundle, CodexBinding, binding_path},
};

const MCP_NAME: &str = "codex-loops";
const SKILL_VERSION_FILE: &str = ".codex-loops-version";

mod skill;

use skill::{install_skill, skill_destination, skill_matches};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
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

#[derive(Debug, Serialize)]
pub struct InstallOutput {
    #[serde(serialize_with = "serialize_change_state")]
    pub changed: ChangeState,
    pub mode: Mode,
    pub runtime: InstallRuntime,
    pub codex: InstallCodex,
    pub skill: InstallSkill,
    pub mcp: InstallMcp,
    pub plugin: (),
    pub plan: Vec<&'static str>,
    pub commands: Vec<String>,
    pub next_steps: [&'static str; 1],
}

#[derive(Debug, Serialize)]
pub struct InstallRuntime {
    pub root: PathBuf,
    pub control_plane: PathBuf,
    pub scheduler: PathBuf,
    pub skill: PathBuf,
}

#[derive(Debug, Serialize)]
pub struct InstallCodex {
    pub path: PathBuf,
    pub version: String,
}

#[derive(Debug, Serialize)]
pub struct InstallSkill {
    pub path: PathBuf,
    pub version: &'static str,
}

#[derive(Debug, Serialize)]
pub struct InstallMcp {
    pub name: &'static str,
    pub command: PathBuf,
    pub args: [&'static str; 1],
}

fn serialize_change_state<S>(state: &ChangeState, serializer: S) -> Result<S::Ok, S::Error>
where
    S: Serializer,
{
    serializer.serialize_bool(state.is_changed())
}

#[derive(Debug, PartialEq, Eq)]
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

#[derive(Debug, PartialEq, Eq)]
struct McpRegistration {
    command: String,
    args: Vec<String>,
}

#[derive(Debug, Deserialize, Serialize)]
struct ListedMcp {
    name: String,
    #[serde(default = "enabled_by_default")]
    enabled: bool,
    #[serde(default)]
    startup_timeout_sec: Option<f64>,
    #[serde(default)]
    tool_timeout_sec: Option<f64>,
    transport: ListedMcpTransport,
}

#[derive(Debug, Deserialize, Serialize)]
struct ListedMcpTransport {
    #[serde(rename = "type")]
    kind: String,
    command: Option<String>,
    #[serde(default)]
    args: Vec<String>,
    #[serde(default, skip_serializing)]
    env: Option<BTreeMap<String, String>>,
    #[serde(default)]
    env_vars: Vec<String>,
    #[serde(default)]
    cwd: Option<String>,
}

fn enabled_by_default() -> bool {
    true
}

#[derive(Debug, PartialEq, Eq)]
enum McpInstallation {
    Missing,
    Current,
    Replace(McpRegistration),
}

enum SkillInstallation {
    Missing,
    Current,
}

struct State {
    binding: Option<CodexBinding>,
    skill: SkillInstallation,
    mcp: McpInstallation,
}

struct ExecutionContext<'a> {
    skill_source: &'a Path,
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

pub fn run(options: Options) -> AppResult<InstallOutput> {
    let bundle = Bundle::installed()?;
    let integration_command = bundle.integration_command();
    let skill_source = bundle.skill();
    let binding_path = binding_path()?;
    let codex = select_codex(options.codex.as_deref(), &binding_path)?;
    check_capabilities(codex.path())?;
    let skill_destination = skill_destination()?;
    let context = ExecutionContext {
        skill_source: &skill_source,
        codex: &codex,
        binding_path: &binding_path,
        skill_destination: &skill_destination,
        integration_command: &integration_command,
    };
    let initial = read_state(&context)?;
    let actions = plan(initial, &codex);

    if options.mode == Mode::Check && !actions.is_empty() {
        return Err(AppError::new(
            ExitStatus::Unsatisfied,
            "state_missing",
            "Codex Loops is not fully installed.",
        )
        .details(json!({"plan": action_names(&actions)})));
    }

    let mut changed = ChangeState::Unchanged;
    if options.mode == Mode::Install {
        for action in &actions {
            execute(action, &context, changed)?;
            changed = ChangeState::Changed;
        }

        let final_state = read_state(&context).map_err(|error| error.changed(changed))?;
        let remaining = plan(final_state, &codex);
        if !remaining.is_empty() {
            return Err(AppError::new(
                ExitStatus::Runtime,
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

    Ok(InstallOutput {
        changed,
        mode: options.mode,
        runtime: InstallRuntime {
            root: bundle.root().to_path_buf(),
            control_plane: bundle.control_plane(),
            scheduler: bundle.scheduler(),
            skill: skill_source,
        },
        codex: InstallCodex {
            path: codex.path().to_path_buf(),
            version: codex.version().to_owned(),
        },
        skill: InstallSkill {
            path: skill_destination,
            version: env!("CARGO_PKG_VERSION"),
        },
        mcp: InstallMcp {
            name: MCP_NAME,
            command: integration_command,
            args: ["mcp"],
        },
        plugin: (),
        plan: action_names(&actions),
        commands,
        next_steps: ["Restart Codex, then ask: Use the codex-loops skill."],
    })
}

fn select_codex(explicit: Option<&Path>, binding_path: &Path) -> AppResult<CodexBinding> {
    match explicit {
        Some(path) => CodexBinding::probe(path),
        None if read_stored_binding(binding_path)?.is_some() => CodexBinding::load(binding_path),
        None => Err(AppError::new(
            ExitStatus::Prerequisite,
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
    if !list_help.contains("--json") {
        return Err(AppError::new(
            ExitStatus::Prerequisite,
            "codex_incompatible",
            "The selected Codex CLI does not support direct MCP registration.",
        )
        .next_steps([
            "Select a newer CLI with `codex-loops install --codex /absolute/path/to/codex`.",
        ]));
    }
    Ok(())
}

fn read_state(context: &ExecutionContext<'_>) -> AppResult<State> {
    let binding = read_stored_binding(context.binding_path)?;
    let skill = match skill_matches(context.skill_source, context.skill_destination)? {
        true => SkillInstallation::Current,
        false => SkillInstallation::Missing,
    };
    let mcp = read_mcp(context.codex.path(), context.integration_command)?;
    Ok(State {
        binding,
        skill,
        mcp,
    })
}

fn read_stored_binding(path: &Path) -> AppResult<Option<CodexBinding>> {
    CodexBinding::read_optional(path)
}

fn read_mcp(codex: &Path, integration_command: &Path) -> AppResult<McpInstallation> {
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
    resolve_mcp(
        servers.into_iter().find(|server| server.name == MCP_NAME),
        integration_command,
    )
}

fn resolve_mcp(
    listed: Option<ListedMcp>,
    integration_command: &Path,
) -> AppResult<McpInstallation> {
    let integration_command = command_text(integration_command, ChangeState::Unchanged)?;
    let Some(listed) = listed else {
        return Ok(McpInstallation::Missing);
    };
    let restorable_transport = listed.transport.kind == "stdio"
        && listed.transport.env.as_ref().is_none_or(BTreeMap::is_empty)
        && listed.transport.env_vars.is_empty()
        && listed.transport.cwd.is_none();
    let restorable_settings =
        listed.enabled && listed.startup_timeout_sec.is_none() && listed.tool_timeout_sec.is_none();
    if restorable_transport
        && restorable_settings
        && listed.transport.command.as_deref() == Some(integration_command)
        && listed.transport.args == ["mcp"]
    {
        return Ok(McpInstallation::Current);
    }
    if !restorable_transport || !restorable_settings {
        return Err(mcp_not_restorable(listed));
    }

    match listed {
        ListedMcp {
            transport:
                ListedMcpTransport {
                    command: Some(command),
                    args,
                    ..
                },
            ..
        } if !command.is_empty() => Ok(McpInstallation::Replace(McpRegistration { command, args })),
        registration => Err(mcp_not_restorable(registration)),
    }
}

fn mcp_not_restorable(registration: ListedMcp) -> AppError {
    AppError::new(
        ExitStatus::Command,
        "mcp_registration_not_restorable",
        "The existing Codex Loops MCP registration cannot be replaced safely.",
    )
    .details(json!({"registration": registration}))
}

fn plan(state: State, codex: &CodexBinding) -> Vec<Action> {
    let mut actions = Vec::new();
    if state.binding.as_ref() != Some(codex) {
        actions.push(Action::BindCodex);
    }
    match state.skill {
        SkillInstallation::Missing => actions.push(Action::InstallSkill),
        SkillInstallation::Current => {}
    }
    match state.mcp {
        McpInstallation::Missing => actions.push(Action::AddMcp),
        McpInstallation::Current => {}
        McpInstallation::Replace(previous) => actions.push(Action::ReplaceMcp { previous }),
    }
    actions
}

fn execute(action: &Action, context: &ExecutionContext<'_>, changed: ChangeState) -> AppResult<()> {
    match action {
        Action::BindCodex => context.codex.persist(context.binding_path),
        Action::InstallSkill => install_skill(context.skill_source, context.skill_destination)
            .map_err(|error| match changed {
                ChangeState::Unchanged => error,
                ChangeState::Changed => error.changed(ChangeState::Changed),
            }),
        Action::AddMcp => add_mcp(context.codex.path(), context.integration_command, changed),
        Action::ReplaceMcp { previous } => replace_mcp(McpReplacement {
            codex: context.codex.path(),
            integration_command: context.integration_command,
            previous,
            changed,
        }),
    }
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
                ExitStatus::Command,
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
    let command = command_text(control_plane, changed)?;
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

fn command_text(path: &Path, changed: ChangeState) -> AppResult<&str> {
    path.to_str().ok_or_else(|| {
        AppError::new(
            ExitStatus::Runtime,
            "runtime_invalid",
            "The control-plane path is not valid UTF-8.",
        )
        .changed(changed)
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
        ExitStatus::Command,
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
            Action::BindCodex => format!("bind Codex {}", codex.path().display()),
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
    use std::fs;

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

    fn listed_stdio(command: Option<&str>) -> ListedMcp {
        ListedMcp {
            name: MCP_NAME.into(),
            enabled: true,
            startup_timeout_sec: None,
            tool_timeout_sec: None,
            transport: ListedMcpTransport {
                kind: "stdio".into(),
                command: command.map(str::to_owned),
                args: vec!["mcp".into()],
                env: None,
                env_vars: Vec::new(),
                cwd: None,
            },
        }
    }

    #[test]
    fn install_output_serializes_only_the_typed_command_payload() {
        let output = InstallOutput {
            changed: ChangeState::Changed,
            mode: Mode::DryRun,
            runtime: InstallRuntime {
                root: "/runtime".into(),
                control_plane: "/runtime/bin/codex-loops".into(),
                scheduler: "/runtime/libexec/scheduler/bin/agent_loops".into(),
                skill: "/runtime/share/skills/codex-loops".into(),
            },
            codex: InstallCodex {
                path: "/usr/local/bin/codex".into(),
                version: "codex-cli 9.9.9".into(),
            },
            skill: InstallSkill {
                path: "/home/user/.agents/skills/codex-loops".into(),
                version: env!("CARGO_PKG_VERSION"),
            },
            mcp: InstallMcp {
                name: MCP_NAME,
                command: "/runtime/bin/codex-loops".into(),
                args: ["mcp"],
            },
            plugin: (),
            plan: vec!["bind_codex"],
            commands: vec!["bind Codex /usr/local/bin/codex".into()],
            next_steps: ["Restart Codex, then ask: Use the codex-loops skill."],
        };

        let value = serde_json::to_value(output).unwrap();

        assert_eq!(value["changed"], true);
        assert_eq!(value["mode"], "dry_run");
        assert!(value["plugin"].is_null());
        assert!(value.get("ok").is_none());
        assert!(value.get("command").is_none());
    }

    #[cfg(unix)]
    #[test]
    fn missing_install_state_has_one_deterministic_plan() {
        let root = fake_codex("echo 'codex-cli 9.9.9'");
        let codex = CodexBinding::probe(&root.path().join("codex")).unwrap();
        let state = State {
            binding: None,
            skill: SkillInstallation::Missing,
            mcp: McpInstallation::Missing,
        };
        assert_eq!(
            plan(state, &codex),
            [Action::BindCodex, Action::InstallSkill, Action::AddMcp]
        );
    }

    #[cfg(unix)]
    #[test]
    fn matching_direct_state_is_idempotent() {
        let root = fake_codex("echo 'codex-cli 9.9.9'");
        let codex_path = root.path().join("codex");
        let codex = CodexBinding::probe(&codex_path).unwrap();
        let state = State {
            binding: Some(CodexBinding::probe(&codex_path).unwrap()),
            skill: SkillInstallation::Current,
            mcp: McpInstallation::Current,
        };
        assert!(plan(state, &codex).is_empty());
    }

    #[test]
    fn listed_mcp_resolves_into_typed_installation_state() {
        let integration_command = Path::new("/runtime/bin/codex-loops");
        let current = resolve_mcp(
            Some(listed_stdio(integration_command.to_str())),
            integration_command,
        )
        .unwrap();
        assert_eq!(current, McpInstallation::Current);

        let replacement = resolve_mcp(
            Some(listed_stdio(Some("/old/codex-loops"))),
            integration_command,
        )
        .unwrap();
        assert_eq!(
            replacement,
            McpInstallation::Replace(McpRegistration {
                command: "/old/codex-loops".into(),
                args: vec!["mcp".into()],
            })
        );

        let malformed = resolve_mcp(Some(listed_stdio(None)), integration_command).unwrap_err();
        assert_eq!(malformed.code(), "mcp_registration_not_restorable");
    }

    #[cfg(unix)]
    #[test]
    fn non_utf8_integration_command_is_not_confused_with_a_missing_mcp_command() {
        use std::{ffi::OsString, os::unix::ffi::OsStringExt};

        let integration_command = PathBuf::from(OsString::from_vec(vec![b'/', 0xff]));
        let listed = listed_stdio(None);

        let error = resolve_mcp(Some(listed), &integration_command).unwrap_err();

        assert_eq!(error.code(), "runtime_invalid");
    }

    #[test]
    fn stored_binding_read_distinguishes_absence_read_failure_and_invalid_json() {
        let root = tempfile::tempdir().unwrap();
        let missing = root.path().join("missing.json");
        assert_eq!(read_stored_binding(&missing).unwrap(), None);

        let unreadable = root.path().join("binding-directory");
        fs::create_dir(&unreadable).unwrap();
        let read_error = read_stored_binding(&unreadable).unwrap_err();
        assert!(
            read_error.details_ref()["reason"]
                .as_str()
                .is_some_and(|reason| reason.starts_with("could not read binding file:"))
        );

        let invalid = root.path().join("invalid.json");
        fs::write(&invalid, "{").unwrap();
        let parse_error = read_stored_binding(&invalid).unwrap_err();
        assert!(
            parse_error.details_ref()["reason"]
                .as_str()
                .is_some_and(|reason| reason.starts_with("invalid binding file:"))
        );
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
