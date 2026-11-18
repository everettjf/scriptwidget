//! `fetch` and `$http`: policy, redirects, budgets and results. Ported from
//! `Windows/tests/ScriptWidget.Core.Tests/Api/FetchModuleTests.cs` and
//! `FetchUserAgentTests.cs`. Every exchange is answered inside the process;
//! the transport over real sockets is tested in `api_http.rs`.

mod api_common;

use std::net::IpAddr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use api_common::*;
use serde_json::{Value, json};
use sw_core::api::fetch::{self, FetchError, FetchModule, Resolver, Url, system_resolver};
use sw_core::{Completion, NativeModule};

const HTTP: &str = "http.request";

fn rendered(source: &str, manifest: Option<&str>, module: FetchModule, environments: &[(&str, &str)]) -> String {
    render(source, manifest, vec![Arc::new(module)], environments)
}

// MARK: - From a script (NativeApiTest on Android)

#[test]
fn fetch_requires_a_declared_host() {
    let script = r#"fetch("https://example.org/").then(v => $render(<text>ok</text>), e => $render(<text>{String(e)}</text>))"#;
    let transport = FakeTransport::ok();
    assert_eq!(rendered(script, Some(&widget_manifest(r#"["network"]"#, r#"["example.com"]"#)), offline(&transport), &[]), "Network host is not declared in widget.json");
    assert_eq!(rendered(script, Some(&widget_manifest("[]", "[]")), offline(&transport), &[]), "Network host is not declared in widget.json");
    assert_eq!(transport.count(), 0);
}

#[test]
fn fetch_rejects_private_hosts_by_name_and_by_resolved_address() {
    let by_name = r#"fetch("http://192.168.1.1/").then(v => $render(<text>ok</text>), e => $render(<text>{String(e)}</text>))"#;
    let transport = FakeTransport::ok();
    assert_eq!(rendered(by_name, None, offline(&transport), &[]), BLOCKED);
    let rebinding = FetchModule::with_parts(fixed_resolver(&["10.0.0.5"]), transport.clone());
    let by_address = r#"fetch("https://public.example.com/").then(v => $render(<text>ok</text>), e => $render(<text>{String(e)}</text>))"#;
    assert_eq!(rendered(by_address, None, rebinding, &[]), BLOCKED);
    assert_eq!(transport.count(), 0);
}

#[test]
fn fetch_policy_holds_when_built_ins_are_tampered() {
    let script = r#"
        RegExp.prototype.exec = function () { return ["https://example.com", "https", "example.com"]; };
        String.prototype.startsWith = function () { return false; };
        Array.prototype.includes = function () { return true; };
        fetch("http://127.0.0.1:8080/").then(v => $render(<text>ok</text>), e => $render(<text>{String(e)}</text>))
    "#;
    let transport = FakeTransport::ok();
    assert_eq!(rendered(script, Some(&widget_manifest(r#"["network"]"#, r#"["example.com"]"#)), offline(&transport), &[]), BLOCKED);
    assert_eq!(transport.count(), 0);
}

#[test]
fn fetch_is_read_only_in_future_timeline_entries() {
    let script = r#"fetch("https://example.com/").then(v => $render(<text>ok</text>), e => $render(<text>{String(e).slice(0, 20)}</text>))"#;
    assert_eq!(rendered(script, None, offline(&FakeTransport::ok()), &[("timeline-is-projection", "true")]), "[timeline_read_only]");
}

/// The Android test reads example.com; here the exchange is answered in the process.
#[test]
fn fetch_returns_bodies_and_metadata() {
    let script = r#"
        $http.getResponse("https://example.com/").then(
          r => $render(<text>{[r.status, r.body.includes("Example Domain"), typeof r.headers["content-type"]].join("|")}</text>),
          e => $render(<text>{"error: " + String(e)}</text>))
    "#;
    let manifest = widget_manifest(r#"["network"]"#, r#"["example.com"]"#);
    let transport = FakeTransport::new(|_| FakeResponse::typed(200, "<h1>Example Domain</h1>", "text/html"));
    assert_eq!(rendered(script, Some(&manifest), offline(&transport), &[]), "200|true|string");
    let requests = transport.requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].url.as_str(), "https://example.com/");
    let plain = r#"fetch("https://example.com/a").then(v => $render(<text>{v}</text>), e => $render(<text>{"error: " + String(e)}</text>))"#;
    assert_eq!(rendered(plain, Some(&manifest), offline(&FakeTransport::ok()), &[]), "ok");
    // POST with a JSON body, as a script writes it.
    let post = r#"$http.post("https://example.com/items", { body: { a: 1 }, headers: { "X-Token": "t" } }).then(v => $render(<text>{v}</text>), e => $render(<text>{"error: " + String(e)}</text>))"#;
    let echo = FakeTransport::new(|request| FakeResponse::text(200, &format!("{} {} {}", request.method, String::from_utf8_lossy(request.body.as_deref().unwrap_or_default()), request.header("content-type").unwrap_or("-"))));
    assert_eq!(rendered(post, Some(&manifest), offline(&echo), &[]), r#"POST {"a":1} application/json"#);
}

// MARK: - The module without a script

fn perform(module: &FetchModule, method: &str, address: &str, headers: &[(String, String)], body: Option<&[u8]>) -> Result<fetch::Response, FetchError> {
    module.perform(method, &url(address), headers, body, 5000, &any_redirect, None)
}

#[test]
fn handles_only_the_http_operation_and_reports_presentation_and_url_errors() {
    let module = offline(&FakeTransport::ok());
    assert!(module.handles("http.request"));
    assert!(!module.handles("datasource.request"));
    let reject = |package: &Package, job: Value| rejection(&module, &package.request(), HTTP, &job);
    assert_eq!(
        reject(&Package::legacy().environments(&[("widget-size", "live-activity")]), get("https://example.com/")),
        "[live_activity_unavailable] Live Activity presentations cannot request network data; update their state from the app"
    );
    assert_eq!(
        reject(&Package::legacy().environments(&[("widget-size", "medium"), ("timeline-is-projection", "true")]), get("https://example.com/")),
        "[timeline_read_only] Future entries cannot make live network requests; read a saved snapshot"
    );
    let legacy = Package::legacy();
    assert_eq!(reject(&legacy, get("ftp://example.com/x")), "Only HTTP and HTTPS URLs are allowed");
    assert_eq!(reject(&legacy, get("file:///etc/passwd")), "Only HTTP and HTTPS URLs are allowed");
    assert_eq!(reject(&legacy, get("example.com/x")), "Only HTTP and HTTPS URLs are allowed");
    assert_eq!(reject(&legacy, json!({})), "Only HTTP and HTTPS URLs are allowed");
    assert_eq!(reject(&legacy, get("https:///status")), "https:///status is not url");
    assert_eq!(reject(&legacy, get("https://user:pw@example.com/")), "URL credentials are not allowed");
    assert_eq!(reject(&legacy, get("https://user@example.com/")), "URL credentials are not allowed");
    assert_eq!(reject(&legacy, get("http://localhost:8080/")), BLOCKED);
    assert_eq!(reject(&legacy, get("http://printer.local/")), BLOCKED);
    // A package with a manifest needs the network permission and the host in networkDomains.
    assert_eq!(reject(&Package::with_domains(&["example.com"]), get("https://example.org/")), "Network host is not declared in widget.json");
    assert_eq!(reject(&Package::with_domains(&["*.example.com"]), get("https://example.com/")), "Network host is not declared in widget.json");
    assert!(start(&module, &Package::with_domains(&["*.example.com"]).request(), HTTP, get("https://api.example.com/").as_object()).0);
    let no_permission = Package::with_manifest(json!({ "formatVersion": 2, "permissions": [], "networkDomains": ["example.com"] }));
    assert_eq!(reject(&no_permission, get("https://example.com/")), "Network host is not declared in widget.json");
    let no_domains = Package::with_manifest(json!({ "formatVersion": 2, "permissions": ["network"] }));
    assert_eq!(reject(&no_domains, get("https://example.com/")), "Network host is not declared in widget.json");
    // A manifest that is present but could not be read declares nothing; it is not a legacy package.
    let mut unreadable = Package::legacy();
    unreadable.prepared.has_manifest = true;
    assert_eq!(reject(&unreadable, get("https://example.com/")), "Network host is not declared in widget.json");
}

#[test]
fn hosts_resolving_to_private_addresses_are_refused_before_anything_is_sent() {
    let refused = [
        "127.0.0.1", "127.8.9.10", "10.1.2.3", "169.254.169.254", "::1", "fc00::1", "fd12:3456:789a::1", "::ffff:127.0.0.1", "::ffff:10.0.0.1", "::ffff:169.254.169.254", "192.168.0.10", "172.16.5.4", "172.31.255.255",
        "100.64.0.1", "0.0.0.0", "::", "fe80::1", "fec0::1", "ff02::1", "64:ff9b::7f00:1", "2002:7f00:1::1", "224.0.0.1", "255.255.255.255",
    ];
    let transport = FakeTransport::new(|_| FakeResponse::text(200, "secret"));
    for text in refused {
        let module = FetchModule::with_parts(fixed_resolver(&[text]), transport.clone());
        assert_eq!(failure(perform(&module, "GET", "https://public.example.com/", &[], None)), BLOCKED, "{text}");
        // One private address among public ones is enough: the connection could go to it.
        let mixed = FetchModule::with_parts(fixed_resolver(&[PUBLIC, text]), transport.clone());
        assert_eq!(failure(perform(&mixed, "GET", "https://public.example.com/", &[], None)), BLOCKED, "{text}");
        assert_eq!(rejection(&module, &Package::legacy().request(), HTTP, &get("https://public.example.com/")), BLOCKED, "{text}");
    }
    let none = FetchModule::with_parts(fixed_resolver(&[]), transport.clone());
    assert_eq!(failure(perform(&none, "GET", "https://public.example.com/", &[], None)), BLOCKED);
    let unknown: Resolver = Arc::new(|_| Err(std::io::Error::other("no such host")));
    assert_eq!(failure(perform(&FetchModule::with_parts(unknown, transport.clone()), "GET", "https://public.example.com/", &[], None)), "Could not resolve public.example.com");
    assert_eq!(transport.count(), 0);
    // Public addresses pass.
    for text in ["93.184.216.34", "2606:2800:220:1:248:1893:25c8:1946", "::ffff:93.184.216.34", "172.32.0.1", "100.128.0.1"] {
        let module = FetchModule::with_parts(fixed_resolver(&[text]), FakeTransport::ok());
        assert_eq!(perform(&module, "GET", "https://public.example.com/", &[], None).unwrap().status, 200, "{text}");
    }
}

/// Address literals need no DNS: every spelling of a local address is refused by name or by value.
#[test]
fn address_literals_in_blocked_ranges_are_refused() {
    let transport = FakeTransport::new(|_| FakeResponse::text(200, "secret"));
    let module = FetchModule::with_parts(Arc::new(system_resolver), transport.clone());
    for address in [
        "http://127.0.0.1/", "http://[::1]/", "http://[::ffff:127.0.0.1]/", "http://[::ffff:7f00:1]/", "http://[fd00::1]/", "http://[fe80::1]/", "http://169.254.169.254/latest/meta-data/", "http://0.0.0.0/",
        "http://2130706433/", "http://0x7f.0.0.1/", "http://127.1/", "http://10.0.0.1:8080/", "https://192.168.1.1/", "http://100.64.0.1/", "http://[64:ff9b::a00:1]/", "http://017700000001/", "http://[0:0:0:0:0:0:0:1]/",
        "http://127.0.0.1.:80/", "http://LOCALHOST/",
    ] {
        assert_eq!(rejection(&module, &Package::legacy().request(), HTTP, &get(address)), BLOCKED, "{address}");
    }
    assert_eq!(transport.count(), 0);
}

/// DNS rebinding: the name is public when the request is checked and local
/// when the connection is opened. The production transport resolves again at
/// connect and refuses, so nothing is sent.
#[test]
fn a_dns_answer_that_changes_before_the_connect_is_refused() {
    let answers: Arc<Mutex<Vec<String>>> = Arc::default();
    let rebinding = |answers: Arc<Mutex<Vec<String>>>| -> Resolver {
        Arc::new(move |host: &str| {
            let mut answers = answers.lock().unwrap();
            answers.push(host.to_owned());
            Ok(vec![if answers.len() == 1 { PUBLIC.parse::<IpAddr>().unwrap() } else { "127.0.0.1".parse().unwrap() }])
        })
    };
    let module = FetchModule::with_resolver(rebinding(answers.clone()));
    assert_eq!(failure(perform(&module, "GET", "http://rebind.example.com:9/", &[], None)), BLOCKED);
    assert_eq!(*answers.lock().unwrap(), ["rebind.example.com", "rebind.example.com"]);
    let second = FetchModule::with_resolver(rebinding(Arc::default()));
    assert_eq!(rejection(&second, &Package::with_domains(&["rebind.example.com"]).request(), HTTP, &get("https://rebind.example.com/")), BLOCKED);
}

#[test]
fn redirects_to_blocked_or_undeclared_hosts_are_refused() {
    let location: Arc<Mutex<String>> = Arc::default();
    let target = location.clone();
    let transport = FakeTransport::new(move |request| if request.path() == "/start" { FakeResponse::redirect(302, Some(&target.lock().unwrap())) } else { FakeResponse::text(200, "arrived") });
    let resolver: Resolver = Arc::new(|host: &str| match host {
        "example.com" | "other.example.org" => Ok(addresses(&[PUBLIC])),
        "cdn.example.com" => Ok(addresses(&["10.0.0.1"])),
        _ => Err(std::io::Error::other("unknown host")),
    });
    let module = FetchModule::with_parts(resolver, transport.clone());
    let follow = |to: &str, domains: Option<&[&str]>| -> (bool, String, usize) {
        transport.clear();
        *location.lock().unwrap() = to.to_owned();
        let package = domains.map_or_else(Package::legacy, Package::with_domains);
        let (ok, value) = start(&module, &package.request(), HTTP, get("https://example.com/start").as_object());
        (ok, value.as_str().unwrap_or("").to_owned(), transport.count())
    };
    let declared: &[&str] = &["example.com", "cdn.example.com"];
    assert_eq!(follow("https://example.com/next", Some(declared)), (true, "arrived".into(), 2));
    assert_eq!(follow("/next", Some(declared)), (true, "arrived".into(), 2));
    let refused = (false, "Redirect target is not allowed".to_owned(), 1);
    // Not in networkDomains.
    assert_eq!(follow("https://other.example.org/x", Some(declared)), refused);
    // Local by name, by literal address, with credentials, or not HTTP at all.
    for to in ["http://localhost/x", "http://127.0.0.1/x", "http://[::1]/x", "http://192.168.1.1/x", "https://user:pw@example.com/x", "ftp://example.com/x", "file:///etc/passwd", "javascript:alert(1)", "http://2130706433/x"] {
        assert_eq!(follow(to, Some(declared)), refused, "{to}");
        assert_eq!(follow(to, None), refused, "{to}");
    }
    // Declared, but the name resolves to a private address: refused when the hop is resolved.
    assert_eq!(follow("https://cdn.example.com/x", Some(declared)), (false, BLOCKED.into(), 1));
}

#[test]
fn redirects_follow_the_method_rules_and_stop_at_the_limit() {
    let transport = FakeTransport::new(|request| match request.path() {
        "/found" => FakeResponse::redirect(302, Some("/after-found")),
        "/moved" => FakeResponse::redirect(301, Some("/after-moved")),
        "/other" => FakeResponse::redirect(303, Some("/after-other")),
        "/temporary" => FakeResponse::redirect(307, Some("/after-temporary")),
        "/permanent" => FakeResponse::redirect(308, Some("https://example.com/after-permanent")),
        "/loop" => FakeResponse::redirect(302, Some("/loop")),
        "/nowhere" => FakeResponse::redirect(302, None),
        "/unchanged" => FakeResponse::redirect(304, Some("/never")),
        _ => FakeResponse::text(200, "done"),
    });
    let module = offline(&transport);
    let traced = headers(&[("X-Trace", "1")]);
    let trace = |method: &str, path: &str| -> String {
        transport.clear();
        let response = perform(&module, method, &format!("https://example.com{path}"), &traced, Some(b"payload")).unwrap();
        let steps: Vec<String> = transport
            .requests()
            .iter()
            .map(|request| format!("{}:{}:{}", request.method, request.path(), request.body.as_deref().filter(|body| !body.is_empty()).map_or("-".into(), |body| String::from_utf8_lossy(body).into_owned())))
            .collect();
        format!("{} {}", response.status, steps.join(" "))
    };
    assert_eq!(trace("post", "/found"), "200 POST:/found:payload GET:/after-found:-");
    assert_eq!(trace("POST", "/moved"), "200 POST:/moved:payload GET:/after-moved:-");
    assert_eq!(trace("PUT", "/found"), "200 PUT:/found:payload PUT:/after-found:payload");
    assert_eq!(trace("PUT", "/other"), "200 PUT:/other:payload GET:/after-other:-");
    assert_eq!(trace("POST", "/temporary"), "200 POST:/temporary:payload POST:/after-temporary:payload");
    assert_eq!(trace("DELETE", "/permanent"), "200 DELETE:/permanent:payload DELETE:/after-permanent:payload");
    assert_eq!(trace("GET", "/found"), "200 GET:/found:- GET:/after-found:-");
    assert_eq!(trace("GET", "/unchanged"), "304 GET:/unchanged:-");
    assert!(transport.requests().iter().all(|request| request.header("X-Trace") == Some("1")));

    transport.clear();
    assert_eq!(failure(perform(&module, "GET", "https://example.com/loop", &[], None)), "Redirect target is not allowed");
    assert_eq!(transport.count(), fetch::MAXIMUM_REDIRECTS + 1);
    assert_eq!(failure(perform(&module, "GET", "https://example.com/nowhere", &[], None)), "Redirect without a location");
    // The caller's rule is asked for every hop, with the resolved target.
    let asked: Mutex<Vec<String>> = Mutex::default();
    let refuse = |target: &Url| {
        asked.lock().unwrap().push(target.as_str().to_owned());
        false
    };
    assert_eq!(failure(module.perform("GET", &url("https://example.com/found"), &[], None, 5000, &refuse, None)), "Redirect target is not allowed");
    assert_eq!(*asked.lock().unwrap(), ["https://example.com/after-found"]);
    assert_eq!(failure(perform(&module, "brew", "https://example.com/", &[], None)), "Unknown method 'BREW'");
}

#[test]
fn over_budget_bodies_are_cut_off() {
    let limit = format!("Response exceeds the {}-byte limit", fetch::MAXIMUM_RESPONSE_BYTES);
    assert_eq!(limit, "Response exceeds the 2097152-byte limit");
    let maximum = fetch::MAXIMUM_RESPONSE_BYTES as u64;
    let module = |length: Option<u64>, declared: Option<u64>, read: &Arc<AtomicU64>| {
        let read = read.clone();
        offline(&FakeTransport::new(move |_| {
            let response = FakeResponse::zeros(length, false, &read);
            match declared {
                Some(declared) => response.header("Content-Length", &declared.to_string()),
                None => response,
            }
        }))
    };

    // No length at all: the body is counted while it is read and reading stops at the limit.
    let endless: Arc<AtomicU64> = Arc::default();
    assert_eq!(failure(perform(&module(None, None, &endless), "GET", "https://example.com/", &[], None)), limit);
    assert!((maximum..=maximum + 256 * 1024).contains(&endless.load(Ordering::SeqCst)));

    // A length that understates the body is not trusted.
    let lying: Arc<AtomicU64> = Arc::default();
    assert_eq!(failure(perform(&module(None, Some(10), &lying), "GET", "https://example.com/", &[], None)), limit);
    assert!((maximum..=maximum + 256 * 1024).contains(&lying.load(Ordering::SeqCst)));

    // A declared length above the limit is refused without reading.
    let unread: Arc<AtomicU64> = Arc::default();
    assert_eq!(failure(perform(&module(None, Some(maximum + 1), &unread), "GET", "https://example.com/", &[], None)), limit);
    assert_eq!(unread.load(Ordering::SeqCst), 0);

    // Exactly the limit is delivered; the script sees the same message for one byte more.
    let exact = module(Some(maximum), None, &Arc::default());
    assert_eq!(perform(&exact, "GET", "https://example.com/", &[], None).unwrap().body.len(), fetch::MAXIMUM_RESPONSE_BYTES);
    let over = module(Some(maximum + 1), None, &Arc::default());
    assert_eq!(rejection(&over, &Package::legacy().request(), HTTP, &get("https://example.com/")), limit);
}

#[test]
fn the_request_budget_and_the_request_body_limit_are_enforced() {
    let transport = FakeTransport::ok();
    let module = offline(&transport);
    let package = Package::legacy();
    let request = package.request();
    for _ in 0..fetch::MAXIMUM_REQUESTS {
        assert!(start(&module, &request, HTTP, get("https://example.com/").as_object()).0);
    }
    assert_eq!(rejection(&module, &request, HTTP, &get("https://example.com/")), "Network request budget exceeded");
    assert_eq!(transport.count(), fetch::MAXIMUM_REQUESTS as usize);
    // Requests that policy refuses before the budget do not count.
    let other = package.request();
    rejection(&module, &other, HTTP, &get("http://localhost/"));
    assert_eq!(other.session.network_requests(), 0);

    transport.clear();
    let large = json!({ "method": "POST", "url": "https://example.com/", "body": "x".repeat(fetch::MAXIMUM_REQUEST_BODY_BYTES + 1) });
    assert_eq!(rejection(&module, &package.request(), HTTP, &large), "Request body exceeds the 1048576-byte limit");
    assert_eq!(transport.count(), 0);
    let fits = json!({ "method": "POST", "url": "https://example.com/", "body": "x".repeat(fetch::MAXIMUM_REQUEST_BODY_BYTES) });
    assert!(start(&module, &package.request(), HTTP, fits.as_object()).0);
    assert_eq!(transport.requests()[0].body.as_ref().unwrap().len(), fetch::MAXIMUM_REQUEST_BODY_BYTES);
}

#[test]
fn requests_carry_the_script_headers_and_body_but_not_host_or_length() {
    let transport = FakeTransport::ok();
    let module = offline(&transport);
    let package = Package::legacy();
    let job = json!({
        "method": "POST", "url": "https://example.com/items?x=1", "body": "{\"a\":1}", "jsonBody": true,
        "headers": { "X-Token": "t", "Host": "evil.example.net", "Content-Length": "999", "Accept": "application/json" },
    });
    assert!(start(&module, &package.request(), HTTP, job.as_object()).0);
    let sent = transport.requests().remove(0);
    assert_eq!(sent.method, "POST");
    assert_eq!(sent.url.as_str(), "https://example.com/items?x=1");
    assert_eq!(sent.body.as_deref(), Some(&b"{\"a\":1}"[..]));
    assert_eq!(sent.header("X-Token"), Some("t"));
    assert_eq!(sent.header("Accept"), Some("application/json"));
    assert_eq!(sent.header("Content-Type"), Some("application/json"));
    for absent in ["Host", "Content-Length", "Cookie", "Authorization"] {
        assert_eq!(sent.header(absent), None, "{absent}");
    }

    // The script's own content type wins over the JSON default; a GET sends no body.
    transport.clear();
    let job = json!({ "method": "PUT", "url": "https://example.com/", "body": "a=1", "jsonBody": true, "headers": { "content-type": "application/x-www-form-urlencoded" } });
    assert!(start(&module, &package.request(), HTTP, job.as_object()).0);
    assert_eq!(transport.requests()[0].header("Content-Type"), Some("application/x-www-form-urlencoded"));
    transport.clear();
    assert!(start(&module, &package.request(), HTTP, json!({ "method": "GET", "url": "https://example.com/", "body": "ignored" }).as_object()).0);
    assert_eq!(transport.requests()[0].body, None);

    // A header value cannot add a header line, and a header name cannot hold a separator.
    transport.clear();
    let job = json!({ "method": "GET", "url": "https://example.com/", "headers": { "X-Token": "a\r\nX-Evil: 1" } });
    assert_eq!(rejection(&module, &package.request(), HTTP, &job), "Request header X-Token is not valid");
    for name in ["X Token", "X-Token:", "X\r\nEvil", "", "Näme", "X(1)"] {
        let job = json!({ "method": "GET", "url": "https://example.com/", "headers": { name: "v" } });
        assert!(rejection(&module, &package.request(), HTTP, &job).ends_with("is not valid"), "{name:?}");
    }
    let job = json!({ "method": "GET", "url": "https://example.com/", "headers": { "X-Token": "a\u{0}b" } });
    assert_eq!(rejection(&module, &package.request(), HTTP, &job), "Request header X-Token is not valid");
    assert_eq!(transport.count(), 0);
}

#[test]
fn responses_are_text_metadata_or_base64() {
    let transport = FakeTransport::new(|request| {
        if request.path() == "/binary" {
            return FakeResponse::bytes(200, &[0xFF, 0x00, 0x10]);
        }
        FakeResponse::typed(if request.path() == "/missing" { 404 } else { 200 }, "body \u{e9}", "application/json")
            .header("Cache-Control", "max-age=60")
            .header("Set-Cookie", "session=secret")
            .header("X-Internal", "secret")
            .header("Retry-After", &"9".repeat(2049))
            .header("Last-Modified", "Fri, 13 Nov 2026 07:00:00 GMT")
    });
    let module = offline(&transport);
    let package = Package::legacy();
    let value = |job: Value| start(&module, &package.request(), HTTP, job.as_object()).1;
    assert_eq!(value(get("https://example.com/")), "body \u{e9}");
    // An error status still delivers its body, as on the other platforms.
    assert_eq!(value(get("https://example.com/missing")), "body \u{e9}");

    let metadata = value(json!({ "method": "GET", "url": "https://example.com/missing", "metadata": true }));
    assert_eq!(metadata["status"], 404);
    assert_eq!(metadata["body"], "body \u{e9}");
    let mut names: Vec<&String> = metadata["headers"].as_object().unwrap().keys().collect();
    names.sort_unstable();
    assert_eq!(names, ["cache-control", "content-type", "last-modified"]);
    assert_eq!(metadata["headers"]["content-type"], "application/json");
    assert_eq!(metadata["headers"]["last-modified"], "Fri, 13 Nov 2026 07:00:00 GMT");

    assert_eq!(value(json!({ "method": "GET", "url": "https://example.com/binary", "base64": true })), "/wAQ");
    assert_eq!(rejection(&module, &package.request(), HTTP, &get("https://example.com/binary")), "https://example.com/binary is empty");
    assert_eq!(rejection(&module, &package.request(), HTTP, &json!({ "method": "GET", "url": "https://example.com/binary", "metadata": true })), "Response is not HTTP or has invalid UTF-8");
}

#[test]
fn timeouts_and_cancellation_stop_the_request() {
    // An exchange that never answers.
    let waiting = offline(&FakeTransport::waiting(|_, wait| Err(wait.expire())));
    let started = std::time::Instant::now();
    assert_eq!(failure(waiting.perform("GET", &url("https://example.com/"), &[], None, 150, &any_redirect, None)), "The request timed out.");
    assert!(started.elapsed() < Duration::from_secs(5));

    // A body that stops arriving is given up on as well.
    let read: Arc<AtomicU64> = Arc::default();
    let counter = read.clone();
    let stalled = offline(&FakeTransport::new(move |_| FakeResponse::zeros(None, true, &counter)));
    assert_eq!(failure(stalled.perform("GET", &url("https://example.com/"), &[], None, 150, &any_redirect, None)), "The request timed out.");
    assert!(read.load(Ordering::SeqCst) > 0);

    // The end of the execution cancels the request.
    let ended = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let flag = ended.clone();
    let timer = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(150));
        flag.store(true, Ordering::SeqCst);
    });
    let flag = ended.clone();
    let started = std::time::Instant::now();
    assert_eq!(waiting.perform("GET", &url("https://example.com/"), &[], None, 5000, &any_redirect, Some(Arc::new(move || flag.load(Ordering::SeqCst)))), Err(FetchError::Cancelled));
    assert!(started.elapsed() < Duration::from_secs(3));
    timer.join().unwrap();
    let transport = FakeTransport::ok();
    assert_eq!(offline(&transport).perform("GET", &url("https://example.com/"), &[], None, 5000, &any_redirect, Some(Arc::new(|| true))), Err(FetchError::Cancelled));
    assert_eq!(transport.count(), 0);

    // A result that arrives after the execution ended is dropped.
    let package = Package::legacy();
    let request = package.request();
    let session = request.session.clone();
    let late = offline(&FakeTransport::new(move |_| {
        session.finish();
        FakeResponse::text(200, "late")
    }));
    let (done, answers) = Completion::detached(request.session.clone());
    late.start(&request, HTTP, get("https://example.com/").as_object(), done);
    assert!(answers.recv_timeout(Duration::from_millis(500)).is_err());
}

// MARK: - FetchUserAgentTests

fn user_agent(given: &[(String, String)]) -> Option<String> {
    let transport = FakeTransport::ok();
    offline(&transport).perform("GET", &url("https://example.com/"), given, None, 3000, &any_redirect, None).unwrap();
    let requests = transport.requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].headers.iter().filter(|(name, _)| name.eq_ignore_ascii_case("User-Agent")).count(), 1);
    requests[0].header("User-Agent").map(str::to_owned)
}

#[test]
fn requests_name_the_client_when_the_script_does_not() {
    let agent = user_agent(&[]).unwrap();
    assert_eq!(agent, fetch::DEFAULT_USER_AGENT);
    assert_eq!(agent, format!("ScriptWidget-Linux/{}", env!("CARGO_PKG_VERSION")));
    // Nothing about the user or the machine.
    for variable in ["USER", "LOGNAME", "HOSTNAME"] {
        if let Ok(value) = std::env::var(variable).map(|value| value.to_lowercase())
            && value.len() > 2
        {
            assert!(!agent.to_lowercase().contains(&value), "{variable}");
        }
    }
}

#[test]
fn credentials_stay_with_the_origin_the_script_addressed() {
    let transport = FakeTransport::new(|request| match (request.url.host_str().unwrap_or(""), request.path()) {
        ("api.example.com", "/start") => FakeResponse::redirect(302, Some("/same-origin")),
        ("api.example.com", "/same-origin") => FakeResponse::redirect(302, Some("https://cdn.example.net/elsewhere")),
        ("cdn.example.net", "/elsewhere") => FakeResponse::redirect(302, Some("https://api.example.com/back")),
        _ => FakeResponse::text(200, "arrived"),
    });
    let given = headers(&[("Authorization", "Bearer secret"), ("cookie", "session=1"), ("Proxy-Authorization", "Basic x"), ("Accept", "application/json")]);
    offline(&transport).perform("GET", &url("https://api.example.com/start"), &given, None, 3000, &any_redirect, None).unwrap();
    let requests = transport.requests();
    assert_eq!(requests.len(), 4);
    // The same origin keeps the credentials across a redirect.
    assert_eq!(requests[1].header("Authorization"), Some("Bearer secret"));
    assert_eq!(requests[1].header("Cookie"), Some("session=1"));
    // Another origin gets the ordinary headers only.
    let elsewhere = &requests[2];
    assert_eq!(elsewhere.url.host_str(), Some("cdn.example.net"));
    for credential in ["Authorization", "Cookie", "Proxy-Authorization"] {
        assert_eq!(elsewhere.header(credential), None, "{credential}");
    }
    assert_eq!(elsewhere.header("Accept"), Some("application/json"));
    // Back at the first origin they are sent again: they were meant for it.
    assert_eq!(requests[3].header("Authorization"), Some("Bearer secret"));

    // Another scheme or port of the same host is another origin.
    for other in ["http://api.example.com/plain", "https://api.example.com:8443/port"] {
        let target = other.to_owned();
        let transport = FakeTransport::new(move |request| if request.path() == "/start" { FakeResponse::redirect(307, Some(&target)) } else { FakeResponse::text(200, "arrived") });
        offline(&transport).perform("POST", &url("https://api.example.com/start"), &given, Some(b"x"), 3000, &any_redirect, None).unwrap();
        let requests = transport.requests();
        assert_eq!(requests[1].url.as_str(), other);
        assert_eq!(requests[1].header("Authorization"), None, "{other}");
        assert_eq!(requests[1].header("Cookie"), None, "{other}");
        assert_eq!(requests[1].header("Accept"), Some("application/json"));
    }
}

#[test]
fn a_scripts_own_user_agent_wins() {
    assert_eq!(user_agent(&headers(&[("user-agent", "my-widget/2.0")])).as_deref(), Some("my-widget/2.0"));
}
