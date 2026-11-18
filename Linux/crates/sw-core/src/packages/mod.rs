//! Packages on disk: the library of installed packages, `.swt` archives, and
//! the read-only view the runtime compiles and runs from. Ported from
//! `Windows/src/ScriptWidget.Core/Packages` (itself a port of
//! `Android/core/.../pkg`, which ports the Swift `ScriptManager`).
//!
//! Everything here treats package directories and archives as untrusted:
//!
//! - A package-relative path is refused unless it is in normal form with no
//!   traversal, absolute path, backslash, NUL or control character
//!   ([`path_rules`]).
//! - Nothing is read or written through a symbolic link, and a file with a
//!   second hard link is not a package file. Files are opened relative to the
//!   package directory with `openat2` and `RESOLVE_BENEATH`, and the link
//!   count is checked on the open file before it is read (`safe_files`).
//! - Two names that differ only in case or Unicode normalization are refused
//!   wherever they meet, although Linux would keep both ([`names::identity`]).
//! - An archive is validated completely before anything is extracted
//!   (entry count, file size, expanded size, paths, entry kinds), extracted
//!   into a unique private directory, verified again as a tree, and published
//!   with one atomic rename ([`archive`], [`PackageStore`]).
//! - A manifest that is present but malformed is an error; it is never
//!   reinterpreted as a legacy package.
//!
//! The rules that exist only for Win32 (reserved device names, alternate data
//! streams, trailing dots and spaces, UTF-16 path lengths) are not applied:
//! Linux has no such names, and the Android port, which runs the same
//! packages, accepts them. A colon in an archive entry name is refused on
//! every platform and so here as well.

pub mod archive;
mod disk_files;
mod error;
mod file_remover;
mod file_writer;
pub mod limits;
pub mod manifests;
pub mod names;
pub mod path_rules;
mod preflight;
mod safe_files;
mod store;
mod tree;

pub use archive::ExtractedPackage;
pub use disk_files::DiskPackageFiles;
pub use error::{PackageError, codes};
pub use limits::ArchiveLimits;
pub use store::{ImportValidator, PackageInfo, PackageStore, export_directory, manifest_present};
pub use tree::{validate_source_tree, validate_tree};
