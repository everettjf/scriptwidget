//! Removes one file of an installed package, under the same path rules as
//! the package file writer. `scriptwidget dev` uses it to make an installed
//! package follow the folder it is developed in.

use std::path::Path;

use rustix::fs::AtFlags;

use super::error::{PackageError, codes};
use super::{path_rules, safe_files};

/// Removes `relative_path` below the package `root`.
///
/// The path must pass the package path rules. The directory that holds the
/// file is opened beneath `root` without following a link, and the entry
/// must be a singly linked regular file: a link, a directory or anything
/// else is refused, so nothing outside the package can be removed. A file
/// that is already gone is not an error. Directories are left in place.
pub(crate) fn remove(root: &Path, relative_path: &str) -> Result<(), PackageError> {
    let parts = path_rules::visible_components(relative_path).ok_or_else(|| PackageError::new(codes::INVALID_PATH, "Invalid package path."))?;
    let (file_name, directories) = parts.split_last().ok_or_else(|| PackageError::new(codes::INVALID_PATH, "Invalid package path."))?;
    let unavailable = |error| PackageError::caused(codes::PACKAGE_NOT_FOUND, "Package directory is unavailable.", error);
    let root = safe_files::open_directory(root).map_err(unavailable)?;
    let directory = if directories.is_empty() {
        root
    } else {
        match safe_files::open_beneath(&root, directories, safe_files::DIRECTORY_FLAGS) {
            Ok(directory) => directory,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
            Err(error) => return Err(PackageError::caused(codes::UNSAFE_FILE, "Package path crosses a link or a file.", error)),
        }
    };
    match safe_files::attributes_at(&directory, file_name) {
        Ok(entry) if entry.is_private_regular_file() => {}
        Ok(_) => return Err(PackageError::new(codes::UNSAFE_FILE, "Only regular package files can be removed.")),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(PackageError::caused(codes::UNSAFE_FILE, "Package file could not be verified.", error)),
    }
    rustix::fs::unlinkat(&directory, *file_name, AtFlags::empty()).map_err(|error| PackageError::caused(codes::STORAGE_UNAVAILABLE, "Package file could not be removed.", error))
}
