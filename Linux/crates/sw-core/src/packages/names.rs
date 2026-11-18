//! Package (library directory) names, ported from `PackageNames.cs`, itself
//! `validPackageName` in `manifest.js` and `ScriptWidgetPackageName.isValid`
//! in Swift.
//!
//! The rules are those of the Android port. The Windows port also refuses the
//! names Win32 cannot store (a colon, a trailing dot, `CON` and so on); Linux
//! stores them like any other name, and Android accepts them, so they are
//! accepted here too.

use unicode_normalization::UnicodeNormalization;
use unicode_properties::{GeneralCategory, UnicodeGeneralCategory};
use unicode_segmentation::UnicodeSegmentation;

use super::limits::{MAX_NAME_BYTES, MAX_NAME_GRAPHEMES};

/// The identity two names share when a case-insensitive or normalizing
/// filesystem would treat them as one entry: NFC, then case folding
/// (`ScriptWidgetPackageFiles.identity`).
///
/// A Linux filesystem keeps `Main.jsx` and `main.jsx` as two files; the
/// package would then lose one of them on macOS, Windows or an Android SD
/// card, so the two are one identity here as well. The fold goes through
/// upper case first, as the Windows port does because NTFS compares names
/// that way: the long s and the Kelvin sign meet their ASCII letters. Rust's
/// full case mappings fold a little more than .NET's simple ones (`ß` meets
/// `ss`), which only makes more spellings collide.
pub fn identity(name: &str) -> String {
    name.nfc().collect::<String>().to_uppercase().to_lowercase()
}

/// True when `name` may be used as a package name and directory name.
///
/// Rejects blank names, a leading dot (hidden files, `.`/`..`), the reserved
/// `__Build` cache name in any case, path separators, Windows drive prefixes,
/// and control/format characters other than ZWNJ/ZWJ, so a display name can
/// never become a traversal or a cache path. Length is bounded to 80 grapheme
/// clusters and 240 UTF-8 bytes.
pub fn is_valid(name: &str) -> bool {
    if name.trim().is_empty() || name.starts_with('.') {
        return false;
    }
    if identity(name) == "__build" || name.contains('/') || name.contains('\\') || has_drive_prefix(name) {
        return false;
    }
    if has_control_characters(name) {
        return false;
    }
    grapheme_count(name) <= MAX_NAME_GRAPHEMES && name.len() <= MAX_NAME_BYTES
}

/// `^[A-Za-z]:`, which Windows reads as a drive.
pub(crate) fn has_drive_prefix(text: &str) -> bool {
    let bytes = text.as_bytes();
    bytes.len() >= 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':'
}

/// Control or format characters, except ZWNJ/ZWJ, which joined emoji and some scripts need.
pub fn has_control_characters(text: &str) -> bool {
    text.chars().any(|character| {
        !matches!(character, '\u{200C}' | '\u{200D}') && matches!(character.general_category(), GeneralCategory::Control | GeneralCategory::Format)
    })
}

pub fn grapheme_count(text: &str) -> usize {
    text.graphemes(true).count()
}

/// `name` followed by `suffix`, with the stem shortened by whole grapheme
/// clusters until the result fits the name limits. This is the truncation
/// `getValidPackageName` and `duplicateScript` apply in Swift.
pub fn with_suffix(name: &str, suffix: &str) -> String {
    let bounds: Vec<usize> = name.grapheme_indices(true).map(|(start, _)| start).chain([name.len()]).collect();
    let mut keep = (bounds.len() - 1).min(MAX_NAME_GRAPHEMES.saturating_sub(grapheme_count(suffix)));
    while keep > 0 && bounds[keep] + suffix.len() > MAX_NAME_BYTES {
        keep -= 1;
    }
    format!("{}{suffix}", &name[..bounds[keep]])
}

/// `WidgetPackageManifest.legacy`: the identifier of a package that had no `widget.json`.
pub fn legacy_id(name: &str) -> String {
    let mut slug = String::new();
    let mut gap = false;
    for character in name.to_lowercase().chars() {
        if character.is_ascii_lowercase() || character.is_ascii_digit() {
            if gap && !slug.is_empty() {
                slug.push('-');
            }
            gap = false;
            slug.push(character);
        } else {
            gap = true;
        }
    }
    format!("legacy.{}", if slug.is_empty() { "widget" } else { &slug })
}

/// `packageDirectoryName` in `archive.js`: a root directory name every
/// platform's importer accepts. At most 80 UTF-16 units, as there.
pub fn archive_root_name(name: &str) -> String {
    let replaced: String = name.chars().map(|character| if matches!(character, '\\' | '/' | ':' | '*' | '?' | '"' | '<' | '>' | '|' | '\0') { '-' } else { character }).collect();
    let mut cleaned = String::new();
    let mut units = 0;
    for character in replaced.trim_start_matches('.').trim().chars() {
        units += character.len_utf16();
        if units > 80 {
            break;
        }
        cleaned.push(character);
    }
    if cleaned.is_empty() { "Widget".into() } else { cleaned }
}
