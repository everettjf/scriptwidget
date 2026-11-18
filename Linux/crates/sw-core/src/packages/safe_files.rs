//! Link-refusing filesystem primitives shared by the package layer. Ported
//! from `SafeFiles.cs`, with the parts Linux can do better done better.
//!
//! Every lookup looks at the path itself (`lstat`, `O_NOFOLLOW`), so a
//! symbolic link is seen as a link and never as its target.
//!
//! Files and directories inside a package are opened relative to a
//! descriptor of the package directory with `openat2` and
//! `RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS`: the
//! kernel resolves the whole relative path in one call and refuses it when
//! any component is a symbolic link or would leave the directory, so there is
//! no window between a check and the open. The opened descriptor is then
//! examined with `fstat`: only a regular file with a single link is read.
//!
//! Fallback. `openat2` exists since Linux 5.6. Where the call is missing
//! (`ENOSYS`: an older kernel or another Unix such as the Mac used for
//! development) or refused by a sandbox's system call filter (`EPERM`), and
//! when it keeps reporting `EAGAIN` because the tree is being renamed
//! underneath it, the path is walked one component at a time instead: each
//! component is opened relative to the descriptor of its parent with
//! `openat` and `O_NOFOLLOW`. A component is a single name (never `..`, never
//! containing a slash), so the walk can only go down, and no step follows a
//! link; it gives the same guarantee with one system call per component.
//!
//! The Windows port has a canonical-path check (`Inside`) because Win32
//! rewrites the paths it is given. Here nothing is rewritten and the
//! descriptor-relative opens enforce the boundary, so there is no such check.

