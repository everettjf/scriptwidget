//! `$weather`: options, provider normalisation, the cache and the policy
//! order. Ported from
//! `Windows/tests/ScriptWidget.Core.Tests/Api/WeatherModuleTests.cs`.

mod api_common;

use std::path::PathBuf;
use std::sync::atomic::{AtomicI64, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};

use api_common::*;
use serde_json::{Value, json};
use sw_core::NativeModule;
use sw_core::api::fetch::{Cancel, FetchModule, Url};
use sw_core::api::support::{CallContext, SystemReject, canonical, iso_dates, system_log};
use sw_core::api::weather::{FetchWeatherTransport, WeatherModule, WeatherOptions, WeatherResponse, WeatherTransport, WeatherTransportError, weather_rules};
use sw_core::json::{Object, stringify_object};

const OWNER: &str = "11111111-1111-4111-8111-111111111111";
const OTHER_OWNER: &str = "22222222-2222-4222-8222-222222222222";
const DECLARED: &[&str] = &["weather", "network"];
const DOMAINS: &[&str] = &["api.met.no"];

/// A recorded response for lat=59.91&lon=10.75: 85 entries from
/// 2026-11-13T07:00:00Z, hourly for 53 hours and without `next_1_hours` after that.
fn recorded() -> Vec<u8> {
    std::fs::read(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/api_fixtures/met-norway-compact.json")).expect("fixture")
}

#[derive(Default)]
struct State {
    status: u16,
    body: Vec<u8>,
    urls: Vec<String>,
    agents: Vec<Option<String>>,
    timeout: u64,
    fail: bool,
    redirect: Option<Url>,
    redirect_allowed: Option<bool>,
}

struct FakeWeather(Mutex<State>);

impl WeatherTransport for FakeWeather {
    fn get(&self, url: &str, headers: &[(String, String)], timeout_milliseconds: u64, allow_redirect: &dyn Fn(&Url) -> bool, _: Option<Cancel>) -> Result<WeatherResponse, WeatherTransportError> {
        let mut state = self.0.lock().unwrap();
        state.urls.push(url.to_owned());
        state.agents.push(headers.iter().find(|(name, _)| name == "User-Agent").map(|(_, value)| value.clone()));
        state.timeout = timeout_milliseconds;
        if let Some(target) = state.redirect.clone() {
            state.redirect_allowed = Some(allow_redirect(&target));
        }
        if state.fail {
            return Err(WeatherTransportError);
        }
        Ok(WeatherResponse { status: state.status, body: state.body.clone() })
    }
}

struct Fixture {
    now: Arc<AtomicI64>,
    directory: PathBuf,
    transport: Arc<FakeWeather>,
    module: WeatherModule,
}

impl Fixture {
    fn new() -> Self {
        let now = Arc::new(AtomicI64::new(iso_dates::parse("2026-11-13T07:30:00Z").unwrap()));
        let directory = temporary_directory("weather");
        let transport = Arc::new(FakeWeather(Mutex::new(State { status: 200, body: recorded(), ..State::default() })));
        let clock = now.clone();
        let module = WeatherModule::with_clock(transport.clone(), &directory, WeatherModule::user_agent("1.1.0"), Arc::new(move || clock.load(Ordering::SeqCst)));
        Self { now, directory, transport, module }
    }

    fn now(&self) -> i64 {
        self.now.load(Ordering::SeqCst)
    }

    fn advance(&self, milliseconds: i64) {
        self.now.fetch_add(milliseconds, Ordering::SeqCst);
    }

    fn state(&self) -> std::sync::MutexGuard<'_, State> {
        self.transport.0.lock().unwrap()
    }

    fn urls(&self) -> usize {
        self.state().urls.len()
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}

/// A call context with adjustable budgets.
fn context(permissions: &[&str], domains: &[&str], installation: &str, queries: u32, network: u32) -> CallContext {
    let (used_queries, used_network) = (AtomicU32::new(0), AtomicU32::new(0));
    CallContext::new(installation, true, permissions, domains, Some("1.6")).with_probes(
        move || used_queries.fetch_add(1, Ordering::SeqCst) < queries,
        move || used_network.fetch_add(1, Ordering::SeqCst) < network,
        || true,
    )
}

fn widget() -> CallContext {
    context(DECLARED, DOMAINS, OWNER, 8, 32)
}

fn options(value: Value) -> Object {
    value.as_object().cloned().expect("options")
}

fn oslo(hours: Option<i64>) -> Object {
    let mut options = options(json!({ "latitude": 59.91, "longitude": 10.75 }));
    if let Some(hours) = hours {
        options.insert("hours".into(), json!(hours));
    }
    options
}

fn with(mut target: Object, name: &str, value: Value) -> Object {
    target.insert(name.into(), value);
    target
}

fn rejects<T: std::fmt::Debug>(code: &str, result: Result<T, SystemReject>) {
    match result {
        Err(error) => assert_eq!(system_log::code(&error.0), code, "{}", error.0),
        Ok(value) => panic!("expected [{code}], got {value:?}"),
    }
}

fn series(items: &[Value]) -> Vec<u8> {
    json!({ "properties": { "timeseries": items } }).to_string().into_bytes()
}

fn entry(time: &str, details: Value, next: Option<Value>) -> Value {
    let mut data = json!({ "instant": { "details": details } });
    if let Some(next) = next {
        data["next_1_hours"] = next;
    }
    json!({ "time": time, "data": data })
}

fn details() -> Value {
    json!({ "air_temperature": 1.5, "wind_speed": 2.0 })
}

fn hours(result: &Object) -> &Vec<Value> {
    result["hours"].as_array().expect("hours")
}

fn keys(value: &Value) -> Vec<&str> {
    value.as_object().unwrap().keys().map(String::as_str).collect()
}

#[test]
fn option_validation_and_rounding() {
    let parsed = WeatherOptions::parse(&options(json!({ "latitude": 37.3349, "longitude": -122.00902 }))).unwrap();
    assert_eq!((parsed.latitude, parsed.longitude, parsed.hours), (37.33, -122.01, 24));
    assert_eq!(parsed.url(), "https://api.met.no/weatherapi/locationforecast/2.0/compact?lat=37.33&lon=-122.01");
    // Halves round away from zero, and whole numbers keep one decimal in the URL.
    assert_eq!(WeatherOptions::round2(0.125), 0.13);
    assert_eq!(WeatherOptions::round2(-0.125), -0.13);
    assert_eq!(WeatherOptions::parse(&options(json!({ "latitude": 60, "longitude": -180 }))).unwrap().url(), "https://api.met.no/weatherapi/locationforecast/2.0/compact?lat=60.0&lon=-180.0");
    assert_eq!(WeatherOptions::parse(&oslo(Some(48))).unwrap().hours, 48);
    assert_eq!(WeatherOptions::parse(&oslo(Some(1))).unwrap().hours, 1);
    let bad = [
        options(json!({})),
        options(json!({ "latitude": 59.91 })),
        options(json!({ "longitude": 10.75 })),
        with(oslo(None), "latitude", json!(90.01)),
        with(oslo(None), "latitude", json!(-90.01)),
        with(oslo(None), "longitude", json!(180.5)),
        with(oslo(None), "longitude", json!(-181)),
        with(oslo(None), "latitude", json!("59.91")),
        with(oslo(None), "latitude", json!(true)),
        with(oslo(None), "latitude", Value::Null),
        oslo(Some(0)),
        oslo(Some(49)),
        with(oslo(None), "hours", json!(1.5)),
        with(oslo(None), "hours", json!("24")),
        with(oslo(None), "hours", Value::Null),
        with(oslo(None), "units", json!("imperial")),
        options(json!({ "invalid": true })),
        with(oslo(None), "padding", json!("x".repeat(17_000))),
    ];
    for item in &bad {
        rejects("invalid_options", WeatherOptions::parse(item));
    }
}

#[test]
fn normalizes_a_recorded_met_norway_payload() {
    let now = iso_dates::parse("2026-11-13T07:30:00Z").unwrap();
    let result = weather_rules::normalize(&recorded(), &WeatherOptions::parse(&oslo(None)).unwrap(), now).unwrap();
    assert_eq!(result.keys().map(String::as_str).collect::<Vec<_>>(), ["provider", "attribution", "latitude", "longitude", "fetchedAt", "isStale", "hours"]);
    assert_eq!(result["provider"], "MET Norway");
    assert_eq!(result["attribution"].to_string(), r#"{"text":"Weather data from MET Norway","url":"https://www.met.no/en/free-meteorological-data/Download-services"}"#);
    assert_eq!((result["latitude"].as_f64(), result["longitude"].as_f64()), (Some(59.91), Some(10.75)));
    assert_eq!(result["fetchedAt"], "2026-11-13T07:30:00Z");
    assert_eq!(result["isStale"], false);
    assert_eq!(hours(&result).len(), 24);
    let first = &hours(&result)[0];
    assert_eq!(keys(first), ["time", "temperatureC", "windMetersPerSecond", "precipitationMM", "condition"]);
    assert_eq!(first["time"], "2026-11-13T07:00:00Z");
    assert_eq!((first["temperatureC"].as_f64(), first["windMetersPerSecond"].as_f64(), first["precipitationMM"].as_f64()), (Some(1.7), Some(3.0), Some(0.0)));
    assert_eq!(first["condition"], "fair_day");
    assert_eq!(hours(&result)[23]["time"], "2026-11-14T06:00:00Z");

    // Entries more than an hour old are skipped; the rest keep their order.
    let later = weather_rules::normalize(&recorded(), &WeatherOptions::parse(&oslo(Some(48))).unwrap(), iso_dates::parse("2026-11-13T17:30:00Z").unwrap()).unwrap();
    assert_eq!(hours(&later).len(), 48);
    assert_eq!(hours(&later)[0]["time"], "2026-11-13T17:00:00Z");
    // After the hourly part the provider has no next-hour data: both fields stay null.
    assert!(!hours(&later)[42]["condition"].is_null());
    assert_eq!(hours(&later)[43]["time"], "2026-11-15T12:00:00Z");
    for row in &hours(&later)[43..=47] {
        assert_eq!((row.get("precipitationMM"), row.get("condition")), (Some(&Value::Null), Some(&Value::Null)));
    }
    assert_eq!(hours(&weather_rules::normalize(&recorded(), &WeatherOptions::parse(&oslo(Some(1))).unwrap(), now).unwrap()).len(), 1);
    // A forecast that is entirely in the past has no usable row.
    rejects("unavailable", weather_rules::normalize(&recorded(), &WeatherOptions::parse(&oslo(None)).unwrap(), iso_dates::parse("2026-12-24T00:00:00Z").unwrap()));
}

#[test]
fn normalization_bounds() {
    let now = iso_dates::parse("2026-11-13T07:30:00Z").unwrap();
    let query = WeatherOptions::parse(&oslo(None)).unwrap();
    let normalize = |body: &[u8]| weather_rules::normalize(body, &query, now);
    for body in ["not json", "[]", "{}", r#"{"properties":{}}"#, r#"{"properties":{"timeseries":{}}}"#, r#"{"properties":{"timeseries":[1]}}"#, r#"{"properties":{"timeseries":[]}}"#] {
        rejects("unavailable", normalize(body.as_bytes()));
    }
    // A repeated member name makes the document ambiguous: it is refused, not half read.
    rejects("unavailable", normalize(br#"{"properties":{"timeseries":[]},"properties":{"timeseries":[]}}"#));
    let good = entry("2026-11-13T08:00:00Z", details(), None).to_string();
    rejects("unavailable", normalize(format!(r#"{{"properties":{{"timeseries":[]}},"properties":{{"timeseries":[{good}]}}}}"#).as_bytes()));
    assert_eq!(hours(&normalize(format!(r#"{{"properties":{{"timeseries":[{good}]}}}}"#).as_bytes()).unwrap()).len(), 1);
    rejects("unavailable", normalize(&vec![b' '; weather_rules::MAXIMUM_RESPONSE_BYTES + 1]));
    let many = |count: usize| series(&vec![entry("2026-11-13T08:00:00Z", details(), None); count]);
    rejects("unavailable", normalize(&many(301)));
    assert_eq!(hours(&normalize(&many(300)).unwrap()).len(), 24);
    // Entries without a usable time or instant details are skipped, not fatal.
    let skipped = normalize(&series(&[
        json!({ "time": 5 }),
        json!({ "time": "2026-11-13T08:00" }),
        json!({ "time": "2026-11-13T08:00:00Z" }),
        json!({ "time": "2026-11-13T08:00:00Z", "data": { "instant": {} } }),
        entry("2026-11-13T06:29:59Z", details(), None),
        entry("2026-11-13T06:30:00Z", json!({ "air_temperature": -40, "wind_speed": 0 }), None),
    ]))
    .unwrap();
    assert_eq!(hours(&skipped).len(), 1);
    assert_eq!(hours(&skipped)[0]["temperatureC"].as_f64(), Some(-40.0));
    // Values outside the physical bounds reject the payload.
    let out_of_bounds = [
        json!({ "air_temperature": 100.1, "wind_speed": 2.0 }),
        json!({ "air_temperature": -150.5, "wind_speed": 2.0 }),
        json!({ "wind_speed": 2.0 }),
        json!({ "air_temperature": "1", "wind_speed": 2.0 }),
        json!({ "air_temperature": 1.5, "wind_speed": -0.1 }),
        json!({ "air_temperature": 1.5, "wind_speed": 200.5 }),
        json!({ "air_temperature": 1.5 }),
    ];
    for bad in out_of_bounds {
        rejects("invalid_options", normalize(&series(&[entry("2026-11-13T08:00:00Z", bad, None)])));
    }
    let next = |amount: Option<Value>, symbol: Option<Value>| {
        let mut next = json!({});
        if let Some(amount) = amount {
            next["details"] = json!({ "precipitation_amount": amount });
        }
        if let Some(symbol) = symbol {
            next["summary"] = json!({ "symbol_code": symbol });
        }
        Some(next)
    };
    let one = |next: Option<Value>| normalize(&series(&[entry("2026-11-13T08:00:00Z", details(), next)]));
    rejects("invalid_options", one(next(Some(json!(1000.5)), None)));
    rejects("invalid_options", one(next(Some(json!(-1)), None)));
    rejects("invalid_options", one(next(Some(Value::Null), None)));
    let row = hours(&one(next(Some(json!(1000)), Some(json!("x".repeat(70))))).unwrap())[0].clone();
    assert_eq!(row["precipitationMM"].as_f64(), Some(1000.0));
    assert_eq!(row["condition"], "x".repeat(64));
    let untyped = hours(&one(next(None, Some(json!(7)))).unwrap())[0].clone();
    assert!(untyped["precipitationMM"].is_null() && untyped["condition"].is_null());
    // A condition is cut by characters, never through the middle of one.
    let emoji = hours(&one(next(None, Some(json!("🌧".repeat(70))))).unwrap())[0].clone();
    assert_eq!(emoji["condition"], "🌧".repeat(64));
}

#[test]
fn cache_freshness_rules() {
    let now = iso_dates::parse("2026-11-13T07:30:00Z").unwrap();
    let query = WeatherOptions::parse(&oslo(None)).unwrap();
    let fetched = stringify_object(&weather_rules::normalize(&recorded(), &query, now).unwrap());
    let cached = |age: i64, query: &WeatherOptions| weather_rules::from_cache(Some(&fetched), query, now + age);
    assert_eq!(cached(0, &query).unwrap()["isStale"], false);
    assert_eq!(cached(3_599_999, &query).unwrap()["isStale"], false);
    assert_eq!(cached(3_600_000, &query).unwrap()["isStale"], true);
    assert_eq!(cached(6 * 3_600_000, &query).unwrap()["isStale"], true);
    assert_eq!(cached(6 * 3_600_000 + 1, &query), None);
    assert_eq!(cached(-1, &query), None, "fetched in the future: the clock moved");
    // Fewer hours are served from a longer cache; more are not.
    assert_eq!(hours(&cached(0, &WeatherOptions::parse(&oslo(Some(6))).unwrap()).unwrap()).len(), 6);
    assert_eq!(cached(0, &WeatherOptions::parse(&oslo(Some(25))).unwrap()), None);
    // Other coordinates never match, even when they are close.
    assert_eq!(cached(0, &WeatherOptions::parse(&with(oslo(None), "latitude", json!(59.92))).unwrap()), None);
    assert_eq!(cached(0, &WeatherOptions::parse(&with(oslo(None), "longitude", json!(-10.75))).unwrap()), None);
    let oversize = "x".repeat(weather_rules::MAXIMUM_CACHE_BYTES + 1);
    let duplicate = fetched.replacen('{', r#"{"latitude":0,"#, 1);
    for text in [None, Some(""), Some("not json"), Some("{}"), Some(r#"{"latitude":59.91,"longitude":10.75,"fetchedAt":"yesterday","hours":[]}"#), Some(oversize.as_str()), Some(duplicate.as_str())] {
        assert_eq!(weather_rules::from_cache(text, &query, now), None);
    }
}

#[test]
fn policy_order() {
    let fixture = Fixture::new();
    let module = &fixture.module;
    let oslo_options = oslo(None);
    let forecast = |context: CallContext| module.forecast(&context, Some(&oslo_options));
    let plain = |permissions: &[&str], domains: &[&str]| context(permissions, domains, OWNER, 8, 32);
    rejects("permission_denied", forecast(plain(&["network"], DOMAINS)));
    let mut old = widget();
    old.minimum_runtime_version = Some("1.5".into());
    rejects("permission_denied", forecast(old));
    let mut legacy = widget();
    legacy.has_manifest = false;
    rejects("permission_denied", forecast(legacy));
    rejects("permission_denied", forecast(context(DECLARED, DOMAINS, "preview", 8, 32)));
    let mut projection = widget();
    projection.is_timeline_projection = true;
    rejects("read_only", forecast(projection));
    let mut live = widget();
    live.is_live_activity = true;
    rejects("read_only", forecast(live));
    rejects("query_limit", forecast(context(DECLARED, DOMAINS, OWNER, 0, 32)));
    // Options are checked before the network declaration.
    rejects("invalid_options", module.forecast(&plain(&["weather"], &[]), Some(&oslo(Some(99)))));
    rejects("invalid_options", module.forecast(&widget(), None));
    rejects("permission_denied", forecast(plain(&["weather"], DOMAINS)));
    rejects("permission_denied", forecast(plain(DECLARED, &[])));
    rejects("permission_denied", forecast(plain(DECLARED, &["met.no", "*.example.com"])));
    rejects("query_limit", forecast(context(DECLARED, DOMAINS, OWNER, 8, 0)));
    assert_eq!(fixture.urls(), 0, "nothing reached the network");
    assert_eq!(hours(&forecast(plain(DECLARED, &["*.met.no"])).unwrap()).len(), 24);
}

#[test]
fn request_shape_and_fresh_cache() {
    let fixture = Fixture::new();
    let module = &fixture.module;
    let first = module.forecast(&widget(), Some(&options(json!({ "latitude": 59.9149, "longitude": 10.7461, "hours": 12 })))).unwrap();
    assert_eq!(fixture.state().urls, ["https://api.met.no/weatherapi/locationforecast/2.0/compact?lat=59.91&lon=10.75"]);
    assert_eq!(fixture.state().agents, [Some("ScriptWidget-Linux/1.1.0 https://github.com/everettjf/scriptwidget".to_owned())]);
    assert_eq!(fixture.state().timeout, 3000);
    assert_eq!(hours(&first).len(), 12);
    assert_eq!(first["isStale"], false);

    // Within the hour the cache answers without a request and without the network budget.
    fixture.advance(3_599_000);
    let second = module.forecast(&context(DECLARED, DOMAINS, OWNER, 8, 0), Some(&oslo(Some(6)))).unwrap();
    assert_eq!(fixture.urls(), 1);
    assert_eq!(hours(&second).len(), 6);
    assert_eq!(second["isStale"], false);
    assert_eq!(second["fetchedAt"], "2026-11-13T07:30:00Z");
    // More hours than were cached, other coordinates and another installation all go to the network.
    module.forecast(&widget(), Some(&oslo(Some(24)))).unwrap();
    assert_eq!(fixture.urls(), 2);
    module.forecast(&widget(), Some(&with(oslo(None), "latitude", json!(60)))).unwrap();
    assert_eq!(fixture.urls(), 3);
    module.forecast(&context(DECLARED, DOMAINS, OTHER_OWNER, 8, 32), Some(&with(oslo(None), "latitude", json!(60)))).unwrap();
    assert_eq!(fixture.urls(), 4);
    assert_eq!(WeatherModule::user_agent(""), "ScriptWidget-Linux/0 https://github.com/everettjf/scriptwidget");
}

#[test]
fn a_stale_cache_stands_in_for_a_failed_request() {
    let fixture = Fixture::new();
    let module = &fixture.module;
    let oslo_options = oslo(None);
    let forecast = || module.forecast(&widget(), Some(&oslo_options));
    forecast().unwrap();
    fixture.advance(3_600_000);
    fixture.state().fail = true;
    let stale = module.forecast(&widget(), Some(&oslo(Some(3)))).unwrap();
    assert_eq!(stale["isStale"], true);
    assert_eq!(hours(&stale).len(), 3);
    assert_eq!(stale["fetchedAt"], "2026-11-13T07:30:00Z");
    assert_eq!(fixture.urls(), 2);
    fixture.state().fail = false;
    for status in [304, 403, 429, 500] {
        fixture.state().status = status;
        assert_eq!(forecast().unwrap()["isStale"], true, "{status}");
    }
    fixture.state().status = 200;
    fixture.state().body = b"{}".to_vec();
    assert_eq!(forecast().unwrap()["isStale"], true);
    // A stale cache is not returned when the network budget is spent: the request was never attempted.
    rejects("query_limit", module.forecast(&context(DECLARED, DOMAINS, OWNER, 8, 0), Some(&oslo_options)));
    fixture.advance(5 * 3_600_000 + 1);
    rejects("unavailable", forecast());
    fixture.state().fail = true;
    rejects("unavailable", forecast());
    // A good response replaces the cache and is fresh again.
    fixture.state().fail = false;
    fixture.state().body = recorded();
    fixture.now.store(iso_dates::parse("2026-11-13T15:00:00Z").unwrap(), Ordering::SeqCst);
    let fresh = forecast().unwrap();
    assert_eq!(fresh["isStale"], false);
    assert_eq!(fresh["fetchedAt"], "2026-11-13T15:00:00Z");
    assert_eq!(fixture.now(), iso_dates::parse("2026-11-13T15:00:00Z").unwrap());
}

#[test]
fn redirects_stay_inside_the_declared_hosts_and_caches_are_retired() {
    use std::os::unix::fs::PermissionsExt;
    let fixture = Fixture::new();
    let module = &fixture.module;
    let oslo_options = oslo(None);
    fixture.state().redirect = Some(url("https://example.com/forecast"));
    module.forecast(&widget(), Some(&oslo_options)).unwrap();
    assert_eq!(fixture.state().redirect_allowed, Some(false));
    fixture.state().redirect = Some(url("https://api.met.no/weatherapi/other"));
    fixture.advance(3_600_000);
    module.forecast(&widget(), Some(&oslo_options)).unwrap();
    assert_eq!(fixture.state().redirect_allowed, Some(true));
    fixture.advance(3_600_000);
    let finished = CallContext::new(OWNER, true, DECLARED, DOMAINS, Some("1.6")).with_probes(|| true, || true, || false);
    module.forecast(&finished, Some(&oslo_options)).unwrap();
    assert_eq!(fixture.state().redirect_allowed, Some(false), "a finished execution follows no redirect");

    let entries: Vec<_> = std::fs::read_dir(&fixture.directory).unwrap().map(|entry| entry.unwrap()).collect();
    let names: Vec<String> = entries.iter().map(|entry| entry.file_name().to_string_lossy().into_owned()).collect();
    assert_eq!(names, [canonical::owner_file_name(OWNER, ".json")]);
    assert!(!names[0].contains(OWNER), "the installation identity is not a file name");
    assert_eq!(entries[0].metadata().unwrap().permissions().mode() & 0o777, 0o600, "the cache is private to the user");
    module.retire(OWNER);
    assert_eq!(std::fs::read_dir(&fixture.directory).unwrap().count(), 0);
    // A cache file that is not a regular bounded file is ignored, never trusted.
    let cache = fixture.directory.join(canonical::owner_file_name(OWNER, ".json"));
    std::fs::write(&cache, "x".repeat(weather_rules::MAXIMUM_CACHE_BYTES + 1)).unwrap();
    fixture.state().fail = true;
    rejects("unavailable", module.forecast(&widget(), Some(&oslo_options)));
    // Nor is a link that someone put in its place.
    fixture.state().fail = false;
    let good = fixture.directory.join("elsewhere.json");
    module.forecast(&widget(), Some(&oslo_options)).unwrap();
    std::fs::rename(&cache, &good).unwrap();
    std::os::unix::fs::symlink(&good, &cache).unwrap();
    fixture.state().fail = true;
    rejects("unavailable", module.forecast(&widget(), Some(&oslo_options)));
}

/// The ISO-8601 reader is written by hand, so its edges are pinned here.
#[test]
fn iso_dates_accept_only_full_instants() {
    assert_eq!(iso_dates::parse("2026-11-12T12:00:00Z"), Some(1_794_484_800_000));
    assert_eq!(iso_dates::parse("2026-11-12T13:00:00+01:00"), Some(1_794_484_800_000));
    assert_eq!(iso_dates::parse("2026-11-12T06:30:00-05:30"), Some(1_794_484_800_000));
    assert_eq!(iso_dates::parse("2026-11-12T12:00:00.123456789Z"), Some(1_794_484_800_123));
    assert_eq!(iso_dates::parse("2026-11-12T12:00:00.5Z"), Some(1_794_484_800_500));
    assert_eq!(iso_dates::parse("1969-12-31T23:59:59Z"), Some(-1000));
    assert_eq!(iso_dates::parse("2024-02-29T00:00:00Z"), Some(1_709_164_800_000));
    assert_eq!(iso_dates::parse("2026-11-17T08:00:00.000Z"), Some(1_794_902_400_000));
    for text in [
        "", "2026-11-12", "2026-11-12T12:00:00", "2026-11-12T12:00Z", "2026-11-12 12:00:00Z", "2026-13-12T12:00:00Z", "2026-02-30T12:00:00Z", "2026-11-12T24:00:00Z", "2026-11-12T12:60:00Z", "2026-11-12T12:00:60Z",
        "2026-11-12T12:00:00+19:00", "2026-11-12T12:00:00+0100", "2026-11-12T12:00:00.Z", "2026-11-12T12:00:00Z\n", " 2026-11-12T12:00:00Z", "2025-02-29T00:00:00Z", "0000-01-01T00:00:00Z", "2026-11-12T12:00:00.1234567890Z",
        "2026-11-12T12:00:00+18:01", "２０２６-11-12T12:00:00Z",
    ] {
        assert_eq!(iso_dates::parse(text), None, "{text:?}");
    }
    assert_eq!(iso_dates::format(1_794_484_800_999), "2026-11-12T12:00:00Z");
    assert_eq!(iso_dates::format(-1), "1969-12-31T23:59:59Z");
    assert_eq!(iso_dates::format(0), "1970-01-01T00:00:00Z");
    assert_eq!(iso_dates::format(951_782_400_000), "2000-02-29T00:00:00Z");
}

/// The operation as the script bridge calls it, and the transport over `fetch`.
#[test]
fn the_operation_resolves_once_and_the_fetch_transport_stays_on_declared_public_hosts() {
    let fixture = Fixture::new();
    let module = &fixture.module;
    let package = |domains: &[&str], package_id: &str| {
        let mut package = Package::with_manifest(json!({ "minimumRuntimeVersion": "1.6", "permissions": DECLARED, "networkDomains": domains }));
        package.package_id = package_id.to_owned();
        package
    };
    let payload = json!({ "options": oslo(Some(2)) });
    assert_eq!(module.apis(), ["$weather"]);
    assert!(module.handles("weather.forecast"));
    assert!(!module.handles("http.request"));

    let lines: Arc<Mutex<Vec<String>>> = Arc::default();
    let sink = lines.clone();
    let previous = system_log::set_sink(Some(Arc::new(move |line: &str| sink.lock().unwrap().push(line.to_owned()))));
    let (ok, resolved) = start(module, &package(DOMAINS, OWNER).request(), "weather.forecast", payload.as_object());
    assert!(ok);
    assert_eq!(resolved["hours"].as_array().unwrap().len(), 2);
    assert_eq!(
        rejection(module, &package(&["example.com"], OTHER_OWNER).request(), "weather.forecast", &payload),
        "[permission_denied] System operation could not complete. Existing user data is preserved."
    );
    assert_eq!(rejection(module, &package(DOMAINS, OWNER).request(), "weather.other", &payload), "Unsupported operation weather.other");
    // An installed package without the runtime version in its manifest is refused too.
    let mut unversioned = Package::with_manifest(json!({ "permissions": DECLARED, "networkDomains": DOMAINS }));
    unversioned.package_id = OWNER.to_owned();
    assert!(rejection(module, &unversioned.request(), "weather.forecast", &payload).starts_with("[permission_denied]"));
    system_log::set_sink(previous);
    {
        let lines = lines.lock().unwrap();
        assert!(lines.contains(&"weather.forecast -> ok".to_owned()), "{lines:?}");
        assert!(lines.contains(&"weather.forecast -> permission_denied".to_owned()), "{lines:?}");
        assert!(!lines.iter().any(|line| line.contains("59.9") || line.contains(OWNER)), "{lines:?}");
    }

    // The real transport: the forecast host must resolve to a public address, and a redirect must stay declared.
    let location: Arc<Mutex<String>> = Arc::new(Mutex::new("https://api.met.no/weatherapi/locationforecast/2.0/moved".into()));
    let address: Arc<Mutex<String>> = Arc::new(Mutex::new("157.249.81.141".into()));
    let (target, body) = (location.clone(), recorded());
    let exchange = FakeTransport::new(move |request| if request.path().ends_with("/compact") { FakeResponse::redirect(307, Some(&target.lock().unwrap())) } else { FakeResponse::bytes(200, &body) });
    let answer = address.clone();
    let fetch = FetchModule::with_parts(Arc::new(move |_| Ok(addresses(&[answer.lock().unwrap().as_str()]))), exchange.clone());
    let now = fixture.now.clone();
    let online = WeatherModule::with_clock(Arc::new(FetchWeatherTransport::new(Arc::new(fetch))), fixture.directory.join("fetch"), WeatherModule::user_agent("1.0"), Arc::new(move || now.load(Ordering::SeqCst)));
    let oslo_options = oslo(None);
    assert_eq!(hours(&online.forecast(&widget(), Some(&oslo_options)).unwrap()).len(), 24);
    let requests = exchange.requests();
    assert_eq!(requests.iter().map(|request| request.url.as_str()).collect::<Vec<_>>(), ["https://api.met.no/weatherapi/locationforecast/2.0/compact?lat=59.91&lon=10.75", "https://api.met.no/weatherapi/locationforecast/2.0/moved"]);
    assert_eq!(requests[0].header("User-Agent"), Some("ScriptWidget-Linux/1.0 https://github.com/everettjf/scriptwidget"));
    let other = || context(DECLARED, DOMAINS, OTHER_OWNER, 8, 32);
    *location.lock().unwrap() = "https://example.com/forecast".into();
    rejects("unavailable", online.forecast(&other(), Some(&oslo_options)));
    *location.lock().unwrap() = "http://127.0.0.1/forecast".into();
    rejects("unavailable", online.forecast(&other(), Some(&oslo_options)));
    *address.lock().unwrap() = "10.0.0.9".into();
    exchange.clear();
    rejects("unavailable", online.forecast(&other(), Some(&oslo_options)));
    assert_eq!(exchange.count(), 0);
}
