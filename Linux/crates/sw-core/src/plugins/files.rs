//! Link-refusing filesystem primitives of the plugin store, and the reader
//! and writer of `.swplugin` archives. Ported from
//! `Windows/src/ScriptWidget.Core/Plugins/PluginFiles.cs`.
//!
//! Every lookup looks at the entry itself, so a symbolic link is seen as a
//! link and never as its target. A check and the following open are separate
//! system calls; the opened file is checked again before anything is read.
//! Plugin directories live in the user's private data directory.

use std::collections::{HashMap, HashSet};
use std::io::{Read, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

use crate::api::support::is_control_or_format;
use crate::plugins::manifest::PluginError;

/// Most directory entries listed before a listing fails closed.
const MAXIMUM_DIRECTORY_ENTRIES: usize = 100_000;

/// A directory could not be staged or published; the message is safe to show.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StorageError(pub String);

/// True when something, including a dangling link, occupies `path`.
pub fn occupied(path: &Path) -> bool {
    std::fs::symlink_metadata(path).is_ok()
}

/// True when `path` is a real directory rather than a link to one.
pub fn real_directory(path: &Path) -> bool {
    std::fs::symlink_metadata(path).is_ok_and(|metadata| metadata.file_type().is_dir())
}

/// Entry names of `directory`, or `None` when it cannot be listed or is
/// implausibly large. A name that is not UTF-8 is listed in a form that
/// matches no name the store asks for.
pub fn names(directory: &Path) -> Option<Vec<String>> {
    let mut result = Vec::new();
    for entry in std::fs::read_dir(directory).ok()? {
        result.push(entry.ok()?.file_name().to_string_lossy().into_owned());
        if result.len() > MAXIMUM_DIRECTORY_ENTRIES {
            return None;
        }
    }
    Some(result)
}

/// The identity two names share when a case-insensitive or normalizing
/// filesystem would treat them as one entry: NFC, then lower case.
pub fn identity(name: &str) -> String {
    icu_normalizer::ComposingNormalizerBorrowed::new_nfc().normalize(name).to_lowercase()
}

/// Resolves `name` directly below `directory` to an existing regular file, or
/// `None`. The name must be spelled exactly as stored, must not be a link and
/// must not have a case or Unicode-form alias.
pub fn existing_file(directory: &Path, name: &str) -> Option<PathBuf> {
    if !real_directory(directory) || name.contains('/') {
        return None;
    }
    let siblings = names(directory)?;
    let wanted = identity(name);
    if !siblings.iter().any(|sibling| sibling == name) || siblings.iter().any(|sibling| sibling != name && identity(sibling) == wanted) {
        return None;
    }
    let child = directory.join(name);
    std::fs::symlink_metadata(&child).ok().filter(|metadata| metadata.file_type().is_file()).map(|_| child)
}

/// Reads `file`, or returns `None` when it holds more than `maximum_bytes`,
/// is not a regular file, is a link, or has more than one hard link: a second
/// link could expose or alter a file outside the plugin.
pub fn read_bounded(file: &Path, maximum_bytes: usize) -> Option<Vec<u8>> {
    // O_NONBLOCK: opening a FIFO that someone put in the way must not hang.
    let opened = std::fs::OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC).open(file).ok()?;
    let metadata = opened.metadata().ok()?;
    if !metadata.is_file() || metadata.nlink() > 1 {
        return None;
    }
    // The size is counted while reading, never taken from metadata that may change.
    let mut bytes = Vec::new();
    opened.take(maximum_bytes as u64 + 1).read_to_end(&mut bytes).ok()?;
    (bytes.len() <= maximum_bytes).then_some(bytes)
}

/// Creates `file` exclusively, readable by the user only, writes `bytes` and flushes them to storage.
pub fn write_new(file: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let mut output = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).custom_flags(libc::O_NOFOLLOW).open(file)?;
    output.write_all(bytes)?;
    output.sync_all()
}