use std::fs::File;
use std::io::{self, Read, Write};
use std::os::fd::{AsFd, OwnedFd};
use std::os::unix::fs::{DirBuilderExt, MetadataExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use rustix::fs::{AtFlags, Dir, FileType, Mode, OFlags, Stat};
use rustix::io::Errno;

use super::error::{PackageError, codes};
use super::limits::MAX_DIRECTORY_ENTRIES;
use super::names;

/// What [`attributes`] reports about a path itself, never about a link target.
#[derive(Debug, Clone, Copy)]
pub(crate) struct FileEntry {
    /// A directory that is not a symbolic link.
    pub is_directory: bool,
    pub is_symbolic_link: bool,
    /// A plain file: not a directory, link, device, socket or FIFO.
    pub is_regular_file: bool,
    /// File size in bytes as the filesystem reports it.
    pub size: u64,
    /// Number of hard links.
    pub links: u64,
}

impl FileEntry {
    #[allow(clippy::unnecessary_cast)] // The field types differ between Linux architectures and macOS.
    fn of(stat: &Stat) -> Self {
        let kind = FileType::from_raw_mode(stat.st_mode);
        Self {
            is_directory: kind == FileType::Directory,
            is_symbolic_link: kind == FileType::Symlink,
            is_regular_file: kind == FileType::RegularFile,
            size: u64::try_from(stat.st_size).unwrap_or(u64::MAX),
            links: stat.st_nlink as u64,
        }
    }

    /// A regular file that no second hard link could expose or alter from outside the package.
    pub fn is_private_regular_file(&self) -> bool {
        self.is_regular_file && self.links <= 1
    }
}

/// Entry names of a directory. A name that is not UTF-8 cannot be a package
/// path; it is left out of `names` and reported by `foreign`.
#[derive(Debug, Default)]
pub(crate) struct Listing {
    pub names: Vec<String>,
    pub foreign: bool,
}

/// Flags for opening a directory itself, never a link to one.
pub(crate) const DIRECTORY_FLAGS: OFlags = OFlags::RDONLY.union(OFlags::DIRECTORY).union(OFlags::NOFOLLOW).union(OFlags::CLOEXEC);
/// Flags for reading a file. `O_NONBLOCK` keeps a FIFO from blocking the open; it has no effect on a regular file.
const READ_FLAGS: OFlags = OFlags::RDONLY.union(OFlags::NOFOLLOW).union(OFlags::CLOEXEC).union(OFlags::NONBLOCK).union(OFlags::NOCTTY);
const DIRECTORY_MODE: u32 = 0o700;
const FILE_MODE: u32 = 0o600;

/// The absolute form of a caller-supplied root directory. Links are not resolved.
pub(crate) fn root(path: &Path) -> PathBuf {
    std::path::absolute(path).unwrap_or_else(|_| path.to_owned())
}

/// `name` directly below `directory`. Joined as text: `Path::join` would let a rooted name replace the directory.
pub(crate) fn child(directory: &Path, name: &str) -> PathBuf {
    let mut joined = directory.as_os_str().to_owned();
    if !joined.as_encoded_bytes().ends_with(b"/") {
        joined.push("/");
    }
    joined.push(name);
    PathBuf::from(joined)
}

/// Attributes of `path` itself (never of a link target), or `None` when it is absent or unreadable.
pub(crate) fn attributes(path: &Path) -> Option<FileEntry> {
    let metadata = std::fs::symlink_metadata(path).ok()?;
    let kind = metadata.file_type();
    Some(FileEntry { is_directory: kind.is_dir(), is_symbolic_link: kind.is_symlink(), is_regular_file: kind.is_file(), size: metadata.len(), links: metadata.nlink() })
}

/// True when something, including a dangling link, occupies `path`. Present but unreadable still occupies the name.
pub(crate) fn occupied(path: &Path) -> bool {
    !matches!(std::fs::symlink_metadata(path), Err(error) if matches!(error.kind(), io::ErrorKind::NotFound | io::ErrorKind::NotADirectory))
}

/// True when `path` is a real directory rather than a link to one.
pub(crate) fn real_directory(path: &Path) -> bool {
    attributes(path).is_some_and(|entry| entry.is_directory)
}

/// Opens `path` as a directory; fails when it is a symbolic link or not a directory.
pub(crate) fn open_directory(path: &Path) -> io::Result<OwnedFd> {
    Ok(rustix::fs::open(path, DIRECTORY_FLAGS, Mode::empty())?)
}

/// Entry names of `directory`, or `None` when it cannot be listed, is a link, or is implausibly large.
pub(crate) fn names(directory: &Path) -> Option<Listing> {
    names_of(&open_directory(directory).ok()?)
}

/// [`names`] for an open directory.
pub(crate) fn names_of(directory: &impl AsFd) -> Option<Listing> {
    let mut listing = Listing::default();
    let mut count = 0;
    for entry in Dir::read_from(directory).ok()? {
        let entry = entry.ok()?;
        let name = entry.file_name().to_bytes();
        if name == b"." || name == b".." {
            continue;
        }
        count += 1;
        if count > MAX_DIRECTORY_ENTRIES {
            return None;
        }
        match std::str::from_utf8(name) {
            Ok(name) => listing.names.push(name.to_owned()),
            Err(_) => listing.foreign = true,
        }
    }
    Some(listing)
}

/// False when `names` holds a different spelling of `name` (another case or
/// Unicode form). Such aliases resolve to one file on some filesystems and
/// two on others, so they are refused.
pub(crate) fn unambiguous(names: &[String], name: &str) -> bool {
    let identity = names::identity(name);
    !names.iter().any(|other| other != name && names::identity(other) == identity)
}

/// One name of a directory entry: nothing that could address another directory.
fn is_single_name(name: &str) -> bool {
    !name.is_empty() && name != "." && name != ".." && !name.contains('/') && !name.contains('\0')
}

fn invalid_name() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, "not a single file name")
}

