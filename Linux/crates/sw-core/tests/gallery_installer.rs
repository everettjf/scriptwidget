//! Downloading, verifying and installing Gallery items. Ported from
//! `GalleryInstallerTest.kt`. Every download comes from [`FakeTransport`];
//! the catalog is the copy checked into this repository.

mod gallery_common;
#[path = "packages_support/mod.rs"]
mod support;

use std::cmp::Ordering;
use std::path::PathBuf;

use gallery_common::*;
use support::{TemporaryFolder, symlink, tree};
use sw_core::PackageFiles;
use sw_core::gallery::validator::{self, decode};
use sw_core::gallery::{GalleryError, GalleryErrorKind, GalleryFile, GalleryInstallState, GalleryInstallationRegistry, GalleryInstalledRecord, GalleryInstaller, GalleryItem, GalleryItemKind, semantic_version, sha256, supports};
use sw_core::packages::PackageStore;
use sw_core::skills::{SkillStore, built_ins};

struct Fixture {
    temporary: TemporaryFolder,
    library: PathBuf,
    staging: PathBuf,
    skills_root: PathBuf,
    downloads: PathBuf,
    registry_file: PathBuf,
    transport: FakeTransport,
    packages: PackageStore,
    skills: SkillStore,
    registry: GalleryInstallationRegistry,
}

impl Fixture {
    fn new() -> Self {
        let temporary = TemporaryFolder::new();
        let (library, staging, skills_root, downloads, registry_file) = (temporary.path("Scripts"), temporary.path("staging"), temporary.path("Skills"), temporary.path("downloads"), temporary.path("registry.json"));
        Self {
            packages: PackageStore::new(&library, &staging),
            skills: SkillStore::new(&skills_root),
            registry: GalleryInstallationRegistry::new(&registry_file),
            transport: FakeTransport::default(),
            temporary,
            library,
            staging,
            skills_root,
            downloads,
            registry_file,
        }
    }

    fn installer(&self) -> GalleryInstaller<'_> {
        GalleryInstaller::new(&self.transport, &self.registry, &self.packages, &self.skills, &self.downloads).runtime_api_version(Some("1.6")).carried_files(&[".installation"])
    }

    fn install(&self, item: &GalleryItem) -> Result<GalleryInstalledRecord, GalleryError> {
        self.installer().install(item)
    }

    fn state(&self, item: &GalleryItem) -> GalleryInstallState {
        self.installer().state(item)
    }

    fn package_names(&self) -> Vec<String> {
        self.packages.list().unwrap().into_iter().map(|package| package.name).collect()
    }

    fn custom_skills(&self) -> Vec<String> {
        self.skills.list().into_iter().filter(|skill| !skill.is_built_in).map(|skill| skill.id).collect()
    }

    /// Nothing was installed and no temporary, staging or record file is left.
    #[track_caller]
    fn assert_nothing_installed(&self) {
        assert_eq!(self.package_names(), [] as [&str; 0]);
        assert!(self.custom_skills().is_empty());
        for folder in [&self.library, &self.staging, &self.skills_root, &self.downloads] {
            assert_eq!(tree(folder), [] as [&str; 0], "{}", folder.display());
        }
        assert!(!self.registry_file.exists());
    }
}

fn update(current: &str) -> GalleryInstallState {
    GalleryInstallState::UpdateAvailable { current: current.into() }
}

fn with_last_file(item: &GalleryItem, change: impl Fn(&mut GalleryFile)) -> GalleryItem {
    let mut item = item.clone();
    change(item.files.last_mut().unwrap());
    item
}

// Success

