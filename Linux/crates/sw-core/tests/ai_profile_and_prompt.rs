//! Profile validation, prompts and output extraction. Ported from
//! `AiProfileAndPromptTest.kt`, with the facts of Linux where the Android
//! test has those of Android.

use std::collections::BTreeMap;

use serde_json::{Value, json};
use sw_core::ai::*;

fn custom(url: &str) -> AiProfile {
    AiProfile::new(AiProviderKind::OpenAiCompatible, url, "m")
}

fn sources(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
    pairs.iter().map(|(name, text)| (name.to_string(), text.to_string())).collect()
}

#[test]
fn provider_defaults() {
    assert_eq!(AiProviderKind::Anthropic.default_model(), "claude-fable-5-2");
    assert_eq!(AiProviderKind::Anthropic.suggested_models(), ["claude-fable-5-2", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]);
    assert_eq!(AiProviderKind::Anthropic.default_base_url(), "https://api.anthropic.com");
    assert_eq!(AiProviderKind::OpenAi.default_base_url(), "https://api.openai.com");
    assert_eq!(AiProviderKind::OpenAi.default_model(), "gpt-4o-mini");
    assert_eq!((AiSettings::DEFAULT_MAX_ITERATIONS, AiSettings::DEFAULT_TEMPERATURE), (20, 0.7));
    assert_eq!(AiProviderKind::from_id(Some("oauth")), None);
    assert_eq!(AiProviderKind::from_id(None), None);
    assert_eq!(AiProviderKind::from_id(Some("custom")), Some(AiProviderKind::OpenAiCompatible));
    for kind in [AiProviderKind::Anthropic, AiProviderKind::OpenAi] {
        assert!(AiProfile::defaults(kind).is_configured());
        assert_eq!(AiProviderKind::from_id(Some(kind.id())), Some(kind));
    }
    assert!(!AiProfile::defaults(AiProviderKind::OpenAiCompatible).is_configured());
}

#[test]
fn base_url_is_normalized_like_swift() {
    assert_eq!(custom("  https://api.example.com/v1/  ").normalized_base_url(), "https://api.example.com");
    assert_eq!(custom("https://api.example.com/proxy///").normalized_base_url(), "https://api.example.com/proxy");
    assert_eq!(AiProfile::new(AiProviderKind::OpenAi, "   ", "m").normalized_base_url(), "https://api.openai.com");
    assert_eq!(custom("").normalized_base_url(), "");
}

/// As on Android: HTTPS for every host. A plain-HTTP endpoint is refused also on this
/// machine and in a private network, because the request carries the API key.
#[test]
fn only_https_base_urls_are_accepted() {
    for url in ["https://api.example.com", "https://api.example.com:8443/openai/v1", "HTTPS://Example.com/", "https://192.0.2.10/v1", "https://[2001:db8::1]:8443", "https://localhost:11434", "https://ollama.lan/v1", "https://192.168.1.20:8443"] {
        assert_eq!(custom(url).validation_error(), None, "{url}");
    }
    for url in [
        "", "   ", "http://api.example.com", "http://localhost:11434", "http://127.0.0.1:11434", "http://[::1]:11434", "ftp://example.com", "api.example.com", "//example.com", "https://",
        "https:///path", "https://user:pass@example.com", "https://key@example.com", "https://example.com?key=1", "https://example.com/#frag",
        "https://example.com/v1/chat/completions", "https://example.com/v1/messages", "https://exa mple.com", "https://example.com/a/../b",
        "javascript:alert(1)", "file:///etc/passwd", "https://example.com\\@evil.com", "https://example.com\n.evil.com",
        "https:example.com", "https://example.com:0", "https://example.com:99999", "https://example.com:abc", "https://[::1", "https://[not-an-address]", "https://exa_mple.com",
        "https://example.com/a b", "https://example.com/<script>", "https://0x7f.1", "https://例え.jp",
    ] {
        assert!(custom(url).validation_error().is_some(), "{url:?}");
    }
    assert!(custom("http://example.com").validation_error().unwrap().contains("https://"));
    assert!(custom("https://key@example.com").validation_error().unwrap().contains("credentials"));
    assert!(custom(&format!("https://example.com/{}", "a".repeat(AiProfile::MAXIMUM_BASE_URL_LENGTH))).validation_error().is_some());
}

