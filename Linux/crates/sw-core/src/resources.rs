//! Where the read-only files that ship with the programs are: the generated
//! JavaScript (`runtime/`, what `Linux/scripts/build-shared-js.mjs` writes)
//! and the bundled templates (`templates/template`, `templates/component`,
//! `templates/api`). Windows keeps both next to the program; a Linux package
//! installs them under a data directory:
//!
//! ```text
//! /usr/bin/scriptwidget
//! /usr/share/scriptwidget/runtime/kernel.js …
//! /usr/share/scriptwidget/templates/template/<Name>/main.jsx …
//! ```
//!
//! `Linux/scripts/stage-resources.sh` assembles that directory. The first
//! of these that holds `runtime/kernel.js` is used:
//!
//! 1. `SCRIPTWIDGET_RESOURCES`, when set. Nothing else is tried then.
//! 2. `../share/scriptwidget` from the directory of the program, so that an
//!    unpacked release and any installation prefix work without settings.
//! 3. `scriptwidget` in each directory of `XDG_DATA_DIRS`
//!    (`/usr/local/share` and `/usr/share` when it is unset).
//!
//! For development and tests each half can be named on its own, which takes
//! precedence over the above: `SCRIPTWIDGET_RUNTIME_ASSETS` (in a checkout,
//! `Linux/assets/scriptwidget`) and `SCRIPTWIDGET_TEMPLATES` (in a checkout,
//! `Shared/ScriptWidgetRuntime/Resource/Script.bundle`). Nothing is compiled
//! into the program, so it never needs the repository.
//!
//! These directories are trusted in the sense that the user or the package
//! manager chose them; the templates are still read as packages, through the
//! same checks as any other.

use std::ffi::OsString;
use std::io;
use std::path::{Path, PathBuf};

pub const ROOT_VARIABLE: &str = "SCRIPTWIDGET_RESOURCES";
pub const RUNTIME_VARIABLE: &str = "SCRIPTWIDGET_RUNTIME_ASSETS";
pub const TEMPLATES_VARIABLE: &str = "SCRIPTWIDGET_TEMPLATES";

const APPLICATION: &str = "scriptwidget";
const RUNTIME: &str = "runtime";
const TEMPLATES: &str = "templates";
const MARKER: &str = "kernel.js";

/// The resource directories of this process.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Resources {
    /// The folder with `kernel.js` and the other generated scripts.
    pub runtime: PathBuf,
    /// The folder with the template groups; `None` when no location has one.
    pub templates: Option<PathBuf>,
}

impl Resources {
    /// The directories for this process, from its environment and the place of its executable.
    pub fn locate() -> io::Result<Self> {
        let executable = std::env::current_exe().ok().map(|path| std::fs::canonicalize(&path).unwrap_or(path));
        Self::locate_with(|name| std::env::var_os(name), executable.as_deref(), &|path| path.is_file(), &|path| path.is_dir())
    }

    /// [`Resources::locate`] with everything it reads passed in.
    pub fn locate_with(variable: impl Fn(&str) -> Option<OsString>, executable: Option<&Path>, is_file: &dyn Fn(&Path) -> bool, is_directory: &dyn Fn(&Path) -> bool) -> io::Result<Self> {
        let named = |name: &str| variable(name).filter(|value| !value.is_empty()).map(|value| std::path::absolute(Path::new(&value)).unwrap_or_else(|_| PathBuf::from(value)));
        let roots = roots(&variable, executable);
        let root = roots.iter().find(|root| is_file(&root.join(RUNTIME).join(MARKER)));
        let runtime = match (named(RUNTIME_VARIABLE), root) {
            (Some(runtime), _) => runtime,
            (None, Some(root)) => root.join(RUNTIME),
            (None, None) => {
                let tried: Vec<String> = roots.iter().map(|root| root.join(RUNTIME).display().to_string()).collect();
                return Err(io::Error::new(
                    io::ErrorKind::NotFound,
                    format!("The ScriptWidget runtime files were not found (looked in {}). Install the package, or set {ROOT_VARIABLE} or {RUNTIME_VARIABLE}.", tried.join(", ")),
                ));
            }
        };
        let templates = named(TEMPLATES_VARIABLE).or_else(|| root.map(|root| root.join(TEMPLATES)).filter(|path| is_directory(path)));
        Ok(Self { runtime, templates })
    }
}