#[test]
fn installs_every_checked_in_catalog_item_from_verified_bytes() {
    let fixture = Fixture::new();
    let index = decode(&checked_in_index()).unwrap();
    for file in index.items.iter().flat_map(|item| &item.files) {
        fixture.transport.serve(&file.url, &checked_in_file(file));
    }
    for item in &index.items {
        assert_eq!(fixture.state(item), GalleryInstallState::NotInstalled);
        let record = fixture.install(item).unwrap_or_else(|error| panic!("{}: {}", item.id, error.message));
        assert_eq!((record.item_id.as_str(), record.version.as_str()), (item.id.as_str(), item.version.as_str()));
        assert_eq!(fixture.state(item), GalleryInstallState::Installed);
        match item.kind {
            GalleryItemKind::Widget => {
                let installed = fixture.packages.list().unwrap().into_iter().find(|package| package.name == record.local_identifier).expect("the package");
                assert_eq!((installed.manifest_id.as_deref(), installed.manifest_version.as_deref()), (Some(item.id.as_str()), Some(item.version.as_str())));
                let mut listed: Vec<&str> = item.files.iter().map(|file| file.path.as_str()).collect();
                listed.sort_unstable();
                assert_eq!(fixture.packages.files(&installed.name).unwrap().paths(), listed);
                for file in &item.files {
                    assert_eq!(sha256(&std::fs::read(installed.directory.join(&file.path)).unwrap()), file.sha256);
                }
            }
            GalleryItemKind::Skill => {
                assert_eq!(record.local_identifier, item.id);
                assert_eq!(fixture.skills.find(&item.id).unwrap().version, item.version);
            }
        }
    }
    assert!(fixture.library.join("Gallery Hello Card/main.jsx").is_file());
    assert!(fixture.skills_root.join("privacy-review/SKILL.md").is_file());
    assert_eq!(fixture.package_names().len(), index.items.iter().filter(|item| item.kind == GalleryItemKind::Widget).count());
    assert_eq!(tree(&fixture.downloads), [] as [&str; 0]);
    assert_eq!(tree(&fixture.staging), [] as [&str; 0]);
    let requests = fixture.transport.requests();
    assert_eq!(requests[0].header("User-Agent"), Some("ScriptWidget-Gallery/1"));
    assert!(requests.iter().all(|request| validator::is_raw_github_url(&request.url) && request.headers.len() == 1));
}

#[test]
fn installs_nested_files_and_records_the_installation() {
    let fixture = Fixture::new();
    let (item, files) = widget_with("1.0.0", None, &[("lib/helpers/format.js", b"export const x = 1;"), ("assets/icon.png", &[1, 2, 3])]);
    fixture.transport.serve_all(&files);
    let record = fixture.install(&item).unwrap();
    assert_eq!(record.local_identifier, "Fixture Widget");
    assert_eq!(record.content_fingerprint, item.content_fingerprint());
    assert_eq!(std::fs::read(fixture.library.join("Fixture Widget/assets/icon.png")).unwrap(), [1, 2, 3]);
    assert_eq!(GalleryInstallationRegistry::new(&fixture.registry_file).record(&item.id), Some(record));
    assert_eq!(support::mode(&fixture.registry_file), 0o600);
    assert_eq!(tree(&fixture.downloads), [] as [&str; 0]);
}

#[test]
fn a_first_install_never_replaces_an_unrelated_package_with_the_same_name() {
    let fixture = Fixture::new();
    fixture.packages.create("Fixture Widget", "$render(<text>mine</text>);", None).unwrap();
    let (item, files) = widget();
    fixture.transport.serve_all(&files);
    assert_eq!(fixture.install(&item).unwrap().local_identifier, "Fixture Widget (1)");
    assert_eq!(std::fs::read_to_string(fixture.library.join("Fixture Widget/main.jsx")).unwrap(), "$render(<text>mine</text>);");
}

// Download verification

#[test]
fn byte_count_mismatch_installs_nothing() {
    let fixture = Fixture::new();
    let (item, files) = widget();
    fixture.transport.serve_all(&files);
    let (url, body) = &files[1];
    fixture.transport.serve(url, &[body.as_slice(), b" "].concat());
    let error = assert_kind(GalleryErrorKind::InvalidDownload, fixture.install(&item));
    assert!(error.message.contains("main.jsx"));
    fixture.assert_nothing_installed();

    fixture.transport.serve(url, &body[..body.len() - 1]);
    assert_kind(GalleryErrorKind::InvalidDownload, fixture.install(&item));
    fixture.assert_nothing_installed();
}

