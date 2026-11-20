//! Loading the Gallery index: ETag, the offline cache, what is refused, and
//! the production transport's redirect rule. Ported from
//! `GalleryRepositoryTest.kt`; nothing here reaches the Internet.

mod gallery_common;
#[path = "packages_support/mod.rs"]
mod support;

use std::io::Read;
use std::net::IpAddr;
use std::path::PathBuf;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, Mutex};

use gallery_common::*;
use support::{TemporaryFolder, symlink, tree};
use sw_core::api::fetch::{FetchError, FetchModule, Resolver, Transport, TransportRequest, TransportResponse, Wait};
use sw_core::gallery::validator::decode;
use sw_core::gallery::{FetchGalleryTransport, GalleryErrorKind, GalleryIndexCache, GalleryRepository, GalleryRequest, GalleryResponse, GalleryTransport};

const URL: &str = GalleryRepository::DEFAULT_INDEX_URL;

struct Fixture {
    temporary: TemporaryFolder,
    cache: PathBuf,
    transport: Arc<FakeTransport>,
    clock: Arc<AtomicI64>,
    repository: GalleryRepository,
}

impl Fixture {
    fn new() -> Self {
        let temporary = TemporaryFolder::new();
        let cache = temporary.path("cache");
        let transport = Arc::new(FakeTransport::default());
        let clock = Arc::new(AtomicI64::new(1_000_000));
        let repository = Self::repository(&transport, &cache, &clock);
        Self { temporary, cache, transport, clock, repository }
    }

    fn repository(transport: &Arc<FakeTransport>, cache: &PathBuf, clock: &Arc<AtomicI64>) -> GalleryRepository {
        let clock = clock.clone();
        GalleryRepository::new(transport.clone(), GalleryIndexCache::new(cache)).with_clock(move || clock.load(Ordering::SeqCst))
    }

    fn advance(&self, milliseconds: i64) -> i64 {
        self.clock.fetch_add(milliseconds, Ordering::SeqCst) + milliseconds
    }

    fn queue(&self, status: u16, body: &[u8], headers: &'static [(&'static str, &'static str)]) {
        let body = body.to_vec();
        self.transport.queue(move || Ok(GalleryResponse::new(status, body.clone(), headers, URL)));
    }

    fn queue_ok(&self) {
        self.queue(200, &checked_in_index(), &[("ETag", "gallery-v1")]);
    }

    fn requests(&self) -> Vec<GalleryRequest> {
        self.transport.requests()
    }
}

#[test]
fn default_index_url_is_the_swift_default() {
    assert_eq!(GalleryRepository::DEFAULT_INDEX_URL, "https://raw.githubusercontent.com/everettjf/scriptwidget/main/Gallery/index.json");
    assert_eq!(Fixture::new().repository.index_url(), URL);
}

#[test]
fn uses_etag_and_falls_back_to_the_verified_offline_cache() {
    let fixture = Fixture::new();
    fixture.queue_ok();
    fixture.queue(304, b"", &[]);
    fixture.transport.queue(|| Err(sw_core::gallery::GalleryError::network("offline")));

    let online = fixture.repository.load(true).unwrap();
    assert!(!online.is_offline);
    let first = &fixture.requests()[0];
    assert_eq!((first.url.as_str(), first.header("Accept"), first.header("User-Agent"), first.header("If-None-Match")), (URL, Some("application/json"), Some("ScriptWidget-Gallery/1"), None));
    assert!(first.headers.iter().all(|(name, _)| !["authorization", "cookie"].contains(&name.to_lowercase().as_str())));

    let now = fixture.advance(60_000);
    let revalidated = fixture.repository.load(true).unwrap();
    assert!(!revalidated.is_offline);
    assert_eq!(revalidated.index, online.index);
    assert_eq!(revalidated.fetched_at, now);
    assert_eq!(fixture.requests()[1].header("If-None-Match"), Some("gallery-v1"));

    fixture.advance(60_000);
    let offline = fixture.repository.load(true).unwrap();
    assert!(offline.is_offline);
    assert_eq!(offline.index, online.index);
    assert_eq!(offline.fetched_at, now);
    assert_eq!(offline.offline_reason.as_deref(), Some("offline"));
    assert_eq!(fixture.requests()[2].header("If-None-Match"), Some("gallery-v1"));
}

