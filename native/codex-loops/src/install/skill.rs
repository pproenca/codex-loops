use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
};

use serde_json::json;

use crate::error::{AppError, AppResult, ChangeState, ExitStatus};

use super::SKILL_VERSION_FILE;

pub(super) fn skill_matches(source: &Path, destination: &Path) -> AppResult<bool> {
    let version_path = destination.join(SKILL_VERSION_FILE);
    let version = match fs::read_to_string(&version_path) {
        Ok(version) => version,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(skill_snapshot_error(&version_path, error)),
    };
    if version.trim() != env!("CARGO_PKG_VERSION") {
        return Ok(false);
    }

    let source_snapshot = directory_snapshot(source, SnapshotMode::Complete)
        .map_err(|error| skill_snapshot_error(source, error))?;
    let destination_snapshot = directory_snapshot(destination, SnapshotMode::IgnoreVersion)
        .map_err(|error| skill_snapshot_error(destination, error))?;
    Ok(source_snapshot == destination_snapshot)
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

enum SkillCommitError {
    Install(AppError),
    Rollback(AppError),
}

struct DirectorySnapshot {
    mode: SnapshotMode,
    files: BTreeMap<PathBuf, Vec<u8>>,
}

impl DirectorySnapshot {
    fn visit(&mut self, directory: &Path, relative_directory: &Path) -> std::io::Result<()> {
        for entry in fs::read_dir(directory)? {
            let entry = entry?;
            let relative = relative_directory.join(entry.file_name());
            if self.mode == SnapshotMode::IgnoreVersion && relative == Path::new(SKILL_VERSION_FILE)
            {
                continue;
            }
            if entry.file_type()?.is_dir() {
                self.visit(&entry.path(), &relative)?;
            } else {
                self.files.insert(relative, fs::read(entry.path())?);
            }
        }
        Ok(())
    }
}

fn directory_snapshot(
    root: &Path,
    mode: SnapshotMode,
) -> std::io::Result<BTreeMap<PathBuf, Vec<u8>>> {
    let mut snapshot = DirectorySnapshot {
        mode,
        files: BTreeMap::new(),
    };
    snapshot.visit(root, Path::new(""))?;
    Ok(snapshot.files)
}

pub(super) fn install_skill(source: &Path, destination: &Path) -> AppResult<()> {
    let parent = destination.parent().ok_or_else(|| {
        AppError::new(
            ExitStatus::Runtime,
            "skill_install_failed",
            "The user skill path has no parent.",
        )
    })?;
    fs::create_dir_all(parent).map_err(skill_error)?;
    let temp = parent.join(format!(".codex-loops-{}.tmp", std::process::id()));
    let backup = parent.join(format!(".codex-loops-{}.old", std::process::id()));
    remove_directory_if_present(&temp).map_err(skill_error)?;
    remove_directory_if_present(&backup).map_err(skill_error)?;
    let staged = (|| {
        copy_dir(source, &temp).map_err(SkillCommitError::Install)?;
        fs::write(temp.join(SKILL_VERSION_FILE), env!("CARGO_PKG_VERSION"))
            .map_err(skill_error)
            .map_err(SkillCommitError::Install)?;
        commit_skill(
            SkillCommit {
                temp: &temp,
                destination,
                backup: &backup,
            },
            |source, destination| fs::rename(source, destination),
        )
    })();
    if let Err(error) = staged {
        return cleanup_failed_staging(&temp, error);
    }
    remove_directory_if_present(&backup).map_err(|error| {
        skill_error(error)
            .changed(ChangeState::Changed)
            .step("skill_cleanup")
    })?;
    Ok(())
}

fn cleanup_failed_staging(temp: &Path, failure: SkillCommitError) -> AppResult<()> {
    let install_error = match failure {
        SkillCommitError::Rollback(error) => return Err(error),
        SkillCommitError::Install(error) => error,
    };
    match remove_directory_if_present(temp) {
        Ok(()) => Err(install_error),
        Err(cleanup_error) => Err(AppError::new(
            ExitStatus::Runtime,
            "skill_cleanup_failed",
            "Codex Loops could not clean up a failed user skill installation.",
        )
        .details(json!({
            "install_error": install_error.diagnostic(),
            "cleanup_error": cleanup_error.to_string()
        }))
        .changed(ChangeState::Changed)
        .step("skill_cleanup")),
    }
}

fn commit_skill(
    commit: SkillCommit<'_>,
    mut rename: impl FnMut(&Path, &Path) -> std::io::Result<()>,
) -> Result<(), SkillCommitError> {
    let had_previous = commit
        .destination
        .try_exists()
        .map_err(skill_error)
        .map_err(SkillCommitError::Install)?;
    if had_previous {
        rename(commit.destination, commit.backup)
            .map_err(skill_error)
            .map_err(SkillCommitError::Install)?;
    }
    if cfg!(debug_assertions)
        && std::env::var("CODEX_LOOPS_TEST_SKILL_COMMIT_FAILURE").as_deref() == Ok("rollback")
    {
        return Err(SkillCommitError::Rollback(
            AppError::new(
            ExitStatus::Runtime,
            "skill_rollback_failed",
            "Codex Loops could not restore the previous user skill.",
        )
        .details(json!({"install_error": "injected install failure", "restore_error": "injected restore failure"}))
        .changed(ChangeState::Changed)
        .step("skill_restore"),
        ));
    }
    if let Err(error) = rename(commit.temp, commit.destination) {
        if had_previous && let Err(restore_error) = rename(commit.backup, commit.destination) {
            return Err(SkillCommitError::Rollback(
                AppError::new(
                    ExitStatus::Runtime,
                    "skill_rollback_failed",
                    "Codex Loops could not restore the previous user skill.",
                )
                .details(json!({
                    "install_error": error.to_string(),
                    "restore_error": restore_error.to_string()
                }))
                .changed(ChangeState::Changed)
                .step("skill_restore"),
            ));
        }
        return Err(SkillCommitError::Install(skill_error(error)));
    }
    Ok(())
}

fn remove_directory_if_present(path: &Path) -> std::io::Result<()> {
    match fs::remove_dir_all(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
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
            ExitStatus::Runtime,
            "skill_install_failed",
            "HOME is not set; the user skill cannot be installed.",
        )
    })?;
    Ok(PathBuf::from(home).join(".agents/skills/codex-loops"))
}

