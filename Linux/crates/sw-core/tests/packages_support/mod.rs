//! Fixtures shared by the package tests: hand-written ZIP archives in which
//! every header field an attacker controls can be forged, a temporary folder,
//! links, and a listing of a directory tree. Ported from `ZipFixtures.cs`.

#![allow(dead_code)]

use std::collections::BTreeMap;
use std::io::Write;
use std::path::{Path, PathBuf};

use sw_core::packages::PackageError;

/// One hand-written ZIP entry.
#[derive(Clone)]
pub struct RawEntry {
    pub name: String,
    pub data: Vec<u8>,
    pub external_attributes: u32,
    pub declared_size: Option<u64>,
    pub declared_compressed_size: Option<u64>,
    pub flags: u16,
    pub method: u16,
    pub name_bytes: Option<Vec<u8>>,
}

/// Unix mode of a regular file in the high half of the external attributes.
pub const REGULAR_FILE: u32 = 0x81A4 << 16;
pub const SYMBOLIC_LINK: u32 = 0xA1FF << 16;

impl RawEntry {
    pub fn new(name: &str, data: impl Into<Vec<u8>>) -> Self {
        Self { name: name.to_owned(), data: data.into(), external_attributes: REGULAR_FILE, declared_size: None, declared_compressed_size: None, flags: 0x0800, method: 0, name_bytes: None }
    }

    pub fn mode(mut self, external_attributes: u32) -> Self {
        self.external_attributes = external_attributes;
        self
    }

    pub fn declared_size(mut self, size: u64) -> Self {
        self.declared_size = Some(size);
        self
    }

    pub fn declared_compressed_size(mut self, size: u64) -> Self {
        self.declared_compressed_size = Some(size);
        self
    }

    pub fn flags(mut self, flags: u16) -> Self {
        self.flags = flags;
        self
    }

    pub fn method(mut self, method: u16) -> Self {
        self.method = method;
        self
    }

    pub fn name_bytes(mut self, bytes: &[u8]) -> Self {
        self.name_bytes = Some(bytes.to_vec());
        self
    }
}

/// An entry holding "x".
pub fn entry(name: &str) -> RawEntry {
    RawEntry::new(name, "x")
}

/// CRC-32 computed bit by bit, independently of the implementation under test.
pub fn crc32(bytes: &[u8]) -> u32 {
    let mut state = 0xFFFF_FFFFu32;
    for byte in bytes {
        state ^= u32::from(*byte);
        for _ in 0..8 {
            state = if state & 1 != 0 { 0xEDB8_8320 ^ (state >> 1) } else { state >> 1 };
        }
    }
    !state
}

/// ZIP written byte by byte, like `makeStoredZIP` in the Swift tests. The
/// data of an entry is written as given, whatever its method says.
pub fn raw_zip(entries: &[RawEntry]) -> Vec<u8> {
    raw_zip_with_checksums(entries, &entries.iter().map(|entry| crc32(&entry.data)).collect::<Vec<_>>())
}

