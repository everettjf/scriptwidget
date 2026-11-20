//! `$documents` and `$photos`: files the user picked for a widget, opened
//! again by their recorded path. The parsers, the limits, what a script can
//! and cannot see, and what happens when a picked file is replaced by
//! something else.

mod api_common;

use std::ffi::CString;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicI64, AtomicU32, Ordering};
use std::sync::Arc;

use api_common::*;
use serde_json::{Value, json};
use sw_core::NativeModule;
use sw_core::api::documents::{DocumentStore, DocumentsModule, PickError, document_rules};
use sw_core::api::photos::{PhotoLibrary, PhotoQuery, PhotosError, PhotosModule, Thumbnail, ThumbnailMaker, photo_limits, thumbnail_plan};
use sw_core::api::support::{CallContext, PickedFileError, SYSTEM_FAILED, SystemServiceError, iso_dates, read_picked_file};

const OWNER: &str = "11111111-1111-4111-8111-111111111111";
const OTHER: &str = "22222222-2222-4222-8222-222222222222";

fn code(error: SystemServiceError) -> String {
    error.message()
}

/// The real path of a scratch folder: macOS keeps its temporary folder behind a link.
fn scratch(name: &str) -> PathBuf {
    std::fs::canonicalize(temporary_directory(name)).unwrap()
}

fn write(directory: &Path, name: &str, content: &[u8]) -> PathBuf {
    let path = directory.join(name);
    std::fs::write(&path, content).unwrap();
    path
}

// The parsers

#[test]
fn csv_follows_the_apple_parser() {
    let csv = |text: &str| document_rules::csv(text.as_bytes());
    assert_eq!(csv("name,count\nApples,3\n\"Pears, ripe\",\"say \"\"hi\"\"\"\r\nplums,\"two\nlines\"").unwrap(), json!({"headers": ["name", "count"], "rows": [["Apples", "3"], ["Pears, ripe", "say \"hi\""], ["plums", "two\nlines"]], "truncated": false}));
    assert_eq!(csv("\u{feff}a\r1\r").unwrap(), json!({"headers": ["a"], "rows": [["1"]], "truncated": false}), "a byte-order mark and bare carriage returns");
    assert_eq!(csv("a,b\n,").unwrap()["rows"], json!([["", ""]]));
    for text in ["", "a,b\n1", "a,a\n1,2", "a,\n1,2", "a\"b,c\n1,2", "\"a\"b,c\n1,2", "\"a,b\n1,2", "a,b\n1,2,3"] {
        assert_eq!(csv(text).unwrap_err().0, code(SystemServiceError::InvalidOptions), "{text:?}");
    }
    assert_eq!(document_rules::csv(&[b'a', 0xff, b'\n']).unwrap_err().0, code(SystemServiceError::InvalidOptions), "not UTF-8");
    // Nothing is cut short without saying so: more than the limits is refused.
    let wide = (0..33).map(|index| format!("c{index}")).collect::<Vec<_>>().join(",");
    assert_eq!(csv(&wide).unwrap_err().0, code(SystemServiceError::LimitExceeded));
    assert!(csv(&(0..32).map(|index| format!("c{index}")).collect::<Vec<_>>().join(",")).is_ok());
    assert_eq!(csv(&format!("a\n{}", "x".repeat(8193))).unwrap_err().0, code(SystemServiceError::LimitExceeded));
    assert!(csv(&format!("a\n{}", "é".repeat(4096))).is_ok(), "8192 bytes fit");
    assert_eq!(csv(&format!("a\n{}", "1\n".repeat(501))).unwrap_err().0, code(SystemServiceError::LimitExceeded));
    assert_eq!(csv(&format!("a\n{}", "1\n".repeat(500))).unwrap()["rows"].as_array().unwrap().len(), 500);
    assert_eq!(document_rules::csv(&vec![b'a'; document_rules::MAXIMUM_BYTES + 1]).unwrap_err().0, code(SystemServiceError::InvalidOptions));
}

