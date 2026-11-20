//! The Gallery 1.0 index: what is decoded, every rule that refuses an index
//! or an item, and the trust rule for addresses. Ported from
//! `GalleryIndexValidatorTest.kt` and `GalleryTrustTest.kt`.

mod gallery_common;

use std::collections::BTreeSet;

use gallery_common::*;
use serde_json::{Value, json};
use sw_core::gallery::validator::{self, decode, is_github_url, is_raw_github_url, is_safe_relative_path, validate, validate_item};
use sw_core::gallery::{FetchGalleryTransport, GalleryError, GalleryErrorKind, GalleryFile, GalleryIndex, GalleryItem, GalleryItemKind, GalleryRequest, GalleryTransport, sha256};

fn widget_item() -> GalleryItem {
    widget().0
}

fn skill_item() -> GalleryItem {
    skill().0
}

fn valid() -> GalleryIndex {
    index(&[widget_item(), skill_item()])
}

fn index_rules(index: &GalleryIndex) -> BTreeSet<String> {
    validate(index).into_iter().map(|issue| issue.id).collect()
}

/// The rules an item breaks, without the item's id in front.
fn rules(item: &GalleryItem) -> BTreeSet<String> {
    let prefix = format!("{}.", if item.id.is_empty() { "item" } else { &item.id });
    validate_item(item).into_iter().map(|issue| issue.id.strip_prefix(&prefix).unwrap_or(&issue.id).to_owned()).collect()
}

fn has(rules: &BTreeSet<String>, rule: &str) -> bool {
    rules.contains(rule)
}

fn with_file(item: &GalleryItem, position: usize, change: impl Fn(&mut GalleryFile)) -> GalleryItem {
    let mut item = item.clone();
    change(&mut item.files[position]);
    item
}

fn bytes(json: &Value) -> Vec<u8> {
    json.to_string().into_bytes()
}

#[track_caller]
fn rejects_json(change: impl Fn(&mut Value)) -> GalleryError {
    let mut json = index_json(&valid());
    change(&mut json);
    assert_kind(GalleryErrorKind::InvalidIndex, decode(&bytes(&json)))
}

fn remove(object: &mut Value, key: &str) {
    object.as_object_mut().unwrap().remove(key);
}

// Accepted

#[test]
fn checked_in_index_validates_and_matches_the_checked_in_files() {
    let index = decode(&checked_in_index()).unwrap();
    assert!(index.items.len() >= 2);
    assert!(index.items.iter().any(|item| item.kind == GalleryItemKind::Widget) && index.items.iter().any(|item| item.kind == GalleryItemKind::Skill));
    for item in &index.items {
        for file in &item.files {
            let local = checked_in_file(file);
            assert_eq!(file.bytes, local.len() as i64, "{}", file.url);
            assert_eq!(file.sha256, sha256(&local), "{}", file.url);
        }
    }
}

#[test]
fn the_schema_and_the_decoder_know_the_same_fields() {
    // A field added to the schema must be added to the decoder, which refuses what it does not know.
    let schema: Value = serde_json::from_slice(&std::fs::read(repository_root().join("Gallery/gallery.schema.json")).unwrap()).unwrap();
    let keys = |value: &Value| value["properties"].as_object().map(|properties| properties.keys().cloned().collect::<BTreeSet<String>>()).unwrap_or_default();
    let set = |names: &[&str]| names.iter().map(|name| name.to_string()).collect::<BTreeSet<String>>();
    assert_eq!(keys(&schema), set(&["schemaVersion", "generatedAt", "repository", "items"]));
    let text = schema.to_string();
    for key in ["id", "kind", "name", "version", "summary", "symbol", "author", "license", "tags", "minimumRuntimeVersion", "sourceURL", "featured", "files", "path", "url", "sha256", "bytes"] {
        assert!(text.contains(&format!("\"{key}\"")), "{key}");
    }
    assert_eq!(schema["additionalProperties"], json!(false));
}

#[test]
fn decodes_a_valid_index_exactly() {
    let decoded = decode(&bytes(&index_json(&valid()))).unwrap();
    assert_eq!(decoded, valid());
    assert_eq!((decoded.schema_version, decoded.generated_at), (1, GENERATED_AT_MILLISECONDS));
    assert!(validate(&valid()).is_empty());
}

// Decoding rejections