/// Opens `parts` below the open directory `root` without following any link
/// and without leaving `root`. See the module description for the two ways
/// this is done.
pub(crate) fn open_beneath(root: &impl AsFd, parts: &[&str], flags: OFlags) -> io::Result<OwnedFd> {
    if parts.is_empty() || !parts.iter().all(|part| is_single_name(part)) {
        return Err(invalid_name());
    }
    #[cfg(target_os = "linux")]
    if !beneath::UNAVAILABLE.load(Ordering::Relaxed) {
        match beneath::open(root, parts, flags) {
            Err(Errno::NOSYS) => beneath::UNAVAILABLE.store(true, Ordering::Relaxed),
            Err(Errno::PERM | Errno::AGAIN) => {}
            result => return Ok(result?),
        }
    }
    open_by_walking(root, parts, flags)
}

#[cfg(target_os = "linux")]
pub(crate) mod beneath {
    use std::os::fd::{AsFd, OwnedFd};
    use std::sync::atomic::AtomicBool;

    use rustix::fs::{Mode, OFlags, ResolveFlags};
    use rustix::io::Errno;

    /// Set once the kernel has answered `ENOSYS`, so later opens go straight to the walk.
    pub(crate) static UNAVAILABLE: AtomicBool = AtomicBool::new(false);

    /// One `openat2` call for the whole relative path. `EAGAIN` means the
    /// kernel could not prove the path stayed beneath `root` while something
    /// was being renamed; it is retried a few times.
    pub(crate) fn open(root: &impl AsFd, parts: &[&str], flags: OFlags) -> Result<OwnedFd, Errno> {
        let path = parts.join("/");
        let resolve = ResolveFlags::BENEATH | ResolveFlags::NO_SYMLINKS | ResolveFlags::NO_MAGICLINKS;
        let mut attempts = 0;
        loop {
            match rustix::fs::openat2(root, path.as_str(), flags | OFlags::NOFOLLOW, Mode::empty(), resolve) {
                Err(Errno::AGAIN) if attempts < 3 => attempts += 1,
                result => return result,
            }
        }
    }
}

/// The fallback of [`open_beneath`]: one `openat` with `O_NOFOLLOW` per component.
pub(crate) fn open_by_walking(root: &impl AsFd, parts: &[&str], flags: OFlags) -> io::Result<OwnedFd> {
    let mut current: Option<OwnedFd> = None;
    for (index, name) in parts.iter().enumerate() {
        if !is_single_name(name) {
            return Err(invalid_name());
        }
        let component_flags = if index + 1 == parts.len() { flags | OFlags::NOFOLLOW } else { DIRECTORY_FLAGS };
        let next = match &current {
            Some(directory) => rustix::fs::openat(directory, *name, component_flags, Mode::empty())?,
            None => rustix::fs::openat(root, *name, component_flags, Mode::empty())?,
        };
        current = Some(next);
    }
    current.ok_or_else(invalid_name)
}

/// Attributes of the entry `name` of an open directory, never of a link target.
pub(crate) fn attributes_at(directory: &impl AsFd, name: &str) -> io::Result<FileEntry> {
    if !is_single_name(name) {
        return Err(invalid_name());
    }
    Ok(FileEntry::of(&rustix::fs::statat(directory, name, AtFlags::SYMLINK_NOFOLLOW)?))
}

/// Opens the directory `name` of an open directory, creating it when it does not exist.
pub(crate) fn create_directory_at(directory: &impl AsFd, name: &str) -> io::Result<OwnedFd> {
    if !is_single_name(name) {
        return Err(invalid_name());
    }
    match rustix::fs::mkdirat(directory, name, Mode::from_raw_mode(DIRECTORY_MODE as _)) {
        Ok(()) | Err(Errno::EXIST) => {}
        Err(error) => return Err(error.into()),
    }
    open_beneath(directory, &[name], DIRECTORY_FLAGS)
}

/// Creates the file `name` in an open directory; fails when anything, a link included, already has that name.
pub(crate) fn create_file_at(directory: &impl AsFd, name: &str) -> io::Result<File> {
    if !is_single_name(name) {
        return Err(invalid_name());
    }
    let flags = OFlags::WRONLY | OFlags::CREATE | OFlags::EXCL | OFlags::NOFOLLOW | OFlags::CLOEXEC;
    Ok(File::from(rustix::fs::openat(directory, name, flags, Mode::from_raw_mode(FILE_MODE as _))?))
}