#[test]
fn hash_mismatch_installs_nothing() {
    let fixture = Fixture::new();
    let (item, files) = widget();
    fixture.transport.serve_all(&files);
    // The same number of bytes, other content.
    fixture.transport.serve(&item.files[0].url, &vec![120u8; item.files[0].bytes as usize]);
    assert_kind(GalleryErrorKind::InvalidDownload, fixture.install(&item));
    fixture.assert_nothing_installed();
    assert_eq!(fixture.state(&item), GalleryInstallState::NotInstalled);
}

#[test]
fn error_status_and_off_host_responses_install_nothing() {
    let fixture = Fixture::new();
    let (item, files) = widget();
    fixture.transport.serve_all(&files);
    let (second, body) = &files[1];
    fixture.transport.serve_as(second, body, 404, second);
    assert_kind(GalleryErrorKind::InvalidDownload, fixture.install(&item));
    fixture.assert_nothing_installed();

    // Correct bytes, but delivered after a redirect to another host.
    fixture.transport.serve_as(second, body, 200, "https://evil.example/main.jsx");
    assert_kind(GalleryErrorKind::InvalidDownload, fixture.install(&item));
    fixture.transport.serve_as(second, body, 200, "http://raw.githubusercontent.com/main.jsx");
    assert_kind(GalleryErrorKind::InvalidDownload, fixture.install(&item));
    fixture.assert_nothing_installed();
}

#[test]
fn a_network_failure_after_some_files_leaves_no_package_and_no_temporary_files() {
    let fixture = Fixture::new();
    let (item, files) = widget_with("1.0.0", None, &[("lib/a.js", b"1"), ("lib/b.js", b"2")]);
    fixture.transport.serve_all(&files);
    fixture.transport.unmap(&item.files[3].url);
    assert_kind(GalleryErrorKind::Network, fixture.install(&item));
    assert_eq!(fixture.transport.requests().len(), 4);
    fixture.assert_nothing_installed();

    fixture.transport.map(&item.files[2].url, || Err(GalleryError::network("Redirect target is not allowed")));
    assert_kind(GalleryErrorKind::Network, fixture.install(&item));
    fixture.assert_nothing_installed();
}

// Items refused before any request

#[test]
fn unsafe_paths_are_refused_before_any_download() {
    let fixture = Fixture::new();
    let (item, files) = widget_with("1.0.0", None, &[("lib/a.js", b"1")]);
    fixture.transport.serve_all(&files);
    for path in ["../escape.js", "/tmp/escape.js", "lib/../../escape.js", "lib\\a.js", "C:escape.js", ""] {
        assert_kind(GalleryErrorKind::Install, fixture.install(&with_last_file(&item, |file| file.path = path.to_owned())));
    }
    assert!(fixture.transport.requests().is_empty());
    fixture.assert_nothing_installed();
    assert!(tree(&fixture.temporary.root).iter().all(|path| !path.contains("escape")));
}

#[test]
fn untrusted_file_urls_are_refused_before_any_download() {
    let fixture = Fixture::new();
    let (item, files) = widget();
    fixture.transport.serve_all(&files);
    for url in ["https://evil.example/main.jsx", "http://raw.githubusercontent.com/a/main.jsx", "https://raw.githubusercontent.com/a/main.jsx?x=1"] {
        fixture.transport.serve(url, &files[1].1);
        let untrusted = with_last_file(&item, |file| file.url = url.to_owned());
        assert_kind(GalleryErrorKind::Install, fixture.install(&untrusted));
        assert_kind(GalleryErrorKind::Install, fixture.installer().download_verified(&untrusted, "main.jsx"));
    }
    assert!(fixture.transport.requests().is_empty());
    fixture.assert_nothing_installed();
}

#[test]
fn oversized_items_are_refused_before_any_download() {
    let fixture = Fixture::new();
    let ((widget, widget_files), (skill, skill_files)) = (widget(), skill());
    fixture.transport.serve_all(&widget_files);
    fixture.transport.serve_all(&skill_files);
    let sized = |item: &GalleryItem, bytes: i64| {
        let mut item = item.clone();
        item.files.iter_mut().for_each(|file| file.bytes = bytes);
        item
    };
    let huge_file = with_last_file(&widget, |file| file.bytes = validator::MAX_FILE_BYTES + 1);
    for item in [huge_file, sized(&widget, 17 * 1024 * 1024), sized(&skill, 200 * 1024)] {
        assert_kind(GalleryErrorKind::Install, fixture.install(&item));
    }
    assert!(fixture.transport.requests().is_empty());
    fixture.assert_nothing_installed();
}