/// Creates a private directory; the parents must exist.
pub fn create_private_directory(path: &Path) -> std::io::Result<()> {
    std::fs::DirBuilder::new().mode(0o700).create(path)
}

/// Creates a uniquely named private working directory below `staging_root`.
pub fn new_work_directory(staging_root: &Path, prefix: &str) -> Result<PathBuf, StorageError> {
    let unavailable = || StorageError("The staging directory is unavailable.".into());
    if !occupied(staging_root) {
        create_private_directory(staging_root).map_err(|_| unavailable())?;
    }
    if !real_directory(staging_root) {
        return Err(unavailable());
    }
    let mut random = [0u8; 16];
    getrandom::fill(&mut random).map_err(|_| unavailable())?;
    let name: String = random.iter().map(|byte| format!("{byte:02x}")).collect();
    let path = staging_root.join(format!("{prefix}-{name}"));
    // Fails when the name is taken, by a link or by anything else.
    create_private_directory(&path).map_err(|_| unavailable())?;
    Ok(path)
}

/// Publishes a prepared directory with one rename, so observers see either
/// nothing or the complete plugin. `destination` must be free; callers hold
/// the store lock.
pub fn publish(prepared: &Path, destination: &Path) -> Result<(), StorageError> {
    if occupied(destination) {
        return Err(StorageError("A package with this name already exists.".into()));
    }
    std::fs::rename(prepared, destination).map_err(|_| StorageError("The package could not be published.".into()))
}

/// Removes `path` and everything below it. Links are removed, never followed. Best effort.
pub fn delete_tree(path: &Path) {
    let Ok(metadata) = std::fs::symlink_metadata(path) else { return };
    // Leftovers stay inside the private staging directory and are retried by later cleanups.
    let _ = if metadata.file_type().is_dir() { std::fs::remove_dir_all(path) } else { std::fs::remove_file(path) };
}

// MARK: - Archives

/// One central-directory entry that passed validation. `parts` are the non-empty path components.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ArchiveEntry {
    pub name: String,
    pub parts: Vec<String>,
    pub is_directory: bool,
    pub uncompressed_size: u64,
    pub crc: u32,
    compressed_size: u64,
    method: u16,
    local_header: u64,
    /// Where the central directory starts: no entry's data may reach into it.
    data_end: u64,
}

// ScriptPackageArchivePolicy.
const MAXIMUM_ARCHIVE_BYTES: usize = 32 * 1024 * 1024;
const MAXIMUM_EXPANDED_BYTES: u64 = 64 * 1024 * 1024;
const MAXIMUM_FILE_BYTES: u64 = 25 * 1024 * 1024;
const MAXIMUM_FILE_COUNT: usize = 500;
const MAXIMUM_PATH_DEPTH: usize = 16;
const MAXIMUM_COMPONENT_BYTES: usize = 255;

const END_SIGNATURE: u64 = 0x0605_4B50;
const CENTRAL_SIGNATURE: u64 = 0x0201_4B50;
const LOCAL_SIGNATURE: u64 = 0x0403_4B50;
const UINT32_MAX: u64 = 0xFFFF_FFFF;

fn u16_at(data: &[u8], index: usize) -> u64 {
    data.get(index..index + 2).map_or(0, |bytes| u64::from(u16::from_le_bytes([bytes[0], bytes[1]])))
}

fn u32_at(data: &[u8], index: usize) -> u64 {
    data.get(index..index + 4).map_or(0, |bytes| u64::from(u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]])))
}

fn u64_at(data: &[u8], index: usize) -> u64 {
    u32_at(data, index) | (u32_at(data, index + 4) << 32)
}