/// The resource roots to try, in order.
fn roots(variable: &impl Fn(&str) -> Option<OsString>, executable: Option<&Path>) -> Vec<PathBuf> {
    if let Some(root) = variable(ROOT_VARIABLE).filter(|value| !value.is_empty()) {
        return vec![std::path::absolute(Path::new(&root)).unwrap_or_else(|_| PathBuf::from(root))];
    }
    let mut roots = Vec::new();
    if let Some(prefix) = executable.and_then(Path::parent).and_then(Path::parent) {
        roots.push(prefix.join("share").join(APPLICATION));
    }
    let data_directories = variable("XDG_DATA_DIRS").filter(|value| !value.is_empty()).unwrap_or_else(|| "/usr/local/share:/usr/share".into());
    // As the XDG specification requires, a relative entry is ignored.
    for directory in std::env::split_paths(&data_directories).filter(|path| path.is_absolute()) {
        let root = directory.join(APPLICATION);
        if !roots.contains(&root) {
            roots.push(root);
        }
    }
    roots
}

#[cfg(test)]
mod tests {
    use super::*;

    fn located(variables: &[(&str, &str)], executable: Option<&str>, files: &[&str]) -> io::Result<Resources> {
        Resources::locate_with(
            |name| variables.iter().find(|(key, _)| *key == name).map(|(_, value)| OsString::from(value)),
            executable.map(Path::new),
            &|path| files.iter().any(|file| Path::new(file) == path),
            &|path| files.iter().any(|file| Path::new(file).starts_with(path) && Path::new(file) != path),
        )
    }

    #[test]
    fn the_installed_layout_is_found_from_the_program() {
        let found = located(&[], Some("/opt/sw/bin/scriptwidget"), &["/opt/sw/share/scriptwidget/runtime/kernel.js", "/opt/sw/share/scriptwidget/templates/api/x/main.jsx"]).unwrap();
        assert_eq!(found.runtime, Path::new("/opt/sw/share/scriptwidget/runtime"));
        assert_eq!(found.templates.as_deref(), Some(Path::new("/opt/sw/share/scriptwidget/templates")));
    }

    #[test]
    fn the_system_data_directories_follow() {
        let found = located(&[], Some("/home/u/bin/scriptwidget"), &["/usr/share/scriptwidget/runtime/kernel.js"]).unwrap();
        assert_eq!(found.runtime, Path::new("/usr/share/scriptwidget/runtime"));
        assert_eq!(found.templates, None, "a root without templates has none");
        let found = located(&[("XDG_DATA_DIRS", "relative:/nix/share")], None, &["/nix/share/scriptwidget/runtime/kernel.js", "/usr/share/scriptwidget/runtime/kernel.js"]).unwrap();
        assert_eq!(found.runtime, Path::new("/nix/share/scriptwidget/runtime"));
    }

    #[test]
    fn the_root_variable_replaces_every_other_place() {
        let files = ["/usr/share/scriptwidget/runtime/kernel.js", "/dev/res/runtime/kernel.js", "/dev/res/templates/api/x/main.jsx"];
        let found = located(&[("SCRIPTWIDGET_RESOURCES", "/dev/res")], Some("/usr/bin/scriptwidget"), &files).unwrap();
        assert_eq!(found.runtime, Path::new("/dev/res/runtime"));
        assert_eq!(found.templates.as_deref(), Some(Path::new("/dev/res/templates")));
        let missing = located(&[("SCRIPTWIDGET_RESOURCES", "/nowhere")], Some("/usr/bin/scriptwidget"), &files).unwrap_err();
        assert_eq!(missing.kind(), io::ErrorKind::NotFound);
        assert!(missing.to_string().contains("/nowhere/runtime"), "{missing}");
    }

    #[test]
    fn each_half_can_be_named_on_its_own() {
        let found = located(&[("SCRIPTWIDGET_RUNTIME_ASSETS", "/repo/Linux/assets/scriptwidget"), ("SCRIPTWIDGET_TEMPLATES", "/repo/Script.bundle")], None, &[]).unwrap();
        assert_eq!(found.runtime, Path::new("/repo/Linux/assets/scriptwidget"));
        assert_eq!(found.templates.as_deref(), Some(Path::new("/repo/Script.bundle")));
        let mixed = located(&[("SCRIPTWIDGET_TEMPLATES", "/repo/Script.bundle")], Some("/usr/bin/scriptwidget"), &["/usr/share/scriptwidget/runtime/kernel.js"]).unwrap();
        assert_eq!(mixed.runtime, Path::new("/usr/share/scriptwidget/runtime"));
        assert_eq!(mixed.templates.as_deref(), Some(Path::new("/repo/Script.bundle")));
    }

    #[test]
    fn nothing_found_is_an_error_that_names_the_places() {
        let error = located(&[], Some("/usr/bin/scriptwidget"), &[]).unwrap_err();
        assert!(error.to_string().contains("/usr/share/scriptwidget/runtime") && error.to_string().contains("SCRIPTWIDGET_RESOURCES"), "{error}");
    }
}