#[test]
fn a_response_larger_than_declared_is_never_written() {
    let fixture = Fixture::new();
    let (item, files) = widget();
    fixture.transport.serve_all(&files);
    fixture.transport.serve(&item.files[0].url, &vec![0u8; 4 * 1024 * 1024]);
    assert_kind(GalleryErrorKind::InvalidDownload, fixture.install(&item));
    fixture.assert_nothing_installed();
}

// Widget content refused after download

#[test]
fn manifest_identity_or_version_mismatch_installs_nothing() {
    let fixture = Fixture::new();
    for manifest in [widget_manifest("com.example.other", WIDGET_NAME, "1.0.0", ""), widget_manifest(WIDGET_ID, WIDGET_NAME, "9.9.9", ""), "not json".to_owned(), "[]".to_owned()] {
        let (item, files) = widget_with("1.0.0", Some(&manifest), &[]);
        fixture.transport.serve_all(&files);
        assert_kind(GalleryErrorKind::Install, fixture.install(&item));
        fixture.assert_nothing_installed();
    }
}

#[test]
fn widgets_requiring_a_newer_runtime_api_are_refused() {
    let fixture = Fixture::new();
    let manifest = |extra: &str| widget_manifest(WIDGET_ID, WIDGET_NAME, "1.0.0", extra);
    for extra in [",\"minimumRuntimeVersion\":\"1.7\"", ",\"minimumRuntimeVersion\":\"2.0\"", ",\"minimumRuntimeVersion\":\"latest\"", ",\"minimumRuntimeVersion\":3"] {
        let (item, files) = widget_with("1.0.0", Some(&manifest(extra)), &[]);
        fixture.transport.serve_all(&files);
        assert!(assert_kind(GalleryErrorKind::Install, fixture.install(&item)).message.contains("Runtime API"), "{extra}");
        fixture.assert_nothing_installed();
    }
    let wrong_contract = manifest("").replace("\"runtimeVersion\":\"1.0\"", "\"runtimeVersion\":\"2.0\"");
    let (refused, refused_files) = widget_with("1.0.0", Some(&wrong_contract), &[]);
    fixture.transport.serve_all(&refused_files);
    assert_kind(GalleryErrorKind::Install, fixture.install(&refused));
    fixture.assert_nothing_installed();

    let (item, files) = widget_with("1.0.0", Some(&manifest(",\"minimumRuntimeVersion\":\"1.6\"")), &[]);
    fixture.transport.serve_all(&files);
    fixture.install(&item).unwrap();
    assert_eq!(fixture.package_names(), ["Fixture Widget"]);
    assert!(supports("1.3", "1.6") && supports("1.6", "1.6") && supports("0.0", "0.5"));
    for (minimum, current) in [("1.7", "1.6"), ("2.0", "1.6"), ("1", "1.6"), ("01.2", "1.6"), ("1.06", "1.6"), ("1.6", "latest"), ("1.1000", "1.2000"), ("", "1.6"), ("1.6.0", "1.6"), ("-1.2", "1.6")] {
        assert!(!supports(minimum, current), "{minimum} on {current}");
    }
}

#[test]
fn paths_the_package_store_would_drop_are_refused_instead_of_installed_partially() {
    let fixture = Fixture::new();
    for path in [".hidden", "__Build/prepared.json", "lib/.secret.js"] {
        let (item, files) = widget_with("1.0.0", None, &[(path, b"x")]);
        fixture.transport.serve_all(&files);
        assert_kind(GalleryErrorKind::Install, fixture.install(&item));
        fixture.assert_nothing_installed();
    }
}

