//! A version of a conversation as a package: the trial run in the real engine,
//! and what saving and applying write. The Linux counterpart of what
//! `AiCandidates` does in the Android app, with the Linux executor.
//! These tests need the files of `node Linux/scripts/build-shared-js.mjs`.

mod ai_common;
mod api_common;

use std::sync::Arc;

use ai_common::*;
use api_common::{scripts, temporary_directory};
use serde_json::Value;
use sw_core::ai::candidates::{AiCandidates, Draw, PREVIEW_PACKAGE_ID};
use sw_core::ai::*;
use sw_core::{DataPaths, InstalledPackage, Library, PackageFiles, WidgetRuntime};

const GOOD: &str = "$render(<vstack frame=\"max\"><text>Hello</text></vstack>);\n";
const HOSTS: &str = r#"{"permissions":["network"],"networkDomains":["api.example.com"]}"#;

struct Fixture {
    runtime: WidgetRuntime,
    library: Library,
}

fn fixture(name: &str) -> Fixture {
    let paths = DataPaths::new(Some(&temporary_directory(name))).unwrap();
    Fixture { runtime: WidgetRuntime::new(scripts(), &paths).expect("the runtime files: run node Linux/scripts/build-shared-js.mjs"), library: Library::new(&paths, None) }
}

impl Fixture {
    fn validate(&self, installed: Option<&InstalledPackage>, source: &str, declaration: Option<&str>, baseline: Option<&str>, draw: Option<Draw<'_>>) -> ValidationResult {
        AiCandidates::validate(&self.runtime, installed, source, declaration, "medium", false, baseline, draw)
    }
}

fn version(source: &str, domains: &[&str]) -> AiConversationVersion {
    let mut conversation = AiConversation::new(1);
    conversation.add_version(source, domains.iter().map(|domain| domain.to_string()).collect(), 1).clone()
}

fn manifest(package: &InstalledPackage) -> Value {
    serde_json::from_str(&std::fs::read_to_string(package.directory.join("widget.json")).unwrap()).unwrap()
}

#[test]
fn a_candidate_is_compiled_and_run_in_the_engine() {
    let fixture = fixture("ai-candidates-run");
    let good = fixture.validate(None, GOOD, None, None, None);
    assert!(good.ok, "{good:?}");
    let logged = fixture.validate(None, "console.log('started');\n$render(<vstack><text>a</text></vstack>);", None, None, None);
    assert!(logged.ok && logged.logs.iter().any(|line| line == "[log] started"), "{logged:?}");

    let broken = fixture.validate(None, "$render(<vstack><text>a</text></vstac>);", None, None, None);
    assert!(!broken.ok);
    assert!(broken.error_summary.as_deref().unwrap().starts_with("scriptException: SyntaxError"), "{broken:?}");
    let thrown = fixture.validate(None, "missing.call();\n$render(<vstack/>);", None, None, None);
    assert!(thrown.error_summary.as_deref().unwrap().starts_with("scriptException: "), "{thrown:?}");
    let nothing = fixture.validate(None, "const a = 1;", None, None, None);
    assert!(!nothing.ok, "a script that renders nothing is not a widget: {nothing:?}");
    let large = fixture.validate(None, &format!("// {}\n{GOOD}", "x".repeat(600 * 1024)), None, None, None);
    assert_eq!(large.error_summary.as_deref(), Some("resourceLimit: main.jsx exceeds 512 KiB."));
}

