//! `$services`: the GitHub token, the connection record, the per-widget
//! grant and the fixed profile read. GitHub is a stand-in that answers in
//! this process, and the keyring is one in memory: no test sends a token
//! anywhere, and the tokens here are made up.

mod api_common;

use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};

use api_common::*;
use serde_json::{Value, json};
use sw_core::NativeModule;
use sw_core::ai::credentials::{ApiKey, CredentialStore, MemoryCredentialStore};
use sw_core::api::services::{FetchServiceTransport, KEYRING_ACCOUNT, ServiceConnections, ServiceError, ServiceHttpResponse, ServiceTransport, ServicesModule, github_profile, valid_token};
use sw_core::api::support::CallContext;

const OWNER: &str = "11111111-1111-4111-8111-111111111111";
const OTHER: &str = "22222222-2222-4222-8222-222222222222";
/// Not a token of anyone: the prefix GitHub uses and forty letters.
const TOKEN: &str = "github_pat_FAKEFAKEFAKEFAKEFAKE_notARealToken00000001";
const SECOND_TOKEN: &str = "github_pat_FAKEFAKEFAKEFAKEFAKE_notARealToken00000002";

fn profile_body(id: u64, login: &str) -> String {
    json!({
        "login": login, "id": id, "name": "Mona Lisa", "email": "mona@example.com", "location": "Paris", "company": "GitHub",
        "public_repos": 12, "total_private_repos": 3, "followers": 40, "following": 5, "two_factor_authentication": true, "plan": {"name": "pro"},
    })
    .to_string()
}

/// An address and the headers sent to it.
type Asked = (String, Vec<(String, String)>);

struct FakeGitHub {
    response: Mutex<Result<ServiceHttpResponse, ()>>,
    requests: Mutex<Vec<Asked>>,
}

impl FakeGitHub {
    fn new() -> Arc<Self> {
        Arc::new(Self { response: Mutex::new(Ok(ok(&profile_body(583_231, "octocat")))), requests: Mutex::default() })
    }

    fn answer(&self, response: Result<ServiceHttpResponse, ()>) {
        *self.response.lock().unwrap() = response;
    }

    fn count(&self) -> usize {
        self.requests.lock().unwrap().len()
    }
}

impl ServiceTransport for FakeGitHub {
    fn get(&self, url: &str, headers: &[(String, String)]) -> Result<ServiceHttpResponse, ()> {
        self.requests.lock().unwrap().push((url.to_owned(), headers.to_vec()));
        self.response.lock().unwrap().clone()
    }
}

fn ok(body: &str) -> ServiceHttpResponse {
    response(200, body)
}

fn response(status: u16, body: &str) -> ServiceHttpResponse {
    ServiceHttpResponse { status, content_type: Some("application/json; charset=utf-8".into()), rate_limited: false, body: body.as_bytes().to_vec() }
}

struct Fixture {
    directory: PathBuf,
    keyring: Arc<MemoryCredentialStore>,
    github: Arc<FakeGitHub>,
    connections: Arc<ServiceConnections>,
    module: ServicesModule,
}

impl Fixture {
    fn new() -> Self {
        Self::with_keyring(Arc::new(MemoryCredentialStore::new()))
    }

    fn with_keyring(keyring: Arc<MemoryCredentialStore>) -> Self {
        let directory = temporary_directory("services");
        let github = FakeGitHub::new();
        let connections = Arc::new(ServiceConnections::with_clock(directory.join("services.json"), keyring.clone(), github.clone(), Arc::new(|| 1_767_268_800_000)));
        Self { module: ServicesModule::new(connections.clone()), directory, keyring, github, connections }
    }

    fn record(&self) -> String {
        std::fs::read_to_string(self.directory.join("services.json")).unwrap_or_default()
    }
}

fn widget(owner: &str) -> CallContext {
    CallContext::new(owner, true, &["services", "network"], &["api.github.com"], Some("1.6"))
}

#[test]
fn only_a_fine_grained_token_is_a_token() {
    assert!(valid_token(TOKEN));
    assert!(valid_token(&format!("github_pat_{}", "a".repeat(20))));
    assert!(valid_token(&format!("github_pat_{}", "a".repeat(244))));
    for token in ["", "github_pat_", &format!("github_pat_{}", "a".repeat(19)), &format!("github_pat_{}", "a".repeat(245)), "ghp_0123456789012345678901234567890123456789", "github_pat_with space_0123456789012345", "github_pat_new\nline_01234567890123456789", "GITHUB_PAT_01234567890123456789012", "github_pat_0123456789-0123456789abc"] {
        assert!(!valid_token(token), "{token:?}");
    }
}

