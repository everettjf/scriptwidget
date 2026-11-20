//! `.swt` (ZIP) import and export with the hardening of the Swift
//! implementation (`ScriptPackageArchivePreflight`,
//! `ScriptManager.importScriptPackage`). Ported from `PackageArchive.cs`.
//!
//! Archives are untrusted. The whole central directory is validated before
//! anything is written; extraction happens in a unique directory under a
//! caller-supplied staging directory; and the sizes an archive declares are
//! never trusted, only the bytes actually inflated.
//!
//! The Windows and Android ports hand the bytes to the platform's ZIP reader
//! after the preflight and compare its view of each entry with the
//! preflight's. Here the entries are read through the preflight's own view of
//! the central directory, so there is one reading of the archive and nothing
//! to compare; only inflating is delegated (to `flate2`).

use std::collections::BTreeMap;
use std::io::{Read, Write};
use std::os::fd::OwnedFd;
use std::path::{Path, PathBuf};

use flate2::Compression;
use flate2::read::DeflateDecoder;
use flate2::write::DeflateEncoder;

use super::disk_files::DiskPackageFiles;
use super::error::{PackageError, codes};
use super::limits::ArchiveLimits;
use super::preflight::{self, Entry, u16_at, u32_at};
use super::{names, path_rules, safe_files, tree};

const MACOS_RESOURCE_DIRECTORY: &str = "__MACOSX";
const LOCAL_SIGNATURE: u64 = 0x0403_4B50;
/// 1980-01-01 00:00:00 as an MS-DOS date; every exported entry carries it.
const FIXED_DATE: u16 = 0x0021;
/// General purpose flag: the name is UTF-8.
const UTF8_FLAG: u16 = 0x0800;

/// A package extracted from an archive into a private staging directory.
/// Nothing is visible in the library until [`ExtractedPackage::move_to`]
/// succeeds; dropping the value removes whatever is still in staging, so a
/// failed or abandoned import leaves nothing behind.
#[derive(Debug)]
pub struct ExtractedPackage {
    directory: PathBuf,
    root_name: Option<String>,
    work_directory: PathBuf,
}

impl ExtractedPackage {
    /// The extracted package root (inside the staging directory until moved).
    pub fn directory(&self) -> &Path {
        &self.directory
    }

    /// Name of the single top-level archive directory, or `None` when files sat at the archive root.
    pub fn root_name(&self) -> Option<&str> {
        self.root_name.as_deref()
    }

    /// Publishes the package with one atomic rename. `destination` must not
    /// exist and must be on the same filesystem as the staging directory.
    pub fn move_to(&self, destination: &Path) -> Result<(), PackageError> {
        safe_files::publish(&self.directory, &safe_files::root(destination))
    }
}

impl Drop for ExtractedPackage {
    fn drop(&mut self) {
        safe_files::delete_tree(&self.work_directory);
    }
}

/// Validates `archive` without extracting it and returns its entry names.
/// Fails with an `archive_*` code for every rule of the preflight.
pub fn preflight(archive: &[u8], limits: &ArchiveLimits) -> Result<Vec<String>, PackageError> {
    Ok(preflight::validate(archive, limits)?.into_iter().map(|entry| entry.name).collect())
}

