//! The library of installed packages. Ported from `PackageStore.cs`, itself
//! `ScriptManager` in Swift.

use std::collections::{BTreeMap, HashSet};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};

use serde_json::Value;

use super::archive::{self, ExtractedPackage};
use super::disk_files::DiskPackageFiles;
use super::error::{PackageError, codes};
use super::limits::{ArchiveLimits, MAX_FILE_BYTES, MAX_METADATA_BYTES, MAX_NAME_ATTEMPTS, MAX_SCRIPT_BYTES};
use super::{file_remover, file_writer, manifests, names, path_rules, safe_files, tree};
use crate::json::Object;
use crate::package_files::PackageFiles;

/// One installed package as shown in the library. The manifest fields are
/// display values read leniently from `widget.json`; they are `None` when the
/// manifest is absent, unreadable or the field is not a string. They are not
/// validated.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PackageInfo {
    /// The package (directory) name.
    pub name: String,
    /// Absolute path of the package directory.
    pub directory: PathBuf,
    /// True when any spelling of `widget.json` is present; such a package is never treated as legacy.
    pub has_manifest: bool,
    pub manifest_id: Option<String>,
    pub manifest_name: Option<String>,
    pub manifest_version: Option<String>,
}

/// A check run on a staged package before it is published; an error vetoes the import.
pub type ImportValidator<'a> = &'a dyn Fn(&dyn PackageFiles) -> Result<(), PackageError>;

/// The library of installed packages, one directory per package under
/// `library_root/<PackageName>/`.
///
/// Everything that enters the library is prepared in a unique directory under
/// the staging root and published with one atomic rename, so a failed create,
/// import or duplicate leaves no partial package. The staging root must be on
/// the same filesystem as the library root and must not be inside it. Package
/// names follow [`names::is_valid`], and a name is usable only when no other
/// library entry has the same identity after case folding and NFC
/// normalization.
///
/// Mutations are serialized per store instance; use one instance per library.
#[derive(Debug)]
pub struct PackageStore {
    library: PathBuf,
    staging: PathBuf,
    limits: ArchiveLimits,
    gate: Mutex<()>,
}

impl PackageStore {
    pub fn new(library_root: impl AsRef<Path>, staging_root: impl AsRef<Path>) -> Self {
        Self::with_limits(library_root, staging_root, ArchiveLimits::default())
    }

    pub fn with_limits(library_root: impl AsRef<Path>, staging_root: impl AsRef<Path>, limits: ArchiveLimits) -> Self {
        Self { library: safe_files::root(library_root.as_ref()), staging: safe_files::root(staging_root.as_ref()), limits, gate: Mutex::new(()) }
    }

    /// Installed packages sorted by name. Entries that are links, files, invalid or ambiguous names are not packages.
    pub fn list(&self) -> Result<Vec<PackageInfo>, PackageError> {
        let names = self.library_names()?;
        let mut sorted: Vec<&String> = names.iter().collect();
        sorted.sort_unstable();
        let mut result = Vec::new();
        for name in sorted {
            if !names::is_valid(name) || !safe_files::unambiguous(&names, name) {
                continue;
            }
            let directory = safe_files::child(&self.library, name);
            if safe_files::real_directory(&directory) {
                result.push(info(name, directory));
            }
        }
        Ok(result)
    }

    /// Read-only, boundary-checked view of an installed package.
    pub fn files(&self, name: &str) -> Result<DiskPackageFiles, PackageError> {
        Ok(DiskPackageFiles::new(self.existing(name)?))
    }

    /// `recommended` if it is free, otherwise the first free `"<stem> (n)"`
    /// for n in 1…10000, with the stem shortened to keep the name limits
    /// (`ScriptManager.getValidPackageName`).
    ///
    /// Fails with `invalid_name` when `recommended` is invalid or no name is free.
    pub fn unique_name(&self, recommended: &str) -> Result<String, PackageError> {
        let _guard = self.lock();
        self.unique_name_locked(recommended)
    }

