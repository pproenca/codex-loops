use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
};

use serde_json::json;

use crate::error::{AppError, AppResult, ChangeState};

use super::SKILL_VERSION_FILE;

pub(super) fn skill_matches(source: &Path, destination: &Path) -> bool {
    let version_matches = fs::read_to_string(destination.join(SKILL_VERSION_FILE))
        .is_ok_and(|version| version.trim() == env!("CARGO_PKG_VERSION"));
    version_matches
        && directory_snapshot(source, false)
            .zip(directory_snapshot(destination, true))
            .is_some_and(|(source, destination)| source == destination)
}

fn directory_snapshot(root: &Path, ignore_version: bool) -> Option<BTreeMap<PathBuf, Vec<u8>>> {
    fn visit(
        root: &Path,
        directory: &Path,
        ignore_version: bool,
        snapshot: &mut BTreeMap<PathBuf, Vec<u8>>,
    ) -> Option<()> {
        for entry in fs::read_dir(directory).ok()? {
            let entry = entry.ok()?;
            let relative = entry.path().strip_prefix(root).ok()?.to_path_buf();
            if ignore_version && relative == Path::new(SKILL_VERSION_FILE) {
                continue;
            }
            if entry.file_type().ok()?.is_dir() {
                visit(root, &entry.path(), ignore_version, snapshot)?;
            } else {
                snapshot.insert(relative, fs::read(entry.path()).ok()?);
            }
        }
        Some(())
    }

    let mut snapshot = BTreeMap::new();
    visit(root, root, ignore_version, &mut snapshot)?;
    Some(snapshot)
}

pub(super) fn install_skill(source: &Path, destination: &Path) -> AppResult<()> {
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
        if backup.exists()
            && let Err(restore_error) = fs::rename(&backup, destination)
        {
            return Err(AppError::new(
                6,
                "skill_rollback_failed",
                "Codex Loops could not restore the previous user skill.",
            )
            .details(json!({
                "install_error": error.to_string(),
                "restore_error": restore_error.to_string()
            }))
            .changed(ChangeState::Changed)
            .step("skill_restore"));
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

pub(super) fn skill_destination() -> AppResult<PathBuf> {
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
