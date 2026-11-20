//! Skills 1.0: validation, the store, tampered directories and hostile
//! archives. Ported from `Android/core/src/test/.../skills/SkillStoreTest.kt`;
//! the folder import, which Android does not have, is tested at the end.

#[path = "packages_support/mod.rs"]
mod support;

use std::path::PathBuf;

use serde_json::{Value, json};
use support::{RawEntry, SYMBOLIC_LINK, TemporaryFolder, deflated_zip, forge_declared_size, hard_link, raw_zip, read_zip, symlink, tree, write_file};
use sw_core::skills::{Skill, SkillError, SkillManifest, SkillStore, built_ins, errors, validator};

const ID: &str = "com.example.weather";
const INSTRUCTION: &str = "Prefer concise forecasts.\nMention the data source.";
const INSTALLED: [&str; 3] = ["weather-expert/", "weather-expert/SKILL.md", "weather-expert/skill.json"];

fn skill_manifest(id: &str, name: &str, version: &str, extra: &str) -> String {
    format!(r#"{{"formatVersion":1,"id":"{id}","name":"{name}","version":"{version}","summary":"Reviews privacy.","symbol":"lock","promptFile":"SKILL.md","tags":["privacy"],"minimumRuntimeVersion":"1.0"{extra}}}"#)
}

fn manifest() -> String {
    skill_manifest(ID, "Weather Expert", "1.0.0", "")
}

fn parsed() -> SkillManifest {
    validator::parse_manifest(manifest().as_bytes()).unwrap()
}

#[track_caller]
fn assert_code<T: std::fmt::Debug>(code: &str, result: Result<T, SkillError>) -> SkillError {
    match result {
        Err(error) => {
            assert_eq!(error.code, code, "{}", error.message);
            error
        }
        Ok(value) => panic!("expected {code}, but it succeeded with {value:?}"),
    }
}

struct Fixture {
    temporary: TemporaryFolder,
    root: PathBuf,
    store: SkillStore,
}

impl Fixture {
    fn new() -> Self {
        let temporary = TemporaryFolder::new();
        let root = temporary.path("Skills");
        Self { store: SkillStore::new(&root), root, temporary }
    }

    fn custom(&self) -> Vec<String> {
        self.store.list().into_iter().filter(|skill| !skill.is_built_in).map(|skill| skill.id).collect()
    }

    fn install(&self) -> Skill {
        self.store.install(manifest().as_bytes(), INSTRUCTION.as_bytes(), false).unwrap()
    }

    fn import(&self, archive: &[u8]) -> Result<Skill, SkillError> {
        self.store.import_archive(&mut &archive[..])
    }

    /// The import was refused and left neither a Skill nor staging files.
    #[track_caller]
    fn assert_import_refused(&self, code: &str, archive: &[u8]) {
        assert_code(code, self.import(archive));
        assert!(self.custom().is_empty());
        assert_eq!(tree(&self.root), [] as [&str; 0]);
    }
}

fn rules(manifest: &SkillManifest, text: &str) -> Vec<&'static str> {
    let mut rules: Vec<&'static str> = validator::validate(manifest, text).into_iter().map(|issue| issue.id).collect();
    rules.sort_unstable();
    rules
}

// Validation