    fn unique_name_locked(&self, recommended: &str) -> Result<String, PackageError> {
        require_valid(recommended)?;
        let identities: HashSet<String> = self.library_names()?.iter().map(|name| names::identity(name)).collect();
        let available = |name: &str| names::is_valid(name) && !identities.contains(&names::identity(name));
        if available(recommended) {
            return Ok(recommended.to_owned());
        }
        (1..=MAX_NAME_ATTEMPTS)
            .map(|index| names::with_suffix(recommended, &format!(" ({index})")))
            .find(|candidate| available(candidate))
            .ok_or_else(|| PackageError::new(codes::INVALID_NAME, "No free package name is available."))
    }

    /// Creates a package named exactly `name` from `main_source` and a
    /// manifest. Without `manifest_json` a default Package 2.0 manifest is
    /// generated. The source is written to the manifest's `entry` (default
    /// `main.jsx`). The package becomes visible only after source and
    /// manifest are fully written.
    ///
    /// `manifest_json` must be a JSON object of at most 256 KiB with a safe
    /// `.js`/`.jsx` entry path; its semantic validation is the caller's
    /// responsibility.
    ///
    /// Fails with `invalid_name`, `package_exists`, `invalid_manifest`, `invalid_entry` or `file_too_large`.
    pub fn create(&self, name: &str, main_source: &str, manifest_json: Option<&str>) -> Result<PackageInfo, PackageError> {
        require_valid(name)?;
        if main_source.len() > MAX_SCRIPT_BYTES {
            return Err(PackageError::new(codes::FILE_TOO_LARGE, "Script source exceeds 512 KiB."));
        }
        let mut entry = manifests::LEGACY_ENTRY.to_owned();
        let manifest_bytes = match manifest_json {
            None => manifests::encode(&manifests::new_manifest(name)),
            Some(text) => {
                if text.len() > MAX_METADATA_BYTES {
                    return Err(PackageError::new(codes::FILE_TOO_LARGE, "widget.json exceeds 256 KiB."));
                }
                let invalid = || PackageError::new(codes::INVALID_MANIFEST, "widget.json is invalid.");
                let manifest = manifests::parse(Some(text)).ok_or_else(invalid)?;
                entry = manifests::string_value(&manifest, "entry").ok_or_else(invalid)?;
                if path_rules::visible_components(&entry).is_none() || entry == manifests::FILE_NAME || !is_entry_file(&entry) {
                    return Err(PackageError::new(codes::INVALID_ENTRY, "entry must be a package-relative .js or .jsx file."));
                }
                text.as_bytes().to_vec()
            }
        };
        self.staged("create", |prepared| {
            file_writer::write(prepared, &entry, main_source.as_bytes())?;
            file_writer::write(prepared, manifests::FILE_NAME, &manifest_bytes)?;
            tree::validate_tree(prepared, &self.limits)?;
            let _guard = self.lock();
            if !self.free(name)? {
                return Err(PackageError::new(codes::PACKAGE_EXISTS, "A package with this name already exists."));
            }
            let destination = safe_files::child(&self.library, name);
            safe_files::publish(prepared, &destination)?;
            Ok(info(name, destination))
        })
    }

