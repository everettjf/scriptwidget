//! Where ScriptWidget keeps its data. The Linux counterpart of
//! `Windows/src/ScriptWidget.Core/Hosting/DataPaths.cs`, following the XDG
//! Base Directory Specification.
//!
//! - Data: `$XDG_DATA_HOME/scriptwidget`, or `~/.local/share/scriptwidget`.
//! - Cache: `$XDG_CACHE_HOME/scriptwidget`, or `~/.cache/scriptwidget`.
//!
//! As the specification requires, a variable that is unset, empty or not an
//! absolute path is ignored. `SCRIPTWIDGET_DATA` names one directory that
//! holds everything, the cache included, as on Windows; it is for tests and
//! for running a second, separate instance.

use std::ffi::OsString;
use std::io;
use std::os::unix::fs::DirBuilderExt;
use std::path::{Path, PathBuf};

const APPLICATION: &str = "scriptwidget";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DataPaths {
    root: PathBuf,
    cache: PathBuf,
}

impl DataPaths {
    /// The directories for this process: `root` when given, otherwise taken
    /// from the environment. The data and cache directories are created,
    /// readable by the user only, when they do not exist.
    pub fn new(root: Option<&Path>) -> io::Result<Self> {
        let paths = match root {
            Some(root) => Self::at(root)?,
            None => Self::locate(|name| std::env::var_os(name))?,
        };
        for directory in [&paths.root, &paths.cache] {
            std::fs::DirBuilder::new().recursive(true).mode(0o700).create(directory)?;
        }
        Ok(paths)
    }

    /// Everything, the cache included, below one directory.
    pub fn at(root: &Path) -> io::Result<Self> {
        let root = std::path::absolute(root)?;
        Ok(Self { cache: root.join("Cache"), root })
    }

