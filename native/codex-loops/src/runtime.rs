use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};

use serde::{Deserialize, Serialize};

use crate::error::{AppError, AppResult, ExitStatus};

const CONTROL_PLANE: &str = "bin/codex-loops";
const SCHEDULER: &str = "libexec/scheduler/bin/agent_loops";
const SCHEDULER_ROOT: &str = "libexec/scheduler";
const SKILL: &str = "share/skills/codex-loops";

#[derive(Debug, PartialEq, Eq)]
pub struct Bundle {
    root: PathBuf,
}

#[derive(Debug, PartialEq, Eq)]
pub struct CodexBinding {
    pub(crate) path: PathBuf,
    pub(crate) version: String,
}

#[derive(Debug, PartialEq, Eq)]
pub struct Runtime {
    pub(crate) bundle: Bundle,
    pub(crate) codex: CodexBinding,
}

#[derive(Deserialize)]
struct StoredCodexBinding {
    path: PathBuf,
    version: String,
}

#[derive(Serialize)]
struct StoredCodexBindingRef<'a> {
    path: &'a Path,
    version: &'a str,
}

impl CodexBinding {
    pub fn probe(path: &Path) -> AppResult<Self> {
        if !path.is_absolute() {
            return Err(invalid_codex_binding(
                path,
                "the selected Codex command must be an absolute executable path",
            ));
        }

        let metadata = fs::metadata(path).map_err(|error| {
            invalid_codex_binding(path, &format!("could not inspect command: {error}"))
        })?;
        if !metadata.is_file() {
            return Err(invalid_codex_binding(
                path,
                "the selected Codex command is not a file",
            ));
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            if metadata.permissions().mode() & 0o111 == 0 {
                return Err(invalid_codex_binding(
                    path,
                    "the selected Codex command is not executable",
                ));
            }
        }
        let output = Command::new(path)
            .arg("--version")
            .output()
            .map_err(|error| invalid_codex_binding(path, &error.to_string()))?;
        if !output.status.success() {
            return Err(invalid_codex_binding(
                path,
                &format!("Codex --version exited with {}", output.status),
            ));
        }
        let version = String::from_utf8(output.stdout)
            .map_err(|error| {
                invalid_codex_binding(
                    path,
                    &format!("Codex --version returned invalid UTF-8: {error}"),
                )
            })?
            .trim()
            .to_owned();
        if !valid_codex_version(&version) {
            return Err(invalid_codex_binding(
                path,
                "Codex --version returned an unexpected response",
            ));
        }
        Ok(Self {
            path: path.to_path_buf(),
            version,
        })
    }

    pub fn load(path: &Path) -> AppResult<Self> {
        let stored = Self::read_optional(path)?.ok_or_else(|| {
            AppError::new(
                ExitStatus::Prerequisite,
                "codex_binding_missing",
                "Codex Loops has no configured Codex command.",
            )
            .details(serde_json::json!({"path": path}))
            .next_steps(["Run `codex-loops install --codex /absolute/path/to/codex`."])
        })?;
        let current = Self::probe(&stored.path)?;
        if current.version != stored.version {
            return Err(AppError::new(
                ExitStatus::Prerequisite,
                "codex_binding_changed",
                "The configured Codex command changed after it was bound to Codex Loops.",
            )
            .details(serde_json::json!({
                "path": stored.path,
                "configured_version": stored.version,
                "current_version": current.version
            }))
            .next_steps(["Rerun `codex-loops install --codex /absolute/path/to/codex`."]));
        }
        Ok(current)
    }