#[test]
fn a_package_rejected_by_the_package_layer_or_the_injected_validator_installs_nothing() {
    let fixture = Fixture::new();
    // The package store refuses a manifest whose name is not a valid package name.
    let (invalid, invalid_files) = widget_with("1.0.0", Some(&widget_manifest(WIDGET_ID, "bad/name", "1.0.0", "")), &[]);
    fixture.transport.serve_all(&invalid_files);
    assert_kind(GalleryErrorKind::Install, fixture.install(&invalid));
    fixture.assert_nothing_installed();

    let (item, files) = widget();
    fixture.transport.serve_all(&files);
    let refuse = |staged: &dyn PackageFiles| -> Result<(), String> {
        assert_eq!(staged.paths(), ["main.jsx", "widget.json"]);
        Err("permission not allowed".into())
    };
    let strict = fixture.installer().widget_validator(&refuse);
    assert_eq!(assert_kind(GalleryErrorKind::Install, strict.install(&item)).message, "permission not allowed");
    fixture.assert_nothing_installed();
}

// Updates

#[test]
fn update_replaces_the_installed_package_in_place() {
    let fixture = Fixture::new();
    let (first, first_files) = widget_with("1.0.0", None, &[("old.js", b"old")]);
    let (next, next_files) = widget_with("2.0.0", None, &[("new.js", b"new")]);
    fixture.transport.serve_all(&first_files);
    fixture.transport.serve_all(&next_files);

    let installed = fixture.install(&first).unwrap();
    std::fs::write(fixture.library.join(&installed.local_identifier).join(".installation"), "installation-1").unwrap();
    assert_eq!(fixture.state(&first), GalleryInstallState::Installed);
    assert_eq!(fixture.state(&next), update("1.0.0"));

    let updated = fixture.install(&next).unwrap();
    assert_eq!(updated.local_identifier, installed.local_identifier);
    assert_eq!(fixture.package_names(), ["Fixture Widget"]);
    assert_eq!(fixture.packages.list().unwrap()[0].manifest_version.as_deref(), Some("2.0.0"));
    assert_eq!(fixture.packages.files("Fixture Widget").unwrap().paths(), ["main.jsx", "new.js", "widget.json"]);
    assert_eq!(std::fs::read_to_string(fixture.library.join("Fixture Widget/.installation")).unwrap(), "installation-1");
    assert_eq!(fixture.state(&next), GalleryInstallState::Installed);
    // The older catalog entry is not offered as a downgrade.
    assert_eq!(fixture.state(&first), GalleryInstallState::Installed);
    assert_eq!(tree(&fixture.staging), [] as [&str; 0]);
    assert_eq!(tree(&fixture.downloads), [] as [&str; 0]);
}

#[test]
fn a_bookkeeping_file_that_is_a_link_is_not_carried_to_the_update() {
    let fixture = Fixture::new();
    let ((first, first_files), (next, next_files)) = (widget_with("1.0.0", None, &[]), widget_with("2.0.0", None, &[]));
    fixture.transport.serve_all(&first_files);
    fixture.transport.serve_all(&next_files);
    fixture.install(&first).unwrap();
    let secret = fixture.temporary.new_file("secret", "not a package file");
    symlink(&fixture.library.join("Fixture Widget/.installation"), &secret);
    fixture.install(&next).unwrap();
    assert!(!fixture.library.join("Fixture Widget/.installation").exists());
    assert_eq!(fixture.packages.list().unwrap()[0].manifest_version.as_deref(), Some("2.0.0"));
}

#[test]
fn a_failed_update_keeps_the_installed_version() {
    let fixture = Fixture::new();
    let ((first, first_files), (next, next_files)) = (widget_with("1.0.0", None, &[]), widget_with("2.0.0", None, &[]));
    fixture.transport.serve_all(&first_files);
    fixture.transport.serve_all(&next_files);
    fixture.install(&first).unwrap();
    fixture.transport.serve(&next.files[1].url, b"tampered");
    assert_kind(GalleryErrorKind::InvalidDownload, fixture.install(&next));
    assert_eq!(fixture.package_names(), ["Fixture Widget"]);
    assert_eq!(fixture.packages.list().unwrap()[0].manifest_version.as_deref(), Some("1.0.0"));
    assert_eq!(fixture.state(&next), update("1.0.0"));
    assert_eq!(tree(&fixture.staging), [] as [&str; 0]);
    assert_eq!(tree(&fixture.downloads), [] as [&str; 0]);
}