/// Reads, validates and extracts one package from `input`.
///
/// Steps, each failing closed: read at most the archive byte limit; preflight
/// the complete central directory; pick the package root (files at the
/// archive root, or exactly one top-level directory); extract only that root
/// into a fresh directory under `staging_directory`; verify the extracted
/// tree. Dot-files, `__MACOSX` and `__Build` (generated cache that must never
/// be accepted from an archive) are not extracted. While inflating, bytes are
/// counted and extraction stops as soon as an entry exceeds its declared size
/// or a limit, so a zip bomb with false size headers cannot expand; the
/// CRC-32 must match as well. Every file is created exclusively, relative to
/// an open descriptor of the fresh directory, and never through a link.
///
/// On failure the staging directory is already clean.
pub fn extract(input: &mut dyn Read, staging_directory: &Path, limits: &ArchiveLimits) -> Result<ExtractedPackage, PackageError> {
    let bytes = read_archive(input, limits)?;
    let entries = preflight::validate(&bytes, limits)?;
    let selection = select(&entries)?;
    let work = safe_files::new_work_directory(&safe_files::root(staging_directory), "import")?;
    let package = safe_files::child(&work, "package");
    let extracted = (|| {
        let unusable = |error: std::io::Error| PackageError::caused(codes::ARCHIVE_CORRUPT, "The package could not be extracted.", error);
        safe_files::create_private_directory(&package).map_err(unusable)?;
        let root = safe_files::open_directory(&package).map_err(unusable)?;
        let mut total = 0u64;
        for (parts, entry) in &selection.files {
            let (file_name, directories) = parts.split_last().ok_or_else(|| corrupt(&entry.name, None))?;
            let mut directory: Option<OwnedFd> = None;
            for name in directories {
                let next = match &directory {
                    Some(parent) => safe_files::create_directory_at(parent, name),
                    None => safe_files::create_directory_at(&root, name),
                };
                directory = Some(next.map_err(unusable)?);
            }
            total += copy_entry(&bytes, entry, directory.as_ref().unwrap_or(&root), file_name, total, limits)?;
        }
        tree::validate_tree(&package, limits)
    })();
    match extracted {
        Ok(()) => Ok(ExtractedPackage { directory: package, root_name: selection.root_name, work_directory: work }),
        Err(error) => {
            safe_files::delete_tree(&work);
            Err(error)
        }
    }
}

/// [`extract`] followed by an atomic move to `destination`; the staging
/// directory is cleaned whether or not the import succeeds. Returns the
/// archive's top-level directory name, if any.
pub fn import_to(input: &mut dyn Read, staging_directory: &Path, destination: &Path, limits: &ArchiveLimits) -> Result<Option<String>, PackageError> {
    let extracted = extract(input, staging_directory, limits)?;
    extracted.move_to(destination)?;
    Ok(extracted.root_name.clone())
}

/// Writes the package in `package_directory` to `output` as a `.swt` archive
/// whose entries live under one `root_name/` directory.
///
/// Dot-files, `__Build`, links, hard-linked and special files are skipped
/// (they are not part of the authored package and must not leak through an
/// export). Entries are sorted and carry a fixed timestamp, so the same
/// package always yields the same bytes. The export obeys the import limits,
/// so every exported archive can be imported again. `extra_files` adds
/// generated files (for example a migrated `widget.json`) that are absent on
/// disk; an extra file takes the place of a disk file of the same path.
/// Nothing is written to `output` unless the whole archive was produced.
pub fn export(package_directory: &Path, root_name: &str, output: &mut dyn Write, extra_files: &BTreeMap<String, Vec<u8>>, limits: &ArchiveLimits) -> Result<(), PackageError> {
    let root = names::archive_root_name(root_name);
    let files = DiskPackageFiles::new(package_directory);
    let mut contents: BTreeMap<String, Option<&[u8]>> = files.list()?.into_iter().map(|path| (path, None)).collect();
    for (path, bytes) in extra_files {
        if path_rules::visible_components(path).is_none() {
            return Err(PackageError::new(codes::INVALID_PATH, "Invalid package path."));
        }
        contents.insert(path.clone(), Some(bytes.as_slice()));
    }
    let count_message = || format!("A package must contain 1–{} files.", limits.maximum_file_count);
    if contents.is_empty() {
        return Err(PackageError::new(codes::ARCHIVE_NO_PACKAGE, count_message()));
    }
    if contents.len() > limits.maximum_file_count {
        return Err(PackageError::new(codes::TOO_MANY_ENTRIES, count_message()));
    }

    let mut archive = ArchiveWriter::default();
    let mut total = 0u64;
    for (path, extra) in &contents {
        let name = format!("{root}/{path}");
        // The importer would refuse this name, so exporting it would produce a dead archive.
        if preflight::entry_parts(&name, limits.maximum_path_depth).is_none() {
            return Err(PackageError::new(codes::INVALID_PATH, format!("Package path {path} cannot be exported.")));
        }
        let read;
        let bytes: &[u8] = match extra {
            Some(bytes) => bytes,
            None => {
                read = files.read_bytes_up_to(path, limits.maximum_file_bytes).ok_or_else(|| PackageError::new(codes::FILE_TOO_LARGE, format!("Package file {path} is unreadable or exceeds 25 MiB.")))?;
                &read
            }
        };
        if bytes.len() as u64 > limits.maximum_file_bytes {
            return Err(PackageError::new(codes::FILE_TOO_LARGE, format!("Package file {path} exceeds 25 MiB.")));
        }
        total += bytes.len() as u64;
        if total > limits.maximum_expanded_bytes {
            return Err(PackageError::new(codes::PACKAGE_TOO_LARGE, "Expanded package exceeds 64 MiB."));
        }
        archive.add(&name, bytes).map_err(|error| PackageError::caused(codes::STORAGE_UNAVAILABLE, "The archive could not be written.", error))?;
        if archive.finished_length() > limits.maximum_archive_bytes {
            return Err(PackageError::new(codes::ARCHIVE_SIZE, "Archive exceeds 32 MiB."));
        }
    }
    output.write_all(&archive.finish()).and_then(|()| output.flush()).map_err(|error| PackageError::caused(codes::STORAGE_UNAVAILABLE, "The archive could not be written.", error))
}

