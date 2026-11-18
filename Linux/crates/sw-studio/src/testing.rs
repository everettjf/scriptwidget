//! Shared by the tests: a scratch folder, a small templates folder and hand-made archives.
//! The tests need the files of `node Linux/scripts/build-shared-js.mjs`.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering};

use sw_core::DataPaths;
use sw_core::packages::{archive, manifests};

use crate::model::Studio;

pub struct Scratch(PathBuf);

impl Scratch {
    pub fn new(name: &str) -> Self {
        Self::under(&std::env::temp_dir(), "scriptwidget-studio-test", name)
    }

    /// A folder with a short path: the path of a Unix socket is limited to about 100 bytes.
    pub fn short(name: &str) -> Self {
        Self::under(Path::new("/tmp"), "sws", name)
    }

    fn under(base: &Path, prefix: &str, name: &str) -> Self {
        static COUNTER: AtomicU32 = AtomicU32::new(0);
        let root = base.join(format!("{prefix}-{name}-{}-{}", std::process::id(), COUNTER.fetch_add(1, Ordering::SeqCst)));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        // The real path: macOS keeps its temporary folder behind a link.
        Self(std::fs::canonicalize(root).unwrap())
    }

    pub fn root(&self) -> &Path {
        &self.0
    }

    pub fn path(&self, relative: &str) -> PathBuf {
        self.0.join(relative)
    }

    pub fn write(&self, relative: &str, bytes: &[u8]) -> PathBuf {
        let path = self.path(relative);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, bytes).unwrap();
        path
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

pub fn runtime_files() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../assets/scriptwidget")
}

/// A studio over an empty data folder and three templates: one that runs, one that asks the network, one that needs an API Linux lacks.
pub fn studio(scratch: &Scratch) -> Studio {
    scratch.write("templates/template/Clock/main.jsx", b"$import('lib/label.js');\n$render(<vstack frame=\"max\" background=\"#1d4ed8\"><text color=\"white\">{label()}</text></vstack>);");
    scratch.write("templates/template/Clock/lib/label.js", b"function label() { return 'clock'; }");
    scratch.write("templates/template/Clock/meta.json", br#"{"description":"A clock"}"#);
    scratch.write("templates/template/Quote/main.jsx", b"const quote = await fetch(\"https://zenquotes.io/api/today\");\n$render(<text>q</text>);");
    scratch.write("templates/component/steps/main.jsx", b"$render(<text>{String(await $health.steps())}</text>);");
    scratch.write("templates/api/storage/main.jsx", b"$render(<text>{$storage.getString('a')}</text>);");
    let paths = DataPaths::new(Some(&scratch.path("data"))).unwrap();
    Studio::with(&paths, &runtime_files(), Some(scratch.path("templates"))).expect("the runtime files: run node Linux/scripts/build-shared-js.mjs")
}

pub fn manifest(name: &str) -> String {
    String::from_utf8(manifests::encode(&manifests::new_manifest(name))).unwrap()
}

/// A ZIP archive with the files stored uncompressed.
pub fn zip(files: &[(&str, &str)]) -> Vec<u8> {
    let mut archive_bytes = Vec::new();
    let mut directory = Vec::new();
    for (name, content) in files {
        let offset = archive_bytes.len() as u32;
        let crc = archive::crc32(content.as_bytes());
        let size = content.len() as u32;
        let header = |signature: u32, central: bool| {
            let mut bytes = Vec::new();
            bytes.extend(signature.to_le_bytes());
            if central {
                bytes.extend(20u16.to_le_bytes());
            }
            bytes.extend(20u16.to_le_bytes());
            bytes.extend(0x0800u16.to_le_bytes());
            bytes.extend(0u16.to_le_bytes());
            bytes.extend(0u32.to_le_bytes());
            bytes.extend(crc.to_le_bytes());
            bytes.extend(size.to_le_bytes());
            bytes.extend(size.to_le_bytes());
            bytes.extend((name.len() as u16).to_le_bytes());
            bytes.extend(0u16.to_le_bytes());
            if central {
                bytes.extend([0u8; 6]);
                bytes.extend((0o100644u32 << 16).to_le_bytes());
                bytes.extend(offset.to_le_bytes());
            }
            bytes.extend(name.as_bytes());
            bytes
        };
        archive_bytes.extend(header(0x0403_4b50, false));
        archive_bytes.extend(content.as_bytes());
        directory.extend(header(0x0201_4b50, true));
    }
    let start = archive_bytes.len() as u32;
    let length = directory.len() as u32;
    archive_bytes.extend(directory);
    archive_bytes.extend(0x0605_4b50u32.to_le_bytes());
    archive_bytes.extend([0u8; 4]);
    archive_bytes.extend((files.len() as u16).to_le_bytes());
    archive_bytes.extend((files.len() as u16).to_le_bytes());
    archive_bytes.extend(length.to_le_bytes());
    archive_bytes.extend(start.to_le_bytes());
    archive_bytes.extend(0u16.to_le_bytes());
    archive_bytes
}