    /// Imports a `.swt` archive and returns the installed package.
    ///
    /// The archive is preflighted and extracted by [`archive::extract`]. The
    /// installed directory name comes from the manifest's `name`, never from
    /// the archive file name; on a collision it gets the next free `" (n)"`
    /// suffix ([`PackageStore::unique_name`]). A package without
    /// `widget.json` is legacy: it must contain `main.jsx` and receives a
    /// generated manifest named after the archive's top-level directory, or
    /// `suggested_name` when the files sit at the archive root. A present
    /// manifest is authoritative: a wrongly cased, non-UTF-8, non-object or
    /// nameless `widget.json` fails the import instead of being reinterpreted
    /// as legacy.
    ///
    /// `validate` runs on the staged package before publication (plug the
    /// shared manifest validator, [`crate::PackageCompiler::validate_manifest`],
    /// in here); if it fails, nothing is installed. A rejected import leaves
    /// nothing in the library or the staging directory.
    pub fn import_archive(&self, input: &mut dyn Read, suggested_name: Option<&str>, validate: Option<ImportValidator<'_>>) -> Result<PackageInfo, PackageError> {
        let extracted: ExtractedPackage = archive::extract(input, &self.staging, &self.limits)?;
        let prepared = extracted.directory();
        let files = DiskPackageFiles::new(prepared);
        let name = if manifest_present(prepared)? {
            manifests::string_value(&read_manifest(&files)?, "name").ok_or_else(|| PackageError::new(codes::INVALID_MANIFEST, "widget.json is invalid."))?
        } else {
            if !files.exists(manifests::LEGACY_ENTRY) {
                return Err(PackageError::new(codes::MISSING_ENTRY, "Entry file main.jsx does not exist."));
            }
            let name = match (extracted.root_name(), suggested_name) {
                (Some(root), _) => root.to_owned(),
                (None, Some(suggested)) if names::is_valid(suggested) => suggested.to_owned(),
                _ => "Imported Widget".to_owned(),
            };
            require_valid(&name)?;
            file_writer::write(prepared, manifests::FILE_NAME, &manifests::encode(&legacy_manifest(&name, &files)))?;
            name
        };
        require_valid(&name)?;
        if let Some(validate) = validate {
            validate(&files)?;
        }
        let _guard = self.lock();
        let installed = self.unique_name_locked(&name)?;
        let destination = safe_files::child(&self.library, &installed);
        extracted.move_to(&destination)?;
        Ok(info(&installed, destination))
    }

    /// Exports an installed package as a `.swt` archive under one top-level
    /// directory named after the package. `__Build`, dot-files and links are
    /// not exported. A legacy package is exported with a generated
    /// `widget.json` (the installed package is not modified); a package whose
    /// present manifest is unreadable is not exported.
    pub fn export_archive(&self, name: &str, output: &mut dyn Write) -> Result<(), PackageError> {
        export_directory(&self.existing(name)?, name, output, &self.limits)
    }

    /// Copies a package to a new `"<name> Remix"` package (made unique like
    /// [`PackageStore::unique_name`]) and returns it. The source tree must be
    /// free of links and special files. `__Build` and dot-files are not
    /// copied. A Package 2.0 copy gets a fresh `id` and its new name; a
    /// legacy package stays legacy (`ScriptManager.duplicateScript`).
    pub fn duplicate(&self, name: &str) -> Result<PackageInfo, PackageError> {
        let source = self.existing(name)?;
        tree::validate_tree(&source, &self.limits)?;
        let files = DiskPackageFiles::new(&source);
        let mut manifest = if manifest_present(&source)? { Some(read_manifest(&files)?) } else { None };
        self.staged("duplicate", |prepared| {
            for path in files.list()? {
                let bytes = files.read_bytes_up_to(&path, self.limits.maximum_file_bytes).ok_or_else(|| PackageError::new(codes::UNSAFE_FILE, "Package file could not be verified."))?;
                file_writer::write(prepared, &path, &bytes)?;
            }
            let _guard = self.lock();
            let copy = self.unique_name_locked(&names::with_suffix(name, " Remix"))?;
            if let Some(manifest) = &mut manifest {
                manifest.insert("id".into(), Value::String(manifests::fresh_id()));
                manifest.insert("name".into(), Value::String(copy.clone()));
                file_writer::write(prepared, manifests::FILE_NAME, &manifests::encode(manifest))?;
            }
            tree::validate_tree(prepared, &self.limits)?;
            let destination = safe_files::child(&self.library, &copy);
            safe_files::publish(prepared, &destination)?;
            Ok(info(&copy, destination))
        })
    }

    /// Renames a package directory atomically. The manifest is left
    /// unchanged, as in Swift. `new_name` must be valid and free; a change of
    /// case only is refused as ambiguous.
    pub fn rename(&self, name: &str, new_name: &str) -> Result<PackageInfo, PackageError> {
        let _guard = self.lock();
        let source = self.existing(name)?;
        require_valid(new_name)?;
        let destination = safe_files::child(&self.library, new_name);
        if name != new_name {
            if !self.free(new_name)? {
                return Err(PackageError::new(codes::PACKAGE_EXISTS, "A package with this name already exists."));
            }
            safe_files::publish(&source, &destination)?;
        }
        Ok(info(new_name, destination))
    }