/// A new widget has a manifest, so a host that is not declared is refused by the same rule as for every package.
#[test]
fn a_candidate_reaches_only_the_hosts_it_declares() {
    let fixture = fixture("ai-candidates-network");
    let source = "const text = await fetch('https://api.example.com/data');\n$render(<vstack><text>{text}</text></vstack>);";
    let undeclared = fixture.validate(None, source, None, None, None);
    assert!(undeclared.error_summary.as_deref().unwrap().contains("Network host is not declared in widget.json"), "{undeclared:?}");
    // Declared for another host: still refused.
    let other = fixture.validate(None, source, Some(r#"{"permissions":["network"],"networkDomains":["other.example.com"]}"#), None, None);
    assert!(other.error_summary.as_deref().unwrap().contains("Network host is not declared"), "{other:?}");
    // A declaration the model cannot make grants nothing.
    let invalid = fixture.validate(None, source, Some(r#"{"permissions":["network","health"],"networkDomains":["api.example.com"]}"#), None, None);
    assert!(invalid.error_summary.as_deref().unwrap().contains("Network host is not declared"), "{invalid:?}");
    // A host on this machine cannot even be declared, so it is never reached.
    let local = fixture.validate(None, "await fetch('http://127.0.0.1:9/');\n$render(<vstack/>);", Some(r#"{"permissions":["network"],"networkDomains":["127.0.0.1"]}"#), None, None);
    assert!(!local.ok, "{local:?}");
}

#[test]
fn what_linux_does_not_have_is_sent_back_unless_the_widget_used_it_before() {
    let fixture = fixture("ai-candidates-unsupported");
    let steps = "let steps = 0;\ntry { steps = await $health.steps(); } catch (error) {}\n$render(<vstack><text>{String(steps)}</text></vstack>);";
    let new = fixture.validate(None, steps, None, None, None);
    assert_eq!(new.error_summary.as_deref(), Some("The widget uses features that are not supported on Linux: $health is not implemented here and every call to it fails."));
    assert!(fixture.validate(None, steps, None, Some("// old\nawait $health.steps();"), None).ok, "what the widget already used is not held against the turn");
    assert!(!fixture.validate(None, steps, None, Some("const $healthy = 1;"), None).ok, "another name that starts the same is not a use");
    // Not caught, the call fails with words that do not say why; the reason is added.
    let uncaught = fixture.validate(None, "const steps = await $health.steps();\n$render(<vstack><text>{String(steps)}</text></vstack>);", None, None, None);
    let summary = uncaught.error_summary.unwrap();
    assert!(summary.starts_with("scriptException: ") && summary.ends_with("$health is not implemented here and every call to it fails."), "{summary}");
    assert!(fixture.validate(None, "const text = $storage.getString('a');\n$render(<vstack><text>{text}</text></vstack>);", None, None, None).ok);
}

#[test]
fn a_candidate_that_cannot_be_drawn_is_not_a_success() {
    let fixture = fixture("ai-candidates-draw");
    let drawn = std::cell::Cell::new(0);
    let fine: Draw<'_> = &|request, result| {
        drawn.set(drawn.get() + 1);
        assert_eq!((request.package_id.as_str(), request.family.as_str()), (PREVIEW_PACKAGE_ID, "medium"));
        assert!(result.execution.tree.is_some());
        Ok(())
    };
    assert!(fixture.validate(None, GOOD, None, None, Some(fine)).ok);
    let failing: Draw<'_> = &|_, _| Err("the painter said no".into());
    let failed = fixture.validate(None, GOOD, None, None, Some(failing));
    assert_eq!(failed.error_summary.as_deref(), Some("internalError: the widget ran but could not be drawn: the painter said no"));
    // A script that failed is not drawn at all.
    fixture.validate(None, "missing.call();", None, None, Some(fine));
    assert_eq!(drawn.get(), 1);
}

#[test]
fn a_version_is_saved_as_a_new_widget_with_exactly_what_it_declares() {
    let fixture = fixture("ai-candidates-save");
    let offline = AiCandidates::save_new(&fixture.library, "Clock", &version(GOOD, &[])).unwrap();
    assert_eq!(offline.name, "Clock");
    assert_eq!(std::fs::read_to_string(offline.directory.join("main.jsx")).unwrap(), GOOD);
    let written = manifest(&offline);
    assert_eq!((&written["name"], &written["formatVersion"], &written["entry"]), (&"Clock".into(), &2.into(), &"main.jsx".into()));
    assert_eq!((&written["permissions"], &written["networkDomains"]), (&serde_json::json!([]), &serde_json::json!([])));
    let online = AiCandidates::save_new(&fixture.library, "Clock", &version(GOOD, &["api.example.com"])).unwrap();
    assert_eq!(online.name, "Clock (1)", "a taken name gets a numbered suffix");
    assert_eq!((&manifest(&online)["permissions"], &manifest(&online)["networkDomains"]), (&serde_json::json!(["network"]), &serde_json::json!(["api.example.com"])));
    assert!(AiCandidates::save_new(&fixture.library, "../escape", &version(GOOD, &[])).is_err());
    assert!(fixture.runtime.validate_package(&online.files()).is_ok(), "what was saved is a package the runtime accepts");
}

#[test]
fn applying_changes_the_entry_and_adds_hosts_without_taking_anything_away() {
    let fixture = fixture("ai-candidates-apply");
    let created = fixture.library.create("Board", "$render(<vstack><text>old</text></vstack>);", Some(&api_common::widget_manifest(r#"["network","storage"]"#, r#"["old.example.com"]"#))).unwrap();
    fixture.library.write_file("Board", "lib/helper.js", b"function helper() { return 1; }").unwrap();
    assert_eq!(AiCandidates::allowed_hosts(Some(&created)), ["old.example.com"]);
    assert_eq!(AiCandidates::new_hosts(Some(&created), &["old.example.com".into(), "new.example.com".into()]), ["new.example.com"]);
    assert_eq!(AiCandidates::declaration(Some(&created), &["new.example.com".into()]).as_deref(), Some(r#"{"permissions":["network"],"networkDomains":["old.example.com","new.example.com"]}"#));
    assert_eq!(AiCandidates::declaration(None, &[]), None);

    // In memory first: the other files of the widget are still there for the trial run.
    let files = AiCandidates::files(Some(&created), "$import('lib/helper.js');\n$render(<vstack><text>{String(helper())}</text></vstack>);", &[], "ignored");
    assert_eq!(files.paths(), ["lib/helper.js", "main.jsx", "widget.json"]);
    let imported = fixture.validate(Some(&created), "$import('lib/helper.js');\n$render(<vstack><text>{String(helper())}</text></vstack>);", None, None, None);
    assert!(imported.ok, "{imported:?}");
    assert_eq!(std::fs::read_to_string(created.directory.join("main.jsx")).unwrap(), "$render(<vstack><text>old</text></vstack>);", "a trial run writes nothing");

    // No new host: only the entry changes, the manifest file is not rewritten.
    let before = std::fs::read(created.directory.join("widget.json")).unwrap();
    let applied = AiCandidates::apply(&fixture.library, &created, &version(GOOD, &["old.example.com"])).unwrap();
    assert_eq!(std::fs::read_to_string(applied.directory.join("main.jsx")).unwrap(), GOOD);
    assert_eq!(std::fs::read(applied.directory.join("widget.json")).unwrap(), before);
    assert_eq!(applied.installation, created.installation, "it is still the same widget");

    // A new host is added; what the widget had, a model cannot take away.
    let applied = AiCandidates::apply(&fixture.library, &applied, &version(GOOD, &["new.example.com"])).unwrap();
    let written = manifest(&applied);
    assert_eq!(written["networkDomains"], serde_json::json!(["old.example.com", "new.example.com"]));
    assert_eq!(written["permissions"], serde_json::json!(["storage", "network"]));
    assert_eq!((&written["id"], &written["name"]), (&"com.example.test".into(), &"Test".into()), "the identity of the widget is its own");
    assert!(applied.directory.join("lib/helper.js").is_file());
    // A version that stays offline leaves the hosts as they are.
    let applied = AiCandidates::apply(&fixture.library, &applied, &version(GOOD, &[])).unwrap();
    assert_eq!(manifest(&applied)["networkDomains"], serde_json::json!(["old.example.com", "new.example.com"]));
}

#[test]
fn a_widget_without_a_manifest_keeps_none_and_an_unreadable_one_is_not_replaced() {
    let fixture = fixture("ai-candidates-legacy");
    let created = fixture.library.create("Legacy", "$render(<vstack/>);", None).unwrap();
    std::fs::remove_file(created.directory.join("widget.json")).unwrap();
    let legacy = fixture.library.find("Legacy").unwrap();
    assert!(!legacy.manifest_present);
    assert_eq!(AiCandidates::manifest_text(Some(&legacy), &["api.example.com".into()], "x"), None);
    let applied = AiCandidates::apply(&fixture.library, &legacy, &version(GOOD, &["api.example.com"])).unwrap();
    assert!(!applied.directory.join("widget.json").exists(), "a conversation does not turn a legacy package into another kind");
    assert_eq!(std::fs::read_to_string(applied.directory.join("main.jsx")).unwrap(), GOOD);

    let odd = fixture.library.create("Odd", "$render(<vstack><text>mine</text></vstack>);", None).unwrap();
    std::fs::write(odd.directory.join("widget.json"), "{ not json").unwrap();
    let odd = fixture.library.find("Odd").unwrap();
    let error = AiCandidates::apply(&fixture.library, &odd, &version(GOOD, &[])).unwrap_err();
    assert_eq!(error.code, sw_core::packages::codes::INVALID_MANIFEST);
    assert_eq!(std::fs::read_to_string(odd.directory.join("main.jsx")).unwrap(), "$render(<vstack><text>mine</text></vstack>);", "nothing was changed");
    assert_eq!(std::fs::read_to_string(odd.directory.join("widget.json")).unwrap(), "{ not json");
}

/// A whole turn with a scripted model and the real engine: the first answer does not compile, the
/// repair runs, and what the turn leaves is a version that is then saved as a widget.
#[test]
fn a_turn_is_repaired_by_what_the_engine_says() {
    let fixture = fixture("ai-candidates-turn");
    let chat = FakeChat::new(vec![
        reply("Shows a greeting.", "$render(<vstack><text>Hello</text></vstac>);", None).into(),
        reply("Shows a greeting.", "$render(<vstack><text weight=\"bold\">Hello</text></vstack>);", Some(HOSTS)).into(),
    ]);
    let mut conversation = AiConversation::new(now_milliseconds());
    let turn = turn(&mut conversation, "say hello", &chat, |source, declaration| fixture.validate(None, source, declaration, None, None));
    assert_eq!((turn.status, turn.repairs, turn.note.as_deref()), (Status::Succeeded, 1, Some("Shows a greeting.")));
    let repair = chat.last_of(1);
    assert!(repair.contains("Runtime feedback:\nscriptException: SyntaxError") && repair.contains("closing tag for <vstack>"), "{repair}");
    let made = conversation.current_version().unwrap();
    assert_eq!(made.network_domains, ["api.example.com"]);
    let saved = AiCandidates::save_new(&fixture.library, "Hello", made).unwrap();
    conversation.package_id = Some(saved.installation.clone());
    let files: Arc<dyn PackageFiles> = Arc::new(saved.files());
    assert!(fixture.runtime.run(&sw_core::RunRequest::new(files, saved.installation.clone())).execution.error.is_none());
    assert_eq!(manifest(&saved)["networkDomains"], serde_json::json!(["api.example.com"]));
}

#[test]
fn a_new_widget_is_named_after_its_conversation_when_that_can_be_a_name() {
    for (title, expected) in [("A clock for my desk", "A clock for my desk"), ("show https://api.example.com/v1 prices", "show https   api.example.com v1 prices"), (".hidden", "hidden"), ("", "AI Widget"), ("///", "AI Widget"), ("a title that was cut…", "a title that was cut"), ("__Build", "AI Widget")] {
        let name = AiCandidates::suggested_name(title);
        assert_eq!(name, expected);
        assert!(sw_core::packages::names::is_valid(&name), "{name}");
    }
}