/// Creates `name` exclusively in an open directory, writes `bytes` and flushes them to storage.
pub(crate) fn write_new_at(directory: &impl AsFd, name: &str, bytes: &[u8]) -> io::Result<()> {
    let mut file = create_file_at(directory, name)?;
    file.write_all(bytes)?;
    file.sync_all()
}

/// Resolves `parts` below `root` to an existing regular file and opens it for reading, or returns `None`.
///
/// Each component must be spelled exactly as stored and must not have a case
/// or normalization alias; intermediate components must be directories and
/// the last one a regular file with a single link; none may be a link. The
/// open itself is [`open_beneath`], and the link count and file type are
/// checked again on the open descriptor before anything is read.
pub(crate) fn existing_file(root: &Path, parts: &[&str]) -> Option<File> {
    if parts.is_empty() || !real_directory(root) {
        return None;
    }
    let mut directory = root.to_owned();
    for (index, name) in parts.iter().enumerate() {
        let siblings = names(&directory)?.names;
        if !siblings.iter().any(|sibling| sibling == name) || !unambiguous(&siblings, name) {
            return None;
        }
        let entry_path = child(&directory, name);
        let entry = attributes(&entry_path)?;
        if entry.is_symbolic_link {
            return None;
        }
        if index + 1 < parts.len() {
            if !entry.is_directory {
                return None;
            }
            directory = entry_path;
        } else if !entry.is_private_regular_file() {
            return None;
        }
    }
    let file = open_beneath(&open_directory(root).ok()?, parts, READ_FLAGS).ok()?;
    FileEntry::of(&rustix::fs::fstat(&file).ok()?).is_private_regular_file().then(|| File::from(file))
}

/// Reads `file`, or returns `None` when it holds more than `maximum_bytes`.
/// The size is counted while reading, never taken from metadata that may change.
pub(crate) fn read_bounded(file: File, maximum_bytes: u64) -> Option<Vec<u8>> {
    let mut bytes = Vec::new();
    file.take(maximum_bytes.saturating_add(1)).read_to_end(&mut bytes).ok()?;
    (bytes.len() as u64 <= maximum_bytes).then_some(bytes)
}

/// Strict UTF-8 decoding: malformed input yields `None` instead of replacement characters.
pub(crate) fn decode_utf8(bytes: Vec<u8>) -> Option<String> {
    String::from_utf8(bytes).ok()
}

/// A random version 4 UUID in its usual text form.
pub(crate) fn unique_token() -> String {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let mut bytes = [0u8; 16];
    if getrandom::fill(&mut bytes).is_err() {
        // No entropy source: time, process and a counter still give a name of its own.
        let nanoseconds = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |elapsed| elapsed.as_nanos() as u64);
        bytes[..8].copy_from_slice(&nanoseconds.to_le_bytes());
        bytes[8..12].copy_from_slice(&std::process::id().to_le_bytes());
        bytes[12..].copy_from_slice(&(COUNTER.fetch_add(1, Ordering::Relaxed) as u32).to_le_bytes());
    }
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;
    let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    format!("{}-{}-{}-{}-{}", &hex[..8], &hex[8..12], &hex[12..16], &hex[16..20], &hex[20..])
}

/// Creates a directory readable by the user only; fails when the name is taken.
pub(crate) fn create_private_directory(path: &Path) -> io::Result<()> {
    std::fs::DirBuilder::new().mode(DIRECTORY_MODE).create(path)
}