    /// The directories an environment asks for; nothing is created.
    /// `variable` returns the value of an environment variable.
    pub fn locate(variable: impl Fn(&str) -> Option<OsString>) -> io::Result<Self> {
        if let Some(root) = variable("SCRIPTWIDGET_DATA").filter(|value| !value.is_empty()) {
            return Self::at(Path::new(&root));
        }
        let absolute = |name: &str| variable(name).map(PathBuf::from).filter(|path| path.is_absolute());
        let home = absolute("HOME");
        let base = |name: &str, fallback: &str| {
            absolute(name)
                .or_else(|| home.as_ref().map(|home| home.join(fallback)))
                .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, format!("neither {name} nor HOME names an absolute directory")))
        };
        Ok(Self { root: base("XDG_DATA_HOME", ".local/share")?.join(APPLICATION), cache: base("XDG_CACHE_HOME", ".cache")?.join(APPLICATION) })
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    /// Installed packages, one folder each.
    pub fn packages(&self) -> PathBuf {
        self.root.join("Packages")
    }

    /// Where packages are prepared before they are published into
    /// [`DataPaths::packages`] with a rename. Windows keeps this in its cache
    /// directory; here it is next to the packages, because `~/.cache` may be
    /// another filesystem (a separate subvolume or a tmpfs) and a rename
    /// cannot cross filesystems.
    pub fn package_staging(&self) -> PathBuf {
        self.root.join("Staging")
    }

    /// Package-scoped `$storage` files.
    pub fn storage(&self) -> PathBuf {
        self.root.join("Storage")
    }

    pub fn plugins(&self) -> PathBuf {
        self.root.join("Plugins")
    }

    /// Compiled artifacts, remote images and other data that can be rebuilt.
    pub fn cache(&self) -> &Path {
        &self.cache
    }

    /// The widgets placed on the desktop.
    pub fn widgets(&self) -> PathBuf {
        self.root.join("widgets.json")
    }

    pub fn settings(&self) -> PathBuf {
        self.root.join("settings.json")
    }

    /// The AI provider profile: endpoint and model, never a key (see [`crate::ai::profile_store`]).
    pub fn ai_profile(&self) -> PathBuf {
        self.root.join("ai-profile.json")
    }

    /// AI conversations, one file each (see [`crate::ai::conversation_store`]).
    pub fn ai_conversations(&self) -> PathBuf {
        self.root.join("AiConversations")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn located(variables: &[(&str, &str)]) -> io::Result<DataPaths> {
        DataPaths::locate(|name| variables.iter().find(|(key, _)| *key == name).map(|(_, value)| OsString::from(value)))
    }

    #[test]
    fn uses_the_xdg_directories() {
        let paths = located(&[("HOME", "/home/u"), ("XDG_DATA_HOME", "/data"), ("XDG_CACHE_HOME", "/cache")]).unwrap();
        assert_eq!(paths.root(), Path::new("/data/scriptwidget"));
        assert_eq!(paths.cache(), Path::new("/cache/scriptwidget"));
        assert_eq!(paths.packages(), Path::new("/data/scriptwidget/Packages"));
        assert_eq!(paths.package_staging(), Path::new("/data/scriptwidget/Staging"));
        assert_eq!(paths.storage(), Path::new("/data/scriptwidget/Storage"));
        assert_eq!(paths.plugins(), Path::new("/data/scriptwidget/Plugins"));
        assert_eq!(paths.widgets(), Path::new("/data/scriptwidget/widgets.json"));
        assert_eq!(paths.settings(), Path::new("/data/scriptwidget/settings.json"));
        assert_eq!(paths.ai_profile(), Path::new("/data/scriptwidget/ai-profile.json"));
        assert_eq!(paths.ai_conversations(), Path::new("/data/scriptwidget/AiConversations"));
    }

    #[test]
    fn falls_back_to_the_home_directory() {
        let paths = located(&[("HOME", "/home/u")]).unwrap();
        assert_eq!(paths.root(), Path::new("/home/u/.local/share/scriptwidget"));
        assert_eq!(paths.cache(), Path::new("/home/u/.cache/scriptwidget"));
    }

    #[test]
    fn ignores_relative_and_empty_values() {
        let paths = located(&[("HOME", "/home/u"), ("XDG_DATA_HOME", "relative/data"), ("XDG_CACHE_HOME", "")]).unwrap();
        assert_eq!(paths.root(), Path::new("/home/u/.local/share/scriptwidget"));
        assert_eq!(paths.cache(), Path::new("/home/u/.cache/scriptwidget"));
        let mixed = located(&[("HOME", "/home/u"), ("XDG_DATA_HOME", "./data"), ("XDG_CACHE_HOME", "/cache")]).unwrap();
        assert_eq!(mixed.root(), Path::new("/home/u/.local/share/scriptwidget"));
        assert_eq!(mixed.cache(), Path::new("/cache/scriptwidget"));
    }

    #[test]
    fn fails_without_any_absolute_base() {
        assert!(located(&[]).is_err());
        assert!(located(&[("HOME", "home/u")]).is_err());
        assert!(located(&[("HOME", ""), ("XDG_DATA_HOME", "/data")]).is_err(), "the cache has no base");
        let paths = located(&[("XDG_DATA_HOME", "/data"), ("XDG_CACHE_HOME", "/cache")]).unwrap();
        assert_eq!(paths.root(), Path::new("/data/scriptwidget"));
    }

    #[test]
    fn one_directory_can_hold_everything() {
        let paths = located(&[("HOME", "/home/u"), ("XDG_DATA_HOME", "/data"), ("SCRIPTWIDGET_DATA", "/srv/sw")]).unwrap();
        assert_eq!(paths.root(), Path::new("/srv/sw"));
        assert_eq!(paths.cache(), Path::new("/srv/sw/Cache"));
        assert_eq!(located(&[("HOME", "/home/u"), ("SCRIPTWIDGET_DATA", "")]).unwrap().root(), Path::new("/home/u/.local/share/scriptwidget"));
    }

    #[test]
    fn creates_private_directories() {
        use std::os::unix::fs::MetadataExt;
        let root = std::env::temp_dir().join(format!("scriptwidget-data-paths-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let paths = DataPaths::new(Some(&root.join("nested"))).unwrap();
        assert_eq!(std::fs::metadata(paths.root()).unwrap().mode() & 0o777, 0o700);
        assert_eq!(std::fs::metadata(paths.cache()).unwrap().mode() & 0o777, 0o700);
        std::fs::remove_dir_all(&root).unwrap();
    }
}
