//! The pictures the display shows: PNG files in
//! `$XDG_RUNTIME_DIR/scriptwidget/frames/`.
//!
//! A picture is written under a hidden temporary name and renamed, so the
//! display never reads half a file. Every picture gets a name that was never
//! used before, in this run of the service or an earlier one: a display that
//! is told the same path again does not load it again. The name is
//! `<widget>-<run>-<version>.png`, or `<widget>-<run>-<version>-<frame>.png`
//! for the frames of an animation, where `<run>` is random for each start of
//! the service.

use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

pub struct FrameStore {
    directory: PathBuf,
    run: String,
}

impl FrameStore {
    /// Opens the directory, which must exist (see `RuntimePaths::prepare`), and removes what an earlier run left in it.
    pub fn new(directory: PathBuf) -> std::io::Result<Self> {
        let mut token = [0u8; 4];
        getrandom::fill(&mut token).map_err(|error| std::io::Error::other(error.to_string()))?;
        let store = Self { directory, run: token.iter().map(|byte| format!("{byte:02x}")).collect() };
        store.clear()?;
        Ok(store)
    }

    pub fn directory(&self) -> &Path {
        &self.directory
    }

    /// Removes every picture. Only regular files directly in the directory are touched; nothing is followed.
    pub fn clear(&self) -> std::io::Result<()> {
        for entry in std::fs::read_dir(&self.directory)? {
            let entry = entry?;
            if entry.file_type().is_ok_and(|kind| kind.is_file() || kind.is_symlink()) {
                let _ = std::fs::remove_file(entry.path());
            }
        }
        Ok(())
    }

    /// Where a job writes frame `index` before the picture is published. `job` is unique in this run.
    pub fn temporary(&self, job: u64, index: usize) -> PathBuf {
        self.directory.join(format!(".job-{}-{job}-{index}.tmp", self.run))
    }

    /// The published name of a picture of `id`. `frame` is `None` for a picture that does not move.
    pub fn published(&self, id: &str, version: u64, frame: Option<usize>) -> PathBuf {
        self.directory.join(match frame {
            Some(frame) => format!("{id}-{}-{version}-{frame}.png", self.run),
            None => format!("{id}-{}-{version}.png", self.run),
        })
    }

    /// Writes a new private file; fails when anything already has the name.
    pub fn write(&self, path: &Path, bytes: &[u8]) -> std::io::Result<()> {
        let mut file = std::fs::OpenOptions::new().write(true).create_new(true).custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC).mode(0o600).open(path)?;
        file.write_all(bytes).inspect_err(|_| {
            let _ = std::fs::remove_file(path);
        })
    }

    pub fn publish(&self, temporary: &Path, published: &Path) -> std::io::Result<()> {
        std::fs::rename(temporary, published)
    }

    pub fn remove(&self, paths: &[PathBuf]) {
        for path in paths {
            // Only files of this directory, whatever the caller kept.
            if path.parent() == Some(self.directory.as_path()) {
                let _ = std::fs::remove_file(path);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_are_new_in_every_run_and_old_pictures_are_removed() {
        let directory = std::env::temp_dir().join(format!("sw-host-frames-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&directory);
        std::fs::create_dir_all(&directory).unwrap();
        let first = FrameStore::new(directory.clone()).unwrap();
        let temporary = first.temporary(7, 0);
        assert!(temporary.file_name().unwrap().to_str().unwrap().starts_with('.'));
        first.write(&temporary, b"png").unwrap();
        assert!(first.write(&temporary, b"again").is_err(), "a name is written once");
        use std::os::unix::fs::MetadataExt;
        assert_eq!(std::fs::metadata(&temporary).unwrap().mode() & 0o777, 0o600);
        let published = first.published("0123456789abcdef", 1, None);
        first.publish(&temporary, &published).unwrap();
        assert!(published.is_file() && !temporary.exists());
        assert_ne!(first.published("0123456789abcdef", 1, Some(0)), published);

        let second = FrameStore::new(directory.clone()).unwrap();
        assert!(!published.exists(), "a new run starts with an empty directory");
        assert_ne!(second.published("0123456789abcdef", 1, None), published, "and never reuses a name");
        // Removing only ever touches this directory.
        let outside = directory.parent().unwrap().join(format!("sw-host-frames-outside-{}", std::process::id()));
        std::fs::write(&outside, b"keep").unwrap();
        second.remove(&[outside.clone()]);
        assert!(outside.exists());
        std::fs::remove_file(outside).unwrap();
        std::fs::remove_dir_all(directory).unwrap();
    }
}
