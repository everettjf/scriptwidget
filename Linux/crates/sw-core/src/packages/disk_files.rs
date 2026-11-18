//! Read-only view of one package directory on disk. Ported from
//! `DiskPackageFiles.cs`. This is what the `$file` API of the shared engine
//! reads through (`package.read` and `package.exists` in the executor).

use std::path::{Path, PathBuf};

use super::error::{PackageError, codes};
use super::limits::{MAX_BINARY_READ_BYTES, MAX_FILE_COUNT, MAX_PATH_DEPTH, MAX_SCRIPT_BYTES, MAX_TEXT_BYTES};
use super::{path_rules, safe_files};
use crate::compiler::is_text_file;
use crate::package_files::PackageFiles;

/// Read-only view of one package directory on disk.
///
/// Every path is package-relative and must already be normalized. A path is
/// refused (reported as missing) when it is absolute, contains a backslash,
/// NUL, `.`/`..` or empty component, names a dot-file or the generated
/// `__Build` cache, crosses a symbolic link at any component, has a case or
/// Unicode-normalization alias in its directory, is a hard-linked or special
/// file, or would resolve outside the root. Files are opened relative to the
/// package directory without following links (see `safe_files`), and reads
/// are size-bounded while reading.
#[derive(Debug, Clone)]
pub struct DiskPackageFiles {
    root: PathBuf,
}

impl DiskPackageFiles {
    pub fn new(root: impl AsRef<Path>) -> Self {
        Self { root: safe_files::root(root.as_ref()) }
    }

    /// Regular files of the package as sorted, normalized relative paths.
    /// Dot-files and dot-directories, `__Build`, links, special files,
    /// hard-linked files, ambiguous spellings, names that are not UTF-8 and
    /// anything deeper than 16 components are left out.
    ///
    /// Fails with `too_many_entries` when the package holds more than 500 files.
    pub fn list(&self) -> Result<Vec<String>, PackageError> {
        let mut result = Vec::new();
        if safe_files::real_directory(&self.root) {
            collect(&self.root, "", 1, &mut result)?;
        }
        result.sort_unstable();
        Ok(result)
    }

    /// Bytes of a file with an explicit bound, for callers with their own limit (manifest, export).
    pub fn read_bytes_up_to(&self, path: &str, maximum_bytes: u64) -> Option<Vec<u8>> {
        let parts = path_rules::visible_components(path)?;
        safe_files::read_bounded(safe_files::existing_file(&self.root, &parts)?, maximum_bytes)
    }
}

impl PackageFiles for DiskPackageFiles {
    /// [`DiskPackageFiles::list`]; a package with too many files lists as
    /// empty, so that it cannot be compiled or run.
    fn paths(&self) -> Vec<String> {
        self.list().unwrap_or_default()
    }

    /// True only for a readable regular file inside the package that passes every rule in the type's description.
    fn exists(&self, path: &str) -> bool {
        path_rules::visible_components(path).is_some_and(|parts| safe_files::existing_file(&self.root, &parts).is_some())
    }

    /// UTF-8 text of a text-like file (per [`is_text_file`]), or `None` when
    /// the file is missing, refused, binary, not valid UTF-8, or larger than
    /// 512 KiB for scripts and 2 MiB for other text.
    fn read_text(&self, path: &str) -> Option<String> {
        if !is_text_file(path) {
            return None;
        }
        let limit = if is_script_file(path) { MAX_SCRIPT_BYTES } else { MAX_TEXT_BYTES };
        safe_files::decode_utf8(self.read_bytes_up_to(path, limit as u64)?)
    }

    /// Bytes of a file, or `None` when it is missing, refused, or larger than 16 MiB.
    fn read_bytes(&self, path: &str) -> Option<Vec<u8>> {
        self.read_bytes_up_to(path, MAX_BINARY_READ_BYTES as u64)
    }
}

/// `.js`, `.jsx` or `.mjs` in any case.
fn is_script_file(path: &str) -> bool {
    path.rsplit_once('.').is_some_and(|(_, extension)| ["js", "jsx", "mjs"].iter().any(|known| extension.eq_ignore_ascii_case(known)))
}

fn collect(directory: &Path, prefix: &str, depth: usize, result: &mut Vec<String>) -> Result<(), PackageError> {
    if depth > MAX_PATH_DEPTH {
        return Ok(());
    }
    let Some(listing) = safe_files::names(directory) else { return Ok(()) };
    for name in &listing.names {
        if path_rules::is_excluded(name) || !path_rules::valid_component(name) || !safe_files::unambiguous(&listing.names, name) {
            continue;
        }
        let child = safe_files::child(directory, name);
        let Some(entry) = safe_files::attributes(&child) else { continue };
        if entry.is_directory {
            collect(&child, &format!("{prefix}{name}/"), depth + 1, result)?;
        } else if entry.is_private_regular_file() {
            result.push(format!("{prefix}{name}"));
            if result.len() > MAX_FILE_COUNT {
                return Err(PackageError::new(codes::TOO_MANY_ENTRIES, "Package contains too many entries."));
            }
        }
    }
    Ok(())
}
