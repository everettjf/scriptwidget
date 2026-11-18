//! `$weather.forecast`: MET Norway's compact forecast for coordinates the
//! script supplies. Ported from
//! `Windows/src/ScriptWidget.Core/Api/WeatherModule.cs`.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

use crate::api::fetch::{Cancel, FetchError, FetchModule, Url, validation_error};
use crate::api::support::{CallContext, PrivateFile, SystemReject, SystemServiceError, canonical, iso_dates, run_system, system_gate, system_log, system_options};
use crate::executor::{Completion, ExecutionRequest, NativeModule};
use crate::json::{Object, ObjectExt, quote, stringify_object};
use crate::plugins::strict_json;

/// `$weather.forecast(options)` input.
///
/// Rules: closed fields (`latitude`, `longitude`, `hours`); latitude −90…90
/// and longitude −180…180, rounded to two decimals before anything leaves the
/// device; `hours` an integer 1…48, 24 when absent.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct WeatherOptions {
    pub latitude: f64,
    pub longitude: f64,
    pub hours: usize,
}

impl WeatherOptions {
    pub const HOST: &'static str = "api.met.no";

    /// The MET Norway compact forecast for the rounded coordinates.
    pub fn url(&self) -> String {
        format!("https://{}/weatherapi/locationforecast/2.0/compact?lat={}&lon={}", Self::HOST, decimal(self.latitude), decimal(self.longitude))
    }

    /// Rejects with `invalid_options` for any violation of the rules above.
    pub fn parse(options: &Object) -> Result<Self, SystemReject> {
        system_options::fields(options, &["latitude", "longitude", "hours"])?;
        let latitude = Self::round2(system_options::number(options.get("latitude"), -90.0, 90.0)?);
        let longitude = Self::round2(system_options::number(options.get("longitude"), -180.0, 180.0)?);
        let hours = if options.has("hours") { system_options::integer(options.get("hours"), 1, 48)? as usize } else { 24 };
        Ok(Self { latitude, longitude, hours })
    }

    /// Two decimals, halves away from zero, as `rounded()` does in the Apple runtime.
    pub fn round2(value: f64) -> f64 {
        let scaled = value * 100.0;
        (if scaled < 0.0 { -(-scaled + 0.5).floor() } else { (scaled + 0.5).floor() }) / 100.0
    }
}

/// Shortest decimal text with at least one decimal place (`60.0`), the form every platform puts in the URL.
fn decimal(value: f64) -> String {
    let text = value.to_string();
    if text.contains('.') { text } else { format!("{text}.0") }
}

/// Pure rules of `$weather`: provider normalisation and the private cache.
pub mod weather_rules {
    use super::*;

    pub const MAXIMUM_RESPONSE_BYTES: usize = 2 * 1024 * 1024;
    pub const MAXIMUM_SERIES: usize = 300;
    pub const MAXIMUM_CACHE_BYTES: usize = 128 * 1024;
    /// A matching cache younger than this is returned without a request.
    pub const FRESH_MILLISECONDS: i64 = 3_600_000;
    /// A matching cache up to this age may stand in for a failed request, marked `isStale`.
    pub const USABLE_MILLISECONDS: i64 = 6 * 3_600_000;
    pub const PROVIDER: &str = "MET Norway";
    pub const ATTRIBUTION_TEXT: &str = "Weather data from MET Norway";
    pub const ATTRIBUTION_URL: &str = "https://www.met.no/en/free-meteorological-data/Download-services";

    fn text(value: Option<&Value>) -> Option<&str> {
        value.and_then(Value::as_str)
    }