#[test]
fn model_is_required() {
    let with_model = |model: &str| AiProfile::new(AiProviderKind::OpenAiCompatible, "https://example.com", model).validation_error();
    assert!(with_model("").is_some() && with_model("  \t").is_some() && with_model("a\nb").is_some() && with_model(&"x".repeat(201)).is_some());
    assert_eq!(with_model(&"x".repeat(200)), None);
}

#[test]
fn system_prompt_contains_rules_limits_unsupported_list_and_reference() {
    let reference = AiReference::build(&sources(&[("text", "<text>hi</text>")]), &sources(&[("fetch", "await fetch(url)")]));
    let prompt = PromptBuilder::system_prompt(&reference);
    assert!(prompt.starts_with("You are a ScriptWidget code generator."));
    assert!(prompt.contains("1. Call $render(<...>) exactly once. The root element MUST be a\n   layout container (vstack / hstack / zstack)."), "the rules keep their line breaks and indentation");
    assert!(prompt.contains("ScriptWidget for Linux") && !prompt.contains("Android."));
    // Runtime limits.
    for limit in ["RUNTIME LIMITS", "within 5 seconds", "64 MiB", "at most 32 requests per run", "2 MiB", "1024 keys", "512 KiB"] {
        assert!(prompt.contains(limit), "{limit}");
    }
    // The Linux unsupported list: every global that reports unsupported_platform here.
    assert!(prompt.contains("NOT SUPPORTED ON LINUX"));
    for global in LinuxPromptNotes::unsupported_globals() {
        assert!(prompt.contains(&global), "{global}");
    }
    for name in ["$health", "$location", "$calendar", "$maps", "$icloud", "$reminders", "accessoryCircular", "$dynamic_island", "backgroundMaterial", "Control Widgets", "<list>", "material.<role>"] {
        assert!(prompt.contains(name), "{name}");
    }
    // What Linux does implement is described, not forbidden.
    let (_, system_data) = prompt.split_once("SYSTEM DATA ON LINUX").expect("the system data section");
    for name in ["$music.current()", "\"mpris\"", "$photos.items", "$documents.list()", "$services.status(\"github\")", "$notifications", "Never put a token in code"] {
        assert!(system_data.contains(name), "{name}");
    }
    for global in ["$music", "$photos", "$documents", "$services", "$notifications"] {
        assert!(!LinuxPromptNotes::unsupported_globals().iter().any(|unsupported| unsupported == global), "{global}");
    }
    // Network declaration contract and the reference.
    assert!(prompt.contains("\"networkDomains\""));
    assert!(prompt.contains("=== COMPONENTS (JSX tags) ===\n// === text ===\n<text>hi</text>"));
    assert!(prompt.contains("=== APIs (globals) ===\n// === fetch ===\nawait fetch(url)"));
    // The prompt never tells the model to use what Linux lacks.
    assert!(!prompt.contains("requires permission `icloud`"));
}

/// Every global the prompt names as usable must be one Linux implements: outside the
/// "not supported" section no unsupported global is mentioned at all.
#[test]
fn the_prompt_does_not_recommend_what_reports_unsupported_platform() {
    let prompt = PromptBuilder::system_prompt(&AiReference::default());
    let (rules, rest) = prompt.split_once("NOT SUPPORTED ON LINUX").unwrap();
    let (unsupported, _) = rest.split_once("\n\n").unwrap_or((rest, ""));
    assert_eq!(unsupported.lines().filter(|line| line.starts_with("- ")).count(), LinuxPromptNotes::unsupported_lines().len());
    for global in LinuxPromptNotes::unsupported_globals() {
        assert!(sw_core::library::is_unsupported_api(&global[1..]));
        assert!(!rules.contains(&format!("{global}.")) && !rules.contains(&format!("`{global}`")), "the rules mention {global}");
    }
    assert_eq!(sw_core::library::unsupported_api(rules), None, "the rules use {:?}", sw_core::library::unsupported_api(rules));
    // What the rules do recommend is implemented here.
    for global in ["$storage", "$http", "$device", "$getenv", "$file", "$gradient", "$json"] {
        assert!(rules.contains(global) && !LinuxPromptNotes::unsupported_globals().iter().any(|unsupported| unsupported == global), "{global}");
    }
    for example in AiExamplePrompts::all() {
        assert_eq!(sw_core::library::unsupported_api(example.prompt), None, "{}", example.title);
    }
    for prompt in [PromptBuilder::user_prompt_turn(&AiTurnContext::new(Some("CODE"), "x", AiWidgetSize::Medium)), PromptBuilder::user_prompt_first("x", AiWidgetSize::Small), PromptBuilder::user_prompt_fix("C", "e", &[])] {
        assert_eq!(sw_core::library::unsupported_api(&prompt), None);
    }
}