fn raw_zip_with_checksums(entries: &[RawEntry], checksums: &[u32]) -> Vec<u8> {
    let mut locals = Vec::new();
    let mut central = Vec::new();
    for (entry, crc) in entries.iter().zip(checksums) {
        let name = entry.name_bytes.clone().unwrap_or_else(|| entry.name.clone().into_bytes());
        let size = entry.declared_size.unwrap_or(entry.data.len() as u64) as u32;
        let compressed = entry.declared_compressed_size.unwrap_or(entry.data.len() as u64) as u32;
        let offset = locals.len() as u32;
        let mut shared = Vec::new();
        for field in [20u16, entry.flags, entry.method, 0, 0x21] {
            shared.extend_from_slice(&field.to_le_bytes());
        }
        for field in [*crc, compressed, size] {
            shared.extend_from_slice(&field.to_le_bytes());
        }
        shared.extend_from_slice(&(name.len() as u16).to_le_bytes());
        shared.extend_from_slice(&0u16.to_le_bytes());

        locals.extend_from_slice(&0x0403_4B50u32.to_le_bytes());
        locals.extend_from_slice(&shared);
        locals.extend_from_slice(&name);
        locals.extend_from_slice(&entry.data);

        central.extend_from_slice(&0x0201_4B50u32.to_le_bytes());
        central.extend_from_slice(&0x031Eu16.to_le_bytes());
        central.extend_from_slice(&shared);
        // Comment length, disk number and internal attributes stay zero.
        central.extend_from_slice(&[0; 6]);
        central.extend_from_slice(&entry.external_attributes.to_le_bytes());
        central.extend_from_slice(&offset.to_le_bytes());
        central.extend_from_slice(&name);
    }
    let mut archive = locals;
    let central_offset = archive.len() as u32;
    archive.extend_from_slice(&central);
    archive.extend_from_slice(&0x0605_4B50u32.to_le_bytes());
    archive.extend_from_slice(&[0; 4]);
    archive.extend_from_slice(&(entries.len() as u16).to_le_bytes());
    archive.extend_from_slice(&(entries.len() as u16).to_le_bytes());
    archive.extend_from_slice(&(central.len() as u32).to_le_bytes());
    archive.extend_from_slice(&central_offset.to_le_bytes());
    archive.extend_from_slice(&[0; 2]);
    archive
}

/// ZIP whose entries are deflated; the headers state the true sizes and checksums.
pub fn deflated_zip(files: &[(&str, &[u8])]) -> Vec<u8> {
    let mut entries = Vec::new();
    let mut checksums = Vec::new();
    for (name, data) in files {
        let mut encoder = flate2::write::DeflateEncoder::new(Vec::new(), flate2::Compression::best());
        encoder.write_all(data).unwrap();
        entries.push(RawEntry::new(name, encoder.finish().unwrap()).method(8).declared_size(data.len() as u64));
        checksums.push(crc32(data));
    }
    raw_zip_with_checksums(&entries, &checksums)
}

fn u16_at(bytes: &[u8], index: usize) -> usize {
    usize::from(u16::from_le_bytes([bytes[index], bytes[index + 1]]))
}

fn u32_at(bytes: &[u8], index: usize) -> u32 {
    u32::from_le_bytes([bytes[index], bytes[index + 1], bytes[index + 2], bytes[index + 3]])
}

/// Overwrites the uncompressed size the central directory declares for entry `index`.
pub fn forge_declared_size(archive: &[u8], index: usize, size: u32) -> Vec<u8> {
    let mut bytes = archive.to_vec();
    let mut cursor = u32_at(&bytes, bytes.len() - 22 + 16) as usize;
    for _ in 0..index {
        cursor += 46 + u16_at(&bytes, cursor + 28) + u16_at(&bytes, cursor + 30) + u16_at(&bytes, cursor + 32);
    }
    assert_eq!(u32_at(&bytes, cursor), 0x0201_4B50);
    bytes[cursor + 24..cursor + 28].copy_from_slice(&size.to_le_bytes());
    bytes
}

/// Entry names and contents of an archive, read by a small reader of its own
/// (central directory, then each local header), for checking exports.
pub fn read_zip(archive: &[u8]) -> Vec<(String, Vec<u8>)> {
    let end = archive.len() - 22;
    assert_eq!(u32_at(archive, end), 0x0605_4B50, "end record");
    let mut cursor = u32_at(archive, end + 16) as usize;
    let mut result = Vec::new();
    for _ in 0..u16_at(archive, end + 10) {
        assert_eq!(u32_at(archive, cursor), 0x0201_4B50, "central header");
        let name_length = u16_at(archive, cursor + 28);
        let name = String::from_utf8(archive[cursor + 46..cursor + 46 + name_length].to_vec()).unwrap();
        let compressed = u32_at(archive, cursor + 20) as usize;
        let local = u32_at(archive, cursor + 42) as usize;
        assert_eq!(u32_at(archive, local), 0x0403_4B50, "local header");
        let start = local + 30 + u16_at(archive, local + 26) + u16_at(archive, local + 28);
        let data = &archive[start..start + compressed];
        let content = match u16_at(archive, cursor + 10) {
            0 => data.to_vec(),
            8 => {
                let mut content = Vec::new();
                std::io::Read::read_to_end(&mut flate2::read::DeflateDecoder::new(data), &mut content).unwrap();
                content
            }
            method => panic!("unexpected method {method}"),
        };
        assert_eq!(content.len(), u32_at(archive, cursor + 24) as usize, "declared size of {name}");
        assert_eq!(crc32(&content), u32_at(archive, cursor + 16), "checksum of {name}");
        result.push((name, content));
        cursor += 46 + name_length + u16_at(archive, cursor + 30) + u16_at(archive, cursor + 32);
    }
    result
}