/// Validates the whole archive and returns its entries.
///
/// Rejected: empty or oversized archives; a missing, multi-disk,
/// trailing-garbage or out-of-bounds central directory; more entries than
/// allowed; encrypted entries; compression other than stored/deflate;
/// malformed ZIP64 sizes; entry names that are not UTF-8, are absolute,
/// contain a backslash, colon, NUL, control character, `.` or `..` component,
/// or nest too deeply; duplicate, case-colliding or file-versus-directory
/// clashing paths; symbolic links and other special files; a declared file
/// size or declared total above the limits; and a large file that claims zero
/// compressed bytes. Validation inspects bytes only and never inflates or
/// writes anything.
pub fn validate_archive(data: &[u8]) -> Result<Vec<ArchiveEntry>, PluginError> {
    let fail = |message: String| PluginError::invalid(message);
    if data.is_empty() || data.len() > MAXIMUM_ARCHIVE_BYTES {
        return Err(fail("Archive must be between 1 byte and 32 MiB.".into()));
    }
    let end = end_of_central_directory(data).ok_or_else(|| fail("Archive has no valid ZIP central directory.".into()))?;
    if u16_at(data, end + 4) != 0 || u16_at(data, end + 6) != 0 || u16_at(data, end + 8) != u16_at(data, end + 10) {
        return Err(fail("Multi-disk ZIP archives are not supported.".into()));
    }
    if end as u64 + 22 + u16_at(data, end + 20) != data.len() as u64 {
        return Err(fail("Archive has a malformed ZIP footer.".into()));
    }
    let count = u16_at(data, end + 10) as usize;
    let central_size = u32_at(data, end + 12);
    let central_offset = u32_at(data, end + 16);
    if count == 0 || count > MAXIMUM_FILE_COUNT {
        return Err(fail(format!("Archive must contain 1–{MAXIMUM_FILE_COUNT} entries.")));
    }
    if central_offset + central_size > data.len() as u64 {
        return Err(fail("Archive central directory is out of bounds.".into()));
    }

    let mut cursor = central_offset as usize;
    let mut expanded = 0u64;
    let mut collisions = Collisions::default();
    let mut entries = Vec::with_capacity(count);
    for _ in 0..count {
        if cursor + 46 > data.len() || u32_at(data, cursor) != CENTRAL_SIGNATURE {
            return Err(fail("Archive central directory contains an invalid entry.".into()));
        }
        let flags = u16_at(data, cursor + 8);
        let method = u16_at(data, cursor + 10);
        let crc = u32_at(data, cursor + 16);
        let name_length = u16_at(data, cursor + 28) as usize;
        let extra_length = u16_at(data, cursor + 30) as usize;
        let comment_length = u16_at(data, cursor + 32) as usize;
        let external = u32_at(data, cursor + 38);
        let local_header = u32_at(data, cursor + 42);
        let entry_end = cursor + 46 + name_length + extra_length + comment_length;
        if name_length == 0 || entry_end > data.len() {
            return Err(fail("Archive contains a truncated filename.".into()));
        }
        let extra_start = cursor + 46 + name_length;
        let Some((compressed, uncompressed)) = resolved_sizes(u32_at(data, cursor + 20), u32_at(data, cursor + 24), data, extra_start, extra_start + extra_length) else {
            return Err(fail("Archive contains malformed ZIP64 size metadata.".into()));
        };
        if flags & 0x1 != 0 {
            return Err(fail("Encrypted package entries are not supported.".into()));
        }
        if method != 0 && method != 8 {
            return Err(fail(format!("Unsupported ZIP compression method {method}.")));
        }
        let name = std::str::from_utf8(&data[cursor + 46..cursor + 46 + name_length]).ok();
        let parts = name.and_then(|name| entry_parts(name, MAXIMUM_PATH_DEPTH));
        let (Some(name), Some(parts)) = (name, parts) else { return Err(fail("Archive contains an unsafe or non-UTF-8 path.".into())) };
        let is_directory = name.ends_with('/');
        if !collisions.add(name, &parts, is_directory) {
            return Err(fail("Archive contains duplicate or case-colliding paths.".into()));
        }
        // Unix mode in the high half: only regular files (0x8000), directories (0x4000) or
        // an absent type are accepted; 0xA000 is a symbolic link.
        let kind = (external >> 16) & 0xF000;
        if kind == 0xA000 {
            return Err(fail("Symbolic links are not allowed in ScriptWidget packages.".into()));
        }
        if kind != 0 && kind != 0x8000 && kind != 0x4000 {
            return Err(fail("Only regular files and directories are allowed in ScriptWidget packages.".into()));
        }
        if !is_directory {
            if uncompressed > MAXIMUM_FILE_BYTES {
                return Err(fail(format!("Package file {name} exceeds 25 MiB.")));
            }
            expanded += uncompressed;
            if expanded > MAXIMUM_EXPANDED_BYTES {
                return Err(fail("Expanded package exceeds 64 MiB.".into()));
            }
            if uncompressed > 1024 * 1024 && compressed == 0 {
                return Err(fail(format!("Archive entry {name} has an invalid compression ratio.")));
            }
        }
        entries.push(ArchiveEntry {
            name: name.to_owned(),
            parts,
            is_directory,
            uncompressed_size: uncompressed,
            crc: crc as u32,
            compressed_size: compressed,
            method: method as u16,
            local_header,
            data_end: central_offset,
        });
        cursor = entry_end;
    }
    if cursor as u64 != central_offset + central_size {
        return Err(fail("Archive entries do not match the declared central directory.".into()));
    }
    Ok(entries)
}