#[test]
fn rejects_an_index_above_one_mebibyte() {
    let mut padded = bytes(&index_json(&valid()));
    padded.extend(std::iter::repeat_n(b' ', validator::MAX_INDEX_BYTES));
    assert!(assert_kind(GalleryErrorKind::InvalidIndex, decode(&padded)).message.contains("1 MiB"));
}

#[test]
fn rejects_bytes_that_are_not_one_utf8_json_object() {
    let good = bytes(&index_json(&valid()));
    let text = String::from_utf8(good.clone()).unwrap();
    let documents: Vec<Vec<u8>> = vec![
        vec![0xFF, 0xFE],
        b"[]".to_vec(),
        Vec::new(),
        b"{".to_vec(),
        b"null".to_vec(),
        [good.clone(), b"{}".to_vec()].concat(),
        [good.clone(), b"x".to_vec()].concat(),
        // A key given twice: two readers could take different values.
        format!("{},\"schemaVersion\":1}}", &text[..text.len() - 1]).into_bytes(),
    ];
    for data in documents {
        assert_kind(GalleryErrorKind::InvalidIndex, decode(&data));
    }
}

#[test]
fn rejects_unknown_fields_at_every_level() {
    rejects_json(|root| root["futureField"] = json!(true));
    rejects_json(|root| root["items"][0]["permissions"] = json!([]));
    rejects_json(|root| root["items"][0]["files"][0]["executable"] = json!(true));
}

#[test]
fn rejects_missing_fields() {
    for key in ["schemaVersion", "generatedAt", "repository", "items"] {
        rejects_json(|root| remove(root, key));
    }
    for key in ["id", "kind", "name", "version", "summary", "symbol", "author", "license", "tags", "minimumRuntimeVersion", "sourceURL", "featured", "files"] {
        rejects_json(|root| remove(&mut root["items"][0], key));
    }
    for key in ["path", "url", "sha256", "bytes"] {
        rejects_json(|root| remove(&mut root["items"][0]["files"][0], key));
    }
}

#[test]
fn rejects_wrongly_typed_fields() {
    rejects_json(|root| root["schemaVersion"] = json!("1"));
    rejects_json(|root| root["schemaVersion"] = json!(1.5));
    rejects_json(|root| root["generatedAt"] = json!(1794589673));
    rejects_json(|root| root["generatedAt"] = json!("yesterday"));
    rejects_json(|root| root["generatedAt"] = json!("2026-11-12T17:07:53"));
    rejects_json(|root| root["repository"] = Value::Null);
    rejects_json(|root| root["items"] = json!({}));
    rejects_json(|root| root["items"][0] = json!("widget"));
    rejects_json(|root| root["items"][0]["name"] = json!(7));
    rejects_json(|root| root["items"][0]["featured"] = json!("true"));
    rejects_json(|root| root["items"][0]["tags"] = json!("starter"));
    rejects_json(|root| root["items"][0]["tags"] = json!([1]));
    rejects_json(|root| root["items"][0]["files"] = json!({}));
    rejects_json(|root| root["items"][0]["files"][0] = json!("main.jsx"));
    rejects_json(|root| root["items"][0]["files"][0]["bytes"] = json!("605"));
    rejects_json(|root| root["items"][0]["files"][0]["bytes"] = json!(60.5));
    rejects_json(|root| root["items"][0]["files"][0]["sha256"] = json!(1));
}

#[test]
fn rejects_unknown_kinds() {
    rejects_json(|root| root["items"][0]["kind"] = json!("plugin"));
    rejects_json(|root| root["items"][0]["kind"] = json!("Widget"));
}

#[test]
fn decode_reports_semantic_failures() {
    let error = rejects_json(|root| root["items"][0]["files"][0]["path"] = json!("../main.jsx"));
    assert!(error.message.contains("unsafe path"), "{}", error.message);
    rejects_json(|root| root["items"] = json!([]));
    assert!(rejects_json(|root| root["schemaVersion"] = json!(2)).message.contains("unsupported"));
    rejects_json(|root| root["schemaVersion"] = json!(4294967297u64));
}

// Index rules

#[test]
fn rejects_unsupported_schema_versions() {
    assert!(has(&index_rules(&GalleryIndex { schema_version: 2, ..valid() }), "schema"));
    assert!(has(&index_rules(&GalleryIndex { schema_version: 0, ..valid() }), "schema"));
}