#[test]
fn changed_fingerprint_at_the_same_version_offers_an_update() {
    let fixture = Fixture::new();
    let (item, files) = widget();
    fixture.transport.serve_all(&files);
    fixture.install(&item).unwrap();
    let corrected = with_last_file(&item, |file| file.sha256 = "0".repeat(64));
    assert_eq!(fixture.state(&corrected), update(&item.version));

    fixture.registry.save(&GalleryInstalledRecord { item_id: item.id.clone(), kind: item.kind, version: item.version.clone(), local_identifier: "Local".into(), content_fingerprint: "different".into(), installed_at: 0 }).unwrap();
    assert_eq!(fixture.registry.state(&item), update(&item.version));
}

#[test]
fn a_record_is_only_honored_while_its_package_is_still_that_item() {
    let fixture = Fixture::new();
    let (item, files) = widget();
    fixture.transport.serve_all(&files);
    let record = fixture.install(&item).unwrap();

    // Deleted by the user.
    fixture.packages.delete(&record.local_identifier).unwrap();
    assert_eq!(fixture.state(&item), GalleryInstallState::NotInstalled);

    // A poisoned record pointing at an unrelated package must not let an install replace it.
    fixture.packages.create("Victim", "$render(<text>do not replace</text>);", None).unwrap();
    fixture.registry.save(&GalleryInstalledRecord { local_identifier: "Victim".into(), ..record }).unwrap();
    assert_eq!(fixture.state(&item), GalleryInstallState::NotInstalled);
    let reinstalled = fixture.install(&item).unwrap();
    assert_ne!(reinstalled.local_identifier, "Victim");
    assert_eq!(std::fs::read_to_string(fixture.library.join("Victim/main.jsx")).unwrap(), "$render(<text>do not replace</text>);");
    assert_eq!(fixture.package_names(), ["Fixture Widget", "Victim"]);
}

#[test]
fn semantic_versions_compare_numerically() {
    use semantic_version::compare;
    assert_eq!(compare("1.2.0", "1.10.0"), Ordering::Less);
    assert_eq!(compare("2.0.0", "1.99.99"), Ordering::Greater);
    assert_eq!(compare("1.0.0", "1.0.0"), Ordering::Equal);
    assert_eq!(compare("1.0", "1.0.1"), Ordering::Less);
    assert_eq!(compare("1.0.1-beta", "1.0.0"), Ordering::Greater);
    assert_eq!(compare("1.0.0-beta.2", "1.0.0-beta.10"), Ordering::Less);
    assert_eq!(compare("1.0.0-rc", "1.0.0"), compare("1.0.0", "1.0.0-rc").reverse());
    assert_ne!(compare("1.0.0-rc", "1.0.0"), Ordering::Equal);
}

#[test]
fn an_unreadable_registry_means_nothing_is_installed() {
    let fixture = Fixture::new();
    let (item, files) = widget();
    fixture.transport.serve_all(&files);
    fixture.install(&item).unwrap();
    let id = &item.id;
    for content in ["not json".to_owned(), "[]".to_owned(), format!("{{\"{id}\":{{\"itemID\":\"{id}\",\"kind\":\"plugin\"}}}}"), format!("{{\"{id}\":7}}")] {
        std::fs::write(&fixture.registry_file, &content).unwrap();
        assert!(fixture.registry.records().is_empty(), "{content}");
        assert_eq!(fixture.state(&item), GalleryInstallState::NotInstalled);
    }
    fixture.registry.remove(id).unwrap();
    assert!(fixture.registry.records().is_empty());
}

// Skills