#[test]
fn connecting_verifies_the_token_and_keeps_it_only_in_the_keyring() {
    let fixture = Fixture::new();
    assert_eq!(fixture.connections.summary(), Ok(None));
    assert_eq!(fixture.connections.connect(&format!("  {TOKEN}\n")).as_deref(), Ok("octocat"));
    // The one request: the fixed address and exactly these headers.
    let requests = fixture.github.requests.lock().unwrap().clone();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].0, "https://api.github.com/user");
    assert_eq!(requests[0].1, headers(&[("Authorization", &format!("Bearer {TOKEN}")), ("User-Agent", "ScriptWidget"), ("Accept", "application/vnd.github+json"), ("X-GitHub-Api-Version", "2026-03-10")]));
    // The keyring has the token; nothing in the data folder does.
    assert_eq!(fixture.keyring.load(KEYRING_ACCOUNT).unwrap().unwrap().expose(), TOKEN);
    for entry in std::fs::read_dir(&fixture.directory).unwrap() {
        let text = std::fs::read_to_string(entry.unwrap().path()).unwrap();
        assert!(!text.contains("github_pat_") && !text.contains("notARealToken"), "the record holds a token: {text}");
    }
    let record: Value = serde_json::from_str(&fixture.record()).unwrap();
    assert_eq!((record["username"].as_str(), record["subject"].as_str(), record["grants"].as_array().map(Vec::len), record["connectedAt"].as_i64()), (Some("octocat"), Some("583231"), Some(0), Some(1_767_268_800_000)));
    assert_eq!(record.as_object().unwrap().len(), 6);
    let summary = fixture.connections.summary().unwrap().unwrap();
    assert_eq!((summary.username.as_str(), summary.grants.len()), ("octocat", 0));
    // Nothing that can be printed shows the account or an answer.
    assert_eq!(format!("{:?}", fixture.connections.connection().unwrap().unwrap()), "<private service connection>");
    assert_eq!(format!("{:?}", ok(&profile_body(1, "x"))), "<private native service response>");
    assert_eq!(format!("{:?}", fixture.keyring.load(KEYRING_ACCOUNT).unwrap().unwrap()), "ApiKey(<hidden>)");
}

#[test]
fn a_token_that_is_refused_is_not_stored() {
    let fixture = Fixture::new();
    // Not a token: nothing is asked of GitHub.
    for text in ["", "ghp_classic0123456789012345678901234567", "github_pat_short"] {
        assert_eq!(fixture.connections.connect(text).unwrap_err().0, ServiceError::Credential.message());
    }
    assert_eq!(fixture.github.count(), 0);
    let cases: [(Result<ServiceHttpResponse, ()>, ServiceError); 9] = [
        (Ok(response(401, "{}")), ServiceError::Expired),
        (Ok(response(403, "{}")), ServiceError::Permission),
        (Ok(ServiceHttpResponse { rate_limited: true, ..response(403, "{}") }), ServiceError::RateLimit),
        (Ok(response(429, "{}")), ServiceError::RateLimit),
        (Ok(response(500, "{}")), ServiceError::Unavailable),
        (Ok(ServiceHttpResponse { content_type: Some("text/html".into()), ..ok(&profile_body(1, "x")) }), ServiceError::Unavailable),
        (Ok(ok("not json")), ServiceError::Unavailable),
        (Ok(ok(&" ".repeat(github_profile::MAXIMUM_RESPONSE_BYTES + 1))), ServiceError::Unavailable),
        (Err(()), ServiceError::Unavailable),
    ];
    for (answer, expected) in cases {
        fixture.github.answer(answer);
        assert_eq!(fixture.connections.connect(TOKEN).unwrap_err().0, expected.message());
    }
    assert_eq!(fixture.keyring.load(KEYRING_ACCOUNT), Ok(None));
    assert_eq!(fixture.record(), "");
    // A keyring that cannot be used: the token is verified, then nothing is stored anywhere.
    let locked = Fixture::with_keyring(Arc::new(MemoryCredentialStore::unavailable()));
    assert_eq!(locked.connections.connect(TOKEN).unwrap_err().0, ServiceError::Storage.message());
    assert_eq!(locked.record(), "");
}