    /// Deletes a package. The directory first leaves the library with one
    /// atomic rename into staging, so it disappears at once; its contents are
    /// then removed without following links.
    pub fn delete(&self, name: &str) -> Result<(), PackageError> {
        let _guard = self.lock();
        let directory = self.existing(name)?;
        let moved = safe_files::new_work_directory(&self.staging, "delete").is_ok_and(|work| {
            let moved = std::fs::rename(&directory, safe_files::child(&work, "package")).is_ok();
            safe_files::delete_tree(&work);
            moved
        });
        if !moved {
            safe_files::delete_tree(&directory);
        }
        if safe_files::occupied(&directory) {
            return Err(PackageError::new(codes::STORAGE_UNAVAILABLE, "The widget could not be deleted."));
        }
        Ok(())
    }

    /// Atomically writes one file of an installed package. See the package
    /// file writer for the path, link and size rules. A new file is refused
    /// once the package holds 500 files.
    pub fn write_file(&self, name: &str, relative_path: &str, bytes: &[u8]) -> Result<(), PackageError> {
        let _guard = self.lock();
        let directory = self.existing(name)?;
        let files = DiskPackageFiles::new(&directory);
        if !files.exists(relative_path) && files.list()?.len() >= self.limits.maximum_file_count {
            return Err(PackageError::new(codes::TOO_MANY_ENTRIES, "Package contains too many entries."));
        }
        file_writer::write(&directory, relative_path, bytes)
    }

    /// Removes one file of an installed package, under the path and link
    /// rules of the package file writer. A file that is already gone is not an error.
    pub fn delete_file(&self, name: &str, relative_path: &str) -> Result<(), PackageError> {
        let _guard = self.lock();
        let directory = self.existing(name)?;
        file_remover::remove(&directory, relative_path)
    }

    /// Bytes of one file of an installed package, at most 25 MiB, under the rules of [`DiskPackageFiles`].
    ///
    /// Fails with `invalid_path` for an unsafe path and `file_not_found` when the file is missing, refused or too large.
    pub fn read_file(&self, name: &str, relative_path: &str) -> Result<Vec<u8>, PackageError> {
        let directory = self.existing(name)?;
        if path_rules::visible_components(relative_path).is_none() {
            return Err(PackageError::new(codes::INVALID_PATH, "Invalid package path."));
        }
        DiskPackageFiles::new(directory).read_bytes_up_to(relative_path, MAX_FILE_BYTES).ok_or_else(|| PackageError::new(codes::FILE_NOT_FOUND, format!("File not found: {relative_path}")))
    }

    fn lock(&self) -> MutexGuard<'_, ()> {
        self.gate.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Runs `build` on a fresh staging directory that is removed afterwards unless it was published.
    fn staged<T>(&self, prefix: &str, build: impl FnOnce(&Path) -> Result<T, PackageError>) -> Result<T, PackageError> {
        let work = safe_files::new_work_directory(&self.staging, prefix)?;
        let prepared = safe_files::child(&work, "package");
        let result = safe_files::create_private_directory(&prepared).map_err(|error| PackageError::caused(codes::STORAGE_UNAVAILABLE, "The package could not be prepared.", error)).and_then(|()| build(&prepared));
        safe_files::delete_tree(&work);
        result
    }

    /// Entry names of the library, which is created when it does not exist yet. Names that are not UTF-8 are not packages.
    fn library_names(&self) -> Result<Vec<String>, PackageError> {
        use std::os::unix::fs::DirBuilderExt;
        let _ = std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&self.library);
        safe_files::names(&self.library).map(|listing| listing.names).ok_or_else(|| PackageError::new(codes::STORAGE_UNAVAILABLE, "The widget library is unavailable."))
    }

    /// True when no library entry shares the identity of `name`.
    fn free(&self, name: &str) -> Result<bool, PackageError> {
        let identity = names::identity(name);
        Ok(!self.library_names()?.iter().any(|other| names::identity(other) == identity))
    }

    /// Directory of an installed package: a valid, exactly spelled, unambiguous name that is a real directory.
    fn existing(&self, name: &str) -> Result<PathBuf, PackageError> {
        require_valid(name)?;
        let names = self.library_names()?;
        let directory = safe_files::child(&self.library, name);
        if names.iter().any(|other| other == name) && safe_files::unambiguous(&names, name) && safe_files::real_directory(&directory) {
            Ok(directory)
        } else {
            Err(PackageError::new(codes::PACKAGE_NOT_FOUND, "Package not found."))
        }
    }
}