/// The archive does not hold what its directory says.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CorruptArchive;

/// Inflates one validated entry in memory, counting real bytes so false size
/// headers cannot expand, and checks its CRC-32. Fails when the entry is
/// missing, does not match its declared size or checksum, or exceeds
/// `maximum_bytes`.
pub fn inflate(archive: &[u8], entry: &ArchiveEntry, maximum_bytes: usize) -> Result<Vec<u8>, CorruptArchive> {
    if entry.is_directory || entry.uncompressed_size > maximum_bytes as u64 {
        return Err(CorruptArchive);
    }
    let header = usize::try_from(entry.local_header).map_err(|_| CorruptArchive)?;
    if header.checked_add(30).is_none_or(|end| end > archive.len()) || u32_at(archive, header) != LOCAL_SIGNATURE {
        return Err(CorruptArchive);
    }
    let start = header as u64 + 30 + u16_at(archive, header + 26) + u16_at(archive, header + 28);
    let end = start.checked_add(entry.compressed_size).filter(|end| *end <= entry.data_end && *end <= archive.len() as u64).ok_or(CorruptArchive)?;
    let stored = &archive[start as usize..end as usize];
    let declared = entry.uncompressed_size as usize;
    let output = match entry.method {
        0 if stored.len() == declared => stored.to_vec(),
        8 => {
            let mut output = Vec::with_capacity(declared.min(64 * 1024));
            // One byte more than declared is enough to see that the declaration is false.
            flate2::read::DeflateDecoder::new(stored).take(declared as u64 + 1).read_to_end(&mut output).map_err(|_| CorruptArchive)?;
            output
        }
        _ => return Err(CorruptArchive),
    };
    if output.len() != declared || crc32(&output) != entry.crc {
        return Err(CorruptArchive);
    }
    Ok(output)
}