#[test]
fn the_profile_is_a_small_projection() {
    let decode = |body: &str| github_profile::decode(&ok(body), TOKEN);
    assert_eq!(
        Value::Object(decode(&profile_body(583_231, "octocat")).unwrap()),
        json!({"service": "github", "subject": "583231", "username": "octocat", "displayName": "Mona Lisa", "publicRepositories": 12, "privateRepositories": 3, "followers": 40, "following": 5})
    );
    // Missing optional values are null, never zero.
    assert_eq!(
        Value::Object(decode(r#"{"login":"a","id":1,"public_repos":0}"#).unwrap()),
        json!({"service": "github", "subject": "1", "username": "a", "displayName": null, "publicRepositories": 0, "privateRepositories": null, "followers": null, "following": null})
    );
    let refused = [
        r#"{"login":"a","public_repos":0}"#.to_owned(),
        r#"{"login":"a","id":0,"public_repos":0}"#.to_owned(),
        r#"{"login":"a","id":1.5,"public_repos":0}"#.to_owned(),
        r#"{"login":"a","id":"1","public_repos":0}"#.to_owned(),
        r#"{"login":"a","id":1}"#.to_owned(),
        r#"{"login":"a","id":1,"public_repos":-1}"#.to_owned(),
        r#"{"login":"-a","id":1,"public_repos":0}"#.to_owned(),
        r#"{"login":"a b","id":1,"public_repos":0}"#.to_owned(),
        format!(r#"{{"login":"{}","id":1,"public_repos":0}}"#, "a".repeat(40)),
        r#"{"login":"a","id":1,"public_repos":0,"name":7}"#.to_owned(),
        r#"{"login":"a","id":1,"public_repos":0,"name":"line\nbreak"}"#.to_owned(),
        format!(r#"{{"login":"a","id":1,"public_repos":0,"name":"{}"}}"#, "n".repeat(257)),
        // An answer that repeats the token is not passed on.
        format!(r#"{{"login":"a","id":1,"public_repos":0,"name":"my token is {TOKEN}"}}"#),
        r#"["login"]"#.to_owned(),
    ];
    for body in refused {
        assert_eq!(decode(&body).unwrap_err().0, ServiceError::Unavailable.message(), "{body}");
    }
}

#[test]
fn a_widget_needs_the_permission_the_grant_and_the_host() {
    let fixture = Fixture::new();
    let status = |context: &CallContext| fixture.module.status(context, "github");
    let profile = |context: &CallContext| fixture.module.profile(context, "github");
    assert_eq!(status(&widget(OWNER)), Ok("notConnected"));
    assert_eq!(profile(&widget(OWNER)).unwrap_err().0, ServiceError::NotConnected.message());
    fixture.connections.connect(TOKEN).unwrap();
    let asked = fixture.github.count();
    assert_eq!(status(&widget(OWNER)), Ok("notGranted"));
    assert_eq!(profile(&widget(OWNER)).unwrap_err().0, ServiceError::Permission.message());
    assert!(fixture.connections.set_grant(OWNER, true));
    assert!(!fixture.connections.set_grant("preview", true), "only an installation can be granted");
    assert_eq!(status(&widget(OWNER)), Ok("connected"));
    assert_eq!(status(&widget(OTHER)), Ok("notGranted"), "a grant is one widget's");
    assert_eq!(fixture.github.count(), asked, "status never asks GitHub");
    assert_eq!(profile(&widget(OWNER)).unwrap()["username"], "octocat");
    assert_eq!(fixture.github.count(), asked + 1);

    // The package's own declarations.
    for context in [CallContext::new(OWNER, true, &["network"], &["api.github.com"], Some("1.6")), CallContext::new("cli:/x", true, &["services", "network"], &["api.github.com"], Some("1.6")), CallContext::new(OWNER, false, &["services"], &[], None)] {
        assert_eq!(status(&context).unwrap_err().0, ServiceError::Permission.message());
        assert_eq!(profile(&context).unwrap_err().0, ServiceError::Permission.message());
    }
    for context in [CallContext::new(OWNER, true, &["services"], &["api.github.com"], Some("1.6")), CallContext::new(OWNER, true, &["services", "network"], &["github.com"], Some("1.6"))] {
        assert_eq!(status(&context), Ok("connected"));
        assert_eq!(profile(&context).unwrap_err().0, ServiceError::Permission.message(), "without the network permission and the host, no request");
    }
    assert_eq!(fixture.module.status(&widget(OWNER), "gitlab").unwrap_err().0, ServiceError::Operation.message());
    assert_eq!(fixture.module.profile(&widget(OWNER), "").unwrap_err().0, ServiceError::Operation.message());
    let mut projection = widget(OWNER);
    projection.is_timeline_projection = true;
    assert!(status(&projection).unwrap_err().0.starts_with("[timeline_read_only]"));
    // Budgets: eight data queries, then the network requests of the execution.
    let spent = Arc::new(AtomicU32::new(0));
    let counter = spent.clone();
    let budget = widget(OWNER).with_probes(move || counter.fetch_add(1, Ordering::SeqCst) < 1, || true, || true);
    assert!(status(&budget).is_ok());
    assert!(status(&budget).unwrap_err().0.starts_with("[query_limit]"));
    let offline = widget(OWNER).with_probes(|| true, || false, || true);
    assert_eq!(profile(&offline).unwrap_err().0, ServiceError::NetworkLimit.message());
    assert_eq!(fixture.github.count(), asked + 1, "none of the refusals reached GitHub");
}

#[test]
fn what_changed_meanwhile_stops_a_result() {
    let fixture = Fixture::new();
    fixture.connections.connect(TOKEN).unwrap();
    fixture.connections.set_grant(OWNER, true);
    // The answer is for another account than the one that was connected.
    fixture.github.answer(Ok(ok(&profile_body(999, "someone-else"))));
    assert_eq!(fixture.module.profile(&widget(OWNER), "github").unwrap_err().0, ServiceError::Credential.message());
    // GitHub says the token is no longer good.
    fixture.github.answer(Ok(response(401, "{}")));
    assert_eq!(fixture.module.profile(&widget(OWNER), "github").unwrap_err().0, ServiceError::Expired.message());
    // The keyring lost the token, or holds something else.
    fixture.github.answer(Ok(ok(&profile_body(583_231, "octocat"))));
    let asked = fixture.github.count();
    fixture.keyring.remove(KEYRING_ACCOUNT).unwrap();
    assert_eq!(fixture.module.profile(&widget(OWNER), "github").unwrap_err().0, ServiceError::Credential.message());
    fixture.keyring.save(KEYRING_ACCOUNT, &ApiKey::new("sk-some-other-secret").unwrap()).unwrap();
    assert_eq!(fixture.module.profile(&widget(OWNER), "github").unwrap_err().0, ServiceError::Credential.message());
    assert_eq!(fixture.github.count(), asked, "nothing that is not a GitHub token is ever sent");
    assert_eq!(fixture.module.status(&widget(OWNER), "github"), Ok("connected"), "status does not ask the keyring");

    // Reconnecting is a new connection: no widget inherits access.
    assert_eq!(fixture.connections.connect(SECOND_TOKEN).as_deref(), Ok("octocat"));
    assert_eq!(fixture.keyring.load(KEYRING_ACCOUNT).unwrap().unwrap().expose(), SECOND_TOKEN);
    assert_eq!(fixture.module.status(&widget(OWNER), "github"), Ok("notGranted"));
    // Disconnecting removes the token and the record.
    fixture.connections.set_grant(OWNER, true);
    fixture.connections.disconnect().unwrap();
    assert_eq!(fixture.keyring.load(KEYRING_ACCOUNT), Ok(None));
    assert_eq!(fixture.record(), "");
    assert_eq!(fixture.module.status(&widget(OWNER), "github"), Ok("notConnected"));
    assert!(!fixture.connections.set_grant(OWNER, true), "nothing to grant without a connection");
}

#[test]
fn a_record_that_is_not_ours_fails_closed() {
    let fixture = Fixture::new();
    fixture.connections.connect(TOKEN).unwrap();
    fixture.connections.set_grant(OWNER, true);
    let good = fixture.record();
    let damaged = [
        "{ not json".to_owned(),
        good.replace("\"formatVersion\":1", "\"formatVersion\":2"),
        good.replace("octocat", "octo cat"),
        good.replace("583231", "0583231"),
        good.replace(OWNER, "everyone"),
        good.replace("\"grants\":[", &format!("\"token\":\"{TOKEN}\",\"grants\":[")),
        good.replace(&format!("[\"{OWNER}\"]"), &format!("[\"{OWNER}\",\"{OWNER}\"]")),
    ];
    for text in damaged {
        assert_ne!(text, good);
        std::fs::write(fixture.directory.join("services.json"), &text).unwrap();
        assert_eq!(fixture.module.status(&widget(OWNER), "github").unwrap_err().0, ServiceError::Storage.message(), "{text}");
        assert_eq!(fixture.module.profile(&widget(OWNER), "github").unwrap_err().0, ServiceError::Storage.message());
        assert!(!fixture.connections.set_grant(OTHER, true));
    }
    // The user's way out: disconnect, which needs no readable record.
    fixture.connections.disconnect().unwrap();
    assert_eq!(fixture.connections.summary(), Ok(None));
}

#[test]
fn the_request_goes_out_through_the_guarded_transport() {
    // The fetch layer answers in this process; the name resolves to a public address.
    let exchange = FakeTransport::new(|request| {
        assert_eq!(request.url.as_str(), "https://api.github.com/user");
        FakeResponse::typed(200, &profile_body(583_231, "octocat"), "application/json; charset=utf-8").header("X-RateLimit-Remaining", "0")
    });
    let transport = FetchServiceTransport::new(Arc::new(offline(&exchange)));
    let answer = transport.get(github_profile::URL, &github_profile::headers(TOKEN)).unwrap();
    assert_eq!((answer.status, answer.content_type.as_deref(), answer.rate_limited), (200, Some("application/json; charset=utf-8"), true));
    let sent = exchange.requests();
    assert_eq!((sent.len(), sent[0].method.as_str(), sent[0].header("Authorization")), (1, "GET", Some(format!("Bearer {TOKEN}").as_str())));
    // A redirect is never followed: the token goes to api.github.com and nowhere else.
    let redirecting = FakeTransport::new(|_| FakeResponse::redirect(302, Some("https://evil.example/user")));
    let transport = FetchServiceTransport::new(Arc::new(offline(&redirecting)));
    assert_eq!(transport.get(github_profile::URL, &github_profile::headers(TOKEN)), Err(()));
    assert_eq!(redirecting.count(), 1, "only the first request was made");
    // An answer larger than a profile can be is not one.
    let read = Arc::new(std::sync::atomic::AtomicU64::new(0));
    let counter = read.clone();
    let large = FakeTransport::new(move |_| FakeResponse::zeros(Some(github_profile::MAXIMUM_RESPONSE_BYTES as u64 + 1), false, &counter));
    assert_eq!(FetchServiceTransport::new(Arc::new(offline(&large))).get(github_profile::URL, &[]), Err(()));
}

#[test]
fn a_script_gets_the_profile_and_never_the_token() {
    let fixture = Fixture::new();
    fixture.connections.connect(TOKEN).unwrap();
    fixture.connections.set_grant(OWNER, true);
    let modules: Vec<Arc<dyn NativeModule>> = vec![Arc::new(fixture.module.clone())];
    let manifest = widget_manifest(r#"["services","network"]"#, r#"["api.github.com"]"#);
    let source = "let text; try { const status = await $services.status('github'); const profile = await $services.profile('github'); text = [status, JSON.stringify(profile), Object.keys($services).sort().join('+')].join('|'); } catch (error) { text = String(error.message ?? error); }\n$render(<text>{text}</text>);";
    let run_as = |owner: &str, manifest: &str| {
        let result = run(source, Some(manifest), modules.clone(), &[], |request| request.package_id = owner.to_owned());
        assert!(result.error.is_none(), "error: {:?}", result.error);
        let logs: String = result.logs.iter().map(|entry| entry.message.clone()).collect();
        assert!(!logs.contains("github_pat_"));
        let tree = result.tree.expect("tree");
        assert!(!tree.contains("github_pat_") && !tree.contains("mona@example.com"), "{tree}");
        let tree: Value = serde_json::from_str(&tree).unwrap();
        tree["children"].as_array().unwrap().iter().map(|child| child.as_str().unwrap_or("").to_owned()).collect::<String>()
    };
    assert_eq!(
        run_as(OWNER, &manifest),
        r#"connected|{"service":"github","subject":"583231","username":"octocat","displayName":"Mona Lisa","publicRepositories":12,"privateRepositories":3,"followers":40,"following":5}|profile+status"#
    );
    assert_eq!(run_as(OTHER, &manifest), ServiceError::Permission.message(), "a widget without the grant");
    assert_eq!(run_as(OWNER, &widget_manifest(r#"["network"]"#, r#"["api.github.com"]"#)), ServiceError::Permission.message());
}