#[test]
fn rejects_empty_and_oversized_catalogs() {
    assert!(has(&index_rules(&GalleryIndex { items: vec![], ..valid() }), "items"));
    let mut many: Vec<GalleryItem> = (0..=validator::MAX_ITEMS).map(|number| GalleryItem { id: format!("com.example.item{number}"), ..widget_item() }).collect();
    assert!(has(&index_rules(&GalleryIndex { items: many.clone(), ..valid() }), "items"));
    many.pop();
    assert!(!has(&index_rules(&GalleryIndex { items: many, ..valid() }), "items"));
}

#[test]
fn rejects_repositories_that_are_not_https_github() {
    for url in ["http://github.com/a/b", "https://gitlab.com/a/b", "https://github.com.evil.example/a", "https://user@github.com/a", "https://github.com:8443/a", "github.com/a/b", ""] {
        assert!(has(&index_rules(&GalleryIndex { repository: url.into(), ..valid() }), "repository"), "{url}");
        assert!(!is_github_url(url), "{url}");
    }
    for url in ["https://github.com/a/b", "https://GitHub.com/a/b/tree/main/x?tab=readme#top", "https://github.com"] {
        assert!(is_github_url(url), "{url}");
    }
}

#[test]
fn rejects_duplicate_item_identifiers_ignoring_case() {
    let twin = GalleryItem { id: widget_item().id.to_uppercase(), ..widget_item() };
    assert!(has(&index_rules(&GalleryIndex { items: vec![widget_item(), twin], ..valid() }), "duplicate_item"));
}

// Item rules

#[test]
fn rejects_invalid_identifiers() {
    for id in ["", "ab", "-abc", ".abc", "com.example/x", "com example", &"a".repeat(129), "com.ex\u{e4}mple"] {
        assert!(has(&rules(&GalleryItem { id: id.into(), ..widget_item() }), "id"), "{id}");
    }
}

#[test]
fn rejects_invalid_display_fields() {
    let widget = widget_item();
    assert!(has(&rules(&GalleryItem { name: "  ".into(), ..widget.clone() }), "name"));
    assert!(has(&rules(&GalleryItem { name: "n".repeat(81), ..widget.clone() }), "name"));
    assert!(!has(&rules(&GalleryItem { name: "n".repeat(80), ..widget.clone() }), "name"));
    assert!(has(&rules(&GalleryItem { summary: String::new(), ..widget.clone() }), "summary"));
    assert!(has(&rules(&GalleryItem { summary: "s".repeat(241), ..widget.clone() }), "summary"));
    assert!(has(&rules(&GalleryItem { symbol: String::new(), ..widget.clone() }), "symbol"));
    assert!(has(&rules(&GalleryItem { symbol: "s".repeat(81), ..widget.clone() }), "symbol"));
    assert!(has(&rules(&GalleryItem { author: " ".into(), ..widget.clone() }), "author"));
    assert!(has(&rules(&GalleryItem { author: "a".repeat(121), ..widget.clone() }), "author"));
    assert!(has(&rules(&GalleryItem { license: String::new(), ..widget.clone() }), "license"));
    assert!(has(&rules(&GalleryItem { license: "l".repeat(41), ..widget }), "license"));
}

#[test]
fn rejects_versions_that_are_not_semantic() {
    for version in ["latest", "1.0", "1", "v1.0.0", "1.0.0+build", "1.0.0-", "1.0.0 ", ""] {
        assert!(has(&rules(&GalleryItem { version: version.into(), ..widget_item() }), "version"), "{version}");
    }
    assert!(!has(&rules(&GalleryItem { version: "1.0.0-beta.1".into(), ..widget_item() }), "version"));
}

#[test]
fn rejects_unsupported_runtime_contracts() {
    for runtime in ["2.0", "1.1", "1", ""] {
        assert!(has(&rules(&GalleryItem { minimum_runtime_version: runtime.into(), ..widget_item() }), "runtime"), "{runtime}");
    }
}

#[test]
fn rejects_too_many_or_case_duplicate_tags() {
    let tags = |count: usize| (0..count).map(|number| format!("tag{number}")).collect::<Vec<_>>();
    assert!(has(&rules(&GalleryItem { tags: tags(21), ..widget_item() }), "tags"));
    assert!(!has(&rules(&GalleryItem { tags: tags(20), ..widget_item() }), "tags"));
    assert!(has(&rules(&GalleryItem { tags: vec!["Offline".into(), "offline".into()], ..widget_item() }), "tags"));
}