#[test]
fn json_is_strict_and_only_data() {
    let parse = |text: &str| document_rules::json(text.as_bytes());
    assert_eq!(parse("\u{feff} {\"a\": [1, 2.5, \"x\", null, true], \"b\": {\"c\": \"$render(1)\"}} ").unwrap(), r#"{"a":[1,2.5,"x",null,true],"b":{"c":"$render(1)"}}"#);
    assert_eq!(parse("[1,2]").unwrap(), "[1,2]");
    for text in ["1", "\"text\"", "null", "true"] {
        assert_eq!(parse(text).unwrap_err().0, code(SystemServiceError::InvalidOptions), "{text}");
    }
    for text in ["", "{", "{'a':1}", "{\"a\":1,}", "[1] trailing", "// comment\n{}", "{\"a\":NaN}"] {
        assert_eq!(parse(text).unwrap_err().0, SYSTEM_FAILED, "{text}");
    }
    assert_eq!(document_rules::json(&[b'[', 0xc3, b']']).unwrap_err().0, SYSTEM_FAILED);
    assert_eq!(document_rules::json(&vec![b' '; document_rules::MAXIMUM_BYTES + 1]).unwrap_err().0, code(SystemServiceError::LimitExceeded));
}

#[test]
fn names_and_types_come_from_the_file_name_only() {
    assert_eq!(document_rules::kind("Data.JSON"), Some("json"));
    assert_eq!(document_rules::kind("table.csv"), Some("csv"));
    for name in ["notes.txt", "json", "archive.json.gz", ".csv.exe", ""] {
        assert_eq!(document_rules::kind(name), None, "{name}");
    }
    assert_eq!(document_rules::name("/home/me/Private Folder/budget.csv"), "budget.csv");
    assert_eq!(document_rules::name("C:\\Users\\me\\a\u{202e}b\n.json"), "ab.json");
    assert_eq!(document_rules::name("///"), "Untitled");
    assert!(document_rules::name(&"好".repeat(200)).len() <= 255);
}

// Opening a picked file again

#[test]
fn only_a_regular_file_at_the_recorded_path_is_read() {
    let directory = scratch("picked");
    let file = write(&directory, "data.json", b"{\"a\":1}");
    assert_eq!(read_picked_file(&file, 100).unwrap().bytes, b"{\"a\":1}");
    assert_eq!(read_picked_file(&file, 6).unwrap_err(), PickedFileError::TooLarge);
    assert_eq!(read_picked_file(Path::new("data.json"), 100).unwrap_err(), PickedFileError::Unreadable, "never relative to where the service happens to run");
    assert_eq!(read_picked_file(&directory.join("missing.json"), 100).unwrap_err(), PickedFileError::Unreadable);
    assert_eq!(read_picked_file(&directory, 100).unwrap_err(), PickedFileError::Unreadable, "a folder");
    // The file was replaced by a link to something the user never picked.
    let secret = write(&directory, "id_rsa", b"PRIVATE KEY");
    let link = directory.join("link.json");
    std::os::unix::fs::symlink(&secret, &link).unwrap();
    assert_eq!(read_picked_file(&link, 100).unwrap_err(), PickedFileError::Unreadable);
    // A named pipe would make an ordinary open wait for a writer for ever.
    let pipe = directory.join("pipe.json");
    let name = CString::new(pipe.as_os_str().as_encoded_bytes()).unwrap();
    // SAFETY: `name` is a NUL-terminated path in a folder of this test.
    assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
    let started = std::time::Instant::now();
    assert_eq!(read_picked_file(&pipe, 100).unwrap_err(), PickedFileError::Unreadable);
    assert!(started.elapsed() < std::time::Duration::from_secs(2), "opening it did not wait");
}

// $documents

struct Documents {
    directory: PathBuf,
    store: Arc<DocumentStore>,
    module: DocumentsModule,
}

impl Documents {
    fn new() -> Self {
        let directory = scratch("documents");
        let store = Arc::new(DocumentStore::new(directory.join("System/Documents")));
        Self { module: DocumentsModule::new(store.clone()), store, directory }
    }
}

fn reader(owner: &str, permission: &str) -> CallContext {
    CallContext::new(owner, true, &[permission], &[], Some("1.6"))
}

#[test]
fn a_widget_reads_what_was_picked_for_it_as_data() {
    let fixture = Documents::new();
    let json_file = write(&fixture.directory, "budget.json", b"{\"total\": 12.5}");
    let csv_file = write(&fixture.directory, "rows.csv", b"a,b\n1,2\n");
    let first = fixture.store.add(OWNER, &json_file).unwrap();
    let second = fixture.store.add(OWNER, &csv_file).unwrap();
    assert_eq!((first.name.as_str(), first.kind.as_str(), second.name.as_str(), second.kind.as_str()), ("budget.json", "json", "rows.csv", "csv"));
    let context = reader(OWNER, "documents");
    // The list a script gets: an identifier, a name, a type, a size. No path.
    let list = fixture.module.list(&context).unwrap();
    assert_eq!(list, json!([{"id": first.id, "name": "budget.json", "type": "json", "bytes": 15}, {"id": second.id, "name": "rows.csv", "type": "csv", "bytes": 8}]));
    assert!(!list.to_string().contains(fixture.directory.to_str().unwrap()));
    assert_eq!(fixture.module.read_json(&context, Some(&json!(first.id))).unwrap(), r#"{"total":12.5}"#);
    assert_eq!(fixture.module.read_csv(&context, Some(&json!(second.id))).unwrap(), json!({"headers": ["a", "b"], "rows": [["1", "2"]], "truncated": false}));
    // The file is opened again for every read: what another program wrote since is what a widget gets.
    std::fs::write(&json_file, b"{\"total\": 99}").unwrap();
    assert_eq!(fixture.module.read_json(&context, Some(&json!(first.id))).unwrap(), r#"{"total":99}"#);

    // The wrong type, another widget's identifier, something that is not an identifier: permission_denied.
    let denied = code(SystemServiceError::PermissionDenied);
    assert_eq!(fixture.module.read_csv(&context, Some(&json!(first.id))).unwrap_err().0, denied);
    assert_eq!(fixture.module.read_json(&reader(OTHER, "documents"), Some(&json!(first.id))).unwrap_err().0, denied);
    for id in [json!("../../etc/passwd"), json!(json_file.to_str().unwrap()), json!(7), Value::Null] {
        assert_eq!(fixture.module.read_json(&context, Some(&id)).unwrap_err().0, denied, "{id}");
    }
    assert_eq!(fixture.module.list(&reader(OTHER, "documents")).unwrap(), json!([]), "nothing was picked for the other widget");
    // The package's own declaration, and the gate.
    for context in [reader(OWNER, "network"), reader("cli:/x", "documents"), CallContext::new(OWNER, true, &["documents"], &[], Some("1.5")), CallContext::new(OWNER, false, &["documents"], &[], Some("1.6"))] {
        assert_eq!(fixture.module.list(&context).unwrap_err().0, denied);
    }
    let mut projection = reader(OWNER, "documents");
    projection.is_timeline_projection = true;
    assert_eq!(fixture.module.list(&projection).unwrap_err().0, code(SystemServiceError::ReadOnly));
    let spent = Arc::new(AtomicU32::new(0));
    let counter = spent.clone();
    let budget = reader(OWNER, "documents").with_probes(move || counter.fetch_add(1, Ordering::SeqCst) < 1, || true, || true);
    assert!(fixture.module.list(&budget).is_ok());
    assert_eq!(fixture.module.list(&budget).unwrap_err().0, code(SystemServiceError::QueryLimit));
}

#[test]
fn a_picked_file_that_changed_into_something_else_is_not_read() {
    let fixture = Documents::new();
    let file = write(&fixture.directory, "data.json", b"{\"a\":1}");
    let entry = fixture.store.add(OWNER, &file).unwrap();
    let context = reader(OWNER, "documents");
    let read = || fixture.module.read_json(&context, Some(&json!(entry.id)));
    // Replaced by a link to a file the user never picked: not followed.
    let secret = write(&fixture.directory, "secret.json", b"{\"password\":\"hunter2\"}");
    std::fs::remove_file(&file).unwrap();
    std::os::unix::fs::symlink(&secret, &file).unwrap();
    assert_eq!(read().unwrap_err().0, code(SystemServiceError::Unavailable));
    assert_eq!(fixture.module.list(&context).unwrap()[0]["bytes"], 0, "its size is not told either");
    // Gone, a folder, grown too large, no longer JSON.
    std::fs::remove_file(&file).unwrap();
    assert_eq!(read().unwrap_err().0, code(SystemServiceError::Unavailable));
    std::fs::create_dir(&file).unwrap();
    assert_eq!(read().unwrap_err().0, code(SystemServiceError::Unavailable));
    std::fs::remove_dir(&file).unwrap();
    std::fs::write(&file, vec![b' '; document_rules::MAXIMUM_BYTES + 1]).unwrap();
    assert_eq!(read().unwrap_err().0, code(SystemServiceError::LimitExceeded));
    std::fs::write(&file, b"#!/bin/sh\necho not json").unwrap();
    assert_eq!(read().unwrap_err().0, SYSTEM_FAILED);
    std::fs::write(&file, b"[true]").unwrap();
    assert_eq!(read().unwrap(), "[true]");
}

#[test]
fn picking_is_checked_and_limited() {
    let fixture = Documents::new();
    let good = write(&fixture.directory, "a.json", b"{}");
    assert_eq!(fixture.store.add("preview", &good).unwrap_err(), PickError::NotInstalled);
    assert_eq!(fixture.store.add(OWNER, &write(&fixture.directory, "notes.txt", b"{}")).unwrap_err(), PickError::UnsupportedType);
    assert_eq!(fixture.store.add(OWNER, &write(&fixture.directory, "bad.json", b"{ nope")).unwrap_err(), PickError::InvalidContent);
    assert_eq!(fixture.store.add(OWNER, &write(&fixture.directory, "big.csv", &vec![b'a'; document_rules::MAXIMUM_BYTES + 1])).unwrap_err(), PickError::TooLarge);
    assert_eq!(fixture.store.add(OWNER, &fixture.directory.join("missing.json")).unwrap_err(), PickError::Unreadable);
    assert_eq!(fixture.store.add(OWNER, &fixture.directory).unwrap_err(), PickError::Unreadable);
    // A link the user picks is resolved once, then: the record names the file itself.
    let link = fixture.directory.join("link.json");
    std::os::unix::fs::symlink(&good, &link).unwrap();
    let entry = fixture.store.add(OWNER, &link).unwrap();
    assert_eq!((entry.path.as_path(), entry.name.as_str()), (good.as_path(), "a.json"));
    assert_eq!(fixture.store.add(OWNER, &good).unwrap_err(), PickError::Duplicate);
    for index in 1..document_rules::MAXIMUM_FILES {
        fixture.store.add(OWNER, &write(&fixture.directory, &format!("f{index}.json"), b"[]")).unwrap();
    }
    assert_eq!(fixture.store.add(OWNER, &write(&fixture.directory, "ninth.json", b"[]")).unwrap_err(), PickError::Full);
    assert!(fixture.store.add(OTHER, &good).is_ok(), "the limit is per widget");
    // Removing forgets the entry and leaves the file alone.
    assert_eq!(fixture.store.remove(OWNER, &entry.id).map(|removed| removed.id), Some(entry.id.clone()));
    assert!(good.is_file());
    assert_eq!(fixture.store.remove(OWNER, &entry.id), None);
    assert_eq!(fixture.store.list(OWNER).unwrap().len(), document_rules::MAXIMUM_FILES - 1);
    // An index that is not this program's is unavailable, never an empty list; clearing is the way out.
    let index = std::fs::read_dir(fixture.directory.join("System/Documents")).unwrap().map(|entry| entry.unwrap().path().join("index.json")).find(|file| std::fs::read_to_string(file).is_ok_and(|text| text.contains("f1.json"))).unwrap();
    for text in ["{", r#"{"formatVersion":1,"documents":[{"id":"x","name":"a","type":"json","path":"/a"}]}"#, r#"{"formatVersion":1,"documents":[{"id":"11111111-1111-4111-8111-111111111111","name":"a","type":"exe","path":"/a"}]}"#, r#"{"formatVersion":1,"documents":[{"id":"11111111-1111-4111-8111-111111111111","name":"a","type":"json","path":"relative/a"}]}"#] {
        std::fs::write(&index, text).unwrap();
        assert_eq!(fixture.module.list(&reader(OWNER, "documents")).unwrap_err().0, code(SystemServiceError::Unavailable), "{text}");
        assert_eq!(fixture.store.add(OWNER, &good).unwrap_err(), PickError::Storage);
    }
    fixture.module.retire(OWNER);
    assert_eq!(fixture.store.list(OWNER).unwrap(), []);
    assert_eq!(fixture.store.list(OTHER).unwrap().len(), 1);
}

#[test]
fn a_script_lists_and_reads_through_the_bridge() {
    let fixture = Documents::new();
    let entry = fixture.store.add(OWNER, &write(&fixture.directory, "budget.json", b"{\"total\": 12.5}")).unwrap();
    let modules: Vec<Arc<dyn NativeModule>> = vec![Arc::new(fixture.module.clone())];
    let manifest = widget_manifest(r#"["documents"]"#, "[]").replace(r#""runtimeVersion":"1.0""#, r#""runtimeVersion":"1.0","minimumRuntimeVersion":"1.6""#);
    let source = "let text; try { const list = await $documents.list(); const data = await $documents.readJSON(list[0].id); text = [list.length, Object.keys(list[0]).sort().join('+'), list[0].name, data.total].join('|'); } catch (error) { text = String(error.message ?? error); }\n$render(<text>{text}</text>);";
    let run_as = |owner: &str| {
        let result = run(source, Some(&manifest), modules.clone(), &[], |request| request.package_id = owner.to_owned());
        assert!(result.error.is_none(), "error: {:?}", result.error);
        let tree = result.tree.expect("tree");
        assert!(!tree.contains(fixture.directory.to_str().unwrap()), "a path reached the script: {tree}");
        let tree: Value = serde_json::from_str(&tree).unwrap();
        tree["children"].as_array().unwrap().iter().map(|child| child.as_str().unwrap_or("").to_owned()).collect::<String>()
    };
    assert_eq!(run_as(OWNER), "1|bytes+id+name+type|budget.json|12.5");
    assert_eq!(run_as("cli:/tmp/x"), code(SystemServiceError::PermissionDenied));
    assert!(entry.path.is_absolute());
}

// $photos

/// A stand-in for the painter: a "picture" is the text `PIC <width> <height> <anything>`.
struct FakePainter;

impl ThumbnailMaker for FakePainter {
    fn make(&self, source: &[u8], _maximum_side: u32, maximum_bytes: usize) -> Option<Thumbnail> {
        let text = std::str::from_utf8(source).ok()?;
        let mut parts = text.split(' ');
        let (Some("PIC"), Some(width), Some(height)) = (parts.next(), parts.next(), parts.next()) else { return None };
        let mut bytes = vec![0xff, 0xd8, 0xff, 0xe0];
        bytes.extend_from_slice(parts.next().unwrap_or("").as_bytes());
        (bytes.len() <= maximum_bytes).then_some(Thumbnail { bytes, original_width: width.parse().ok()?, original_height: height.parse().ok()? })
    }
}

struct Photos {
    now: Arc<AtomicI64>,
    directory: PathBuf,
    library: Arc<PhotoLibrary>,
    module: PhotosModule,
}

impl Photos {
    fn new() -> Self {
        let directory = scratch("photos");
        let library = Arc::new(PhotoLibrary::new(directory.join("System/Photos"), directory.join("Cache/photos")));
        library.set_maker(Arc::new(FakePainter));
        let now = Arc::new(AtomicI64::new(iso_dates::parse("2026-11-19T10:00:00Z").unwrap()));
        let clock = now.clone();
        Self { module: PhotosModule::with_clock(library.clone(), Arc::new(move || clock.load(Ordering::SeqCst))), library, directory, now }
    }

    fn picture(&self, name: &str, content: &str) -> PathBuf {
        write(&self.directory, name, content.as_bytes())
    }

    fn pick(&self, name: &str, content: &str) -> String {
        let now = self.now.fetch_add(1000, Ordering::SeqCst);
        self.library.add(OWNER, &self.picture(name, content), now).unwrap().id
    }
}

#[test]
fn photo_options_are_strict() {
    assert_eq!(PhotoQuery::parse(None).unwrap(), PhotoQuery { limit: 4, offset: 0, max_age_seconds: 3600.0 });
    let parse = |value: Value| PhotoQuery::parse(value.as_object());
    assert_eq!(parse(json!({"limit": 1, "offset": 63, "maxAgeSeconds": 0.5})).unwrap(), PhotoQuery { limit: 1, offset: 63, max_age_seconds: 0.5 });
    for value in [json!({"limit": 0}), json!({"limit": 5}), json!({"limit": 1.5}), json!({"limit": "2"}), json!({"limit": true}), json!({"offset": -1}), json!({"offset": 64}), json!({"maxAgeSeconds": 86_401}), json!({"maxAgeSeconds": -1}), json!({"album": "Favorites"})] {
        assert_eq!(parse(value.clone()).unwrap_err().0, PhotosError::Invalid.message(), "{value}");
    }
    assert_eq!(thumbnail_plan::fit(4000, 3000, 768), (768, 576));
    assert_eq!(thumbnail_plan::fit(300, 200, 768), (300, 200));
    assert_eq!(thumbnail_plan::fit(10_000, 1, 768), (768, 1));
    assert_eq!(thumbnail_plan::fit(0, 5, 768), (0, 0));
}

#[test]
fn a_widget_gets_thumbnails_of_its_own_pictures() {
    let fixture = Photos::new();
    let context = reader(OWNER, "photos");
    assert_eq!(PhotosModule::authorization_status(&context), "limited");
    assert_eq!(fixture.module.request_authorization(&context), Ok(true));
    // Nothing picked yet: there is nothing the widget may see.
    assert_eq!(fixture.module.items(&context, None, false).unwrap_err().0, PhotosError::Denied.message());
    let first = fixture.pick("beach.jpg", "PIC 4000 3000 one");
    let second = fixture.pick("hill.png", "PIC 1200 1600 two");
    let result = fixture.module.items(&context, None, false).unwrap();
    assert_eq!((result["status"].as_str(), result["source"].as_str(), result["stale"].as_bool(), result["unavailableCount"].as_i64(), result["fetchedAt"].as_str()), (Some("ready"), Some("system"), Some(false), Some(0), Some("2026-11-19T10:00:02Z")));
    let items = result["items"].as_array().unwrap();
    assert_eq!(items.len(), 2);
    let ids: Vec<&str> = items.iter().map(|item| item["id"].as_str().unwrap()).collect();
    assert!(ids.contains(&first.as_str()) && ids.contains(&second.as_str()));
    for item in items {
        assert_eq!(item.as_object().unwrap().keys().map(String::as_str).collect::<Vec<_>>(), ["id", "image", "width", "height"], "an identifier, a picture and its size: no name, no path");
        assert!(item["image"].as_str().unwrap().starts_with("data:image/jpeg;base64,/9j/"));
    }
    let beach = items.iter().find(|item| item["id"] == first.as_str()).unwrap();
    assert_eq!((beach["width"].as_i64(), beach["height"].as_i64()), (Some(4000), Some(3000)));
    let text = result.to_string();
    assert!(!text.contains("beach") && !text.contains(fixture.directory.to_str().unwrap()));
    // The same page again within maxAgeSeconds is the snapshot of before.
    fixture.now.fetch_add(60_000, Ordering::SeqCst);
    let again = fixture.module.items(&context, None, false).unwrap();
    assert_eq!((again["source"].as_str(), again["fetchedAt"].as_str()), (Some("cache"), Some("2026-11-19T10:00:02Z")));
    assert_eq!(fixture.module.items(&context, json!({"maxAgeSeconds": 10}).as_object(), false).unwrap()["source"], "system", "older than the script accepts");
    // Pages.
    let page = fixture.module.items(&context, json!({"limit": 1, "offset": 1}).as_object(), false).unwrap();
    assert_eq!(page["items"].as_array().unwrap().len(), 1);
    assert_eq!(fixture.module.items(&context, json!({"offset": 5}).as_object(), false).unwrap()["items"], json!([]));

    // Another widget, a package without the permission, one that is not installed: nothing.
    for context in [reader(OTHER, "photos"), reader(OWNER, "documents"), reader("cli:/x", "photos")] {
        assert_eq!(fixture.module.items(&context, None, false).unwrap_err().0, PhotosError::Denied.message());
    }
    assert_eq!(PhotosModule::authorization_status(&reader(OWNER, "documents")), "undeclared");
    assert_eq!(fixture.module.items(&context, None, true).unwrap_err().0, PhotosError::Invalid.message());
    let spent = reader(OWNER, "photos").with_probes(|| false, || true, || true);
    assert!(fixture.module.items(&spent, None, false).unwrap_err().0.starts_with("[query_limit]"));
}

#[test]
fn a_future_entry_uses_the_snapshot_and_never_reads_anew() {
    let fixture = Photos::new();
    fixture.pick("a.jpg", "PIC 10 10 a");
    let mut projection = reader(OWNER, "photos");
    projection.is_timeline_projection = true;
    assert_eq!(fixture.module.request_authorization(&projection), Ok(true));
    assert_eq!(fixture.module.items(&projection, None, false).unwrap_err().0, PhotosError::CacheMiss.message());
    fixture.module.items(&reader(OWNER, "photos"), None, false).unwrap();
    fixture.now.fetch_add(7_200_000, Ordering::SeqCst);
    let later = fixture.module.items(&projection, None, false).unwrap();
    assert_eq!((later["source"].as_str(), later["stale"].as_bool()), (Some("cache"), Some(true)));
    // A changed selection is another scope: the old snapshot answers nothing.
    fixture.pick("b.jpg", "PIC 10 10 b");
    assert_eq!(fixture.module.items(&projection, None, false).unwrap_err().0, PhotosError::CacheMiss.message());
}

#[test]
fn a_picture_that_changed_into_something_else_is_not_shown() {
    let fixture = Photos::new();
    let file = fixture.picture("a.jpg", "PIC 10 10 first");
    let id = fixture.library.add(OWNER, &file, 1).unwrap().id;
    let context = reader(OWNER, "photos");
    let image = |fixture: &Photos| {
        fixture.now.fetch_add(4_000_000, Ordering::SeqCst);
        fixture.module.items(&context, None, false).unwrap()
    };
    let first = image(&fixture)["items"][0]["image"].as_str().unwrap().to_owned();
    // Edited: the thumbnail is made again from the new content.
    std::thread::sleep(std::time::Duration::from_millis(20));
    std::fs::write(&file, "PIC 10 10 second and longer").unwrap();
    let second = image(&fixture)["items"][0]["image"].as_str().unwrap().to_owned();
    assert_ne!(first, second);
    // Replaced by a link to another picture, by something that is no picture, or gone: unavailable, never something else.
    let other = fixture.picture("private.jpg", "PIC 10 10 private");
    std::fs::remove_file(&file).unwrap();
    std::os::unix::fs::symlink(&other, &file).unwrap();
    let result = image(&fixture);
    assert_eq!((result["status"].as_str(), result["unavailableCount"].as_i64(), result["items"].as_array().map(Vec::len)), (Some("unavailable"), Some(1), Some(0)));
    std::fs::remove_file(&file).unwrap();
    std::fs::write(&file, "#!/bin/sh").unwrap();
    assert_eq!(image(&fixture)["status"], "unavailable");
    std::fs::remove_file(&file).unwrap();
    assert_eq!(image(&fixture)["status"], "unavailable");
    assert!(fixture.library.remove(OWNER, &id));
    assert_eq!(fixture.module.items(&context, None, false).unwrap_err().0, PhotosError::Denied.message());
}

#[test]
fn picking_pictures_is_checked_and_limited() {
    let fixture = Photos::new();
    assert_eq!(fixture.library.add("preview", &fixture.picture("a.jpg", "PIC 1 1 a"), 0).unwrap_err(), PickError::NotInstalled);
    assert_eq!(fixture.library.add(OWNER, &fixture.picture("notes.jpg", "not a picture"), 0).unwrap_err(), PickError::InvalidContent);
    assert_eq!(fixture.library.add(OWNER, &fixture.directory.join("missing.jpg"), 0).unwrap_err(), PickError::Unreadable);
    assert_eq!(fixture.library.add(OWNER, &fixture.picture("huge.jpg", &format!("PIC 1 1 {}", "x".repeat(photo_limits::MAXIMUM_THUMBNAIL_BYTES))), 0).unwrap_err(), PickError::InvalidContent, "a thumbnail above 128 KiB is none");
    for index in 0..photo_limits::MAXIMUM_SELECTED {
        fixture.pick(&format!("p{index}.jpg"), &format!("PIC 1 1 {index}"));
    }
    assert_eq!(fixture.library.add(OWNER, &fixture.picture("one-more.jpg", "PIC 1 1 x"), 0).unwrap_err(), PickError::Full);
    assert_eq!(fixture.library.add(OWNER, &fixture.directory.join("p0.jpg"), 0).unwrap_err(), PickError::Duplicate);
    assert!(fixture.library.add(OTHER, &fixture.directory.join("p0.jpg"), 0).is_ok(), "per widget");
    // At most four in a result, whatever is asked.
    let result = fixture.module.items(&reader(OWNER, "photos"), None, false).unwrap();
    assert_eq!(result["items"].as_array().unwrap().len(), photo_limits::MAXIMUM_RETURNED);
    // A library without a painter can make nothing.
    let bare = PhotoLibrary::new(fixture.directory.join("bare"), fixture.directory.join("bare-cache"));
    assert_eq!(bare.add(OWNER, &fixture.directory.join("p0.jpg"), 0).unwrap_err(), PickError::Storage);
    // A deleted widget leaves no record and no thumbnails.
    fixture.module.retire(OWNER);
    assert_eq!(fixture.library.list(OWNER), Ok(Vec::new()));
    assert_eq!(fixture.library.list(OTHER).unwrap().len(), 1);
    let thumbnails = std::fs::read_dir(fixture.directory.join("Cache/photos")).unwrap().count();
    assert_eq!(thumbnails, 1, "only the other widget's folder is left");
}

#[test]
fn a_script_gets_pictures_through_the_bridge() {
    let fixture = Photos::new();
    fixture.pick("beach.jpg", "PIC 400 300 one");
    let modules: Vec<Arc<dyn NativeModule>> = vec![Arc::new(fixture.module.clone())];
    let source = "let text; try { const granted = await $photos.requestAuthorization(); const result = await $photos.items({limit: 2}); text = [$photos.isAvailable(), $photos.authorizationStatus(), granted, result.status, result.items.length, result.items[0].width, result.items[0].image.slice(0, 23)].join('|'); } catch (error) { text = [$photos.isAvailable(), $photos.authorizationStatus(), String(error.message ?? error)].join('|'); }\n$render(<text>{text}</text>);";
    let run_as = |owner: &str, permissions: &str| {
        let result = run(source, Some(&widget_manifest(permissions, "[]")), modules.clone(), &[], |request| request.package_id = owner.to_owned());
        assert!(result.error.is_none(), "error: {:?}", result.error);
        let tree: Value = serde_json::from_str(result.tree.as_deref().expect("tree")).unwrap();
        tree["children"].as_array().unwrap().iter().map(|child| child.as_str().unwrap_or("").to_owned()).collect::<String>()
    };
    assert_eq!(run_as(OWNER, r#"["photos"]"#), "true|limited|true|ready|1|400|data:image/jpeg;base64,");
    assert_eq!(run_as(OWNER, "[]"), format!("false|undeclared|{}", PhotosError::Denied.message()));
    assert_eq!(run_as(OTHER, r#"["photos"]"#), format!("true|limited|{}", PhotosError::Denied.message()), "declared, but nothing was picked for it");
}
