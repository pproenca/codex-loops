use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};

use serde::{Deserialize, Serialize};

use crate::error::{ErrorContext, RuntimeError, RuntimeResult};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Bundle {
    pub root: PathBuf,
    pub control_plane: PathBuf,
    pub scheduler: PathBuf,
    pub skill: PathBuf,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CodexBinding {
    pub path: PathBuf,
    pub version: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Runtime {
    pub bundle: Bundle,
    pub codex: CodexBinding,
}

impl CodexBinding {
    pub fn probe(path: &Path) -> RuntimeResult<Self> {
        if !path.is_absolute() || !path.is_file() {
            return Err(invalid_codex_binding(
                path,
                "the selected Codex command must be an absolute executable path",
            ));
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let executable = path
                .metadata()
                .map(|metadata| metadata.permissions().mode() & 0o111 != 0)
                .unwrap_or(false);
            if !executable {
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
        let version = String::from_utf8_lossy(&output.stdout).trim().to_owned();
        if !version.starts_with("codex-cli ") {
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

    pub fn load(_path: &Path) -> RuntimeResult<Self> {
        let bytes = fs::read(_path).map_err(|error| {
            RuntimeError::new(
                3,
                "codex_binding_missing",
                "Codex Loops has no configured Codex command.",
            )
            .details(serde_json::json!({"path": _path, "reason": error.to_string()}))
            .next_steps(["Run `codex-loops install --codex /absolute/path/to/codex`."])
        })?;
        let stored: Self = serde_json::from_slice(&bytes).map_err(|error| {
            invalid_codex_binding(_path, &format!("invalid binding file: {error}"))
        })?;
        let current = Self::probe(&stored.path)?;
        if current.version != stored.version {
            return Err(RuntimeError::new(
                3,
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
        Ok(stored)
    }

    pub fn persist(&self, path: &Path) -> RuntimeResult<()> {
        let parent = path
            .parent()
            .ok_or_else(|| invalid_codex_binding(path, "binding path has no parent directory"))?;
        fs::create_dir_all(parent).map_err(|error| {
            invalid_codex_binding(
                path,
                &format!("could not create binding directory: {error}"),
            )
        })?;
        let temp = path.with_extension("json.tmp");
        let bytes = serde_json::to_vec_pretty(self).map_err(|error| {
            invalid_codex_binding(path, &format!("could not encode binding: {error}"))
        })?;
        fs::write(&temp, bytes).map_err(|error| {
            invalid_codex_binding(path, &format!("could not write binding: {error}"))
        })?;
        fs::rename(&temp, path).map_err(|error| {
            invalid_codex_binding(path, &format!("could not commit binding: {error}"))
        })
    }
}

impl Runtime {
    pub fn open(bundle: Bundle, binding_path: &Path) -> RuntimeResult<Self> {
        Ok(Self {
            bundle,
            codex: CodexBinding::load(binding_path)?,
        })
    }

    pub fn installed() -> RuntimeResult<Self> {
        Self::open(Bundle::installed()?, &binding_path()?)
    }
}

fn invalid_codex_binding(path: &Path, reason: &str) -> RuntimeError {
    RuntimeError::new(
        3,
        "codex_binding_invalid",
        "Codex Loops could not use the selected Codex command.",
    )
    .details(serde_json::json!({"path": path, "reason": reason}))
    .next_steps(["Rerun `codex-loops install --codex /absolute/path/to/codex`."])
}

impl Bundle {
    pub fn installed() -> RuntimeResult<Self> {
        let executable = std::env::current_exe()
            .and_then(fs::canonicalize)
            .map_err(|error| {
                RuntimeError::new(
                    6,
                    "runtime_invalid",
                    "Codex Loops could not resolve its installed executable.",
                )
                .details(serde_json::json!({"reason": error.to_string()}))
            })?;
        let root = development_bundle_root().unwrap_or_else(|| {
            executable
                .parent()
                .and_then(Path::parent)
                .map(Path::to_path_buf)
                .unwrap_or_default()
        });
        let control_plane = root.join("bin/codex-loops");
        Self::open(&root, &control_plane)
    }

    pub fn open(root: &Path, control_plane: &Path) -> RuntimeResult<Self> {
        let scheduler = root.join("libexec/scheduler/bin/agent_loops");
        let skill = root.join("share/skills/codex-loops");
        let skill_manifest = skill.join("SKILL.md");
        let required = [
            (control_plane, "control_plane"),
            (scheduler.as_path(), "scheduler"),
            (skill_manifest.as_path(), "skill"),
        ];
        if let Some((path, component)) = required
            .into_iter()
            .find(|(path, _component)| !path.is_file())
        {
            return Err(RuntimeError::new(
                6,
                "runtime_invalid",
                "Codex Loops is not installed as a complete runtime bundle.",
            )
            .details(serde_json::json!({"component": component, "path": path}))
            .next_steps(["Install a Codex Loops distribution bundle or run `make dev-bundle`."]));
        }

        Ok(Self {
            root: root.to_path_buf(),
            control_plane: control_plane.to_path_buf(),
            scheduler,
            skill,
        })
    }

    /// Prefer the OS-reported lexical invocation path when it resolves back to
    /// this exact immutable bundle. This preserves installer-owned stable links
    /// (including Homebrew's `bin/codex-loops`) without PATH or prefix discovery.
    pub fn integration_command(&self) -> PathBuf {
        let invoked = std::env::current_exe().ok();
        match (
            invoked
                .as_deref()
                .and_then(|path| fs::canonicalize(path).ok()),
            fs::canonicalize(&self.control_plane),
        ) {
            (Some(stable_target), Ok(bundle_target)) if stable_target == bundle_target => {
                invoked.expect("matched invocation path exists")
            }
            _other => self.control_plane.clone(),
        }
    }

    pub fn scheduler_root(&self) -> &Path {
        self.scheduler
            .parent()
            .and_then(Path::parent)
            .expect("validated scheduler path has a release root")
    }
}

pub fn binding_path() -> RuntimeResult<PathBuf> {
    let home = std::env::var_os("HOME").ok_or_else(|| {
        RuntimeError::new(
            6,
            "runtime_invalid",
            "HOME is not set; Codex binding cannot be loaded.",
        )
    })?;
    Ok(PathBuf::from(home).join(".codex/workflows/codex-binding.json"))
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

        assert_eq!(
            Bundle::open(root, &control_plane).unwrap(),
            Bundle {
                root: root.to_path_buf(),
                control_plane,
                scheduler,
                skill: skill.parent().unwrap().to_path_buf(),
            }
        );
    }

    #[cfg(unix)]
    #[test]
    fn codex_binding_preserves_the_selected_symlink_path() {
        let temp = tempfile::tempdir().unwrap();
        let executable = temp.path().join("codex-real");
        let selected = temp.path().join("codex");
        fs::write(&executable, "#!/bin/sh\necho 'codex-cli 9.9.9'\n").unwrap();
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o755)).unwrap();
        std::os::unix::fs::symlink(&executable, &selected).unwrap();

        assert_eq!(
            CodexBinding::probe(&selected).unwrap(),
            CodexBinding {
                path: selected,
                version: "codex-cli 9.9.9".into(),
            }
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
        let bundle = Bundle::open(&root, &control_plane).unwrap();

        assert_eq!(
            Runtime::open(bundle.clone(), &binding_path).unwrap(),
            Runtime {
                bundle,
                codex: binding
            }
        );
    }
}