#[test]
fn fresh_cache_is_used_without_a_request_until_it_expires_or_a_refresh_is_forced() {
    let fixture = Fixture::new();
    fixture.queue_ok();
    fixture.repository.load(false).unwrap();
    fixture.advance(GalleryRepository::CACHE_MILLISECONDS - 1);
    assert!(!fixture.repository.load(false).unwrap().is_offline);
    assert_eq!(fixture.requests().len(), 1);

    fixture.advance(1);
    fixture.queue_ok();
    fixture.repository.load(false).unwrap();
    assert_eq!(fixture.requests().len(), 2);

    fixture.queue_ok();
    fixture.repository.load(true).unwrap();
    assert_eq!(fixture.requests().len(), 3);

    // A cache from the future (the clock was set back) is not fresh.
    fixture.advance(-60_000);
    fixture.queue_ok();
    fixture.repository.load(false).unwrap();
    assert_eq!(fixture.requests().len(), 4);
}

#[test]
fn cache_survives_a_new_repository_instance() {
    let fixture = Fixture::new();
    fixture.queue_ok();
    let first = fixture.repository.load(false).unwrap();
    let second = Fixture::repository(&Arc::new(FakeTransport::default()), &fixture.cache, &fixture.clock).load(false).unwrap();
    assert_eq!(first.index, second.index);
    assert!(!second.is_offline);
    assert_eq!(tree(&fixture.cache), ["index.json", "metadata.json"]);
    assert_eq!(support::mode(&fixture.cache.join("index.json")), 0o600);
}

#[test]
fn without_a_cache_a_network_failure_is_reported() {
    let fixture = Fixture::new();
    assert_kind(GalleryErrorKind::Network, fixture.repository.load(false));
    assert_eq!(tree(&fixture.cache), [] as [&str; 0]);
}

#[test]
fn an_index_served_after_a_redirect_off_host_is_neither_used_nor_cached() {
    let fixture = Fixture::new();
    let source = checked_in_index();
    fixture.transport.queue(move || Ok(GalleryResponse::new(200, source.clone(), &[], "https://evil.example/Gallery/index.json")));
    let error = assert_kind(GalleryErrorKind::Network, fixture.repository.load(false));
    assert!(error.message.contains("untrusted host"));
    assert_eq!(tree(&fixture.cache), [] as [&str; 0]);
}

#[test]
fn an_invalid_index_is_neither_used_nor_cached() {
    let fixture = Fixture::new();
    fixture.queue(200, b"{\"schemaVersion\":1}", &[("ETag", "gallery-v1")]);
    assert_kind(GalleryErrorKind::InvalidIndex, fixture.repository.load(false));
    assert_eq!(tree(&fixture.cache), [] as [&str; 0]);

    // With a validated cache, the invalid response is ignored and the cache is shown as offline.
    fixture.queue_ok();
    let online = fixture.repository.load(true).unwrap();
    fixture.queue(200, b"[]", &[("ETag", "gallery-v2")]);
    let fallback = fixture.repository.load(true).unwrap();
    assert!(fallback.is_offline);
    assert_eq!(fallback.index, online.index);
    assert_eq!(decode(&std::fs::read(fixture.cache.join("index.json")).unwrap()).unwrap(), online.index);

    // An index of a schema this program does not know is not shown either: it fails closed.
    let mut future: serde_json::Value = serde_json::from_slice(&checked_in_index()).unwrap();
    future["schemaVersion"] = serde_json::json!(2);
    fixture.queue(200, future.to_string().as_bytes(), &[]);
    assert!(fixture.repository.load(true).unwrap().is_offline);
}