    pub fn read_optional(path: &Path) -> AppResult<Option<Self>> {
        let bytes = match fs::read(path) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => {
                return Err(invalid_stored_binding(
                    path,
                    &format!("could not read binding file: {error}"),
                ));
            }
        };
        let stored: StoredCodexBinding = serde_json::from_slice(&bytes).map_err(|error| {
            invalid_stored_binding(path, &format!("invalid binding file: {error}"))
        })?;
        if !stored.path.is_absolute() {
            return Err(invalid_stored_binding(
                path,
                "the stored Codex command path is not absolute",
            ));
        }
        if !valid_codex_version(&stored.version) {
            return Err(invalid_stored_binding(
                path,
                "the stored Codex version is invalid",
            ));
        }
        Ok(Some(Self {
            path: stored.path,
            version: stored.version,
        }))
    }

    pub fn persist(&self, path: &Path) -> AppResult<()> {
        let parent = path
            .parent()
            .filter(|parent| !parent.as_os_str().is_empty())
            .ok_or_else(|| invalid_stored_binding(path, "binding path has no parent directory"))?;
        fs::create_dir_all(parent).map_err(|error| {
            invalid_stored_binding(
                path,
                &format!("could not create binding directory: {error}"),
            )
        })?;
        let temp = path.with_extension("json.tmp");
        let stored = StoredCodexBindingRef {
            path: &self.path,
            version: &self.version,
        };
        let bytes = serde_json::to_vec_pretty(&stored).map_err(|error| {
            invalid_stored_binding(path, &format!("could not encode binding: {error}"))
        })?;
        fs::write(&temp, bytes).map_err(|error| {
            invalid_stored_binding(path, &format!("could not write binding: {error}"))
        })?;
        fs::rename(&temp, path).map_err(|error| {
            invalid_stored_binding(path, &format!("could not commit binding: {error}"))
        })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn version(&self) -> &str {
        &self.version
    }
}

impl Runtime {
    pub fn open(bundle: Bundle, binding_path: &Path) -> AppResult<Self> {
        Ok(Self {
            bundle,
            codex: CodexBinding::load(binding_path)?,
        })
    }

    pub fn installed() -> AppResult<Self> {
        Self::open(Bundle::installed()?, &binding_path()?)
    }
}

fn invalid_codex_binding(path: &Path, reason: &str) -> AppError {
    AppError::new(
        ExitStatus::Prerequisite,
        "codex_binding_invalid",
        "Codex Loops could not use the selected Codex command.",
    )
    .details(serde_json::json!({"path": path, "reason": reason}))
    .next_steps(["Rerun `codex-loops install --codex /absolute/path/to/codex`."])
}

fn invalid_stored_binding(path: &Path, reason: &str) -> AppError {
    AppError::new(
        ExitStatus::Prerequisite,
        "codex_binding_invalid",
        "Codex Loops could not use its stored Codex binding.",
    )
    .details(serde_json::json!({"path": path, "reason": reason}))
    .next_steps(["Rerun `codex-loops install --codex /absolute/path/to/codex`."])
}

fn valid_codex_version(version: &str) -> bool {
    version
        .strip_prefix("codex-cli ")
        .is_some_and(|version| !version.trim().is_empty() && !version.contains(['\r', '\n']))
}

impl Bundle {
    pub fn installed() -> AppResult<Self> {
        let executable = std::env::current_exe()
            .and_then(fs::canonicalize)
            .map_err(|error| {
                AppError::new(
                    ExitStatus::Runtime,
                    "runtime_invalid",
                    "Codex Loops could not resolve its installed executable.",
                )
                .details(serde_json::json!({"reason": error.to_string()}))
            })?;
        let root = match development_bundle_root() {
            Some(root) => root,
            None => executable
                .parent()
                .and_then(Path::parent)
                .map(Path::to_path_buf)
                .ok_or_else(|| {
                    AppError::new(
                        ExitStatus::Runtime,
                        "runtime_invalid",
                        "Codex Loops is not installed inside a runtime bundle.",
                    )
                    .details(serde_json::json!({"executable": executable}))
                })?,
        };
        Self::open(&root)
    }