    /// Turns a MET Norway compact forecast into the documented result.
    ///
    /// - The body is at most 2 MiB and `properties.timeseries` is an array of
    ///   at most 300 objects, else `unavailable`. A document with a repeated
    ///   member name does not say one thing, so it says nothing.
    /// - Entries older than one hour before `now_milliseconds`, or without a
    ///   time and instant details, are skipped.
    /// - `air_temperature` must be −150…100 and `wind_speed` 0…200; a present
    ///   `precipitation_amount` must be 0…1000. A violation rejects the whole
    ///   payload (`invalid_options`, the Apple runtime's code).
    /// - Missing precipitation and condition stay null; a condition is cut to 64 characters.
    /// - At most `options.hours` rows; no usable row is `unavailable`.
    pub fn normalize(body: &[u8], options: &WeatherOptions, now_milliseconds: i64) -> Result<Object, SystemReject> {
        let unavailable = || SystemServiceError::Unavailable.reject();
        if body.len() > MAXIMUM_RESPONSE_BYTES {
            return Err(unavailable());
        }
        let document = strict_json::parse(&String::from_utf8_lossy(body), false).map_err(|_| unavailable())?;
        let series = document.as_object().and_then(|root| root.opt_object("properties")).and_then(|properties| properties.opt_array("timeseries")).ok_or_else(unavailable)?;
        if series.len() > MAXIMUM_SERIES || series.iter().any(|item| !item.is_object()) {
            return Err(unavailable());
        }
        let mut rows: Vec<Value> = Vec::new();
        for item in series.iter().filter_map(Value::as_object) {
            let Some(time) = text(item.get("time")) else { continue };
            let date = if time.trim().is_empty() || system_options::has_control_characters(time) { None } else { iso_dates::parse(time) };
            if !date.is_some_and(|instant| instant >= now_milliseconds - 3_600_000) {
                continue;
            }
            let Some(values) = item.opt_object("data") else { continue };
            let Some(details) = values.opt_object("instant").and_then(|instant| instant.opt_object("details")) else { continue };
            let temperature = system_options::number(details.get("air_temperature"), -150.0, 100.0)?;
            let wind = system_options::number(details.get("wind_speed"), 0.0, 200.0)?;
            let next = values.opt_object("next_1_hours");
            let precipitation = match next.and_then(|next| next.opt_object("details")) {
                Some(next_details) if next_details.has("precipitation_amount") => Some(system_options::number(next_details.get("precipitation_amount"), 0.0, 1000.0)?),
                _ => None,
            };
            let symbol = text(next.and_then(|next| next.opt_object("summary")).and_then(|summary| summary.get("symbol_code")));
            rows.push(json!({
                "time": time,
                "temperatureC": temperature,
                "windMetersPerSecond": wind,
                "precipitationMM": precipitation,
                "condition": symbol.map(|symbol| symbol.chars().take(64).collect::<String>()),
            }));
            if rows.len() == options.hours {
                break;
            }
        }
        if rows.is_empty() {
            return Err(unavailable());
        }
        let result = json!({
            "provider": PROVIDER,
            "attribution": { "text": ATTRIBUTION_TEXT, "url": ATTRIBUTION_URL },
            "latitude": options.latitude,
            "longitude": options.longitude,
            "fetchedAt": iso_dates::format(now_milliseconds),
            "isStale": false,
            "hours": rows,
        });
        match result {
            Value::Object(result) => Ok(result),
            _ => Err(unavailable()),
        }
    }

    /// A cached forecast that may answer `options`, or `None`.
    ///
    /// It matches only when the rounded coordinates are equal, `fetchedAt` is
    /// not in the future and at most six hours old, and it holds at least the
    /// requested number of hours. The result carries the first
    /// `options.hours` rows and `isStale` (true from one hour of age).
    pub fn from_cache(stored: Option<&str>, options: &WeatherOptions, now_milliseconds: i64) -> Option<Object> {
        let stored = stored.filter(|stored| stored.len() <= MAXIMUM_CACHE_BYTES)?;
        let Ok(Value::Object(mut cached)) = strict_json::parse(stored, false) else { return None };
        if system_options::json_number(cached.get("latitude")) != Some(options.latitude) || system_options::json_number(cached.get("longitude")) != Some(options.longitude) {
            return None;
        }
        let fetched = iso_dates::parse(text(cached.get("fetchedAt"))?)?;
        let age = now_milliseconds - fetched;
        let hours = cached.opt_array("hours")?;
        if !(0..=USABLE_MILLISECONDS).contains(&age) || hours.len() < options.hours {
            return None;
        }
        let rows: Vec<Value> = hours[..options.hours].to_vec();
        cached.insert("hours".into(), Value::Array(rows));
        cached.insert("isStale".into(), Value::Bool(age >= FRESH_MILLISECONDS));
        Some(cached)
    }
}