fn skill_error(error: std::io::Error) -> AppError {
    AppError::new(
        ExitStatus::Runtime,
        "skill_install_failed",
        "Codex Loops could not install its user skill.",
    )
    .details(json!({"reason": error.to_string()}))
}

fn skill_snapshot_error(path: &Path, error: std::io::Error) -> AppError {
    AppError::new(
        ExitStatus::Runtime,
        "skill_snapshot_failed",
        "Codex Loops could not inspect a user skill.",
    )
    .details(json!({"path": path, "reason": error.to_string()}))
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
        assert!(!skill_matches(source.path(), destination.path()).unwrap());

        fs::write(destination.path().join("SKILL.md"), "altered").unwrap();
        assert!(!skill_matches(source.path(), destination.path()).unwrap());

        fs::write(destination.path().join("SKILL.md"), "expected").unwrap();
        assert!(skill_matches(source.path(), destination.path()).unwrap());
    }

    #[test]
    fn packaged_snapshot_failure_is_explicit() {
        let root = tempfile::tempdir().unwrap();
        let source = root.path().join("missing");
        let destination = root.path().join("destination");
        fs::create_dir(&destination).unwrap();
        fs::write(
            destination.join(SKILL_VERSION_FILE),
            env!("CARGO_PKG_VERSION"),
        )
        .unwrap();

        let error = skill_matches(&source, &destination).unwrap_err();

        assert_eq!(error.code(), "skill_snapshot_failed");
    }

    #[cfg(unix)]
    #[test]
    fn destination_snapshot_failure_is_explicit() {
        use std::os::unix::fs::symlink;

        let source = tempfile::tempdir().unwrap();
        let destination = tempfile::tempdir().unwrap();
        fs::write(source.path().join("SKILL.md"), "expected").unwrap();
        fs::write(destination.path().join("SKILL.md"), "expected").unwrap();
        fs::write(
            destination.path().join(SKILL_VERSION_FILE),
            env!("CARGO_PKG_VERSION"),
        )
        .unwrap();
        symlink(
            destination.path().join("missing"),
            destination.path().join("broken"),
        )
        .unwrap();

        let error = skill_matches(source.path(), destination.path()).unwrap_err();

        assert_eq!(error.code(), "skill_snapshot_failed");
    }

    #[test]
    fn cleanup_distinguishes_absence_from_failure() {
        let root = tempfile::tempdir().unwrap();
        remove_directory_if_present(&root.path().join("missing")).unwrap();

        let file = root.path().join("file");
        fs::write(&file, "not a directory").unwrap();
        assert!(remove_directory_if_present(&file).is_err());
    }

    #[test]
    fn failed_staging_removes_the_partial_temp_directory() {
        let root = tempfile::tempdir().unwrap();
        let source = root.path().join("missing-source");
        let destination = root.path().join("skills/codex-loops");
        let temp = destination
            .parent()
            .unwrap()
            .join(format!(".codex-loops-{}.tmp", std::process::id()));

        let error = install_skill(&source, &destination).unwrap_err();

        assert_eq!(error.code(), "skill_install_failed");
        assert!(!temp.try_exists().unwrap());
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

        assert!(matches!(
            error,
            SkillCommitError::Rollback(error) if error.code() == "skill_rollback_failed"
        ));
    }
}