#[test]
fn error_and_rate_limit_statuses_are_reported_not_accepted() {
    let fixture = Fixture::new();
    let source = checked_in_index();
    fixture.queue(403, &source, &[("x-ratelimit-remaining", "0")]);
    assert!(assert_kind(GalleryErrorKind::Network, fixture.repository.load(false)).message.contains("rate limit reached"));
    fixture.queue(429, &source, &[]);
    assert!(assert_kind(GalleryErrorKind::Network, fixture.repository.load(false)).message.contains("temporarily limited"));
    fixture.queue(500, &source, &[]);
    assert!(assert_kind(GalleryErrorKind::Network, fixture.repository.load(false)).message.contains("HTTP 500"));
    // A 304 without a cache is not content either.
    fixture.queue(304, b"", &[]);
    assert_kind(GalleryErrorKind::Network, fixture.repository.load(false));
    assert_eq!(tree(&fixture.cache), [] as [&str; 0]);
}

#[test]
fn a_tampered_cache_is_never_trusted() {
    let fixture = Fixture::new();
    fixture.queue_ok();
    fixture.repository.load(false).unwrap();
    std::fs::write(fixture.cache.join("index.json"), "{\"schemaVersion\":1,\"futureField\":true}").unwrap();
    // Fresh by age, but no longer valid: a request is made, and with the network down nothing is shown.
    assert_kind(GalleryErrorKind::Network, fixture.repository.load(false));
    assert_eq!(fixture.requests().len(), 2);
    assert_eq!(fixture.requests()[1].header("If-None-Match"), None);
}

#[test]
fn a_cache_file_that_is_a_link_is_not_read() {
    let fixture = Fixture::new();
    fixture.queue_ok();
    fixture.repository.load(false).unwrap();
    let outside = fixture.temporary.path("outside.json");
    std::fs::rename(fixture.cache.join("index.json"), &outside).unwrap();
    symlink(&fixture.cache.join("index.json"), &outside);
    assert_kind(GalleryErrorKind::Network, fixture.repository.load(false));
    assert_eq!(fixture.requests().len(), 2);
}

#[test]
fn an_untrusted_index_url_is_refused_without_a_request() {
    let fixture = Fixture::new();
    for bad in ["http://raw.githubusercontent.com/a/index.json", "https://example.com/index.json", "https://raw.githubusercontent.com/a/index.json?ref=x", "https://127.0.0.1/index.json"] {
        let untrusted = GalleryRepository::new(fixture.transport.clone(), GalleryIndexCache::new(&fixture.cache)).with_index_url(bad);
        assert_kind(GalleryErrorKind::InvalidIndex, untrusted.load(false));
    }
    assert!(fixture.requests().is_empty());
}

// The production transport over a stand-in for the socket layer

/// Answers each URL with a status, a `Location` or a body, and records the URLs it was asked for.
#[derive(Default)]
struct Wire {
    routes: Mutex<Vec<(String, u16, String)>>,
    asked: Mutex<Vec<String>>,
}

impl Transport for Wire {
    fn send(&self, request: &TransportRequest<'_>, _: &Wait) -> Result<TransportResponse, FetchError> {
        self.asked.lock().unwrap().push(request.url.to_string());
        assert_eq!(request.method, "GET");
        assert!(request.body.is_none());
        let route = self.routes.lock().unwrap().iter().find(|(url, _, _)| url == request.url.as_str()).cloned();
        let (_, status, content) = route.ok_or_else(|| FetchError::Transport("connection refused by the test".into()))?;
        let redirect = (300..400).contains(&status);
        let body: Box<dyn Read> = Box::new(std::io::Cursor::new(if redirect { Vec::new() } else { content.clone().into_bytes() }));
        Ok(TransportResponse { status, headers: if redirect { vec![("Location".into(), content)] } else { vec![("ETag".into(), "\"v1\"".into())] }, body })
    }
}

