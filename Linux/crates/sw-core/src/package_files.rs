//! Package-relative paths and the read-only view of a package the runtime works with.

use std::collections::BTreeMap;

/// Returns the normalized relative path, or `None` when it could leave the
/// package. Mirrors `normalizePackagePath` in the shared engine.
pub fn normalize_package_path(relative_path: Option<&str>) -> Option<String> {
    let path = relative_path?;
    if path.is_empty() || path.starts_with('/') || path.contains('\\') || path.contains('\0') {
        return None;
    }
    let mut parts: Vec<&str> = Vec::new();
    for part in path.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                parts.pop()?;
            }
            name => parts.push(name),
        }
    }
    if parts.is_empty() { None } else { Some(parts.join("/")) }
}

/// Read-only view of one package. Paths are already normalized.
pub trait PackageFiles: Send + Sync {
    /// Every file, in byte order of the path.
    fn paths(&self) -> Vec<String>;
    fn exists(&self, path: &str) -> bool;
    /// UTF-8 text of a script or data file, or `None` for missing and binary files.
    fn read_text(&self, path: &str) -> Option<String>;
    fn read_bytes(&self, path: &str) -> Option<Vec<u8>>;
}

/// A package held in memory: tests, previews and packages that are being imported.
#[derive(Debug, Clone, Default)]
pub struct MemoryPackageFiles {
    text: BTreeMap<String, String>,
    binary: BTreeMap<String, Vec<u8>>,
}

impl MemoryPackageFiles {
    pub fn new(text: impl IntoIterator<Item = (String, String)>, binary: impl IntoIterator<Item = (String, Vec<u8>)>) -> Self {
        Self { text: text.into_iter().collect(), binary: binary.into_iter().collect() }
    }
}

impl PackageFiles for MemoryPackageFiles {
    fn paths(&self) -> Vec<String> {
        let mut paths: Vec<String> = self.text.keys().chain(self.binary.keys()).cloned().collect();
        paths.sort_unstable();
        paths.dedup();
        paths
    }

    fn exists(&self, path: &str) -> bool {
        self.text.contains_key(path) || self.binary.contains_key(path)
    }

    fn read_text(&self, path: &str) -> Option<String> {
        self.text.get(path).cloned()
    }

    fn read_bytes(&self, path: &str) -> Option<Vec<u8>> {
        self.binary.get(path).cloned().or_else(|| self.text.get(path).map(|text| text.clone().into_bytes()))
    }
}

#[cfg(test)]
mod tests {
    use super::normalize_package_path as normalize;

    #[test]
    fn keeps_paths_inside_the_package() {
        assert_eq!(normalize(Some("main.jsx")).as_deref(), Some("main.jsx"));
        assert_eq!(normalize(Some("./lib//util.js")).as_deref(), Some("lib/util.js"));
        assert_eq!(normalize(Some("lib/../data/a.json")).as_deref(), Some("data/a.json"));
    }

    #[test]
    fn rejects_paths_that_could_leave_the_package() {
        for path in ["", "/etc/passwd", "../main.jsx", "lib/../../main.jsx", "lib\\main.jsx", "a\0b", ".", "lib/.."] {
            assert_eq!(normalize(Some(path)), None, "{path:?}");
        }
        assert_eq!(normalize(None), None);
    }
}