    pub fn open(root: &Path) -> AppResult<Self> {
        if !root.is_absolute() {
            return Err(runtime_bundle_error(
                "root",
                root,
                "the runtime bundle root must be absolute",
            ));
        }

        let bundle = Self {
            root: root.to_path_buf(),
        };
        let required = [
            (bundle.control_plane(), "control_plane"),
            (bundle.scheduler(), "scheduler"),
            (bundle.skill().join("SKILL.md"), "skill"),
        ];
        if let Some((path, component)) = required
            .into_iter()
            .find(|(path, _component)| !path.is_file())
        {
            return Err(runtime_bundle_error(
                component,
                &path,
                "the required bundle component is missing",
            ));
        }

        Ok(bundle)
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn into_root(self) -> PathBuf {
        self.root
    }

    pub fn control_plane(&self) -> PathBuf {
        self.root.join(CONTROL_PLANE)
    }

    pub fn scheduler(&self) -> PathBuf {
        self.root.join(SCHEDULER)
    }

    pub fn skill(&self) -> PathBuf {
        self.root.join(SKILL)
    }

    /// Prefer absolute `argv[0]` when it resolves back to this exact immutable
    /// bundle. Unlike `current_exe`, this preserves installer-owned stable links
    /// on Linux without PATH or prefix discovery.
    pub fn integration_command(&self) -> PathBuf {
        let invoked = std::env::args_os().next().map(PathBuf::from);
        self.integration_command_for(invoked.as_deref())
    }

    fn integration_command_for(&self, invoked: Option<&Path>) -> PathBuf {
        let control_plane = self.control_plane();
        let Some(invoked) = invoked.filter(|path| path.is_absolute()) else {
            return control_plane;
        };
        match (fs::canonicalize(invoked), fs::canonicalize(&control_plane)) {
            (Ok(stable_target), Ok(bundle_target)) if stable_target == bundle_target => {
                invoked.to_path_buf()
            }
            (Ok(_), Ok(_)) | (Ok(_), Err(_)) | (Err(_), Ok(_)) | (Err(_), Err(_)) => control_plane,
        }
    }

    pub fn scheduler_root(&self) -> PathBuf {
        self.root.join(SCHEDULER_ROOT)
    }
}

fn runtime_bundle_error(component: &str, path: &Path, reason: &str) -> AppError {
    AppError::new(
        ExitStatus::Runtime,
        "runtime_invalid",
        "Codex Loops is not installed as a complete runtime bundle.",
    )
    .details(serde_json::json!({"component": component, "path": path, "reason": reason}))
    .next_steps(["Install a Codex Loops distribution bundle or run `make dev-bundle`."])
}

pub fn binding_path() -> AppResult<PathBuf> {
    let home = std::env::var_os("HOME").ok_or_else(|| {
        AppError::new(
            ExitStatus::Runtime,
            "runtime_invalid",
            "HOME is not set; Codex binding cannot be loaded.",
        )
    })?;
    let home = PathBuf::from(home);
    if !home.is_absolute() {
        return Err(AppError::new(
            ExitStatus::Runtime,
            "runtime_invalid",
            "HOME must be absolute; Codex binding cannot be loaded.",
        )
        .details(serde_json::json!({"home": home})));
    }
    Ok(home.join(".codex/workflows/codex-binding.json"))
}

fn development_bundle_root() -> Option<PathBuf> {
    if cfg!(debug_assertions) {
        std::env::var_os("CODEX_LOOPS_DEV_BUNDLE").map(PathBuf::from)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use std::fs;

    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;

    use super::*;

    #[test]
    fn fixed_bundle_layout_is_the_only_runtime_contract() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path();
        let control_plane = root.join("bin/codex-loops");
        let scheduler = root.join("libexec/scheduler/bin/agent_loops");
        let skill = root.join("share/skills/codex-loops/SKILL.md");
        for path in [&control_plane, &scheduler, &skill] {
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, "fixture").unwrap();
        }

        let bundle = Bundle::open(root).unwrap();

        assert_eq!(bundle.root(), root);
        assert_eq!(bundle.control_plane(), control_plane);
        assert_eq!(bundle.scheduler(), scheduler);
        assert_eq!(bundle.skill(), skill.parent().unwrap());
        assert_eq!(bundle.scheduler_root(), root.join("libexec/scheduler"));
    }