pub fn entry_names(archive: &[u8]) -> Vec<String> {
    read_zip(archive).into_iter().map(|(name, _)| name).collect()
}

pub const SOURCE: &str = "$render(<text>Hello</text>);";

pub fn manifest(name: &str) -> String {
    format!(r#"{{"formatVersion":2,"id":"com.example.widget","name":"{name}","version":"1.2.3","runtimeVersion":"1.0","entry":"main.jsx","supportedFamilies":["systemSmall"],"permissions":[],"networkDomains":[]}}"#)
}

/// A well-formed package archive under one top-level directory.
pub fn package_zip(root: &str, name: &str, extra: &[(&str, &str)]) -> Vec<u8> {
    let mut entries = vec![RawEntry::new(&format!("{root}/widget.json"), manifest(name)), RawEntry::new(&format!("{root}/main.jsx"), "$render(<text>hi</text>);")];
    entries.extend(extra.iter().map(|(path, text)| RawEntry::new(&format!("{root}/{path}"), *text)));
    raw_zip(&entries)
}

/// The archive most tests import: `Widget/widget.json` and `Widget/main.jsx`.
pub fn widget_zip() -> Vec<u8> {
    package_zip("Widget", "Widget", &[])
}

#[track_caller]
pub fn assert_code<T: std::fmt::Debug>(code: &str, result: Result<T, PackageError>) {
    match result {
        Err(error) => assert_eq!(error.code, code, "{}", error.message),
        Ok(value) => panic!("expected {code}, but it succeeded with {value:?}"),
    }
}

/// A deflated entry whose real content is longer than the size the central
/// directory declares. The reader stops as soon as the content passes the
/// declared size and reports `archive_size_mismatch`; the Windows reader
/// stops at the declared size and fails the checksum instead, so both codes
/// are accepted there and here.
#[track_caller]
pub fn assert_lying_size_rejected<T: std::fmt::Debug>(result: Result<T, PackageError>) {
    let error = result.expect_err("a lying size must be rejected");
    assert!(["archive_size_mismatch", "archive_corrupt"].contains(&error.code.as_str()), "{error}");
}

/// Relative paths of everything below `root`, directories included (with a
/// trailing slash), for "nothing left behind" checks. Links are listed and
/// never followed. A missing root lists as empty.
pub fn tree(root: &Path) -> Vec<String> {
    fn walk(directory: &Path, prefix: &str, result: &mut Vec<String>) {
        let Ok(entries) = std::fs::read_dir(directory) else { return };
        for entry in entries {
            let entry = entry.unwrap();
            let name = entry.file_name().to_string_lossy().into_owned();
            let is_directory = entry.file_type().unwrap().is_dir();
            result.push(format!("{prefix}{name}{}", if is_directory { "/" } else { "" }));
            if is_directory {
                walk(&entry.path(), &format!("{prefix}{name}/"), result);
            }
        }
    }
    let mut result = Vec::new();
    walk(root, "", &mut result);
    result.sort_unstable();
    result
}

/// A unique directory under the system temporary directory that is removed
/// when the test ends. The counterpart of JUnit's `TemporaryFolder`.
pub struct TemporaryFolder {
    pub root: PathBuf,
}

impl TemporaryFolder {
    pub fn new() -> Self {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let unique = format!("pkg-{}-{}-{}", std::process::id(), NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed), std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos());
        // The canonical form: on macOS the temporary directory is reached through a link.
        let base = std::fs::canonicalize(std::env::temp_dir()).unwrap();
        let root = base.join("scriptwidget-tests").join(unique);
        std::fs::create_dir_all(&root).unwrap();
        Self { root }
    }

    pub fn path(&self, relative: &str) -> PathBuf {
        self.root.join(relative)
    }

    pub fn new_folder(&self, relative: &str) -> PathBuf {
        let path = self.path(relative);
        std::fs::create_dir_all(&path).unwrap();
        path
    }

    pub fn new_file(&self, relative: &str, text: &str) -> PathBuf {
        let path = self.path(relative);
        write_file(&path, text.as_bytes());
        path
    }
}