struct Selection<'a> {
    /// Each file with its path components below the package root.
    files: Vec<(Vec<&'a str>, &'a Entry)>,
    root_name: Option<String>,
}

/// Chooses the package root like `ScriptManager.extractedPackageRoot`: the
/// archive root when `main.jsx` or `widget.json` sits there, otherwise the
/// only top-level directory.
fn select<'a>(entries: &'a [Entry]) -> Result<Selection<'a>, PackageError> {
    let files: Vec<&Entry> = entries.iter().filter(|entry| !entry.is_directory && entry.parts[0] != MACOS_RESOURCE_DIRECTORY && !entry.parts.iter().any(|part| path_rules::is_excluded(part))).collect();
    let below = |entry: &'a Entry, skip: usize| -> (Vec<&'a str>, &'a Entry) { (entry.parts.iter().skip(skip).map(String::as_str).collect(), entry) };
    if files.iter().any(|entry| entry.parts.len() == 1 && matches!(entry.parts[0].as_str(), "main.jsx" | "widget.json")) {
        return Ok(Selection { files: files.into_iter().map(|entry| below(entry, 0)).collect(), root_name: None });
    }
    let mut roots: Vec<&str> = files.iter().filter(|entry| entry.parts.len() > 1).map(|entry| entry.parts[0].as_str()).collect();
    roots.sort_unstable();
    roots.dedup();
    let [root] = roots[..] else {
        return Err(PackageError::new(codes::ARCHIVE_NO_PACKAGE, "The archive must contain one widget package."));
    };
    Ok(Selection { files: files.into_iter().filter(|entry| entry.parts.len() > 1 && entry.parts[0] == root).map(|entry| below(entry, 1)).collect(), root_name: Some(root.to_owned()) })
}

fn read_archive(input: &mut dyn Read, limits: &ArchiveLimits) -> Result<Vec<u8>, PackageError> {
    let mut bytes = Vec::new();
    input
        .take(limits.maximum_archive_bytes as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|error| PackageError::caused(codes::ARCHIVE_CORRUPT, "Archive could not be read.", error))?;
    if bytes.is_empty() || bytes.len() > limits.maximum_archive_bytes {
        return Err(PackageError::new(codes::ARCHIVE_SIZE, "Archive must be between 1 byte and 32 MiB."));
    }
    Ok(bytes)
}

