//! Where the service meets its clients: `$XDG_RUNTIME_DIR/scriptwidget/`,
//! with the socket, the lock that keeps a second service from starting, and
//! the pictures.
//!
//! The runtime directory is the one place the session gives a user alone
//! (the XDG specification: owned by the user, mode 0700, gone at log-out).
//! There is no fallback to `/tmp`: without it the service does not start.

use std::ffi::OsString;
use std::io;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};

const APPLICATION: &str = "scriptwidget";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RuntimePaths {
    directory: PathBuf,
}

impl RuntimePaths {
    /// The paths under the runtime directory of this session, or an error when the session has none.
    pub fn from_environment() -> io::Result<Self> {
        Self::locate(|name| std::env::var_os(name))
    }

    pub fn locate(variable: impl Fn(&str) -> Option<OsString>) -> io::Result<Self> {
        match variable("XDG_RUNTIME_DIR").map(PathBuf::from).filter(|path| path.is_absolute()) {
            Some(runtime) => Ok(Self::under(&runtime)),
            None => Err(io::Error::new(io::ErrorKind::NotFound, "XDG_RUNTIME_DIR does not name an absolute directory; ScriptWidget needs the runtime directory of a login session")),
        }
    }

    /// The paths under a given runtime directory.
    pub fn under(runtime_directory: &Path) -> Self {
        Self { directory: runtime_directory.join(APPLICATION) }
    }

    pub fn directory(&self) -> &Path {
        &self.directory
    }

    pub fn socket(&self) -> PathBuf {
        self.directory.join("host.sock")
    }

    pub fn lock(&self) -> PathBuf {
        self.directory.join("host.lock")
    }

    pub fn frames(&self) -> PathBuf {
        self.directory.join("frames")
    }

    /// Creates the directory and the one for the pictures, both for the user
    /// alone, and refuses anything that is not that: a link, a directory of
    /// another user, or one that others can enter.
    pub fn prepare(&self) -> io::Result<()> {
        // SAFETY: geteuid has no preconditions and cannot fail.
        let user = unsafe { libc::geteuid() };
        for directory in [self.directory.clone(), self.frames()] {
            match std::fs::DirBuilder::new().mode(0o700).create(&directory) {
                Ok(()) => {}
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
                Err(error) => return Err(io::Error::new(error.kind(), format!("{}: {error}", directory.display()))),
            }
            let metadata = std::fs::symlink_metadata(&directory)?;
            if !metadata.is_dir() || metadata.uid() != user {
                return Err(io::Error::new(io::ErrorKind::PermissionDenied, format!("{} is not a directory of this user", directory.display())));
            }
            if metadata.mode() & 0o077 != 0 {
                // Ours, but opened up by something: close it again before anything is put inside.
                std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700))?;
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn needs_an_absolute_runtime_directory() {
        let located = |value: Option<&str>| RuntimePaths::locate(|_| value.map(OsString::from));
        assert_eq!(located(Some("/run/user/1000")).unwrap().socket(), Path::new("/run/user/1000/scriptwidget/host.sock"));
        assert_eq!(located(Some("/run/user/1000")).unwrap().frames(), Path::new("/run/user/1000/scriptwidget/frames"));
        assert!(located(None).is_err());
        assert!(located(Some("")).is_err());
        assert!(located(Some("run/user")).is_err());
    }

    #[test]
    fn prepares_private_directories_and_refuses_a_link() {
        let root = std::env::temp_dir().join(format!("sw-host-paths-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let paths = RuntimePaths::under(&root);
        paths.prepare().unwrap();
        assert_eq!(std::fs::metadata(paths.directory()).unwrap().mode() & 0o777, 0o700);
        assert_eq!(std::fs::metadata(paths.frames()).unwrap().mode() & 0o777, 0o700);
        // Opened up by something else: closed again.
        std::fs::set_permissions(paths.frames(), std::fs::Permissions::from_mode(0o755)).unwrap();
        paths.prepare().unwrap();
        assert_eq!(std::fs::metadata(paths.frames()).unwrap().mode() & 0o777, 0o700);
        // A link where the pictures should be is never followed.
        std::fs::remove_dir(paths.frames()).unwrap();
        std::fs::create_dir(root.join("elsewhere")).unwrap();
        std::os::unix::fs::symlink(root.join("elsewhere"), paths.frames()).unwrap();
        assert!(paths.prepare().is_err());
        std::fs::remove_dir_all(&root).unwrap();
    }
}