#[test]
fn reference_is_sorted_capped_and_skips_examples_linux_cannot_run() {
    let long: String = (1..=60).map(|number| format!("line {number}")).collect::<Vec<_>>().join("\n");
    let reference = AiReference::build(
        &sources(&[("zstack", "z"), ("hstack", &long), ("live-activity", "LIVE")]),
        &sources(&[("health", "HEALTH"), ("location", "LOCATION"), ("calendar", "CALENDAR"), ("storage", "s"), ("fetch", "f")]),
    );
    assert!(reference.components_block.starts_with("// === hstack ===\nline 1\n"));
    assert!(reference.components_block.contains("line 40\n// ...\n\n// === zstack ===\nz"));
    assert!(!reference.components_block.contains("line 41"));
    assert!(!reference.combined().contains("LIVE"));
    for excluded in ["HEALTH", "LOCATION", "CALENDAR"] {
        assert!(!reference.combined().contains(excluded));
    }
    assert_eq!(reference.apis_block, "// === fetch ===\nf\n\n// === storage ===\ns");
    assert_eq!(AiReference::default().combined(), "");
}

#[test]
fn reference_falls_back_to_priority_apis_when_over_budget() {
    let big = "x".repeat(AiReference::SOFT_CHARACTER_BUDGET);
    let reference = AiReference::build(&sources(&[("text", &big)]), &sources(&[("fetch", "f"), ("usage-map", "MAP"), ("animation", "ANIM")]));
    assert_eq!(reference.apis_block, "// === fetch ===\nf");
}

/// The reference of the repository's own examples: read from the folder a release installs, and free of what Linux lacks.
#[test]
fn the_reference_of_the_bundled_examples_is_read_from_disk() {
    let mut root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    while !root.join("Shared/ScriptWidgetRuntime/Resource/Script.bundle").is_dir() {
        assert!(root.pop(), "repository root not found");
    }
    let reference = AiReference::load(Some(&root.join("Shared/ScriptWidgetRuntime/Resource/Script.bundle")));
    assert!(reference.components_block.contains("// === vstack ===") && reference.apis_block.contains("// === storage ==="));
    for missing in ["// === live-activity ===", "// === health ===", "// === calendar ===", "// === location ==="] {
        assert!(!reference.combined().contains(missing), "{missing}");
    }
    assert_eq!(sw_core::library::unsupported_api(&reference.combined()), None, "an example in the reference uses a global Linux lacks");
    assert_eq!(AiReference::load(None), AiReference::default());
    assert_eq!(AiReference::load(Some(&root.join("no-such-folder"))), AiReference::default());
}

