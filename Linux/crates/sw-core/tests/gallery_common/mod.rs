//! Shared by the Gallery tests: an offline transport and the fixtures of
//! `Android/core/src/test/.../gallery/GalleryFixtures.kt`. No test contacts
//! GitHub: the index is the copy checked into this repository
//! (`Gallery/index.json`), served by [`FakeTransport`].

#![allow(dead_code)]

use std::collections::{HashMap, VecDeque};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use serde_json::{Value, json};
use sw_core::gallery::{GalleryError, GalleryErrorKind, GalleryFile, GalleryIndex, GalleryItem, GalleryItemKind, GalleryRequest, GalleryResponse, GalleryTransport, sha256};

pub const RAW: &str = "https://raw.githubusercontent.com/everettjf/scriptwidget/main/Gallery";
pub const SOURCE: &str = "https://github.com/everettjf/scriptwidget/tree/main/Gallery";
pub const GENERATED_AT: &str = "2026-11-12T17:07:53.501Z";
/// `GENERATED_AT` in milliseconds since the epoch.
pub const GENERATED_AT_MILLISECONDS: i64 = 1_794_503_273_501;

type Reply = Arc<dyn Fn() -> Result<GalleryResponse, GalleryError> + Send + Sync>;

/// Offline transport: queued responses first, then responses mapped by URL, else a network failure.
#[derive(Default)]
pub struct FakeTransport {
    queued: Mutex<VecDeque<Reply>>,
    mapped: Mutex<HashMap<String, Reply>>,
    requests: Mutex<Vec<GalleryRequest>>,
}

impl FakeTransport {
    pub fn queue(&self, reply: impl Fn() -> Result<GalleryResponse, GalleryError> + Send + Sync + 'static) {
        self.queued.lock().unwrap().push_back(Arc::new(reply));
    }

    pub fn map(&self, url: &str, reply: impl Fn() -> Result<GalleryResponse, GalleryError> + Send + Sync + 'static) {
        self.mapped.lock().unwrap().insert(url.to_owned(), Arc::new(reply));
    }

    pub fn unmap(&self, url: &str) {
        self.mapped.lock().unwrap().remove(url);
    }

    pub fn serve_as(&self, url: &str, body: &[u8], status: u16, final_url: &str) {
        let (body, final_url) = (body.to_vec(), final_url.to_owned());
        self.map(url, move || Ok(GalleryResponse::new(status, body.clone(), &[], &final_url)));
    }

    pub fn serve(&self, url: &str, body: &[u8]) {
        self.serve_as(url, body, 200, url);
    }

    pub fn serve_all(&self, files: &[(String, Vec<u8>)]) {
        for (url, body) in files {
            self.serve(url, body);
        }
    }

    pub fn requests(&self) -> Vec<GalleryRequest> {
        self.requests.lock().unwrap().clone()
    }
}

impl GalleryTransport for FakeTransport {
    fn fetch(&self, request: &GalleryRequest) -> Result<GalleryResponse, GalleryError> {
        self.requests.lock().unwrap().push(request.clone());
        let queued = self.queued.lock().unwrap().pop_front();
        let reply = queued.or_else(|| self.mapped.lock().unwrap().get(&request.url).cloned());
        match reply {
            Some(reply) => reply(),
            None => Err(GalleryError::network("No test response")),
        }
    }
}

/// The repository checkout that contains this crate.
pub fn repository_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../..")
}

pub fn checked_in_index() -> Vec<u8> {
    std::fs::read(repository_root().join("Gallery/index.json")).expect("Gallery/index.json")
}

/// The checked-in bytes a catalog file URL points at.
pub fn checked_in_file(file: &GalleryFile) -> Vec<u8> {
    let relative = file.url.split_once("/Gallery/").expect("a Gallery URL").1;
    std::fs::read(repository_root().join("Gallery").join(relative)).unwrap_or_else(|error| panic!("{relative}: {error}"))
}

pub fn file(path: &str, data: &[u8], base: &str) -> GalleryFile {
    GalleryFile { path: path.to_owned(), url: format!("{base}/{path}"), sha256: sha256(data), bytes: data.len() as i64 }
}