/// A ZIP archive of deflated regular files with fixed timestamps, so the same input always gives the same bytes.
pub fn write_archive(files: &[(&str, &[u8])]) -> std::io::Result<Vec<u8>> {
    let mut output: Vec<u8> = Vec::new();
    let mut central: Vec<u8> = Vec::new();
    for (name, bytes) in files {
        let mut encoder = flate2::write::DeflateEncoder::new(Vec::new(), flate2::Compression::best());
        encoder.write_all(bytes)?;
        let compressed = encoder.finish()?;
        let offset = output.len() as u32;
        let crc = crc32(bytes);
        // Version 2.0, UTF-8 names, deflate, 1980-01-01 00:00.
        let shared: Vec<u8> = [20u16.to_le_bytes(), 0x0800u16.to_le_bytes(), 8u16.to_le_bytes(), 0u16.to_le_bytes(), 0x0021u16.to_le_bytes()].concat();
        let sizes: Vec<u8> = [crc.to_le_bytes(), (compressed.len() as u32).to_le_bytes(), (bytes.len() as u32).to_le_bytes()].concat();
        output.extend_from_slice(&(LOCAL_SIGNATURE as u32).to_le_bytes());
        output.extend_from_slice(&shared);
        output.extend_from_slice(&sizes);
        output.extend_from_slice(&(name.len() as u16).to_le_bytes());
        output.extend_from_slice(&0u16.to_le_bytes());
        output.extend_from_slice(name.as_bytes());
        output.extend_from_slice(&compressed);

        central.extend_from_slice(&(CENTRAL_SIGNATURE as u32).to_le_bytes());
        central.extend_from_slice(&0x031Eu16.to_le_bytes()); // made on Unix
        central.extend_from_slice(&shared);
        central.extend_from_slice(&sizes);
        central.extend_from_slice(&(name.len() as u16).to_le_bytes());
        central.extend_from_slice(&[0u8; 8]); // extra, comment, disk, internal attributes
        central.extend_from_slice(&(0o100644u32 << 16).to_le_bytes());
        central.extend_from_slice(&offset.to_le_bytes());
        central.extend_from_slice(name.as_bytes());
    }
    let central_offset = output.len() as u32;
    output.extend_from_slice(&central);
    output.extend_from_slice(&(END_SIGNATURE as u32).to_le_bytes());
    output.extend_from_slice(&[0u8; 4]);
    output.extend_from_slice(&(files.len() as u16).to_le_bytes());
    output.extend_from_slice(&(files.len() as u16).to_le_bytes());
    output.extend_from_slice(&(central.len() as u32).to_le_bytes());
    output.extend_from_slice(&central_offset.to_le_bytes());
    output.extend_from_slice(&0u16.to_le_bytes());
    Ok(output)
}

/// Components of an archive entry name, or `None` when the name is unsafe: a
/// leading slash, any backslash, colon or NUL, a `.`/`..` component, a
/// component that is too long or holds control characters, no components, or
/// more than `maximum_depth`.
pub fn entry_parts(name: &str, maximum_depth: usize) -> Option<Vec<String>> {
    if name.starts_with('/') || name.contains(['\\', ':', '\0']) {
        return None;
    }
    let parts: Vec<&str> = name.split('/').filter(|part| !part.is_empty()).collect();
    if parts.is_empty() || parts.len() > maximum_depth || !parts.iter().all(|part| valid_component(part)) {
        return None;
    }
    Some(parts.into_iter().map(str::to_owned).collect())
}

/// No control or format characters, except ZWNJ and ZWJ, which joined emoji and some scripts need.
fn valid_component(part: &str) -> bool {
    !part.is_empty() && part != "." && part != ".." && part.len() <= MAXIMUM_COMPONENT_BYTES && !part.chars().any(|character| !matches!(character, '\u{200c}' | '\u{200d}') && is_control_or_format(character))
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
    fn add(&mut self, name: &str, parts: &[String], is_directory: bool) -> bool {
        if !self.full_paths.insert(identity(name).trim_matches('/').to_owned()) {
            return false;
        }
        let mut path = String::new();
        for (index, part) in parts.iter().enumerate() {
            if index > 0 {
                path.push('/');
            }
            path.push_str(part);
            if self.spellings.entry(identity(&path)).or_insert_with(|| path.clone()) != &path {
                return false;
            }
            let directory = index < parts.len() - 1 || is_directory;
            if *self.directories.entry(path.clone()).or_insert(directory) != directory {
                return false;
            }
        }
        true
    }
}