/// A provider response: the HTTP status and the bounded body.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WeatherResponse {
    pub status: u16,
    pub body: Vec<u8>,
}

/// The transport failed; the reason is not passed on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WeatherTransportError;

/// The network side of `$weather`, replaceable in tests.
pub trait WeatherTransport: Send + Sync {
    /// One GET. `allow_redirect` decides for every redirect target; a refused redirect is a failure.
    fn get(&self, url: &str, headers: &[(String, String)], timeout_milliseconds: u64, allow_redirect: &dyn Fn(&Url) -> bool, cancel: Option<Cancel>) -> Result<WeatherResponse, WeatherTransportError>;
}

/// [`WeatherTransport`] over the bounded `fetch` transport: public hosts only, resolved addresses checked, at most 2 MiB.
pub struct FetchWeatherTransport {
    fetch: Arc<FetchModule>,
}

impl FetchWeatherTransport {
    pub fn new(fetch: Arc<FetchModule>) -> Self {
        Self { fetch }
    }
}

impl WeatherTransport for FetchWeatherTransport {
    fn get(&self, url: &str, headers: &[(String, String)], timeout_milliseconds: u64, allow_redirect: &dyn Fn(&Url) -> bool, cancel: Option<Cancel>) -> Result<WeatherResponse, WeatherTransportError> {
        let url = Url::parse(url).map_err(|_| WeatherTransportError)?;
        if validation_error(&url).is_some() {
            return Err(WeatherTransportError);
        }
        let allowed = |target: &Url| validation_error(target).is_none() && allow_redirect(target);
        let response: Result<_, FetchError> = self.fetch.perform("GET", &url, headers, None, timeout_milliseconds, &allowed, cancel);
        response.map(|response| WeatherResponse { status: response.status, body: response.body }).map_err(|_| WeatherTransportError)
    }
}

/// Epoch milliseconds.
pub type Clock = Arc<dyn Fn() -> i64 + Send + Sync>;

/// `$weather.forecast`. The device location is never read here. The order of
/// checks is the Apple runtime's:
/// 1. the system gate (`weather` declared by an installed Runtime 1.6
///    package, not a future timeline entry or Live Activity, the eight-query
///    budget);
/// 2. `invalid_options` for the options;
/// 3. `permission_denied` unless the package declares `network` and `api.met.no`;
/// 4. a matching cache younger than one hour is returned without a request;
/// 5. `query_limit` when the 32-request network budget of the execution is spent;
/// 6. the request (3 s timeout, redirects only to declared hosts); a failure
///    returns a matching cache up to six hours old with `isStale: true`, else
///    the failure.
///
/// There is no per-widget native grant for weather: nothing is read from the device.
#[derive(Clone)]
pub struct WeatherModule {
    transport: Arc<dyn WeatherTransport>,
    directory: PathBuf,
    user_agent: String,
    clock: Clock,
}

impl WeatherModule {
    pub const PERMISSION: &'static str = "weather";
    pub const TIMEOUT_MILLISECONDS: u64 = 3_000;