#[test]
fn validator_accepts_a_valid_skill_and_reports_each_invalid_field() {
    assert!(validator::validate(&parsed(), INSTRUCTION).is_empty());
    assert_eq!(rules(&SkillManifest { version: "latest".into(), prompt_file: "prompt.txt".into(), ..parsed() }, "  "), ["empty_instruction", "invalid_prompt_file", "invalid_version"]);
    assert_eq!(rules(&SkillManifest { format_version: 2, ..parsed() }, INSTRUCTION), ["unsupported_format"]);
    for bad in ["ab", "-abc", "com.example/x", &"a".repeat(129), ""] {
        assert_eq!(rules(&SkillManifest { id: bad.into(), ..parsed() }, INSTRUCTION), ["invalid_id"], "{bad}");
    }
    assert_eq!(rules(&SkillManifest { name: " ".into(), ..parsed() }, INSTRUCTION), ["invalid_name"]);
    assert_eq!(rules(&SkillManifest { name: "n".repeat(81), ..parsed() }, INSTRUCTION), ["invalid_name"]);
    assert_eq!(rules(&SkillManifest { minimum_runtime_version: "2.0".into(), ..parsed() }, INSTRUCTION), ["unsupported_runtime"]);
    for file in ["../SKILL.md", "skill.md", "run.sh", ""] {
        assert_eq!(rules(&SkillManifest { prompt_file: file.into(), ..parsed() }, INSTRUCTION), ["invalid_prompt_file"], "{file}");
    }
    assert_eq!(rules(&SkillManifest { summary: String::new(), ..parsed() }, INSTRUCTION), ["invalid_summary"]);
    assert_eq!(rules(&SkillManifest { summary: "s".repeat(241), ..parsed() }, INSTRUCTION), ["invalid_summary"]);
    assert_eq!(rules(&SkillManifest { symbol: String::new(), ..parsed() }, INSTRUCTION), ["invalid_symbol"]);
    assert_eq!(rules(&SkillManifest { symbol: "s".repeat(81), ..parsed() }, INSTRUCTION), ["invalid_symbol"]);
    assert_eq!(rules(&SkillManifest { tags: (0..21).map(|index| format!("t{index}")).collect(), ..parsed() }, INSTRUCTION), ["invalid_tags"]);
    assert_eq!(rules(&SkillManifest { tags: vec!["Layout".into(), "layout".into()], ..parsed() }, INSTRUCTION), ["invalid_tags"]);
    assert_eq!(rules(&parsed(), &"x".repeat(validator::MAX_INSTRUCTION_BYTES + 1)), ["instruction_too_large"]);
    assert!(rules(&parsed(), &"x".repeat(validator::MAX_INSTRUCTION_BYTES)).is_empty());
}