fn resolved_sizes(compressed32: u64, uncompressed32: u64, data: &[u8], extra_start: usize, extra_end: usize) -> Option<(u64, u64)> {
    if compressed32 != UINT32_MAX && uncompressed32 != UINT32_MAX {
        return Some((compressed32, uncompressed32));
    }
    let mut compressed = compressed32;
    let mut uncompressed = uncompressed32;
    let mut cursor = extra_start;
    while cursor + 4 <= extra_end {
        let identifier = u16_at(data, cursor);
        let end = cursor + 4 + u16_at(data, cursor + 2) as usize;
        if end > extra_end {
            return None;
        }
        if identifier == 0x0001 {
            let mut value = cursor + 4;
            if uncompressed32 == UINT32_MAX {
                if value + 8 > end {
                    return None;
                }
                uncompressed = u64_at(data, value);
                value += 8;
            }
            if compressed32 == UINT32_MAX {
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

fn end_of_central_directory(data: &[u8]) -> Option<usize> {
    if data.len() < 22 {
        return None;
    }
    let lower_bound = data.len().saturating_sub(65_557);
    (lower_bound..=data.len() - 22).rev().find(|index| u32_at(data, *index) == END_SIGNATURE)
}

pub fn crc32(data: &[u8]) -> u32 {
    let mut crc = 0xFFFF_FFFFu32;
    for byte in data {
        crc ^= u32::from(*byte);
        for _ in 0..8 {
            crc = if crc & 1 != 0 { 0xEDB8_8320 ^ (crc >> 1) } else { crc >> 1 };
        }
    }
    crc ^ 0xFFFF_FFFF
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identities_fold_case_and_unicode_form() {
        assert_eq!(identity("README.md"), identity("readme.MD"));
        assert_eq!(identity("caf\u{e9}"), identity("CAFE\u{301}"));
        assert_ne!(identity("plugin.json"), identity("plugin.jsan"));
    }

    #[test]
    fn entry_names_must_stay_inside_the_archive_root() {
        assert_eq!(entry_parts("Test/plugin.json", 16), Some(vec!["Test".to_owned(), "plugin.json".to_owned()]));
        assert_eq!(entry_parts("Test//a/", 16), Some(vec!["Test".to_owned(), "a".to_owned()]));
        assert!(entry_parts("👨\u{200d}👩\u{200d}👧.txt", 16).is_some());
        let long = "x".repeat(256);
        for name in ["/a", "a\\b", "C:a", "a\0b", "../a", "a/../b", "a/./b", "", "/", "a\u{202e}b", "a\nb", "a\u{feff}", long.as_str(), "1/2/3/4/5/6/7/8/9/10/11/12/13/14/15/16/17"] {
            assert_eq!(entry_parts(name, 16), None, "{name:?}");
        }
    }

    #[test]
    fn written_archives_validate_and_inflate() {
        assert_eq!(crc32(b"123456789"), 0xCBF4_3926);
        let text = "plugin ".repeat(1000);
        let archive = write_archive(&[("plugin.json", text.as_bytes()), ("README.md", b"")]).unwrap();
        assert_eq!(archive, write_archive(&[("plugin.json", text.as_bytes()), ("README.md", b"")]).unwrap());
        assert!(archive.len() < text.len() / 10);
        let entries = validate_archive(&archive).unwrap();
        assert_eq!(entries.iter().map(|entry| entry.name.as_str()).collect::<Vec<_>>(), ["plugin.json", "README.md"]);
        assert_eq!(inflate(&archive, &entries[0], 1 << 20).unwrap(), text.as_bytes());
        assert_eq!(inflate(&archive, &entries[1], 1 << 20).unwrap(), b"");
        assert_eq!(inflate(&archive, &entries[0], 100), Err(CorruptArchive));
    }
}