#[test]
fn rejects_source_links_that_are_not_https_github() {
    for url in ["http://github.com/a", "https://raw.githubusercontent.com/a", "https://evil.example/github.com", "https://github.com:443/a"] {
        assert!(has(&rules(&GalleryItem { source_url: url.into(), ..widget_item() }), "source"), "{url}");
    }
}

#[test]
fn rejects_invalid_file_counts() {
    let widget = widget_item();
    assert!(has(&rules(&GalleryItem { files: widget.files[..1].to_vec(), ..widget.clone() }), "files"));
    assert!(has(&rules(&GalleryItem { files: vec![], ..widget.clone() }), "files"));
    let mut many = widget.files.clone();
    many.extend((0..validator::MAX_FILES - 1).map(|number| GalleryFile { path: format!("lib/file{number}.js"), ..widget.files[1].clone() }));
    assert!(has(&rules(&GalleryItem { files: many.clone(), ..widget.clone() }), "files"));
    many.pop();
    assert!(!has(&rules(&GalleryItem { files: many, ..widget }), "files"));
}

#[test]
fn rejects_duplicate_and_case_colliding_paths() {
    let widget = widget_item();
    let extra = widget.files[1].clone();
    let plus = |added: &[GalleryFile]| GalleryItem { files: [widget.files.clone(), added.to_vec()].concat(), ..widget.clone() };
    assert!(has(&rules(&plus(std::slice::from_ref(&extra))), "paths"));
    assert!(has(&rules(&plus(&[GalleryFile { path: "MAIN.jsx".into(), ..extra.clone() }])), "paths"));
    // U+00E9 and "e" + U+0301 are one name after NFC normalization.
    assert!(has(&rules(&plus(&[GalleryFile { path: "caf\u{e9}.js".into(), ..extra.clone() }, GalleryFile { path: "cafe\u{301}.js".into(), ..extra }])), "paths"));
}

#[test]
fn rejects_unsafe_paths() {
    let deep = format!("{}a", "a/".repeat(16));
    let long = "a".repeat(513);
    let unsafe_paths = ["", "/main.jsx", "\\main.jsx", "../main.jsx", "lib/../../main.jsx", "./main.jsx", "lib/./a.js", "lib//a.js", "lib/", "..", "lib\\a.js", "C:/a.js", "a:b", "a\u{0}b", "a\nb", "a\u{85}b", &deep, &long];
    for path in unsafe_paths {
        assert!(!is_safe_relative_path(path), "{path:?}");
        assert!(has(&rules(&with_file(&widget_item(), 1, |file| file.path = path.to_owned())), "path"), "{path:?}");
    }
    let deepest = format!("{}a", "a/".repeat(15));
    let longest = "a".repeat(512);
    for path in ["main.jsx", "lib/helpers/a.js", &deepest, "assets/icon@2x.png", &longest] {
        assert!(is_safe_relative_path(path), "{path}");
    }
}

#[test]
fn rejects_file_urls_outside_the_trusted_host() {
    for url in UNTRUSTED {
        assert!(has(&rules(&with_file(&widget_item(), 0, |file| file.url = url.to_owned())), "url"), "{url}");
    }
}

#[test]
fn rejects_invalid_hashes() {
    let hash = widget_item().files[0].sha256.clone();
    for value in [hash.to_uppercase(), hash[..63].to_owned(), format!("{hash}0"), "g".repeat(64), String::new(), format!("sha256:{hash}")] {
        assert!(has(&rules(&with_file(&widget_item(), 0, |file| file.sha256 = value.clone())), "hash"), "{value}");
    }
}

#[test]
fn rejects_invalid_file_sizes() {
    for size in [0, -1, validator::MAX_FILE_BYTES + 1, i64::MAX] {
        assert!(has(&rules(&with_file(&widget_item(), 0, |file| file.bytes = size)), "bytes"), "{size}");
    }
    assert!(!has(&rules(&with_file(&widget_item(), 0, |file| file.bytes = validator::MAX_FILE_BYTES)), "bytes"));
    let mut overflow = widget_item();
    overflow.files.iter_mut().for_each(|file| file.bytes = i64::MAX);
    assert!(has(&rules(&overflow), "total"));
    assert_eq!(overflow.total_bytes(), i64::MAX, "the sum saturates");
}