impl Drop for TemporaryFolder {
    fn drop(&mut self) {
        // Tests leave directories without permissions behind; open them up first.
        fn unlock(directory: &Path) {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(directory, std::fs::Permissions::from_mode(0o700));
            for entry in std::fs::read_dir(directory).into_iter().flatten().flatten() {
                if entry.file_type().is_ok_and(|kind| kind.is_dir()) {
                    unlock(&entry.path());
                }
            }
        }
        unlock(&self.root);
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

/// Writes a file, creating the directories above it.
pub fn write_file(path: &Path, bytes: &[u8]) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, bytes).unwrap();
}

/// Makes `link` a symbolic link to `target`, which need not exist.
pub fn symlink(link: &Path, target: &Path) {
    std::fs::create_dir_all(link.parent().unwrap()).unwrap();
    std::os::unix::fs::symlink(target, link).unwrap();
    assert!(std::fs::symlink_metadata(link).unwrap().file_type().is_symlink());
}

/// Makes `link` a second hard link to the file `existing`.
pub fn hard_link(link: &Path, existing: &Path) {
    use std::os::unix::fs::MetadataExt;
    std::fs::create_dir_all(link.parent().unwrap()).unwrap();
    std::fs::hard_link(existing, link).unwrap();
    assert!(std::fs::metadata(link).unwrap().nlink() >= 2);
}

pub fn mode(path: &Path) -> u32 {
    use std::os::unix::fs::MetadataExt;
    std::fs::symlink_metadata(path).unwrap().mode() & 0o777
}

pub fn set_mode(path: &Path, mode: u32) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode)).unwrap();
}

/// True when the test runs as root, for whom file permissions do not hold.
pub fn permissions_are_not_enforced(scratch: &TemporaryFolder) -> bool {
    let probe = scratch.new_file(".permission-probe", "x");
    set_mode(&probe, 0o000);
    let readable = std::fs::read(&probe).is_ok();
    std::fs::remove_file(&probe).unwrap();
    readable
}

/// Puts a Unix socket at `path`. A socket address holds about a hundred
/// bytes, so the directory is reached through a short link while binding.
pub fn make_socket(path: &Path) {
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let short = PathBuf::from(format!("/tmp/sw-{}-{}", std::process::id(), NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)));
    let _ = std::fs::remove_file(&short);
    std::os::unix::fs::symlink(path.parent().unwrap(), &short).unwrap();
    let bound = std::os::unix::net::UnixListener::bind(short.join(path.file_name().unwrap()));
    std::fs::remove_file(&short).unwrap();
    drop(bound.unwrap());
    use std::os::unix::fs::FileTypeExt;
    assert!(std::fs::symlink_metadata(path).unwrap().file_type().is_socket());
}

/// Puts a FIFO at `path`.
pub fn make_fifo(path: &Path) {
    let made = std::process::Command::new("mkfifo").arg(path).status().expect("mkfifo");
    assert!(made.success(), "mkfifo failed");
    use std::os::unix::fs::FileTypeExt;
    assert!(std::fs::symlink_metadata(path).unwrap().file_type().is_fifo());
}

pub fn extras(files: &[(&str, &str)]) -> BTreeMap<String, Vec<u8>> {
    files.iter().map(|(path, text)| (path.to_string(), text.as_bytes().to_vec())).collect()
}

pub fn nested(name: &str, depth: usize) -> String {
    vec![name; depth].join("/")
}
