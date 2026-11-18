//! Atomic, path-validated file writes inside one package. Ported from
//! `PackageFileWriter.cs`, itself `ScriptWidgetPackageFiles.write` in Swift.

use std::os::fd::OwnedFd;
use std::path::Path;

use rustix::fs::AtFlags;
use rustix::io::Errno;

use super::error::{PackageError, codes};
use super::limits::{MAX_FILE_BYTES, MAX_METADATA_BYTES};
use super::{manifests, path_rules, safe_files};

/// Writes `bytes` to `relative_path` below the package `root`.
///
/// The path must pass the package path rules (no traversal, absolute path,
/// backslash, NUL, dot-file or `__Build` component). Every step is made
/// relative to an open descriptor of the directory above it and never follows
/// a link: an existing directory on the way must be a real directory, a
/// missing one is created, and no component may have a case alias, so a write
/// cannot be redirected outside the package. An existing target must be a
/// singly linked regular file. Content is limited to 25 MiB (256 KiB for
/// `widget.json`, whose name must be spelled exactly). The bytes go to a
/// hidden temporary file in the target directory, are flushed, and replace
/// the target with one atomic rename: readers see the old or the new content,
/// never a partial file, and a failed write leaves the old content in place.
pub(crate) fn write(root: &Path, relative_path: &str, bytes: &[u8]) -> Result<(), PackageError> {
    let parts = path_rules::visible_components(relative_path).ok_or_else(|| fail(codes::INVALID_PATH, "Invalid package path."))?;
    if bytes.len() as u64 > MAX_FILE_BYTES {
        return Err(fail(codes::FILE_TOO_LARGE, "Package file exceeds 25 MiB."));
    }
    if let [name] = parts[..]
        && name.to_lowercase() == manifests::FILE_NAME
    {
        if name != manifests::FILE_NAME {
            return Err(fail(codes::INVALID_MANIFEST_CASE, "Use the exact file name widget.json."));
        }
        if bytes.len() > MAX_METADATA_BYTES {
            return Err(fail(codes::FILE_TOO_LARGE, "widget.json exceeds 256 KiB."));
        }
    }
    let (file_name, directories) = parts.split_last().ok_or_else(|| fail(codes::INVALID_PATH, "Invalid package path."))?;
    let mut directory = safe_files::open_directory(root).map_err(|error| PackageError::caused(codes::PACKAGE_NOT_FOUND, "Package directory is unavailable.", error))?;
    for name in directories {
        require_unambiguous(&directory, name)?;
        match safe_files::attributes_at(&directory, name) {
            Ok(entry) if entry.is_directory => {}
            Ok(_) => return Err(fail(codes::UNSAFE_FILE, "Package path crosses a link or a file.")),
            Err(error) if error.raw_os_error() == Some(Errno::NOENT.raw_os_error()) => {}
            Err(error) => return Err(PackageError::caused(codes::UNSAFE_FILE, "Package file could not be verified.", error)),
        }
        // Opens the directory itself, creating it first when it is missing; a link that appeared meanwhile is refused.
        directory = safe_files::create_directory_at(&directory, name).map_err(|error| PackageError::caused(codes::UNSAFE_FILE, "Package directory could not be created.", error))?;
    }
    require_unambiguous(&directory, file_name)?;
    match safe_files::attributes_at(&directory, file_name) {
        Ok(entry) if entry.is_private_regular_file() => {}
        Ok(_) => return Err(fail(codes::UNSAFE_FILE, "Only regular package files can be replaced.")),
        Err(error) if error.raw_os_error() == Some(Errno::NOENT.raw_os_error()) => {}
        Err(error) => return Err(PackageError::caused(codes::UNSAFE_FILE, "Package file could not be verified.", error)),
    }
    let temporary = format!(".write-{}", safe_files::unique_token());
    let saved = safe_files::write_new_at(&directory, &temporary, bytes).and_then(|()| Ok(rustix::fs::renameat(&directory, temporary.as_str(), &directory, *file_name)?));
    if let Err(error) = saved {
        // Hidden temporaries are never listed, read or exported, but none should stay behind.
        let _ = rustix::fs::unlinkat(&directory, temporary.as_str(), AtFlags::empty());
        return Err(PackageError::caused(codes::STORAGE_UNAVAILABLE, "Package file could not be saved.", error));
    }
    // Makes the rename itself durable; the content already is.
    let _ = rustix::fs::fsync(&directory);
    Ok(())
}

fn require_unambiguous(directory: &OwnedFd, name: &str) -> Result<(), PackageError> {
    let siblings = safe_files::names_of(directory).ok_or_else(|| fail(codes::UNSAFE_FILE, "Package directory could not be verified."))?;
    if safe_files::unambiguous(&siblings.names, name) { Ok(()) } else { Err(fail(codes::UNSAFE_FILE, "Case-colliding package paths are not allowed.")) }
}

fn fail(code: &str, message: &str) -> PackageError {
    PackageError::new(code, message)
}