    pub fn new(transport: Arc<dyn WeatherTransport>, directory: impl Into<PathBuf>, user_agent: impl Into<String>) -> Self {
        let clock: Clock = Arc::new(|| SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |elapsed| elapsed.as_millis() as i64));
        Self::with_clock(transport, directory, user_agent, clock)
    }

    pub fn with_clock(transport: Arc<dyn WeatherTransport>, directory: impl Into<PathBuf>, user_agent: impl Into<String>, clock: Clock) -> Self {
        Self { transport, directory: directory.into(), user_agent: user_agent.into(), clock }
    }

    /// MET Norway asks every client to identify itself; no user or device detail is included.
    pub fn user_agent(version_name: &str) -> String {
        format!("ScriptWidget-Linux/{} https://github.com/everettjf/scriptwidget", if version_name.is_empty() { "0" } else { version_name })
    }

    pub fn forecast(&self, context: &CallContext, options: Option<&Object>) -> Result<Object, SystemReject> {
        system_gate::check(context, Self::PERMISSION, false)?;
        let query = WeatherOptions::parse(options.unwrap_or(&Object::new()))?;
        if !context.allows_host(WeatherOptions::HOST) {
            return Err(SystemServiceError::PermissionDenied.reject());
        }
        let cache = self.cache(&context.installation);
        let lock = cache.lock();
        let cached = {
            let _guard = lock.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
            let stored = cache.read().ok().flatten();
            weather_rules::from_cache(stored.as_deref(), &query, (self.clock)())
        };
        if let Some(fresh) = cached.as_ref().filter(|cached| !cached.opt_bool("isStale", false)) {
            return Ok(fresh.clone());
        }
        if !context.consume_network_request() {
            return Err(SystemServiceError::QueryLimit.reject());
        }
        let fetched = (|| -> Result<Object, SystemReject> {
            let unavailable = || SystemServiceError::Unavailable.reject();
            let headers = [("User-Agent".to_owned(), self.user_agent.clone())];
            let allow_redirect = |target: &Url| context.is_active() && context.allows_host(target.host_str().unwrap_or(""));
            let response = self.transport.get(&query.url(), &headers, Self::TIMEOUT_MILLISECONDS, &allow_redirect, None).map_err(|_| unavailable())?;
            system_gate::validate(context, Self::PERMISSION, false)?;
            if !context.allows_host(WeatherOptions::HOST) || response.status != 200 {
                return Err(unavailable());
            }
            let normalized = weather_rules::normalize(&response.body, &query, (self.clock)())?;
            let encoded = stringify_object(&normalized);
            if encoded.len() > weather_rules::MAXIMUM_CACHE_BYTES {
                return Err(SystemServiceError::LimitExceeded.reject());
            }
            let written = {
                let _guard = lock.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
                cache.write(&encoded)
            };
            if !written {
                return Err(unavailable());
            }
            Ok(normalized)
        })();
        match (fetched, cached) {
            (Err(_), Some(stale)) => Ok(stale),
            (outcome, _) => outcome,
        }
    }

    /// Removes the forecast cache of a deleted installation.
    pub fn retire(&self, installation: &str) {
        if crate::api::support::is_owner(installation) {
            self.cache(installation).delete();
        }
        system_log::call("weather.retire", "ok");
    }

    /// One forecast per installation, outside every script-reachable path.
    fn cache(&self, installation: &str) -> PrivateFile {
        PrivateFile::new(self.directory.join(canonical::owner_file_name(installation, ".json")), weather_rules::MAXIMUM_CACHE_BYTES)
    }
}

impl NativeModule for WeatherModule {
    fn handles(&self, operation: &str) -> bool {
        operation.starts_with("weather.")
    }

    fn apis(&self) -> &[&'static str] {
        &["$weather"]
    }

    fn start(&self, request: &ExecutionRequest<'_>, operation: &str, payload: Option<&Object>, done: Completion) {
        if operation != "weather.forecast" {
            return done.complete(false, Some(quote(&format!("Unsupported operation {operation}"))));
        }
        let context = CallContext::from_request(request);
        let options = payload.and_then(|payload| payload.opt_object("options")).cloned();
        let module = self.clone();
        run_system(operation, done, move || module.forecast(&context, options.as_ref()).map(|result| stringify_object(&result)));
    }
}