/// The compressed bytes of `entry`, located through its local header.
///
/// The local header must be where the central directory says, carry the same
/// name and method, and must not be marked encrypted; the data must lie
/// inside the archive. A header that needs ZIP64 to state its offset cannot
/// occur in an archive of at most 32 MiB and is treated as corrupt.
fn entry_data<'a>(archive: &'a [u8], entry: &Entry) -> Result<&'a [u8], PackageError> {
    let header = usize::try_from(entry.local_header_offset).ok().filter(|&offset| u32_at(archive, offset) == LOCAL_SIGNATURE).ok_or_else(|| corrupt(&entry.name, None))?;
    if u16_at(archive, header + 6) & 0x1 != 0 {
        return Err(PackageError::new(codes::ARCHIVE_ENCRYPTED, "Encrypted package entries are not supported."));
    }
    let name_start = header + 30;
    let name_end = name_start + usize::from(u16_at(archive, header + 26));
    let data_start = name_end + usize::from(u16_at(archive, header + 28));
    let data_end = usize::try_from(entry.compressed_size).ok().and_then(|size| data_start.checked_add(size));
    match data_end {
        Some(data_end) if data_end <= archive.len() && u16_at(archive, header + 8) == entry.method && archive[name_start..name_end] == *entry.name.as_bytes() => Ok(&archive[data_start..data_end]),
        _ => Err(corrupt(&entry.name, None)),
    }
}

/// Inflates one entry into a new file, counting real bytes; returns the
/// number written. Only bytes that were actually produced count, never a
/// length the archive states.
fn copy_entry(archive: &[u8], entry: &Entry, directory: &OwnedFd, file_name: &str, total_before: u64, limits: &ArchiveLimits) -> Result<u64, PackageError> {
    let data = entry_data(archive, entry)?;
    let mut input: Box<dyn Read + '_> = if entry.method == 8 { Box::new(DeflateDecoder::new(data)) } else { Box::new(data) };
    let unusable = |error: std::io::Error| PackageError::caused(codes::ARCHIVE_CORRUPT, "The package could not be extracted.", error);
    let mut output = safe_files::create_file_at(directory, file_name).map_err(unusable)?;
    let mismatch = || PackageError::new(codes::ARCHIVE_SIZE_MISMATCH, format!("Archive entry {} does not match its declared size.", entry.name));
    let mut checksum = flate2::Crc::new();
    let mut count = 0u64;
    let mut buffer = [0u8; 16 * 1024];
    loop {
        let read = match input.read(&mut buffer) {
            Ok(0) => break,
            Ok(read) => read,
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(corrupt(&entry.name, Some(error))),
        };
        count += read as u64;
        if count > entry.uncompressed_size || count > limits.maximum_file_bytes {
            return Err(mismatch());
        }
        if total_before + count > limits.maximum_expanded_bytes {
            return Err(PackageError::new(codes::ARCHIVE_EXPANDED_TOO_LARGE, "Expanded package exceeds 64 MiB."));
        }
        checksum.update(&buffer[..read]);
        output.write_all(&buffer[..read]).map_err(unusable)?;
    }
    if count != entry.uncompressed_size {
        return Err(mismatch());
    }
    if checksum.sum() != entry.crc {
        return Err(corrupt(&entry.name, None));
    }
    Ok(count)
}

/// The bytes of one preflighted entry, inflated in memory for the callers that
/// read a small archive without extracting it (Skills). Only bytes that were
/// actually produced count: an entry that inflates to more or less than its
/// declared size, exceeds `maximum_bytes` or fails its CRC-32 is refused.
pub(crate) fn read_entry(archive: &[u8], entry: &Entry, maximum_bytes: u64) -> Result<Vec<u8>, PackageError> {
    if entry.is_directory || entry.uncompressed_size > maximum_bytes {
        return Err(PackageError::new(codes::ARCHIVE_FILE_TOO_LARGE, format!("Archive entry {} is too large.", entry.name)));
    }
    let data = entry_data(archive, entry)?;
    let input: Box<dyn Read + '_> = if entry.method == 8 { Box::new(DeflateDecoder::new(data)) } else { Box::new(data) };
    let mut bytes = Vec::new();
    // One byte more than declared is enough to see that the declaration is false.
    input.take(entry.uncompressed_size + 1).read_to_end(&mut bytes).map_err(|error| corrupt(&entry.name, Some(error)))?;
    if bytes.len() as u64 != entry.uncompressed_size {
        return Err(PackageError::new(codes::ARCHIVE_SIZE_MISMATCH, format!("Archive entry {} does not match its declared size.", entry.name)));
    }
    if crc32(&bytes) != entry.crc {
        return Err(corrupt(&entry.name, None));
    }
    Ok(bytes)
}

