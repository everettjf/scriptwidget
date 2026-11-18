//! Package-relative path rules, ported from `PackagePathRules.cs`, itself
//! `ScriptWidgetPackageFiles.components` in Swift.
//!
//! As on Android, the names that only Win32 cannot store (reserved device
//! names, a trailing dot or space, `< > " | ? *`) are ordinary names here.

use super::limits::{MAX_COMPONENT_BYTES, MAX_PATH_DEPTH};
use super::names;
use crate::package_files::normalize_package_path;

/// Splits a package-relative path into components, or returns `None` when it is unsafe.
///
/// The path must already be in normal form: no leading slash, no empty, `.`
/// or `..` component, no backslash and no NUL (so nothing can name a location
/// outside the package), no Windows drive prefix, at most 16 components of at
/// most 255 UTF-8 bytes each, and no control characters.
pub fn components(relative: &str) -> Option<Vec<&str>> {
    let normalized = normalize_package_path(Some(relative))?;
    if normalized != relative || names::has_drive_prefix(relative) {
        return None;
    }
    let parts: Vec<&str> = relative.split('/').collect();
    (parts.len() <= MAX_PATH_DEPTH && parts.iter().all(|part| valid_component(part))).then_some(parts)
}

/// [`components`], additionally refusing dot-files and the generated
/// `__Build` cache at any depth. Those are never part of the authored
/// package, so they are neither listed, read nor written.
pub fn visible_components(relative: &str) -> Option<Vec<&str>> {
    components(relative).filter(|parts| !parts.iter().any(|part| is_excluded(part)))
}

pub fn valid_component(part: &str) -> bool {
    !part.is_empty() && part != "." && part != ".." && !part.contains('/') && !part.contains('\\') && part.len() <= MAX_COMPONENT_BYTES && !names::has_control_characters(part)
}

pub fn is_excluded(part: &str) -> bool {
    part.starts_with('.') || names::identity(part) == "__build"
}