/// Exports the package in `directory` as a `.swt` archive under one top-level
/// directory named `name`, under the rules of [`PackageStore::export_archive`].
/// The directory need not be in a library: the command line packs a package
/// from where its author keeps it.
pub fn export_directory(directory: &Path, name: &str, output: &mut dyn Write, limits: &ArchiveLimits) -> Result<(), PackageError> {
    let files = DiskPackageFiles::new(directory);
    let mut extras = BTreeMap::new();
    if manifest_present(directory)? {
        read_manifest(&files)?;
    } else {
        if !files.exists(manifests::LEGACY_ENTRY) {
            return Err(PackageError::new(codes::MISSING_ENTRY, "Entry file main.jsx does not exist."));
        }
        extras.insert(manifests::FILE_NAME.to_owned(), manifests::encode(&legacy_manifest(name, &files)));
    }
    archive::export(directory, name, output, &extras, limits)
}

fn require_valid(name: &str) -> Result<(), PackageError> {
    if names::is_valid(name) { Ok(()) } else { Err(PackageError::new(codes::INVALID_NAME, "Invalid package name.")) }
}

/// `.js` or `.jsx` in any case.
fn is_entry_file(path: &str) -> bool {
    path.rsplit_once('.').is_some_and(|(_, extension)| extension.eq_ignore_ascii_case("js") || extension.eq_ignore_ascii_case("jsx"))
}

/// True when the package has a manifest. Any other spelling of `widget.json`
/// is an error: on a case-insensitive platform it would be the manifest, so
/// it must not be skipped as legacy.
pub fn manifest_present(directory: &Path) -> Result<bool, PackageError> {
    let listing = safe_files::names(directory).ok_or_else(|| PackageError::new(codes::UNSAFE_FILE, "Package directory could not be verified."))?;
    let mut present = false;
    for name in listing.names.iter().filter(|name| name.to_lowercase() == manifests::FILE_NAME) {
        if name != manifests::FILE_NAME {
            return Err(PackageError::new(codes::INVALID_MANIFEST_CASE, "Use the exact file name widget.json."));
        }
        present = true;
    }
    Ok(present)
}

fn read_text(files: &DiskPackageFiles, path: &str) -> Option<String> {
    safe_files::decode_utf8(files.read_bytes_up_to(path, MAX_METADATA_BYTES as u64)?)
}

/// The manifest of a package that has one. Unreadable, non-UTF-8 or malformed is an error, never "no manifest".
fn read_manifest(files: &DiskPackageFiles) -> Result<Object, PackageError> {
    manifests::parse(read_text(files, manifests::FILE_NAME).as_deref()).ok_or_else(|| PackageError::new(codes::INVALID_MANIFEST, "widget.json is invalid."))
}

fn legacy_manifest(name: &str, files: &DiskPackageFiles) -> Object {
    manifests::legacy_manifest(name, read_text(files, manifests::LEGACY_METADATA).as_deref())
}

fn info(name: &str, directory: PathBuf) -> PackageInfo {
    let names = safe_files::names(&directory).map(|listing| listing.names).unwrap_or_default();
    let has_manifest = names.iter().any(|entry| entry.to_lowercase() == manifests::FILE_NAME);
    let summary = if names.iter().any(|entry| entry == manifests::FILE_NAME) {
        manifests::parse(read_text(&DiskPackageFiles::new(&directory), manifests::FILE_NAME).as_deref()).map(|manifest| manifests::summarize(&manifest)).unwrap_or_default()
    } else {
        manifests::Summary::default()
    };
    PackageInfo { name: name.to_owned(), directory, has_manifest, manifest_id: summary.id, manifest_name: summary.name, manifest_version: summary.version }
}
