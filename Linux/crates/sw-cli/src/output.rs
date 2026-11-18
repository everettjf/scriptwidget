//! Writing the one file a command was asked to write: the PNG of `render`
//! and the archive of `pack`.
//!
//! The file is written under a fresh private name in the directory the user
//! named and then moved to its final name. So nothing is ever written
//! *through* what is at that name: a symbolic link there is refused, and even
//! one that appears at the last moment is replaced (or, for a file that must
//! be new, makes the command fail) instead of being followed. The output may
//! not lie inside the package it was made from.

use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Component, Path, PathBuf};

use crate::report::Failure;

/// The absolute path a user-supplied output names, with the directories that
/// already exist resolved, so that it can be compared with the package directory.
pub fn resolve(text: &str) -> Result<PathBuf, Failure> {
    let unusable = || Failure::environment("output.path", format!("{text} is not a usable output path"));
    if text.is_empty() || text.contains('\0') {
        return Err(unusable());
    }
    let absolute = std::path::absolute(Path::new(text)).map_err(|_| unusable())?;
    let name = absolute.file_name().ok_or_else(unusable)?.to_owned();
    // The deepest directory that exists, resolved; what follows it must be plain names.
    let mut existing = absolute.parent().ok_or_else(unusable)?.to_owned();
    let mut pending = Vec::new();
    let resolved = loop {
        match std::fs::canonicalize(&existing) {
            Ok(resolved) => break resolved,
            Err(_) => {
                let Some(Component::Normal(last)) = existing.components().next_back() else { return Err(unusable()) };
                pending.push(last.to_owned());
                if !existing.pop() {
                    return Err(unusable());
                }
            }
        }
    };
    let mut result = resolved;
    result.extend(pending.into_iter().rev());
    result.push(name);
    Ok(result)
}

/// Refuses an output inside the package: it would become part of what is packed or run next.
pub fn require_outside(output: &Path, package: &Path) -> Result<(), Failure> {
    let package = std::fs::canonicalize(package).unwrap_or_else(|_| package.to_owned());
    if output.starts_with(&package) {
        return Err(Failure::environment("output.inside_package", "The output must be outside the package folder."));
    }
    Ok(())
}

/// Writes `bytes` to `output` (a path from [`resolve`]). With `replace` an
/// existing regular file is replaced; without it the name must be free.
pub fn write(output: &Path, bytes: &[u8], replace: bool) -> Result<(), Failure> {
    let failed = |what: &str, error: std::io::Error| Failure::environment("output.write", format!("{}: {what}: {error}", output.display()));
    let (Some(parent), Some(name)) = (output.parent(), output.file_name()) else {
        return Err(Failure::environment("output.path", format!("{} is not a usable output path", output.display())));
    };
    std::fs::create_dir_all(parent).map_err(|error| failed("the folder could not be created", error))?;
    match std::fs::symlink_metadata(output) {
        Ok(metadata) if metadata.file_type().is_symlink() => return Err(Failure::environment("output.symlink", format!("{} is a symbolic link; choose another output.", output.display()))),
        Ok(metadata) if !metadata.is_file() => return Err(Failure::environment("output.not_a_file", format!("{} exists and is not a regular file.", output.display()))),
        Ok(_) if !replace => return Err(Failure::environment("output.exists", format!("{} exists; choose a new file or pass --force.", output.display()))),
        _ => {}
    }
    let mut token = [0u8; 8];
    getrandom::fill(&mut token).map_err(|error| Failure::internal(format!("No random source: {error}")))?;
    let mut temporary_name = std::ffi::OsString::from(".");
    temporary_name.push(name);
    temporary_name.push(format!(".{}.tmp", token.iter().map(|byte| format!("{byte:02x}")).collect::<String>()));
    let temporary = parent.join(temporary_name);
    let written = (|| {
        let mut file = std::fs::OpenOptions::new().write(true).create_new(true).custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC).mode(0o644).open(&temporary)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        if replace {
            std::fs::rename(&temporary, output)
        } else {
            // A hard link fails when the name is taken, whatever took it in the meantime.
            let linked = std::fs::hard_link(&temporary, output);
            let _ = std::fs::remove_file(&temporary);
            linked
        }
    })();
    written.map_err(|error| {
        let _ = std::fs::remove_file(&temporary);
        if error.kind() == std::io::ErrorKind::AlreadyExists { Failure::environment("output.exists", format!("{} exists; choose a new file or pass --force.", output.display())) } else { failed("the file could not be written", error) }
    })
}