fn sized(item: &GalleryItem, bytes: i64) -> GalleryItem {
    let mut item = item.clone();
    item.files.iter_mut().for_each(|file| file.bytes = bytes);
    item
}

#[test]
fn rejects_widgets_without_required_files_or_above_thirty_two_mebibytes() {
    let widget = widget_item();
    assert!(has(&rules(&with_file(&widget, 1, |file| file.path = "index.jsx".into())), "required"));
    assert!(has(&rules(&with_file(&widget, 0, |file| file.path = "Widget.json".into())), "required"));
    assert_eq!(rules(&sized(&widget, 17 * 1024 * 1024)).into_iter().collect::<Vec<_>>(), ["total"]);
    assert!(rules(&sized(&widget, 16 * 1024 * 1024)).is_empty());
}

#[test]
fn rejects_skills_that_are_not_exactly_two_files_or_above_the_limit() {
    let skill = skill_item();
    let mut three = skill.clone();
    three.files.push(GalleryFile { path: "run.sh".into(), ..skill.files[0].clone() });
    assert!(has(&rules(&three), "required"));
    assert!(has(&rules(&with_file(&skill, 1, |file| file.path = "README.md".into())), "required"));
    assert!(has(&rules(&with_file(&skill, 1, |file| file.path = "skill.md".into())), "required"));
    assert!(has(&rules(&GalleryItem { kind: GalleryItemKind::Widget, ..skill.clone() }), "required"));
    assert_eq!(rules(&sized(&skill, 128 * 1024 + 1)).into_iter().collect::<Vec<_>>(), ["total"]);
    assert!(rules(&sized(&skill, 128 * 1024)).is_empty());
}

// The trust rule (GalleryTrustTest.kt)

#[test]
fn accepts_only_bare_https_raw_github_urls() {
    for url in ["https://raw.githubusercontent.com/everettjf/scriptwidget/main/Gallery/index.json", "HTTPS://RAW.GitHubUserContent.com/a/b", "https://raw.githubusercontent.com/a/b%20c.png"] {
        assert!(is_raw_github_url(url), "{url}");
    }
}

#[test]
fn rejects_every_other_url_shape() {
    for url in UNTRUSTED {
        assert!(!is_raw_github_url(url), "{url}");
    }
    // Text a URL library would repair or normalize is refused as written.
    for url in ["https://raw.githubusercontent.com/\u{0}", "https://raw.githubusercontent.com/a\tb", "https://raw.githubusercontent.com/a%2", "https://raw.githubusercontent.com/a%zz", " https://raw.githubusercontent.com/a", "https://raw.githubusercontent.com/a\n", "https:\\\\raw.githubusercontent.com\\a", "https://raw.githubusercontent.com\u{ff0f}a"] {
        assert!(!is_raw_github_url(url), "{url:?}");
    }
}

#[test]
fn redirect_targets_are_held_to_the_same_rule() {
    assert!(is_raw_github_url("https://raw.githubusercontent.com/a/b"));
    for url in ["https://evil.example/a/b", "http://raw.githubusercontent.com/a/b", "https://github.com/a/b", "https://objects.githubusercontent.com/a", "https://raw.githubusercontent.com/a?token=1", "https://127.0.0.1/a"] {
        assert!(!is_raw_github_url(url), "{url}");
    }
}

#[test]
fn production_transport_refuses_untrusted_start_urls_before_any_request() {
    // A resolver that must never be asked: the refusal comes before anything is resolved.
    let fetch = sw_core::api::fetch::FetchModule::with_resolver(std::sync::Arc::new(|host: &str| panic!("{host} was resolved")));
    let transport = FetchGalleryTransport::with_fetch(fetch);
    for url in ["https://evil.example/index.json", "http://raw.githubusercontent.com/a", "https://raw.githubusercontent.com/a?b=c", "https://raw.githubusercontent.com:443/a", "https://user@raw.githubusercontent.com/a"] {
        let error = assert_kind(GalleryErrorKind::Network, transport.fetch(&GalleryRequest { url: url.into(), headers: vec![], timeout_milliseconds: 1000 }));
        assert!(error.message.contains("raw.githubusercontent.com"), "{}", error.message);
    }
}