/// Creates a uniquely named private working directory below `staging_root`.
pub(crate) fn new_work_directory(staging_root: &Path, prefix: &str) -> Result<PathBuf, PackageError> {
    (|| {
        std::fs::DirBuilder::new().recursive(true).mode(DIRECTORY_MODE).create(staging_root)?;
        if !real_directory(staging_root) {
            return Err(io::Error::other("Staging directory is a link"));
        }
        let work = child(staging_root, &format!("{prefix}-{}", unique_token()));
        create_private_directory(&work)?;
        Ok(work)
    })()
    .map_err(|error: io::Error| PackageError::caused(codes::STORAGE_UNAVAILABLE, "The staging directory is unavailable.", error))
}

/// Publishes a prepared directory with one atomic rename, so observers see
/// either nothing or the complete package. `destination` must be free.
pub(crate) fn publish(prepared: &Path, destination: &Path) -> Result<(), PackageError> {
    let taken = || PackageError::new(codes::PACKAGE_EXISTS, "A package with this name already exists.");
    if occupied(destination) {
        return Err(taken());
    }
    rename_without_replacing(prepared, destination).map_err(|error| match error.kind() {
        io::ErrorKind::AlreadyExists => taken(),
        io::ErrorKind::CrossesDevices => PackageError::caused(codes::STORAGE_UNAVAILABLE, "Staging and library directories must share a filesystem.", error),
        _ => PackageError::caused(codes::STORAGE_UNAVAILABLE, "The package could not be published.", error),
    })
}

/// Renames `from` to `to`, which must not exist.
///
/// On Linux this is `renameat2` with `RENAME_NOREPLACE`: the kernel refuses
/// an existing destination in the same step as the rename, so nothing that
/// appears there in the meantime is replaced (a plain `rename` silently
/// replaces an empty directory). Where the filesystem or the kernel does not
/// know the flag, and on other systems, it is a plain rename: callers check
/// the destination first and hold the store lock, as on Android.
pub(crate) fn rename_without_replacing(from: &Path, to: &Path) -> io::Result<()> {
    #[cfg(target_os = "linux")]
    match rustix::fs::renameat_with(rustix::fs::CWD, from, rustix::fs::CWD, to, rustix::fs::RenameFlags::NOREPLACE) {
        Err(Errno::INVAL | Errno::NOSYS) => {}
        result => return Ok(result?),
    }
    std::fs::rename(from, to)
}

/// Removes `path` and everything below it. Links are removed, never followed. Best effort:
/// leftovers stay inside the private staging directory and are retried by later cleanups.
pub(crate) fn delete_tree(path: &Path) {
    let Some(entry) = attributes(path) else { return };
    if !entry.is_directory {
        let _ = std::fs::remove_file(path);
        return;
    }
    if std::fs::remove_dir_all(path).is_err() {
        // A directory without write or search permission keeps its entries; open it up and try once more.
        make_removable(path, 0);
        let _ = std::fs::remove_dir_all(path);
    }
}