#[test]
fn user_prompts_carry_the_request_size_and_failure() {
    let first = PromptBuilder::user_prompt_first("a clock", AiWidgetSize::Small);
    assert!(first.starts_with("Widget size: small\nSize hint: Square"));
    assert!(first.contains("User description:\na clock"));
    let logs: Vec<String> = (1..=12).map(|number| format!("[log] {number}")).collect();
    let fix = PromptBuilder::user_prompt_fix("CODE", "scriptError: x is not defined", &logs);
    assert!(fix.contains("```jsx\nCODE\n```"));
    assert!(fix.contains("Runtime feedback:\nscriptError: x is not defined"));
    assert!(!fix.contains("[log] 2\n") && fix.contains("[log] 3\n") && fix.contains("[log] 12"));
    assert!(PromptBuilder::user_prompt_fix("CODE", "e", &[]).contains("(no console output)"));
    // A script may print anything: of each console line only the first 300 characters are repeated.
    let long = vec![format!("[log] {}TAIL", "é".repeat(400)), "[log] short".to_owned(), format!("[error] {}", "x".repeat(292))];
    let fix = PromptBuilder::user_prompt_fix("CODE", "e", &long);
    assert!(fix.contains(&format!("Last console output:\n[log] {}…\n[log] short\n[error] {}\n", "é".repeat(294), "x".repeat(292))), "{fix}");
    assert!(!fix.contains("TAIL"));
    assert_eq!(PromptBuilder::MAXIMUM_LOG_LINE_CHARACTERS, 300);
    let refine = PromptBuilder::user_prompt_refine("OLD", "make it blue", Some(r#"{"permissions":["network"],"networkDomains":["a.example.com"]}"#), Some("scriptError: boom"));
    for part in ["```jsx\nOLD\n```", "a.example.com", "scriptError: boom", "Apply this change request from the user:\nmake it blue"] {
        assert!(refine.contains(part), "{part}");
    }
    assert!(!PromptBuilder::user_prompt_refine("OLD", "x", None, None).contains("package declaration is"));
    assert_eq!(AiWidgetSize::from_family(Some("extraLarge")), AiWidgetSize::ExtraLarge);
    assert_eq!(AiWidgetSize::from_family(Some("accessoryInline")), AiWidgetSize::Medium);
    assert_eq!(AiWidgetSize::ALL.map(AiWidgetSize::family), sw_core::library::FAMILIES, "the sizes a conversation offers are the ones Linux places");
}

#[test]
fn skills_are_appended_only_when_present() {
    assert_eq!(PromptBuilder::augment_with_skills("p", None), "p");
    assert_eq!(PromptBuilder::augment_with_skills("p", Some("  \n")), "p");
    assert_eq!(PromptBuilder::augment_with_skills("p", Some("- Layout v1:\n  be tidy\n")), "p\n\nApply these ScriptWidget skills:\n- Layout v1:\n  be tidy");
    assert!(PromptBuilder::augment_with_skills("p", Some(&"s".repeat(200_000))).len() < 70_000);
}

#[test]
fn example_prompts_avoid_unsupported_apis() {
    assert!(AiExamplePrompts::all().len() >= 5);
    for example in AiExamplePrompts::all() {
        for global in LinuxPromptNotes::unsupported_globals() {
            assert!(!example.prompt.contains(&global), "{}", example.title);
        }
    }
    assert!(!AiExamplePrompts::all().iter().any(|example| example.prompt.contains("device location")));
}

// Extraction

#[test]
fn strip_code_fences_matches_swift() {
    assert_eq!(AiOutput::strip_code_fences("  $render(<vstack/>)\n"), "$render(<vstack/>)");
    assert_eq!(AiOutput::strip_code_fences("```jsx\n$render(<vstack/>)\n```"), "$render(<vstack/>)");
    assert_eq!(AiOutput::strip_code_fences("Here you go:\n```javascript\n$render(<vstack/>)\n```\nEnjoy!"), "$render(<vstack/>)");
    assert_eq!(AiOutput::strip_code_fences("```\nfirst\n```\n```\nsecond\n```"), "first");
    // An unterminated fence: markers are dropped, content kept.
    assert_eq!(AiOutput::strip_code_fences("```jsx\n$render(<vstack/>)"), "$render(<vstack/>)");
    assert_eq!(AiOutput::strip_code_fences("   "), "");
}

#[test]
fn extract_separates_code_from_the_declaration() {
    let declaration = r#"{"permissions": ["network"], "networkDomains": ["api.example.com"]}"#;
    let bare = AiOutput::extract(&format!("const a = await fetch(u);\n$render(<vstack/>)\n\n```json\n{declaration}\n```"));
    assert_eq!((bare.source.as_str(), bare.manifest_json.as_deref()), ("const a = await fetch(u);\n$render(<vstack/>)", Some(declaration)));
    let fenced = AiOutput::extract(&format!("```jsx\n$render(<vstack/>)\n```\n\n```json\n{declaration}\n```\n"));
    assert_eq!((fenced.source.as_str(), fenced.manifest_json.as_deref()), ("$render(<vstack/>)", Some(declaration)));
    let tagged = AiOutput::extract(&format!("```jsx\ncode\n```\n```widget.json\n{declaration}\n```"));
    assert_eq!(tagged.manifest_json.as_deref(), Some(declaration));
    let untagged = AiOutput::extract(&format!("```jsx\ncode\n```\n```\n{declaration}\n```"));
    assert_eq!((untagged.source.as_str(), untagged.manifest_json.as_deref()), ("code", Some(declaration)));
    let none = AiOutput::extract("```jsx\n$render(<vstack/>)\n```");
    assert_eq!((none.source.as_str(), none.manifest_json), ("$render(<vstack/>)", None));
    // Text that is not ASCII around the fences is cut at the right places.
    let wide = AiOutput::extract(&format!("说明：\n```jsx\n$render(<text>你好</text>)\n```\n然后：\n```json\n{declaration}\n```\n完"));
    assert_eq!((wide.source.as_str(), wide.manifest_json.as_deref()), ("$render(<text>你好</text>)", Some(declaration)));
}

#[test]
fn extract_does_not_mistake_code_for_a_declaration() {
    // A jsx block is never a declaration, and neither is a fenced block that is not a JSON object.
    let object_literal = AiOutput::extract("```jsx\n{\"a\": 1}\n```");
    assert_eq!((object_literal.source.as_str(), object_literal.manifest_json), ("{\"a\": 1}", None));
    let not_json = AiOutput::extract("```jsx\ncode\n```\n```json\nnot json\n```");
    assert_eq!((not_json.source.as_str(), not_json.manifest_json), ("code", None));
    assert_eq!(AiOutput::extract("").source, "");
    assert_eq!(AiOutput::extract("```").source, "");
    assert_eq!(AiOutput::extract("````\n```").source, "");
}

#[test]
fn candidate_round_trips_through_the_assistant_message() {
    let candidate = AiCandidate::new("code", Some(r#"{"permissions":["network"],"networkDomains":["a.example.com"]}"#.into()));
    assert_eq!(AiOutput::extract(&candidate.as_assistant_message()), candidate);
    assert_eq!(AiCandidate::new("code", None).as_assistant_message(), "code");
}

/// `aRuntimeDiagnosticCarriesTheErrorAndTheEndsOfTheLastConsoleLines` of `AiProfileAndPromptTest.kt`.
#[test]
fn a_runtime_diagnostic_carries_the_error_and_the_ends_of_the_last_console_lines() {
    assert_eq!(PromptBuilder::runtime_diagnostic("scriptError: boom", &[]), "scriptError: boom");
    let long = format!("[log] {}", "z".repeat(400));
    let mut logs: Vec<String> = (1..=11).map(|number| format!("[log] line {number}")).collect();
    logs.push(long.clone());
    let text = PromptBuilder::runtime_diagnostic("scriptError: boom", &logs);
    assert!(text.starts_with("scriptError: boom\nLast console output:\n[log] line 3\n"), "{text}");
    assert!(!text.contains("[log] line 2\n"));
    assert!(text.ends_with(&format!("{}…", &long[..300])));
    assert_eq!(text.lines().count(), 2 + PromptBuilder::MAXIMUM_LOG_LINES);
    // It reaches the model inside the turn, cut to 2,000 characters.
    let mut context = AiTurnContext::new(Some("CODE"), "fix it", AiWidgetSize::Small);
    context.runtime_diagnostic = Some(PromptBuilder::runtime_diagnostic(&"e".repeat(3_000), &["[log] tail".to_owned()]));
    let turn = PromptBuilder::user_prompt_turn(&context);
    assert!(turn.contains(&format!("The latest local ScriptWidget runtime diagnostic is:\n{}…", "e".repeat(2_000))));
    assert!(!turn.contains("[log] tail"));
}

#[test]
fn declaration_accepts_only_network_and_public_hosts() {
    let parsed = AiManifestDeclaration::parse(r#"{"permissions":["network","network"],"networkDomains":["API.Example.com","*.example.org"]}"#).unwrap();
    assert_eq!(parsed.permissions, ["network"]);
    assert_eq!(parsed.network_domains, ["api.example.com", "*.example.org"]);
    assert_eq!(parsed.to_json(), r#"{"permissions":["network"],"networkDomains":["api.example.com","*.example.org"]}"#);
    let empty = AiManifestDeclaration::parse("{}").unwrap();
    assert!(empty.permissions.is_empty() && empty.network_domains.is_empty());
    // As many hosts and bytes as the Apple apps read (`AINetworkDeclaration`), and what they say beyond that.
    assert_eq!((AiManifestDeclaration::MAXIMUM_DOMAINS, AiManifestDeclaration::MAXIMUM_BYTES), (8, 4_096));
    let hosts = |count: usize| (1..=count).map(|number| format!("\"h{number}.example.com\"")).collect::<Vec<String>>();
    let declaring = |hosts: &[String]| format!(r#"{{"permissions":["network"],"networkDomains":[{}]}}"#, hosts.join(","));
    assert_eq!(AiManifestDeclaration::parse(&declaring(&hosts(8))).unwrap().network_domains.len(), 8);
    assert_eq!(AiManifestDeclaration::parse(&declaring(&hosts(9))).unwrap_err(), "\"networkDomains\" must list 1 to 8 hosts");
    let padded = |bytes: usize| format!("{{\"permissions\":[],\"networkDomains\":[]{}}}", " ".repeat(bytes - 38));
    assert_eq!(padded(4_096).len(), 4_096);
    assert!(AiManifestDeclaration::parse(&padded(4_096)).is_ok());
    assert_eq!(AiManifestDeclaration::parse(&padded(4_097)).unwrap_err(), "it is not a JSON object");
    let many = hosts(9);
    let rejected = [
        "[]".to_owned(),
        "not json".to_owned(),
        r#"{"permissions":["location"]}"#.to_owned(),
        r#"{"permissions":["network","health"],"networkDomains":["a.example.com"]}"#.to_owned(),
        r#"{"permissions":"network","networkDomains":["a.example.com"]}"#.to_owned(),
        r#"{"permissions":[1],"networkDomains":["a.example.com"]}"#.to_owned(),
        r#"{"permissions":["network"]}"#.to_owned(),
        r#"{"permissions":["network"],"networkDomains":[]}"#.to_owned(),
        r#"{"networkDomains":["a.example.com"]}"#.to_owned(),
        r#"{"permissions":["network"],"networkDomains":["https://a.example.com"]}"#.to_owned(),
        r#"{"permissions":["network"],"networkDomains":["a.example.com/path"]}"#.to_owned(),
        r#"{"permissions":["network"],"networkDomains":["localhost"]}"#.to_owned(),
        r#"{"permissions":["network"],"networkDomains":["127.0.0.1"]}"#.to_owned(),
        r#"{"permissions":["network"],"networkDomains":["192.168.1.1"]}"#.to_owned(),
        r#"{"permissions":["network"],"networkDomains":["printer.local"]}"#.to_owned(),
        r#"{"permissions":["network"],"networkDomains":["*"]}"#.to_owned(),
        r#"{"permissions":["network"],"networkDomains":["*."]}"#.to_owned(),
        r#"{"permissions":["network"],"networkDomains":["a.example.com"],"id":"evil"}"#.to_owned(),
        r#"{"permissions":["network"],"networkDomains":["a.example.com"],"entry":"x.jsx"}"#.to_owned(),
        format!(r#"{{"permissions":["network"],"networkDomains":[{}]}}"#, many.join(",")),
        // Read strictly: a key twice, a comment, or anything after the object is not a declaration.
        r#"{"permissions":["network"],"permissions":[],"networkDomains":["a.example.com"]}"#.to_owned(),
        r#"{"permissions":["network"],"networkDomains":["a.example.com"]} trailing"#.to_owned(),
        r#"{"permissions":["network"],"networkDomains":["-a.example.com"]}"#.to_owned(),
        r#"{"permissions":["network"],"networkDomains":["a..example.com"]}"#.to_owned(),
        r#"{"permissions":["network"],"networkDomains":["example.123"]}"#.to_owned(),
        format!(r#"{{"permissions":["network"],"networkDomains":["{}.example.com"]}}"#, "a".repeat(64)),
        format!("{{\"permissions\":[],\"networkDomains\":[]{}}}", " ".repeat(AiManifestDeclaration::MAXIMUM_BYTES)),
    ];
    for json in &rejected {
        assert!(AiManifestDeclaration::parse(json).is_err_and(|message| !message.is_empty()), "accepted {json}");
    }
    // The whole sentence the model reads is the one of `AgentLoop.swift` and `AiOutput.kt`.
    let refusal = |json: &str| AiManifestDeclaration::failure_text(&AiManifestDeclaration::parse(json).unwrap_err());
    let prefix = "The network declaration block is not valid: ";
    assert_eq!(refusal(&declaring(&hosts(9))), format!("{prefix}\"networkDomains\" must list 1 to 8 hosts."));
    assert_eq!(refusal(r#"{"permissions":["network"],"networkDomains":[]}"#), format!("{prefix}\"networkDomains\" must list 1 to 8 hosts."));
    assert_eq!(refusal(r#"{"permissions":["network"]}"#), format!("{prefix}\"networkDomains\" must list 1 to 8 hosts."));
    assert_eq!(refusal("not json"), format!("{prefix}it is not a JSON object."));
    assert_eq!(refusal("[]"), format!("{prefix}it is not a JSON object."));
    assert_eq!(refusal(&padded(4_097)), format!("{prefix}it is not a JSON object."));
    assert_eq!(refusal(r#"{"permissions":["network"],"networkDomains":["a.example.com"],"id":"evil"}"#), format!("{prefix}only \"permissions\" and \"networkDomains\" may appear."));
    let only_network = format!("{prefix}\"permissions\" must be exactly [\"network\"]; no other permission can be declared.");
    assert_eq!(refusal(r#"{"permissions":["location"]}"#), only_network);
    assert_eq!(refusal(r#"{"permissions":["network","health"],"networkDomains":["localhost"]}"#), only_network);
    assert_eq!(refusal(r#"{"networkDomains":["a.example.com"]}"#), only_network);
    assert_eq!(refusal(r#"{"permissions":"network"}"#), format!("{prefix}\"permissions\" must be an array of strings."));
    assert_eq!(refusal(r#"{"permissions":["network"],"networkDomains":[1]}"#), format!("{prefix}\"networkDomains\" must be an array of strings."));
    assert_eq!(refusal(r#"{"permissions":["network"],"networkDomains":["LOCALHOST"]}"#), format!("{prefix}\"localhost\" is not a public host name; use a host such as api.example.com, without scheme or path."));
}

#[test]
fn declaration_only_changes_network_fields_of_a_manifest() {
    let base = json!({"formatVersion":2,"id":"local.x","name":"N","entry":"main.jsx","permissions":["network","storage"],"networkDomains":["old.example.com"]});
    let base = base.as_object().unwrap();
    let applied = AiManifestDeclaration::parse(r#"{"permissions":["network"],"networkDomains":["new.example.com"]}"#).unwrap().apply_to(base);
    assert_eq!((&applied["id"], &applied["entry"]), (&json!("local.x"), &json!("main.jsx")));
    assert_eq!(applied["permissions"], json!(["storage", "network"]));
    assert_eq!(applied["networkDomains"], json!(["new.example.com"]));
    // Removing network keeps other permissions and leaves the base untouched.
    let removed = AiManifestDeclaration::parse("{}").unwrap().apply_to(base);
    assert_eq!((&removed["permissions"], &removed["networkDomains"]), (&json!(["storage"]), &json!([])));
    assert_eq!(base["networkDomains"], json!(["old.example.com"]));
    assert_eq!(AiManifestDeclaration::from_manifest(None), None);
    assert_eq!(AiManifestDeclaration::from_manifest(json!({"permissions":["storage"]}).as_object()), None);
    assert_eq!(AiManifestDeclaration::from_manifest(Some(base)).unwrap().network_domains, ["old.example.com"]);
}

#[test]
fn candidate_manifest_grants_nothing_by_default() {
    let read = |text: String| serde_json::from_str::<Value>(&text).unwrap();
    let fresh = read(AiManifests::text(None, None, "My Widget"));
    assert_eq!((&fresh["name"], &fresh["formatVersion"]), (&json!("My Widget"), &json!(2)));
    assert_eq!(AiManifests::entry(fresh.as_object()), "main.jsx");
    assert_eq!((&fresh["permissions"], &fresh["networkDomains"]), (&json!([]), &json!([])));
    let network = read(AiManifests::text(None, Some(r#"{"permissions":["network"],"networkDomains":["a.example.com"]}"#), "W"));
    assert_eq!((&network["permissions"], &network["networkDomains"]), (&json!(["network"]), &json!(["a.example.com"])));
    // An invalid declaration never widens a manifest.
    let invalid = read(AiManifests::text(None, Some(r#"{"permissions":["network","health"],"networkDomains":["a.example.com"]}"#), "W"));
    assert_eq!((&invalid["permissions"], &invalid["networkDomains"]), (&json!([]), &json!([])));
    // Improving keeps the installed manifest, including its entry and identity.
    let base = json!({"formatVersion":2,"id":"local.keep","name":"Old","entry":"src/app.jsx","permissions":[],"networkDomains":[]});
    let kept = read(AiManifests::text(base.as_object(), None, "ignored"));
    assert_eq!(kept["id"], "local.keep");
    assert_eq!(AiManifests::entry(kept.as_object()), "src/app.jsx");
    assert_eq!(AiManifests::entry(None), "main.jsx");
    assert_eq!(AiManifests::entry(json!({"entry":5}).as_object()), "main.jsx");
    assert_eq!(AiManifests::parse(Some("[]")), None);
}

#[test]
fn execution_results_are_judged_like_swift() {
    let tree = r#"{"$element":"vstack","props":{},"children":[{"$element":"text","children":["hi"]}]}"#;
    let logs = |lines: &[&str]| lines.iter().map(|line| line.to_string()).collect::<Vec<_>>();
    assert!(ValidationResult::from_execution(Some(tree), None, None, logs(&["[log] ok"])).ok);
    let error = ValidationResult::from_execution(None, Some("scriptError"), Some("x is not defined"), logs(&["[log] a"]));
    assert!(!error.ok);
    assert_eq!(error.error_summary.as_deref(), Some("scriptError: x is not defined"));
    assert_eq!(error.logs, ["[log] a"]);
    assert_eq!(ValidationResult::from_execution(None, None, None, Vec::new()).error_summary.as_deref(), Some("Runtime returned no element."));
    assert_eq!(ValidationResult::from_execution(Some("not json"), None, None, Vec::new()).error_summary.as_deref(), Some("Runtime returned no element."));
    assert_eq!(ValidationResult::from_execution(Some("[]"), None, None, Vec::new()).error_summary.as_deref(), Some("Runtime returned no element."));
    let sentinel = r##"{"$element":"text","children":["#UI Not Found#"]}"##;
    assert!(ValidationResult::from_execution(Some(sentinel), None, None, Vec::new()).error_summary.unwrap().contains("fallback/placeholder"));
    assert!(!ValidationResult::from_execution(Some(tree), None, None, logs(&["[error] fetch failed"])).ok);
    assert!(!ValidationResult::from_execution(Some(tree), None, None, logs(&["[log] Uncaught TypeError"])).ok);
    // A tree nested deeper than serde_json reads by default is still a widget, and its logs still count.
    let deep = format!("{}{}", r##"{"$element":"vstack","props":null,"children":["##.to_string().repeat(200), "]}".repeat(200));
    assert!(serde_json::from_str::<Value>(&deep).is_err());
    assert!(ValidationResult::from_execution(Some(&deep), None, None, Vec::new()).ok);
    assert!(!ValidationResult::from_execution(Some(&deep), None, None, logs(&["[error] x"])).ok);
}
