//! Central-directory validation of an untrusted `.swt` archive, ported from
//! `ArchivePreflight.cs`, itself `ScriptPackageArchivePreflight.validate` in
//! Swift (and `preflightArchive` in `archive.js`). It inspects bytes only and
//! never inflates or writes anything.

use std::collections::{HashMap, HashSet};

use super::error::{PackageError, codes};
use super::limits::ArchiveLimits;
use super::{names, path_rules};

/// One central-directory entry that passed validation.
#[derive(Debug, Clone)]
pub(crate) struct Entry {
    pub name: String,
    /// The non-empty path components.
    pub parts: Vec<String>,
    pub is_directory: bool,
    pub uncompressed_size: u64,
    pub compressed_size: u64,
    pub crc: u32,
    /// 0 (stored) or 8 (deflate).
    pub method: u16,
    /// Offset of the entry's local header as the central directory states it; checked when the entry is read.
    pub local_header_offset: u64,
}

const END_SIGNATURE: u64 = 0x0605_4B50;
const CENTRAL_SIGNATURE: u64 = 0x0201_4B50;
const U32_MAX: u64 = 0xFFFF_FFFF;

/// Validates the whole archive and returns its entries.
///
/// Rejected: empty or oversized archives; a missing, multi-disk,
/// trailing-garbage or out-of-bounds central directory; more entries than
/// allowed; encrypted entries; compression other than stored/deflate;
/// malformed ZIP64 sizes; entry names that are not UTF-8, are absolute,
/// contain a backslash, colon, NUL, control character, `.` or `..`
/// component, or nest too deeply; duplicate, case-colliding or
/// file-versus-directory clashing paths; symbolic links and other special
/// files; a declared file size or declared total above the limits; and a
/// large file that claims zero compressed bytes.
pub(crate) fn validate(data: &[u8], limits: &ArchiveLimits) -> Result<Vec<Entry>, PackageError> {
    if data.is_empty() || data.len() > limits.maximum_archive_bytes {
        return Err(fail(codes::ARCHIVE_SIZE, "Archive must be between 1 byte and 32 MiB."));
    }
    let end = end_of_central_directory(data).ok_or_else(|| fail(codes::ARCHIVE_MALFORMED, "Archive has no valid ZIP central directory."))?;
    if u16_at(data, end + 4) != 0 || u16_at(data, end + 6) != 0 || u16_at(data, end + 8) != u16_at(data, end + 10) {
        return Err(fail(codes::ARCHIVE_MULTI_DISK, "Multi-disk ZIP archives are not supported."));
    }
    if end + 22 + usize::from(u16_at(data, end + 20)) != data.len() {
        return Err(fail(codes::ARCHIVE_MALFORMED, "Archive has a malformed ZIP footer."));
    }
    let count = usize::from(u16_at(data, end + 10));
    let central_size = u32_at(data, end + 12);
    let central_offset = u32_at(data, end + 16);
    if count == 0 || count > limits.maximum_file_count {
        return Err(fail(codes::ARCHIVE_TOO_MANY_ENTRIES, format!("Archive must contain 1–{} entries.", limits.maximum_file_count)));
    }
    if central_offset + central_size > data.len() as u64 {
        return Err(fail(codes::ARCHIVE_MALFORMED, "Archive central directory is out of bounds."));
    }

    let mut cursor = central_offset as usize;
    let mut expanded = 0u64;
    let mut collisions = Collisions::default();
    let mut entries = Vec::with_capacity(count);
    for _ in 0..count {
        if cursor + 46 > data.len() || u32_at(data, cursor) != CENTRAL_SIGNATURE {
            return Err(fail(codes::ARCHIVE_MALFORMED, "Archive central directory contains an invalid entry."));
        }
        let flags = u16_at(data, cursor + 8);
        let method = u16_at(data, cursor + 10);
        let crc = u32_at(data, cursor + 16) as u32;
        let name_length = usize::from(u16_at(data, cursor + 28));
        let extra_length = usize::from(u16_at(data, cursor + 30));
        let comment_length = usize::from(u16_at(data, cursor + 32));
        let external = u32_at(data, cursor + 38);
        let entry_end = cursor + 46 + name_length + extra_length + comment_length;
        if name_length == 0 || entry_end > data.len() {
            return Err(fail(codes::ARCHIVE_MALFORMED, "Archive contains a truncated filename."));
        }
        let extra_start = cursor + 46 + name_length;
        let (compressed, uncompressed) = resolved_sizes(u32_at(data, cursor + 20), u32_at(data, cursor + 24), data, extra_start, extra_start + extra_length)
            .ok_or_else(|| fail(codes::ARCHIVE_MALFORMED, "Archive contains malformed ZIP64 size metadata."))?;
        if flags & 0x1 != 0 {
            return Err(fail(codes::ARCHIVE_ENCRYPTED, "Encrypted package entries are not supported."));
        }
        if method != 0 && method != 8 {
            return Err(fail(codes::ARCHIVE_UNSUPPORTED_COMPRESSION, format!("Unsupported ZIP compression method {method}.")));
        }
        let unsafe_path = || fail(codes::ARCHIVE_UNSAFE_PATH, "Archive contains an unsafe or non-UTF-8 path.");
        let name = std::str::from_utf8(&data[cursor + 46..cursor + 46 + name_length]).map_err(|_| unsafe_path())?;
        let parts = entry_parts(name, limits.maximum_path_depth).ok_or_else(unsafe_path)?;
        let is_directory = name.ends_with('/');
        if !collisions.add(name, &parts, is_directory) {
            return Err(fail(codes::ARCHIVE_PATH_COLLISION, "Archive contains duplicate or case-colliding paths."));
        }
        // Unix mode in the high half: only regular files (0x8000), directories (0x4000) or
        // an absent type are accepted; 0xA000 is a symbolic link.
        let kind = (external >> 16) & 0xF000;
        if kind == 0xA000 {
            return Err(fail(codes::ARCHIVE_SYMLINK, "Symbolic links are not allowed in ScriptWidget packages."));
        }
        if kind != 0 && kind != 0x8000 && kind != 0x4000 {
            return Err(fail(codes::ARCHIVE_SYMLINK, "Only regular files and directories are allowed in ScriptWidget packages."));
        }
        if !is_directory {
            if uncompressed > limits.maximum_file_bytes {
                return Err(fail(codes::ARCHIVE_FILE_TOO_LARGE, format!("Package file {name} exceeds 25 MiB.")));
            }
            expanded += uncompressed;
            if expanded > limits.maximum_expanded_bytes {
                return Err(fail(codes::ARCHIVE_EXPANDED_TOO_LARGE, "Expanded package exceeds 64 MiB."));
            }
            if uncompressed > 1024 * 1024 && compressed == 0 {
                return Err(fail(codes::ARCHIVE_INVALID_RATIO, format!("Archive entry {name} has an invalid compression ratio.")));
            }
        }
        entries.push(Entry {
            name: name.to_owned(),
            parts: parts.iter().map(|part| part.to_string()).collect(),
            is_directory,
            uncompressed_size: uncompressed,
            compressed_size: compressed,
            crc,
            method,
            local_header_offset: u32_at(data, cursor + 42),
        });
        cursor = entry_end;
    }
    if cursor as u64 != central_offset + central_size {
        return Err(fail(codes::ARCHIVE_MALFORMED, "Archive entries do not match the declared central directory."));
    }
    Ok(entries)
}