pub fn widget_manifest(id: &str, name: &str, version: &str, extra: &str) -> String {
    format!(r#"{{"formatVersion":2,"id":"{id}","name":"{name}","version":"{version}","runtimeVersion":"1.0","entry":"main.jsx","supportedFamilies":["systemSmall"],"permissions":[],"networkDomains":[]{extra}}}"#)
}

pub fn skill_manifest(id: &str, name: &str, version: &str, extra: &str) -> String {
    format!(r#"{{"formatVersion":1,"id":"{id}","name":"{name}","version":"{version}","summary":"Reviews privacy.","symbol":"lock","promptFile":"SKILL.md","tags":["privacy"],"minimumRuntimeVersion":"1.0"{extra}}}"#)
}

/// An item and the bytes served for each of its URLs.
pub type Served = (GalleryItem, Vec<(String, Vec<u8>)>);

pub const WIDGET_ID: &str = "com.example.fixture";
pub const WIDGET_NAME: &str = "Fixture Widget";
pub const SKILL_ID: &str = "com.example.skill";

/// A valid widget item at `version`, with the manifest and the extra files given.
pub fn widget_with(version: &str, manifest: Option<&str>, extra: &[(&str, &[u8])]) -> Served {
    let manifest = manifest.map_or_else(|| widget_manifest(WIDGET_ID, WIDGET_NAME, version, ""), str::to_owned);
    let main = format!("$render(<text>{version}</text>);");
    let mut contents: Vec<(&str, &[u8])> = vec![("widget.json", manifest.as_bytes()), ("main.jsx", main.as_bytes())];
    contents.extend_from_slice(extra);
    item(WIDGET_ID, GalleryItemKind::Widget, WIDGET_NAME, version, &contents)
}

pub fn widget() -> Served {
    widget_with("1.0.0", None, &[])
}

pub fn skill_with(version: &str, manifest: Option<&str>, instruction: Option<&str>) -> Served {
    let manifest = manifest.map_or_else(|| skill_manifest(SKILL_ID, "Fixture Skill", version, ""), str::to_owned);
    let instruction = instruction.map_or_else(|| format!("Prefer on-device data. ({version})"), str::to_owned);
    item(SKILL_ID, GalleryItemKind::Skill, "Fixture Skill", version, &[("skill.json", manifest.as_bytes()), ("SKILL.md", instruction.as_bytes())])
}

pub fn skill() -> Served {
    skill_with("1.0.0", None, None)
}

fn item(id: &str, kind: GalleryItemKind, name: &str, version: &str, contents: &[(&str, &[u8])]) -> Served {
    let base = format!("{RAW}/fixtures/{id}/{version}");
    let item = GalleryItem {
        id: id.to_owned(),
        kind,
        name: name.to_owned(),
        version: version.to_owned(),
        summary: "A fixture.".into(),
        symbol: "sparkles".into(),
        author: "Tests".into(),
        license: "MIT".into(),
        tags: vec!["fixture".into()],
        minimum_runtime_version: "1.0".into(),
        source_url: SOURCE.into(),
        featured: false,
        files: contents.iter().map(|(path, data)| file(path, data, &base)).collect(),
    };
    (item, contents.iter().map(|(path, data)| (format!("{base}/{path}"), data.to_vec())).collect())
}

pub fn index(items: &[GalleryItem]) -> GalleryIndex {
    GalleryIndex { schema_version: 1, generated_at: GENERATED_AT_MILLISECONDS, repository: "https://github.com/everettjf/scriptwidget".into(), items: items.to_vec() }
}

/// JSON of an index as the catalog publishes it.
pub fn index_json(index: &GalleryIndex) -> Value {
    json!({
        "schemaVersion": index.schema_version,
        "generatedAt": GENERATED_AT,
        "repository": index.repository,
        "items": index.items.iter().map(|item| json!({
            "id": item.id, "kind": item.kind.wire(), "name": item.name, "version": item.version, "summary": item.summary,
            "symbol": item.symbol, "author": item.author, "license": item.license, "tags": item.tags,
            "minimumRuntimeVersion": item.minimum_runtime_version, "sourceURL": item.source_url, "featured": item.featured,
            "files": item.files.iter().map(|file| json!({ "path": file.path, "url": file.url, "sha256": file.sha256, "bytes": file.bytes })).collect::<Vec<_>>(),
        })).collect::<Vec<_>>(),
    })
}

#[track_caller]
pub fn assert_kind<T: std::fmt::Debug>(kind: GalleryErrorKind, result: Result<T, GalleryError>) -> GalleryError {
    match result {
        Err(error) => {
            assert_eq!(error.kind, kind, "{}", error.message);
            error
        }
        Ok(value) => panic!("expected {kind:?}, but it succeeded with {value:?}"),
    }
}

/// URLs the trust rule must refuse (`GalleryTrustTest.untrusted`).
pub const UNTRUSTED: [&str; 29] = [
    // Scheme
    "http://raw.githubusercontent.com/a/b",
    "ftp://raw.githubusercontent.com/a/b",
    "file:///raw.githubusercontent.com/a",
    "//raw.githubusercontent.com/a/b",
    "raw.githubusercontent.com/a/b",
    "https:raw.githubusercontent.com/a/b",
    "",
    // Host
    "https://github.com/a/b",
    "https://gist.githubusercontent.com/a/b",
    "https://raw.githubusercontent.com.evil.example/a",
    "https://evilraw.githubusercontent.com/a",
    "https://raw.githubusercontent.com./a",
    "https://raw.githubusercontent.co/a",
    "https://raw.github\u{443}sercontent.com/a",
    "https://140.82.112.3/a",
    "https:///a/b",
    // User info
    "https://user@raw.githubusercontent.com/a",
    "https://user:pass@raw.githubusercontent.com/a",
    "https://raw.githubusercontent.com@evil.example/a",
    "https://raw.githubusercontent.com:x@evil.example/a",
    // Port
    "https://raw.githubusercontent.com:443/a",
    "https://raw.githubusercontent.com:8443/a",
    "https://raw.githubusercontent.com:/a",
    // Query and fragment
    "https://raw.githubusercontent.com/a?token=1",
    "https://raw.githubusercontent.com/a?",
    "https://raw.githubusercontent.com/a#x",
    "https://raw.githubusercontent.com/a#",
    // Not well formed
    "https://raw.githubusercontent.com/a b",
    "https://raw.githubusercontent.com\\@evil.example/a",
];