fn corrupt(name: &str, cause: Option<std::io::Error>) -> PackageError {
    PackageError { code: codes::ARCHIVE_CORRUPT.into(), message: format!("Archive entry {name} is corrupt."), cause }
}

/// CRC-32 (IEEE 802.3, as used by ZIP).
pub fn crc32(bytes: &[u8]) -> u32 {
    let mut checksum = flate2::Crc::new();
    checksum.update(bytes);
    checksum.sum()
}

/// A ZIP archive built in memory: deflated entries, UTF-8 names, a fixed
/// timestamp, and the Unix mode of a regular file so that every importer
/// sees plain files.
#[derive(Default)]
struct ArchiveWriter {
    body: Vec<u8>,
    central: Vec<u8>,
    count: u16,
}

impl ArchiveWriter {
    fn add(&mut self, name: &str, bytes: &[u8]) -> std::io::Result<()> {
        let mut encoder = DeflateEncoder::new(Vec::new(), Compression::default());
        encoder.write_all(bytes)?;
        let compressed = encoder.finish()?;
        let too_large = || std::io::Error::other("entry does not fit a ZIP archive without ZIP64");
        let offset = u32::try_from(self.body.len()).map_err(|_| too_large())?;
        let compressed_size = u32::try_from(compressed.len()).map_err(|_| too_large())?;
        let size = u32::try_from(bytes.len()).map_err(|_| too_large())?;
        let name_length = u16::try_from(name.len()).map_err(|_| too_large())?;
        self.count = self.count.checked_add(1).ok_or_else(too_large)?;

        // Version needed 2.0, UTF-8 names, deflate, no modification time, 1980-01-01.
        let mut shared = Vec::with_capacity(26);
        for field in [20, UTF8_FLAG, 8, 0, FIXED_DATE] {
            shared.extend_from_slice(&field.to_le_bytes());
        }
        for field in [crc32(bytes), compressed_size, size] {
            shared.extend_from_slice(&field.to_le_bytes());
        }
        shared.extend_from_slice(&name_length.to_le_bytes());
        shared.extend_from_slice(&0u16.to_le_bytes()); // extra field length

        self.body.extend_from_slice(&(LOCAL_SIGNATURE as u32).to_le_bytes());
        self.body.extend_from_slice(&shared);
        self.body.extend_from_slice(name.as_bytes());
        self.body.extend_from_slice(&compressed);

        self.central.extend_from_slice(&0x0201_4B50u32.to_le_bytes());
        self.central.extend_from_slice(&0x0314u16.to_le_bytes()); // made by: Unix, version 2.0
        self.central.extend_from_slice(&shared);
        // Comment length, disk number, internal attributes.
        self.central.extend_from_slice(&[0; 6]);
        self.central.extend_from_slice(&(0o100644u32 << 16).to_le_bytes());
        self.central.extend_from_slice(&offset.to_le_bytes());
        self.central.extend_from_slice(name.as_bytes());
        Ok(())
    }

    /// Length of the archive [`ArchiveWriter::finish`] would return now.
    fn finished_length(&self) -> usize {
        self.body.len() + self.central.len() + 22
    }

    fn finish(mut self) -> Vec<u8> {
        let central_offset = self.body.len() as u32;
        let central_size = self.central.len() as u32;
        self.body.append(&mut self.central);
        self.body.extend_from_slice(&0x0605_4B50u32.to_le_bytes());
        self.body.extend_from_slice(&[0; 4]); // disk numbers
        self.body.extend_from_slice(&self.count.to_le_bytes());
        self.body.extend_from_slice(&self.count.to_le_bytes());
        self.body.extend_from_slice(&central_size.to_le_bytes());
        self.body.extend_from_slice(&central_offset.to_le_bytes());
        self.body.extend_from_slice(&[0; 2]); // comment length
        self.body
    }
}