fn make_removable(directory: &Path, depth: usize) {
    // Callers have seen a real directory here (`lstat`); chmod itself would follow a link.
    let _ = std::fs::set_permissions(directory, std::os::unix::fs::PermissionsExt::from_mode(DIRECTORY_MODE));
    if depth >= 64 {
        return;
    }
    let Some(listing) = names(directory) else { return };
    for name in listing.names {
        let entry_path = child(directory, &name);
        if real_directory(&entry_path) {
            make_removable(&entry_path, depth + 1);
        }
    }
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::symlink;

    use super::*;

    /// A directory of its own under the system temporary directory, removed when the test ends.
    struct Scratch(PathBuf);

    impl Scratch {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!("scriptwidget-safe-files-{}", unique_token()));
            std::fs::create_dir_all(&path).expect("scratch directory");
            Self(path)
        }

        /// `root/` with `a.txt`, `sub/b.txt`, a link to a file outside, a link to a directory outside, and `outside/secret.txt` next to it.
        fn populated() -> (Self, OwnedFd) {
            let scratch = Self::new();
            let root = scratch.0.join("root");
            std::fs::create_dir_all(root.join("sub")).unwrap();
            std::fs::create_dir_all(scratch.0.join("outside")).unwrap();
            std::fs::write(root.join("a.txt"), "a").unwrap();
            std::fs::write(root.join("sub/b.txt"), "b").unwrap();
            std::fs::write(scratch.0.join("outside/secret.txt"), "secret").unwrap();
            symlink(scratch.0.join("outside/secret.txt"), root.join("link.txt")).unwrap();
            symlink(scratch.0.join("outside"), root.join("linkdir")).unwrap();
            symlink("a.txt", root.join("inside.txt")).unwrap();
            symlink("../outside", root.join("sub/up")).unwrap();
            let handle = open_directory(&root).expect("open root");
            (scratch, handle)
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            delete_tree(&self.0);
        }
    }

    fn text(file: OwnedFd) -> String {
        let mut content = String::new();
        File::from(file).read_to_string(&mut content).expect("read");
        content
    }

    /// The cases every way of opening must agree on.
    fn assert_refuses_links_and_escapes(open: impl Fn(&OwnedFd, &[&str]) -> io::Result<OwnedFd>, root: &OwnedFd) {
        assert_eq!(text(open(root, &["a.txt"]).expect("a.txt")), "a");
        assert_eq!(text(open(root, &["sub", "b.txt"]).expect("sub/b.txt")), "b");
        for parts in [&["link.txt"][..], &["inside.txt"], &["linkdir", "secret.txt"], &["sub", "up", "secret.txt"], &["missing.txt"], &["a.txt", "child"]] {
            assert!(open(root, parts).is_err(), "{parts:?} must not open");
        }
    }

    #[test]
    fn open_beneath_refuses_links_at_every_component() {
        let (_scratch, root) = Scratch::populated();
        assert_refuses_links_and_escapes(|root, parts| open_beneath(root, parts, READ_FLAGS), &root);
    }

    #[test]
    fn the_walking_fallback_refuses_links_at_every_component() {
        let (_scratch, root) = Scratch::populated();
        assert_refuses_links_and_escapes(|root, parts| open_by_walking(root, parts, READ_FLAGS), &root);
    }

    #[test]
    fn names_that_are_not_single_components_never_reach_the_kernel() {
        let (_scratch, root) = Scratch::populated();
        for parts in [&[][..], &[""], &["."], &[".."], &["..", "outside", "secret.txt"], &["sub/b.txt"], &["/etc/passwd"], &["sub", "..", "a.txt"], &["a\0.txt"]] {
            assert_eq!(open_beneath(&root, parts, READ_FLAGS).map(drop).map_err(|error| error.kind()), Err(io::ErrorKind::InvalidInput), "{parts:?}");
            assert_eq!(open_by_walking(&root, parts, READ_FLAGS).map(drop).map_err(|error| error.kind()), Err(io::ErrorKind::InvalidInput), "{parts:?}");
        }
        assert!(attributes_at(&root, "../outside").is_err());
        assert!(create_file_at(&root, "sub/new.txt").is_err());
        assert!(create_directory_at(&root, "..").is_err());
    }

    /// The kernel itself enforces the boundary: this test fails on a kernel
    /// without `openat2`, so a run that passes has used it.
    #[cfg(target_os = "linux")]
    #[test]
    fn openat2_is_available_and_resolves_beneath_without_links() {
        let (_scratch, root) = Scratch::populated();
        assert_refuses_links_and_escapes(|root, parts| beneath::open(root, parts, READ_FLAGS).map_err(io::Error::from), &root);
        assert!(!beneath::UNAVAILABLE.load(Ordering::Relaxed), "openat2 must not have been reported missing");
        // Given raw paths, which the package layer never passes, the kernel still refuses to leave the directory.
        let resolve = rustix::fs::ResolveFlags::BENEATH | rustix::fs::ResolveFlags::NO_SYMLINKS | rustix::fs::ResolveFlags::NO_MAGICLINKS;
        let raw = |path: &str| rustix::fs::openat2(&root, path, READ_FLAGS, Mode::empty(), resolve).map(drop);
        assert_eq!(raw("../outside/secret.txt"), Err(Errno::XDEV));
        assert_eq!(raw("sub/../../outside/secret.txt"), Err(Errno::XDEV));
        assert_eq!(raw("/etc/hostname"), Err(Errno::XDEV));
        assert_eq!(raw("link.txt"), Err(Errno::LOOP));
        assert_eq!(raw("linkdir/secret.txt"), Err(Errno::LOOP));
        assert_eq!(raw("sub/../a.txt"), Ok(()));
    }

    #[test]
    fn created_files_and_directories_are_private_and_exclusive() {
        let (scratch, root) = Scratch::populated();
        let made = create_directory_at(&root, "made").expect("create directory");
        write_new_at(&made, "new.txt", b"new").expect("write");
        assert_eq!(std::fs::read(scratch.0.join("root/made/new.txt")).unwrap(), b"new");
        assert_eq!(std::fs::symlink_metadata(scratch.0.join("root/made")).unwrap().mode() & 0o777, 0o700);
        assert_eq!(std::fs::symlink_metadata(scratch.0.join("root/made/new.txt")).unwrap().mode() & 0o777, 0o600);
        // An existing name is never replaced or written through, whatever it is.
        assert!(write_new_at(&made, "new.txt", b"again").is_err());
        assert!(write_new_at(&root, "link.txt", b"owned").is_err());
        symlink(scratch.0.join("outside/created.txt"), scratch.0.join("root/dangling.txt")).unwrap();
        assert!(write_new_at(&root, "dangling.txt", b"owned").is_err());
        assert!(create_directory_at(&root, "linkdir").is_err());
        assert!(create_directory_at(&root, "a.txt").is_err());
        assert_eq!(std::fs::read(scratch.0.join("outside/secret.txt")).unwrap(), b"secret");
        assert!(!scratch.0.join("outside/created.txt").exists());
    }

    /// Without the flag, `rename` would put the new directory in place of the empty one.
    #[cfg(target_os = "linux")]
    #[test]
    fn the_exclusive_rename_refuses_whatever_is_at_the_destination() {
        let scratch = Scratch::new();
        let prepared = scratch.0.join("prepared");
        std::fs::create_dir(&prepared).unwrap();
        std::fs::write(prepared.join("main.jsx"), "new").unwrap();
        let empty = scratch.0.join("empty");
        std::fs::create_dir(&empty).unwrap();
        std::fs::write(scratch.0.join("file"), "mine").unwrap();
        symlink(scratch.0.join("nowhere"), scratch.0.join("dangling")).unwrap();
        for taken in ["empty", "file", "dangling"] {
            let error = rename_without_replacing(&prepared, &scratch.0.join(taken)).expect_err(taken);
            assert_eq!(error.kind(), io::ErrorKind::AlreadyExists, "{taken}");
        }
        assert!(prepared.join("main.jsx").exists());
        assert_eq!(std::fs::read_dir(&empty).unwrap().count(), 0);
        assert_eq!(std::fs::read(scratch.0.join("file")).unwrap(), b"mine");
        rename_without_replacing(&prepared, &scratch.0.join("free")).unwrap();
        assert_eq!(std::fs::read(scratch.0.join("free/main.jsx")).unwrap(), b"new");
        assert!(!prepared.exists());
    }

    #[test]
    fn unique_tokens_are_version_4_uuids() {
        let token = unique_token();
        assert_eq!(token.len(), 36);
        assert_eq!(token.as_bytes()[14], b'4');
        assert!(token.bytes().all(|byte| byte == b'-' || byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)), "{token}");
        assert_ne!(token, unique_token());
    }

    #[test]
    fn child_never_lets_a_rooted_name_replace_the_directory() {
        assert_eq!(child(Path::new("/data/root"), "/etc/passwd"), PathBuf::from("/data/root//etc/passwd"));
        assert_eq!(child(Path::new("/data/root/"), "a.js"), PathBuf::from("/data/root/a.js"));
    }
}