#[test]
fn manifest_with_unknown_keys_fails_closed() {
    for (key, extra) in [("executable", r#""executable":"payload.sh""#), ("permissions", r#""permissions":["network"]"#), ("tools", r#""tools":[]"#), ("networkDomains", r#""networkDomains":["example.com"]"#), ("Id", r#""Id":"x""#)] {
        let error = assert_code(errors::UNKNOWN_FIELD, validator::parse_manifest(skill_manifest(ID, "Weather Expert", "1.0.0", &format!(",{extra}")).as_bytes()));
        assert!(error.message.contains(key), "{}", error.message);
    }
}

#[test]
fn manifest_that_is_not_one_json_object_is_rejected() {
    let manifest = manifest();
    let documents: Vec<Vec<u8>> = vec![
        Vec::new(),
        b"not json".to_vec(),
        b"[]".to_vec(),
        b"null".to_vec(),
        b"{\"id\":".to_vec(),
        format!("{manifest}{{}}").into_bytes(),
        format!("{manifest} trailing").into_bytes(),
        vec![0xC3, 0x28],
        // Only a lenient reader takes these; two readers must not disagree about a manifest.
        manifest.replace("\"id\"", "id").into_bytes(),
        format!("{},\"id\":\"com.example.second\"}}", &manifest[..manifest.len() - 1]).into_bytes(),
    ];
    for bytes in documents {
        assert_code(errors::INVALID_MANIFEST, validator::parse_manifest(&bytes));
    }
}

#[test]
fn manifest_with_missing_or_wrongly_typed_fields_is_rejected() {
    let base: Value = serde_json::from_str(&manifest()).unwrap();
    let with = |key: &str, value: Value| {
        let mut json = base.clone();
        json[key] = value;
        json.to_string().into_bytes()
    };
    for key in ["formatVersion", "id", "name", "version", "summary", "symbol", "promptFile", "tags", "minimumRuntimeVersion"] {
        let mut json = base.clone();
        json.as_object_mut().unwrap().remove(key);
        assert_code(errors::INVALID_MANIFEST, validator::parse_manifest(json.to_string().as_bytes()));
    }
    let wrong = [
        ("formatVersion", json!("1")),
        ("id", json!(7)),
        ("name", Value::Null),
        ("version", json!(1.5)),
        ("tags", json!("layout")),
        ("author", json!(7)),
        ("promptFile", json!(["SKILL.md"])),
        ("minimumRuntimeVersion", json!(1.5)),
        ("formatVersion", json!(1.5)),
        ("formatVersion", json!(4294967297u64)),
        ("tags", json!(["a", 1])),
    ];
    for (key, value) in wrong {
        assert_code(errors::INVALID_MANIFEST, validator::parse_manifest(&with(key, value)));
    }
    assert_eq!(validator::parse_manifest(&with("author", json!("Ada"))).unwrap().author.as_deref(), Some("Ada"));
}

#[test]
fn oversized_or_non_text_files_are_rejected() {
    let manifest = manifest();
    let padded = format!("{},\"author\":\"{}\"}}", &manifest[..manifest.len() - 1], "a".repeat(validator::MAX_MANIFEST_BYTES));
    assert_code(errors::TOO_LARGE, validator::parse_manifest(padded.as_bytes()));
    assert_code(errors::TOO_LARGE, validator::load(manifest.as_bytes(), &vec![b'x'; validator::MAX_INSTRUCTION_BYTES + 1]));
    assert_code(errors::INVALID_INSTRUCTION, validator::load(manifest.as_bytes(), &[b'a', 0xFF]));
    assert_code(errors::INVALID_SKILL, validator::load(manifest.as_bytes(), b" \n\t"));
    let fixture = Fixture::new();
    assert_code(errors::TOO_LARGE, fixture.store.install(manifest.as_bytes(), &vec![b'x'; validator::MAX_INSTRUCTION_BYTES + 1], false));
    assert_eq!(tree(&fixture.root), [] as [&str; 0]);
}

// The store

#[test]
fn install_list_find_delete_lifecycle() {
    let fixture = Fixture::new();
    assert_eq!(fixture.store.list(), built_ins());
    assert!(!fixture.root.exists(), "listing must not create the directory");
    let skill = fixture.install();
    assert_eq!((skill.id.as_str(), skill.title.as_str(), skill.instruction.as_str(), skill.is_built_in), (ID, "Weather Expert", INSTRUCTION, false));
    let mut expected = built_ins().to_vec();
    expected.push(skill.clone());
    assert_eq!(fixture.store.list(), expected);
    assert_eq!(fixture.store.find(ID), Some(skill.clone()));
    assert!(fixture.store.is_installed(ID));
    assert_eq!(tree(&fixture.root), INSTALLED);
    assert_eq!(std::fs::read_to_string(fixture.root.join("weather-expert/skill.json")).unwrap(), manifest());
    // Private to the user, like every other file of the data folder.
    assert_eq!(support::mode(&fixture.root), 0o700);
    assert_eq!(support::mode(&fixture.root.join("weather-expert")), 0o700);
    assert_eq!(support::mode(&fixture.root.join("weather-expert/SKILL.md")), 0o600);

    // A second store on the same directory sees the same Skill.
    assert_eq!(SkillStore::new(&fixture.root).find(ID), Some(skill));

    fixture.store.delete(ID).unwrap();
    assert_eq!(fixture.store.find(ID), None);
    assert!(!fixture.store.is_installed(ID));
    assert!(!fixture.root.join("weather-expert").exists());
    assert_code(errors::NOT_FOUND, fixture.store.delete(ID));
}

#[test]
fn duplicate_identifiers_are_rejected_unless_replacement_is_explicit() {
    let fixture = Fixture::new();
    fixture.install();
    assert_code(errors::DUPLICATE, fixture.store.install(manifest().as_bytes(), b"Something else.", false));
    assert_eq!(fixture.store.find(ID).unwrap().instruction, INSTRUCTION);

    let replaced = fixture.store.install(skill_manifest(ID, "Weather Expert", "1.1.0", "").as_bytes(), b"Updated guidance.", true).unwrap();
    assert_eq!(replaced.version, "1.1.0");
    assert_eq!(fixture.store.find(ID).unwrap().instruction, "Updated guidance.");
    assert_eq!(fixture.custom(), [ID]);
    assert_eq!(tree(&fixture.root), INSTALLED);

    // A different Skill with the same display name gets its own directory.
    fixture.store.install(skill_manifest("com.example.weather2", "Weather Expert", "1.0.0", "").as_bytes(), INSTRUCTION.as_bytes(), false).unwrap();
    assert!(fixture.root.join("weather-expert-2/skill.json").is_file());
}

#[test]
fn built_in_skills_are_read_only() {
    let fixture = Fixture::new();
    let built_in = &built_ins()[0];
    assert_eq!(built_ins().len(), 5);
    assert!(built_ins().iter().all(|skill| skill.is_built_in && !validator::slug(&skill.title).is_empty()));
    assert_code(errors::BUILT_IN, fixture.store.delete(&built_in.id));
    assert_code(errors::DUPLICATE, fixture.store.install(skill_manifest(&built_in.id, "Shadow", "1.0.0", "").as_bytes(), INSTRUCTION.as_bytes(), false));
    assert_eq!(fixture.store.find(&built_in.id).as_ref(), Some(built_in));
}

#[test]
fn slugs_are_plain_directory_names() {
    assert_eq!(validator::slug("Weather Expert"), "weather-expert");
    assert_eq!(validator::slug("  ../../Etc/Passwd  "), "etc-passwd");
    assert_eq!(validator::slug("天气"), "skill");
    assert_eq!(validator::slug(&"a-".repeat(80)).len(), 63);
}

#[test]
fn enabled_state_is_off_by_default_persists_and_is_dropped_on_delete() {
    let fixture = Fixture::new();
    fixture.install();
    assert!(fixture.store.enabled_ids().is_empty());
    assert_eq!(fixture.store.enabled_skills_prompt_text(), "");
    assert_eq!(fixture.store.augment("hello"), "hello");

    fixture.store.set_enabled(ID, true).unwrap();
    fixture.store.set_enabled("accessible-design", true).unwrap();
    assert!(fixture.store.is_enabled(ID));
    assert_eq!(SkillStore::new(&fixture.root).enabled_ids().into_iter().collect::<Vec<_>>(), ["accessible-design", ID]);
    assert_code(errors::NOT_FOUND, fixture.store.set_enabled("com.example.missing", true));

    fixture.store.set_enabled("accessible-design", false).unwrap();
    assert_eq!(fixture.store.enabled_ids().into_iter().collect::<Vec<_>>(), [ID]);
    fixture.store.delete(ID).unwrap();
    assert!(fixture.store.enabled_ids().is_empty());
    assert_eq!(fixture.store.enabled_skills_prompt_text(), "");
}

#[test]
fn prompt_text_is_deterministic_and_contains_only_enabled_skills() {
    let fixture = Fixture::new();
    fixture.install();
    fixture.store.install(skill_manifest("com.example.alpha", "Alpha Guide", "2.1.0", "").as_bytes(), b"Be brief.", false).unwrap();
    for skill in [ID, "com.example.alpha", "responsive-layout"] {
        fixture.store.set_enabled(skill, true).unwrap();
    }
    let responsive = built_ins().iter().find(|skill| skill.id == "responsive-layout").unwrap();
    let expected = format!(
        "Apply these ScriptWidget skills:\n- Responsive Layout v1.0.0:\n  {}\n- Alpha Guide v2.1.0:\n  Be brief.\n- Weather Expert v1.0.0:\n  Prefer concise forecasts.\n  Mention the data source.",
        responsive.instruction
    );
    assert_eq!(fixture.store.enabled_skills_prompt_text(), expected);
    assert_eq!(SkillStore::new(&fixture.root).enabled_skills_prompt_text(), expected);
    assert_eq!(fixture.store.augment("Make a clock"), format!("Make a clock\n\n{expected}"));
}

/// A conversation names its own Skills: the same text for those ids, whether they are enabled or not.
#[test]
fn prompt_text_for_named_skills_does_not_depend_on_what_is_enabled() {
    let fixture = Fixture::new();
    fixture.install();
    fixture.store.set_enabled("responsive-layout", true).unwrap();
    let ids = |names: &[&str]| names.iter().map(|name| name.to_string()).collect::<Vec<String>>();
    let named = fixture.store.prompt_text(&ids(&[ID, "no.such.skill", "accessible-design"]));
    let accessible = built_ins().iter().find(|skill| skill.id == "accessible-design").unwrap();
    assert_eq!(named, format!("Apply these ScriptWidget skills:\n- Accessible Design v1.0.0:\n  {}\n- Weather Expert v1.0.0:\n  Prefer concise forecasts.\n  Mention the data source.", accessible.instruction.replace('\n', "\n  ")), "in the order of the list, without the id that is not a Skill and without the enabled one");
    assert_eq!(fixture.store.prompt_text(&[]), "");
    assert_eq!(fixture.store.prompt_text(&ids(&["no.such.skill"])), "");
    assert_eq!(fixture.store.skills_with(&ids(&[ID])).iter().map(|skill| skill.title.as_str()).collect::<Vec<_>>(), ["Weather Expert"]);
    // The Skills of a turn: the conversation's own, or without a choice the enabled ones.
    let titles = |chosen: Option<&[String]>| fixture.store.skills_for(chosen).into_iter().map(|skill| skill.id).collect::<Vec<String>>();
    assert_eq!(titles(None), ["responsive-layout"]);
    assert_eq!(titles(Some(&ids(&[ID]))), [ID]);
    assert!(titles(Some(&[])).is_empty(), "no Skill is a choice too");
    assert_eq!(fixture.store.enabled_ids().into_iter().collect::<Vec<_>>(), ["responsive-layout"], "naming a Skill enables nothing");
}

#[test]
fn a_corrupt_or_linked_enabled_file_enables_nothing() {
    let fixture = Fixture::new();
    fixture.install();
    fixture.store.set_enabled(ID, true).unwrap();
    let file = fixture.root.join(".enabled.json");
    let valid = std::fs::read(&file).unwrap();
    for content in ["not json".to_owned(), "{}".to_owned(), "[1]".to_owned(), format!("[\"{ID}\", null]")] {
        std::fs::write(&file, &content).unwrap();
        assert!(fixture.store.enabled_ids().is_empty(), "{content}");
        assert_eq!(fixture.store.enabled_skills_prompt_text(), "");
    }
    // A link in place of the file is not followed.
    let outside = fixture.temporary.path("outside-enabled.json");
    write_file(&outside, &valid);
    std::fs::remove_file(&file).unwrap();
    symlink(&file, &outside);
    assert!(fixture.store.enabled_ids().is_empty());
}

// Tampered directories

#[test]
fn a_directory_that_is_not_exactly_the_two_files_is_not_a_skill() {
    let fixture = Fixture::new();
    fixture.install();
    let directory = fixture.root.join("weather-expert");
    fixture.store.set_enabled(ID, true).unwrap();

    let extra = directory.join("run.sh");
    std::fs::write(&extra, "#!/bin/sh").unwrap();
    assert_eq!(fixture.store.find(ID), None, "extra file");
    assert_eq!(fixture.store.enabled_skills_prompt_text(), "");
    std::fs::remove_file(&extra).unwrap();
    assert!(fixture.store.find(ID).is_some());

    let nested = directory.join("assets");
    std::fs::create_dir(&nested).unwrap();
    assert_eq!(fixture.store.find(ID), None, "extra directory");
    std::fs::remove_dir(&nested).unwrap();

    let instruction_file = directory.join("SKILL.md");
    let saved = std::fs::read(&instruction_file).unwrap();
    std::fs::remove_file(&instruction_file).unwrap();
    assert_eq!(fixture.store.find(ID), None, "missing file");
    std::fs::write(directory.join("skill.md"), &saved).unwrap();
    assert_eq!(fixture.store.find(ID), None, "wrong case");
    std::fs::remove_file(directory.join("skill.md")).unwrap();
    std::fs::write(&instruction_file, &saved).unwrap();
    assert!(fixture.store.find(ID).is_some());

    // Hidden bookkeeping files do not count.
    std::fs::write(directory.join(".DS_Store"), "x").unwrap();
    assert!(fixture.store.find(ID).is_some());
}

#[test]
fn files_altered_on_disk_are_validated_again() {
    let fixture = Fixture::new();
    fixture.install();
    let directory = fixture.root.join("weather-expert");
    let manifest_file = directory.join("skill.json");
    let manifest = manifest();

    std::fs::write(&manifest_file, skill_manifest(ID, "Weather Expert", "1.0.0", ",\"executable\":\"payload.sh\"")).unwrap();
    assert_eq!(fixture.store.find(ID), None, "unknown key");
    std::fs::write(&manifest_file, "not json").unwrap();
    assert_eq!(fixture.store.find(ID), None, "bad JSON");
    std::fs::write(&manifest_file, format!("{},\"author\":\"{}\"}}", &manifest[..manifest.len() - 1], "a".repeat(validator::MAX_MANIFEST_BYTES))).unwrap();
    assert_eq!(fixture.store.find(ID), None, "oversized manifest");
    std::fs::write(&manifest_file, &manifest).unwrap();
    assert!(fixture.store.find(ID).is_some());

    std::fs::write(directory.join("SKILL.md"), vec![b'x'; validator::MAX_INSTRUCTION_BYTES + 1]).unwrap();
    assert_eq!(fixture.store.find(ID), None, "oversized instruction");
    assert!(fixture.custom().is_empty());
}

#[test]
fn links_are_never_followed() {
    let fixture = Fixture::new();
    fixture.install();
    let directory = fixture.root.join("weather-expert");
    let outside = fixture.temporary.new_folder("outside");
    std::fs::write(outside.join("skill.json"), skill_manifest("com.example.linked", "Linked", "1.0.0", "")).unwrap();
    std::fs::write(outside.join("SKILL.md"), "From outside the store.").unwrap();

    symlink(&fixture.root.join("linked"), &outside);
    assert_eq!(fixture.custom(), [ID]);

    // A second hard link could expose or alter the file from outside the store.
    hard_link(&fixture.temporary.path("second-name.md"), &directory.join("SKILL.md"));
    assert!(fixture.custom().is_empty(), "hard link");
    std::fs::remove_file(fixture.temporary.path("second-name.md")).unwrap();
    assert_eq!(fixture.custom(), [ID]);

    let instruction_file = directory.join("SKILL.md");
    std::fs::remove_file(&instruction_file).unwrap();
    symlink(&instruction_file, &outside.join("SKILL.md"));
    assert!(fixture.custom().is_empty());

    // A store whose root is a link to another directory lists nothing and installs nothing.
    let linked_root = fixture.temporary.path("LinkedSkills");
    symlink(&linked_root, &outside);
    let linked = SkillStore::new(&linked_root);
    assert_eq!(linked.list(), built_ins());
    assert_code(errors::STORAGE_UNAVAILABLE, linked.install(manifest().as_bytes(), INSTRUCTION.as_bytes(), false));
    assert_eq!(tree(&outside), ["SKILL.md", "skill.json"]);
}

// Archives

#[test]
fn export_import_round_trip_and_duplicate_rejection() {
    let fixture = Fixture::new();
    fixture.install();
    let archive = fixture.store.export_archive(ID).unwrap();
    let entries = read_zip(&archive);
    assert_eq!(entries.iter().map(|(name, _)| name.as_str()).collect::<Vec<_>>(), ["skill.json", "SKILL.md"]);
    assert_eq!(entries[0].1, manifest().as_bytes(), "byte for byte");
    assert_eq!(archive, fixture.store.export_archive(ID).unwrap(), "the same Skill gives the same bytes");

    let other = fixture.temporary.path("Other");
    let destination = SkillStore::new(&other);
    let imported = destination.import_archive(&mut &archive[..]).unwrap();
    assert_eq!(Some(imported), fixture.store.find(ID));
    assert!(!destination.is_enabled(ID));
    assert_code(errors::DUPLICATE, destination.import_archive(&mut &archive[..]));
    assert_eq!(tree(&other), INSTALLED);
    assert_code(errors::NOT_FOUND, fixture.store.export_archive("com.example.missing"));
}

#[test]
fn built_in_skills_export_as_valid_packages() {
    let fixture = Fixture::new();
    for built_in in built_ins() {
        let files = read_zip(&fixture.store.export_archive(&built_in.id).unwrap());
        assert_eq!(files.iter().map(|(name, _)| name.as_str()).collect::<Vec<_>>(), ["skill.json", "SKILL.md"]);
        assert_eq!(validator::load(&files[0].1, &files[1].1).unwrap(), Skill { is_built_in: false, ..built_in.clone() });
    }
}

#[test]
fn imports_from_one_top_level_directory_and_ignores_platform_metadata() {
    let fixture = Fixture::new();
    let manifest = manifest();
    let archive = deflated_zip(&[("Weather/skill.json", manifest.as_bytes()), ("Weather/SKILL.md", INSTRUCTION.as_bytes()), ("Weather/.DS_Store", b"x"), ("__MACOSX/Weather/._skill.json", b"x")]);
    assert_eq!(fixture.import(&archive).unwrap().id, ID);
    assert_eq!(tree(&fixture.root), INSTALLED);
}

#[test]
fn oversized_archive_is_rejected_before_extraction() {
    let fixture = Fixture::new();
    let error = assert_code(errors::TOO_LARGE, fixture.import(&vec![0u8; validator::MAX_PACKAGE_BYTES + 1]));
    assert!(error.message.contains("256 KiB"));
    assert_eq!(tree(&fixture.root), [] as [&str; 0]);
}

#[test]
fn archives_that_are_not_exactly_the_two_files_are_rejected() {
    let fixture = Fixture::new();
    let manifest = manifest();
    let json = || RawEntry::new("skill.json", manifest.as_str());
    let text = || RawEntry::new("SKILL.md", INSTRUCTION);
    let at = |path: &str, content: &str| RawEntry::new(path, content);
    let invalid: Vec<Vec<RawEntry>> = vec![
        vec![json(), text(), at("run.sh", "#!/bin/sh")],
        vec![json(), text(), at("assets/icon.png", "x")],
        vec![json(), text(), at("assets/", "")],
        vec![json()],
        vec![text()],
        vec![json(), at("skill.md", INSTRUCTION)],
        vec![at("Skill.json", &manifest), text()],
        vec![json(), at("docs/SKILL.md", INSTRUCTION)],
        vec![at("a/skill.json", &manifest), at("b/SKILL.md", INSTRUCTION)],
        vec![at("a/skill.json", &manifest), at("a/SKILL.md", INSTRUCTION), at("b/skill.json", &manifest), at("b/SKILL.md", INSTRUCTION)],
        vec![at("a/b/skill.json", &manifest), at("a/b/SKILL.md", INSTRUCTION)],
        vec![at("a/skill.json", &manifest), at("a/SKILL.md", INSTRUCTION), at("a/extra.md", "x")],
        vec![at(".hidden/skill.json", &manifest), at(".hidden/SKILL.md", INSTRUCTION)],
    ];
    for (index, entries) in invalid.iter().enumerate() {
        assert_code(errors::INVALID_PACKAGE, fixture.import(&raw_zip(entries)));
        assert!(fixture.custom().is_empty(), "archive {index}");
        assert_eq!(tree(&fixture.root), [] as [&str; 0], "archive {index}");
    }
}

#[test]
fn hostile_archives_are_rejected_by_the_preflight() {
    let fixture = Fixture::new();
    let manifest = manifest();
    let json = || RawEntry::new("skill.json", manifest.as_str());
    let text = || RawEntry::new("SKILL.md", INSTRUCTION);
    let at = |path: &str, content: &str| RawEntry::new(path, content);
    let mut too_many = vec![json(), text()];
    too_many.extend((0..15).map(|index| at(&format!(".pad{index}"), "x")));
    let complete = raw_zip(&[json(), text()]);
    let hostile: Vec<(&str, Vec<u8>)> = vec![
        ("traversal", raw_zip(&[json(), text(), at("../escape.md", "x")])),
        ("nested traversal", raw_zip(&[at("a/../../skill.json", &manifest), text()])),
        ("absolute", raw_zip(&[json(), at("/SKILL.md", INSTRUCTION)])),
        ("backslash", raw_zip(&[json(), at("..\\SKILL.md", INSTRUCTION)])),
        ("drive", raw_zip(&[json(), at("C:SKILL.md", INSTRUCTION)])),
        ("symlink", raw_zip(&[json(), at("SKILL.md", "/etc/passwd").mode(SYMBOLIC_LINK)])),
        ("duplicate", raw_zip(&[json(), text(), at("SKILL.md", "Second copy.")])),
        ("case collision", raw_zip(&[json(), text(), at("skill.JSON", &manifest)])),
        ("encrypted", raw_zip(&[json(), text().flags(0x0801)])),
        ("unknown compression", raw_zip(&[json(), text().method(12)])),
        ("too deep", raw_zip(&[at("a/b/c/skill.json", &manifest), at("a/b/c/SKILL.md", INSTRUCTION)])),
        ("too many entries", raw_zip(&too_many)),
        ("declared file too large", raw_zip(&[json(), text().declared_size(65 * 1024)])),
        ("not a zip", b"plain text".to_vec()),
        ("empty", Vec::new()),
        ("truncated", complete[..complete.len() - 8].to_vec()),
    ];
    for (name, archive) in &hostile {
        let error = fixture.import(archive).expect_err(name);
        assert_eq!(error.code, errors::INVALID_ARCHIVE, "{name}: {}", error.message);
        assert!(fixture.custom().is_empty(), "{name}");
        assert_eq!(tree(&fixture.root), [] as [&str; 0], "{name}");
    }
    assert!(!fixture.temporary.path("escape.md").exists());
}

#[test]
fn entries_must_match_their_declared_sizes_and_limits() {
    let fixture = Fixture::new();
    let manifest = manifest();
    let json = || RawEntry::new("skill.json", manifest.as_str());
    // Declares fewer bytes than are stored: the content read back fails its CRC.
    fixture.assert_import_refused(errors::INVALID_ARCHIVE, &raw_zip(&[json(), RawEntry::new("SKILL.md", INSTRUCTION).declared_size(4).declared_compressed_size(4)]));
    // A deflated entry whose central directory understates the real size (zip bomb shape).
    let deflated = deflated_zip(&[("skill.json", manifest.as_bytes()), ("SKILL.md", "x".repeat(40_000).as_bytes())]);
    fixture.assert_import_refused(errors::INVALID_ARCHIVE, &forge_declared_size(&deflated, 1, 10));
    // skill.json above 32 KiB is refused although it fits the per-file archive limit.
    let large_manifest = format!("{},\"author\":\"{}\"}}", &manifest[..manifest.len() - 1], "a".repeat(40_000));
    fixture.assert_import_refused(errors::TOO_LARGE, &deflated_zip(&[("skill.json", large_manifest.as_bytes()), ("SKILL.md", INSTRUCTION.as_bytes())]));
}

#[test]
fn archive_content_is_validated_like_any_other_skill() {
    let fixture = Fixture::new();
    let zip = |manifest: &str, text: &str| deflated_zip(&[("skill.json", manifest.as_bytes()), ("SKILL.md", text.as_bytes())]);
    fixture.assert_import_refused(errors::UNKNOWN_FIELD, &zip(&skill_manifest(ID, "Weather Expert", "1.0.0", ",\"executable\":\"payload.sh\""), INSTRUCTION));
    fixture.assert_import_refused(errors::INVALID_MANIFEST, &zip("not json", INSTRUCTION));
    fixture.assert_import_refused(errors::INVALID_SKILL, &zip(&skill_manifest(ID, "Weather Expert", "latest", ""), INSTRUCTION));
    fixture.assert_import_refused(errors::INVALID_SKILL, &zip(&manifest(), "   "));
    fixture.assert_import_refused(errors::DUPLICATE, &zip(&skill_manifest("visual-polish", "Shadow", "1.0.0", ""), INSTRUCTION));
}

// Folders (Linux only)

#[test]
fn imports_a_folder_that_holds_exactly_the_two_files() {
    let fixture = Fixture::new();
    let source = fixture.temporary.new_folder("source");
    std::fs::write(source.join("skill.json"), manifest()).unwrap();
    std::fs::write(source.join("SKILL.md"), INSTRUCTION).unwrap();
    std::fs::write(source.join(".DS_Store"), "x").unwrap();
    let imported = fixture.store.import_directory(&source).unwrap();
    assert_eq!((imported.id.as_str(), imported.instruction.as_str()), (ID, INSTRUCTION));
    assert_eq!(tree(&fixture.root), INSTALLED);
    assert_eq!(tree(&source), [".DS_Store", "SKILL.md", "skill.json"], "the folder is only read");
    assert_code(errors::DUPLICATE, fixture.store.import_directory(&source));
    // The seed the Gallery ships is such a folder.
    let seed = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../Gallery/skills/privacy-review");
    assert_eq!(fixture.store.import_directory(&seed).unwrap().id, "app.scriptwidget.gallery.privacy-review");
}

#[test]
fn folders_with_anything_else_are_refused() {
    let fixture = Fixture::new();
    let outside = fixture.temporary.new_folder("outside");
    std::fs::write(outside.join("SKILL.md"), "From somewhere else.").unwrap();
    let folder = |name: &str, files: &[(&str, &str)]| {
        let source = fixture.temporary.new_folder(name);
        for (path, text) in files {
            write_file(&source.join(path), text.as_bytes());
        }
        source
    };
    let manifest = manifest();
    let invalid = [
        folder("extra", &[("skill.json", &manifest), ("SKILL.md", INSTRUCTION), ("run.sh", "#!/bin/sh")]),
        folder("nested", &[("skill.json", &manifest), ("SKILL.md", INSTRUCTION), ("assets/icon.png", "x")]),
        folder("missing", &[("skill.json", &manifest)]),
        folder("case", &[("skill.json", &manifest), ("skill.md", INSTRUCTION)]),
        folder("empty", &[]),
        fixture.temporary.path("absent"),
        fixture.temporary.new_file("a-file", "x"),
    ];
    for source in &invalid {
        assert_code(errors::INVALID_PACKAGE, fixture.store.import_directory(source));
    }
    // A link in place of a file is not followed, and neither is a link to the folder.
    let linked = folder("linked", &[("skill.json", &manifest)]);
    symlink(&linked.join("SKILL.md"), &outside.join("SKILL.md"));
    assert_code(errors::INVALID_PACKAGE, fixture.store.import_directory(&linked));
    let complete = folder("complete", &[("skill.json", &manifest), ("SKILL.md", INSTRUCTION)]);
    symlink(&fixture.temporary.path("link-to-folder"), &complete);
    assert_code(errors::INVALID_PACKAGE, fixture.store.import_directory(&fixture.temporary.path("link-to-folder")));
    // Content is held to the same rules as an archive.
    assert_code(errors::TOO_LARGE, fixture.store.import_directory(&folder("large", &[("skill.json", &manifest), ("SKILL.md", &"x".repeat(validator::MAX_INSTRUCTION_BYTES + 1))])));
    assert_code(errors::UNKNOWN_FIELD, fixture.store.import_directory(&folder("unknown", &[("skill.json", &skill_manifest(ID, "Weather Expert", "1.0.0", ",\"tools\":[]")), ("SKILL.md", INSTRUCTION)])));
    assert!(fixture.custom().is_empty());
    assert_eq!(tree(&fixture.root), [] as [&str; 0]);
}