/// Components of an archive entry name, or `None` when the name is unsafe: a
/// leading slash, any backslash, colon (drive or stream syntax on Windows) or
/// NUL, a `.`/`..` component, a component that is too long or holds control
/// characters, no components, or more than `maximum_depth`.
pub(crate) fn entry_parts(name: &str, maximum_depth: usize) -> Option<Vec<&str>> {
    if name.starts_with('/') || name.contains('\\') || name.contains(':') || name.contains('\0') {
        return None;
    }
    let parts: Vec<&str> = name.split('/').filter(|part| !part.is_empty()).collect();
    (!parts.is_empty() && parts.len() <= maximum_depth && parts.iter().all(|part| path_rules::valid_component(part))).then_some(parts)
}

/// Tracks every file and directory prefix seen so far. Two spellings of one
/// identity (case or Unicode form), a repeated path, and a path used as both
/// file and directory would overwrite or shadow each other on extraction, so
/// each is a collision.
#[derive(Default)]
struct Collisions {
    full_paths: HashSet<String>,
    spellings: HashMap<String, String>,
    directories: HashMap<String, bool>,
}

impl Collisions {
    fn add(&mut self, name: &str, parts: &[&str], is_directory: bool) -> bool {
        if !self.full_paths.insert(names::identity(name).trim_matches('/').to_owned()) {
            return false;
        }
        let mut path = String::new();
        for (index, part) in parts.iter().enumerate() {
            if index > 0 {
                path.push('/');
            }
            path.push_str(part);
            if self.spellings.entry(names::identity(&path)).or_insert_with(|| path.clone()) != &path {
                return false;
            }
            let directory = index + 1 < parts.len() || is_directory;
            if *self.directories.entry(path.clone()).or_insert(directory) != directory {
                return false;
            }
        }
        true
    }
}

/// The compressed and uncompressed sizes, read from the ZIP64 extra field when a 32-bit field is saturated.
fn resolved_sizes(compressed32: u64, uncompressed32: u64, data: &[u8], extra_start: usize, extra_end: usize) -> Option<(u64, u64)> {
    if compressed32 != U32_MAX && uncompressed32 != U32_MAX {
        return Some((compressed32, uncompressed32));
    }
    let mut compressed = compressed32;
    let mut uncompressed = uncompressed32;
    let mut cursor = extra_start;
    while cursor + 4 <= extra_end {
        let identifier = u16_at(data, cursor);
        let end = cursor + 4 + usize::from(u16_at(data, cursor + 2));
        if end > extra_end {
            return None;
        }
        if identifier == 0x0001 {
            let mut value = cursor + 4;
            if uncompressed32 == U32_MAX {
                if value + 8 > end {
                    return None;
                }
                uncompressed = u64_at(data, value);
                value += 8;
            }
            if compressed32 == U32_MAX {
                if value + 8 > end {
                    return None;
                }
                compressed = u64_at(data, value);
            }
            return Some((compressed, uncompressed));
        }
        cursor = end;
    }
    None
}

/// Offset of the last end-of-central-directory record.
fn end_of_central_directory(data: &[u8]) -> Option<usize> {
    if data.len() < 22 {
        return None;
    }
    let lower_bound = data.len().saturating_sub(65_557);
    (lower_bound..=data.len() - 22).rev().find(|&index| u32_at(data, index) == END_SIGNATURE)
}

/// Little-endian readers; a read past the end yields 0, which no check accepts as a signature.
pub(crate) fn u16_at(data: &[u8], index: usize) -> u16 {
    data.get(index..index + 2).map_or(0, |bytes| u16::from_le_bytes([bytes[0], bytes[1]]))
}

pub(crate) fn u32_at(data: &[u8], index: usize) -> u64 {
    data.get(index..index + 4).map_or(0, |bytes| u64::from(u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]])))
}

fn u64_at(data: &[u8], index: usize) -> u64 {
    data.get(index..index + 8).map_or(0, |bytes| u64::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7]]))
}

fn fail(code: &str, message: impl Into<String>) -> PackageError {
    PackageError::new(code, message)
}
