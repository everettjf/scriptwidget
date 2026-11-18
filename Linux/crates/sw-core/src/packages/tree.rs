//! Whole-tree verification, ported from `PackageTree.cs`, itself
//! `ScriptManager.validateExtractedTree` in Swift.

use std::path::Path;

use super::error::{PackageError, codes};
use super::limits::ArchiveLimits;
use super::{path_rules, safe_files};

/// Verifies a package directory before it is published or copied.
///
/// The tree may hold only directories and singly linked regular files: a
/// symbolic link, hard link or special file (device, socket, FIFO) could
/// reach outside the package. Names must be UTF-8 and valid components with
/// no case or normalization collisions, nesting is limited to 16 components,
/// and the entry count, per-file size and total size limits are those of the
/// archive policy. Sizes are the ones the filesystem reports for files this
/// layer wrote or is about to copy with a bound.
pub fn validate_tree(root: &Path, limits: &ArchiveLimits) -> Result<(), PackageError> {
    if !safe_files::real_directory(root) {
        return Err(fail(codes::UNSAFE_FILE, "Package directory could not be verified."));
    }
    visit(root, 1, &mut State { limits, count: 0, total: 0 })
}

struct State<'a> {
    limits: &'a ArchiveLimits,
    count: usize,
    total: u64,
}

fn visit(directory: &Path, depth: usize, state: &mut State<'_>) -> Result<(), PackageError> {
    let listing = safe_files::names(directory).ok_or_else(|| fail(codes::UNSAFE_FILE, "Package file could not be verified."))?;
    if listing.foreign {
        return Err(fail(codes::INVALID_PATH, "Invalid package path."));
    }
    for name in &listing.names {
        if depth > state.limits.maximum_path_depth || !path_rules::valid_component(name) {
            return Err(fail(codes::INVALID_PATH, "Invalid package path."));
        }
        if !safe_files::unambiguous(&listing.names, name) {
            return Err(fail(codes::UNSAFE_FILE, "Case-colliding package paths are not allowed."));
        }
        let child = safe_files::child(directory, name);
        let entry = safe_files::attributes(&child).ok_or_else(|| fail(codes::UNSAFE_FILE, "Package file could not be verified."))?;
        if entry.is_symbolic_link {
            return Err(fail(codes::UNSAFE_FILE, "Symbolic links are not allowed."));
        }
        if !entry.is_directory && !entry.is_regular_file {
            return Err(fail(codes::UNSAFE_FILE, "Only directories and regular files are allowed."));
        }
        state.count += 1;
        if state.count > state.limits.maximum_file_count {
            return Err(fail(codes::TOO_MANY_ENTRIES, "Package contains too many entries."));
        }
        if entry.is_directory {
            visit(&child, depth + 1, state)?;
            continue;
        }
        if entry.links > 1 {
            return Err(fail(codes::UNSAFE_FILE, "Hard-linked files are not allowed."));
        }
        if entry.size > state.limits.maximum_file_bytes {
            return Err(fail(codes::FILE_TOO_LARGE, "Package file exceeds 25 MiB."));
        }
        if state.total + entry.size > state.limits.maximum_expanded_bytes {
            return Err(fail(codes::PACKAGE_TOO_LARGE, "Expanded package exceeds 64 MiB."));
        }
        state.total += entry.size;
    }
    Ok(())
}

fn fail(code: &str, message: &str) -> PackageError {
    PackageError::new(code, message)
}