    #[cfg(unix)]
    #[test]
    fn integration_command_preserves_only_a_verified_absolute_launch_path() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("bundle");
        let control_plane = root.join("bin/codex-loops");
        let scheduler = root.join("libexec/scheduler/bin/agent_loops");
        let skill = root.join("share/skills/codex-loops/SKILL.md");
        for path in [&control_plane, &scheduler, &skill] {
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, "fixture").unwrap();
        }
        let stable_command = temp.path().join("bin/codex-loops");
        fs::create_dir_all(stable_command.parent().unwrap()).unwrap();
        std::os::unix::fs::symlink(&control_plane, &stable_command).unwrap();
        let unrelated = temp.path().join("unrelated");
        fs::write(&unrelated, "fixture").unwrap();
        let bundle = Bundle::open(&root).unwrap();

        assert_eq!(
            bundle.integration_command_for(Some(&stable_command)),
            stable_command
        );
        assert_eq!(
            bundle.integration_command_for(Some(Path::new("codex-loops"))),
            control_plane
        );
        assert_eq!(
            bundle.integration_command_for(Some(&unrelated)),
            control_plane
        );
        assert_eq!(bundle.integration_command_for(None), control_plane);
    }

    #[test]
    fn optional_binding_read_distinguishes_absence() {
        let temp = tempfile::tempdir().unwrap();

        assert_eq!(
            CodexBinding::read_optional(&temp.path().join("missing.json")).unwrap(),
            None
        );
    }

    #[cfg(unix)]
    #[test]
    fn codex_binding_preserves_the_selected_symlink_path() {
        let temp = tempfile::tempdir().unwrap();
        let executable = temp.path().join("codex-real");
        let selected = temp.path().join("codex");
        let stored = temp.path().join("config/codex-binding.json");
        fs::write(&executable, "#!/bin/sh\necho 'codex-cli 9.9.9'\n").unwrap();
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o755)).unwrap();
        std::os::unix::fs::symlink(&executable, &selected).unwrap();

        let binding = CodexBinding::probe(&selected).unwrap();
        binding.persist(&stored).unwrap();
        let loaded = CodexBinding::load(&stored).unwrap();

        assert_eq!(loaded.path(), selected);
        assert_eq!(loaded.version(), "codex-cli 9.9.9");
    }

    #[cfg(unix)]
    #[test]
    fn stored_binding_remains_readable_when_the_command_changes() {
        let temp = tempfile::tempdir().unwrap();
        let executable = temp.path().join("codex");
        let stored_path = temp.path().join("config/codex-binding.json");
        fs::write(&executable, "#!/bin/sh\necho 'codex-cli 1.0.0'\n").unwrap();
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o755)).unwrap();
        CodexBinding::probe(&executable)
            .unwrap()
            .persist(&stored_path)
            .unwrap();
        fs::write(&executable, "#!/bin/sh\necho 'codex-cli 2.0.0'\n").unwrap();

        let stored = CodexBinding::read_optional(&stored_path).unwrap().unwrap();

        assert_eq!(stored.path(), executable);
        assert_eq!(stored.version(), "codex-cli 1.0.0");
        assert_eq!(
            CodexBinding::load(&stored_path).unwrap_err().code(),
            "codex_binding_changed"
        );
    }

    #[cfg(unix)]
    #[test]
    fn runtime_loads_the_persisted_codex_binding() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("bundle");
        let control_plane = root.join("bin/codex-loops");
        let scheduler = root.join("libexec/scheduler/bin/agent_loops");
        let skill = root.join("share/skills/codex-loops/SKILL.md");
        let codex = temp.path().join("codex");
        let binding_path = temp.path().join("config/runtime.json");
        for path in [&control_plane, &scheduler, &skill] {
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, "fixture").unwrap();
        }
        fs::write(&codex, "#!/bin/sh\necho 'codex-cli 9.9.9'\n").unwrap();
        fs::set_permissions(&codex, fs::Permissions::from_mode(0o755)).unwrap();
        let binding = CodexBinding::probe(&codex).unwrap();
        binding.persist(&binding_path).unwrap();
        let bundle = Bundle::open(&root).unwrap();
        let runtime = Runtime::open(bundle, &binding_path).unwrap();

        assert_eq!(runtime.bundle.root(), root);
        assert_eq!(runtime.codex, binding);
    }
}