#[test]
fn installs_and_updates_a_skill_without_enabling_or_executing_it() {
    let fixture = Fixture::new();
    let ((first, first_files), (next, next_files)) = (skill_with("1.0.0", None, None), skill_with("1.1.0", None, None));
    fixture.transport.serve_all(&first_files);
    fixture.transport.serve_all(&next_files);

    fixture.install(&first).unwrap();
    assert_eq!(fixture.state(&first), GalleryInstallState::Installed);
    assert_eq!(fixture.state(&next), update("1.0.0"));
    assert_eq!(tree(&fixture.skills_root), ["fixture-skill/", "fixture-skill/SKILL.md", "fixture-skill/skill.json"]);
    assert!(!fixture.skills.is_enabled(&first.id));
    assert_eq!(fixture.skills.enabled_skills_prompt_text(), "");
    assert!(fixture.package_names().is_empty());

    fixture.install(&next).unwrap();
    assert_eq!(fixture.custom_skills(), [first.id.as_str()]);
    let installed = fixture.skills.find(&first.id).unwrap();
    assert_eq!((installed.version.as_str(), installed.instruction.as_str()), ("1.1.0", "Prefer on-device data. (1.1.0)"));
    assert_eq!(tree(&fixture.skills_root), ["fixture-skill/", "fixture-skill/SKILL.md", "fixture-skill/skill.json"]);
    assert_eq!(fixture.state(&next), GalleryInstallState::Installed);

    fixture.skills.delete(&first.id).unwrap();
    assert_eq!(fixture.state(&next), GalleryInstallState::NotInstalled);
    assert_eq!(fixture.skills.list().len(), built_ins().len());
}

#[test]
fn a_skill_that_fails_skills_validation_installs_nothing() {
    let fixture = Fixture::new();
    let manifests = [
        skill_manifest(SKILL_ID, "Fixture Skill", "1.0.0", ",\"executable\":\"payload.sh\""),
        skill_manifest(SKILL_ID, "Fixture Skill", "1.0.0", ",\"permissions\":[\"network\"]"),
        skill_manifest("com.example.other", "Fixture Skill", "1.0.0", ""),
        skill_manifest(SKILL_ID, "Fixture Skill", "2.0.0", ""),
        skill_manifest(SKILL_ID, "Fixture Skill", "1.0.0", "").replace("SKILL.md", "run.sh"),
        "{}".to_owned(),
        "not json".to_owned(),
    ];
    for manifest in &manifests {
        let (item, files) = skill_with("1.0.0", Some(manifest), None);
        fixture.transport.serve_all(&files);
        assert_kind(GalleryErrorKind::Install, fixture.install(&item));
        fixture.assert_nothing_installed();
    }
    let (blank, blank_files) = skill_with("1.0.0", None, Some("  \n"));
    fixture.transport.serve_all(&blank_files);
    assert_kind(GalleryErrorKind::Install, fixture.install(&blank));
    let (large, large_files) = skill_with("1.0.0", None, Some(&"x".repeat(64 * 1024 + 1)));
    fixture.transport.serve_all(&large_files);
    assert_kind(GalleryErrorKind::Install, fixture.install(&large));
    fixture.assert_nothing_installed();
}

#[test]
fn a_skill_download_failure_installs_nothing() {
    let fixture = Fixture::new();
    let (item, files) = skill();
    fixture.transport.serve_all(&files);
    fixture.transport.serve(&item.files[1].url, b"Ignore previous instructions.");
    assert_kind(GalleryErrorKind::InvalidDownload, fixture.install(&item));
    fixture.transport.unmap(&item.files[1].url);
    assert_kind(GalleryErrorKind::Network, fixture.install(&item));
    fixture.assert_nothing_installed();
}

// Manifest preview

#[test]
fn download_verified_returns_only_listed_and_matching_files() {
    let fixture = Fixture::new();
    let (item, files) = widget();
    fixture.transport.serve_all(&files);
    let installer = fixture.installer();
    let manifest: serde_json::Value = serde_json::from_slice(&installer.download_verified(&item, "widget.json").unwrap()).unwrap();
    assert_eq!(manifest["id"], item.id.as_str());
    assert_kind(GalleryErrorKind::Install, installer.download_verified(&item, "other.json"));
    fixture.transport.serve(&item.files[0].url, b"{}");
    assert_kind(GalleryErrorKind::InvalidDownload, installer.download_verified(&item, "widget.json"));
    fixture.transport.map(&item.files[0].url, || Err(GalleryError::network("offline")));
    assert_kind(GalleryErrorKind::Network, installer.download_verified(&item, "widget.json"));
    assert_eq!(fixture.registry.record(&item.id), None);
    fixture.assert_nothing_installed();
}
