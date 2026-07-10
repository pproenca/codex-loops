use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
};

use serde_json::json;

use crate::error::{
    ChangeState, ErrorContext, InstallError as AppError, InstallResult as AppResult,
};

use super::SKILL_VERSION_FILE;

pub(super) fn skill_matches(source: &Path, destination: &Path) -> bool {
    let version_matches = fs::read_to_string(destination.join(SKILL_VERSION_FILE))
        .is_ok_and(|version| version.trim() == env!("CARGO_PKG_VERSION"));
    version_matches
        && directory_snapshot(source, SnapshotMode::Complete)
            .zip(directory_snapshot(destination, SnapshotMode::IgnoreVersion))
            .is_some_and(|(source, destination)| source == destination)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SnapshotMode {
    Complete,
    IgnoreVersion,
}

struct SkillCommit<'a> {
    temp: &'a Path,
    destination: &'a Path,
    backup: &'a Path,
}

struct SnapshotVisitor<'a> {
    root: &'a Path,
    mode: SnapshotMode,
    snapshot: &'a mut BTreeMap<PathBuf, Vec<u8>>,
}

fn directory_snapshot(root: &Path, mode: SnapshotMode) -> Option<BTreeMap<PathBuf, Vec<u8>>> {
    fn visit(directory: &Path, visitor: &mut SnapshotVisitor<'_>) -> Option<()> {
        for entry in fs::read_dir(directory).ok()? {
            let entry = entry.ok()?;
            let relative = entry.path().strip_prefix(visitor.root).ok()?.to_path_buf();
            if visitor.mode == SnapshotMode::IgnoreVersion
                && relative == Path::new(SKILL_VERSION_FILE)
            {
                continue;
            }
            if entry.file_type().ok()?.is_dir() {
                visit(&entry.path(), visitor)?;
            } else {
                visitor
                    .snapshot
                    .insert(relative, fs::read(entry.path()).ok()?);
            }
        }
        Some(())
    }

    let mut snapshot = BTreeMap::new();
    visit(
        root,
        &mut SnapshotVisitor {
            root,
            mode,
            snapshot: &mut snapshot,
        },
    )?;
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
    commit_skill(
        SkillCommit {
            temp: &temp,
            destination,
            backup: &backup,
        },
        |source, destination| fs::rename(source, destination),
    )?;
    let _ = fs::remove_dir_all(backup);
    Ok(())
}

fn commit_skill(
    commit: SkillCommit<'_>,
    mut rename: impl FnMut(&Path, &Path) -> std::io::Result<()>,
) -> AppResult<()> {
    let had_previous = commit.destination.exists();
    if had_previous {
        rename(commit.destination, commit.backup).map_err(skill_error)?;
    }
    if cfg!(debug_assertions)
        && std::env::var("CODEX_LOOPS_TEST_SKILL_COMMIT_FAILURE").as_deref() == Ok("rollback")
    {
        return Err(AppError::new(
            6,
            "skill_rollback_failed",
            "Codex Loops could not restore the previous user skill.",
        )
        .details(json!({"install_error": "injected install failure", "restore_error": "injected restore failure"}))
        .changed(ChangeState::Changed)
        .step("skill_restore"));
    }
    if let Err(error) = rename(commit.temp, commit.destination) {
        if had_previous && let Err(restore_error) = rename(commit.backup, commit.destination) {
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn integrity_rejects_partial_and_corrupt_skill_content() {
        let source = tempfile::tempdir().unwrap();
        let destination = tempfile::tempdir().unwrap();
        fs::write(source.path().join("SKILL.md"), "expected").unwrap();
        fs::write(
            destination.path().join(SKILL_VERSION_FILE),
            env!("CARGO_PKG_VERSION"),
        )
        .unwrap();
        assert!(!skill_matches(source.path(), destination.path()));

        fs::write(destination.path().join("SKILL.md"), "altered").unwrap();
        assert!(!skill_matches(source.path(), destination.path()));

        fs::write(destination.path().join("SKILL.md"), "expected").unwrap();
        assert!(skill_matches(source.path(), destination.path()));
    }

    #[test]
    fn replacement_reports_when_install_and_restore_both_fail() {
        let root = tempfile::tempdir().unwrap();
        let temp = root.path().join("temp");
        let destination = root.path().join("destination");
        let backup = root.path().join("backup");
        fs::create_dir(&temp).unwrap();
        fs::create_dir(&destination).unwrap();
        let mut calls = 0;

        let error = commit_skill(
            SkillCommit {
                temp: &temp,
                destination: &destination,
                backup: &backup,
            },
            |_source, _destination| {
                calls += 1;
                match calls {
                    1 => Ok(()),
                    2 => Err(std::io::Error::other("install failed")),
                    3 => Err(std::io::Error::other("restore failed")),
                    _ => unreachable!(),
                }
            },
        )
        .unwrap_err();

        assert_eq!(error.code(), "skill_rollback_failed");
    }
}