fn production(addresses: &'static [&'static str]) -> (FetchGalleryTransport, Arc<Wire>, Arc<Mutex<Vec<String>>>) {
    let wire = Arc::new(Wire::default());
    let resolved: Arc<Mutex<Vec<String>>> = Arc::default();
    let seen = resolved.clone();
    let resolver: Resolver = Arc::new(move |host: &str| {
        seen.lock().unwrap().push(host.to_owned());
        Ok(addresses.iter().map(|address| address.parse::<IpAddr>().unwrap()).collect())
    });
    (FetchGalleryTransport::with_fetch(FetchModule::with_parts(resolver, wire.clone())), wire, resolved)
}

fn get(transport: &FetchGalleryTransport, url: &str) -> Result<GalleryResponse, sw_core::gallery::GalleryError> {
    transport.fetch(&GalleryRequest { url: url.into(), headers: vec![("User-Agent".into(), GalleryRepository::USER_AGENT.into())], timeout_milliseconds: 5_000 })
}

#[test]
fn the_production_transport_follows_redirects_only_within_the_trusted_host() {
    let raw = "https://raw.githubusercontent.com";
    let (transport, wire, resolved) = production(&["185.199.108.133"]);
    let route = |from: &str, status: u16, content: &str| wire.routes.lock().unwrap().push((from.to_owned(), status, content.to_owned()));
    route(&format!("{raw}/a/index.json"), 200, "direct");
    route(&format!("{raw}/moved"), 302, "/a/index.json");
    route(&format!("{raw}/off-host"), 302, "https://evil.example/index.json");
    route("https://evil.example/index.json", 200, "evil");
    route(&format!("{raw}/to-query"), 301, "/a/index.json?token=1");
    route(&format!("{raw}/to-http"), 302, "http://raw.githubusercontent.com/a/index.json");
    route(&format!("{raw}/to-port"), 302, "https://raw.githubusercontent.com:8443/a/index.json");
    route(&format!("{raw}/missing"), 404, "Not Found");

    let direct = get(&transport, &format!("{raw}/a/index.json")).unwrap();
    assert_eq!((direct.status, direct.body.as_slice(), direct.final_url.as_str(), direct.header("etag")), (200, &b"direct"[..], "https://raw.githubusercontent.com/a/index.json", Some("\"v1\"")));
    let moved = get(&transport, &format!("{raw}/moved")).unwrap();
    assert_eq!((moved.body.as_slice(), moved.final_url.as_str()), (&b"direct"[..], "https://raw.githubusercontent.com/a/index.json"));
    // An error status is a response: the caller decides, and never takes it for content.
    assert_eq!(get(&transport, &format!("{raw}/missing")).unwrap().status, 404);

    for start in ["off-host", "to-query", "to-http", "to-port"] {
        let error = assert_kind(GalleryErrorKind::Network, get(&transport, &format!("{raw}/{start}")));
        assert!(error.message.contains("Redirect target is not allowed"), "{start}: {}", error.message);
    }
    let asked = wire.asked.lock().unwrap().clone();
    assert!(asked.iter().all(|url| url.starts_with("https://raw.githubusercontent.com/") && !url.contains('?')), "{asked:?}");
    assert!(resolved.lock().unwrap().iter().all(|host| host == "raw.githubusercontent.com"));

    // What the system says about a socket is not passed on.
    let error = assert_kind(GalleryErrorKind::Network, get(&transport, &format!("{raw}/unrouted")));
    assert_eq!(error.message, "GitHub could not be reached.");
}

#[test]
fn the_production_transport_refuses_a_host_that_resolves_to_a_private_address() {
    for addresses in [&["127.0.0.1"][..], &["10.0.0.7"], &["185.199.108.133", "192.168.1.10"], &["::1"], &["169.254.169.254"]] {
        let addresses: &'static [&'static str] = Box::leak(addresses.to_vec().into_boxed_slice());
        let (transport, wire, _) = production(addresses);
        wire.routes.lock().unwrap().push(("https://raw.githubusercontent.com/a".into(), 200, "local".into()));
        assert_kind(GalleryErrorKind::Network, get(&transport, "https://raw.githubusercontent.com/a"));
        assert!(wire.asked.lock().unwrap().is_empty(), "{addresses:?}");
    }
}
