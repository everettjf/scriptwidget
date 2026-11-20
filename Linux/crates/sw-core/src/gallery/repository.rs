//! Loading the Gallery index: the transport, the offline cache and the
//! repository. A port of `GalleryRepository.kt` (`GalleryClient` and
//! `GalleryIndexCache` in Swift).

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use serde_json::{Map, Value};

use super::files;
use super::validator;
use super::{GalleryError, GalleryErrorKind, GalleryIndex};
use crate::api::fetch::{FetchError, FetchModule, Url};
use crate::packages::safe_files;

/// One GET request of the Gallery layer. Requests never carry a body, cookies or credentials.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GalleryRequest {
    pub url: String,
    pub headers: Vec<(String, String)>,
    pub timeout_milliseconds: u64,
}

impl GalleryRequest {
    /// Case-insensitive lookup of a request header.
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers.iter().find(|(known, _)| known.eq_ignore_ascii_case(name)).map(|(_, value)| value.as_str())
    }
}

/// A completed response. `final_url` is the URL that produced the body after
/// redirects; callers re-check it against the trust rule instead of assuming
/// the transport did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GalleryResponse {
    pub status: u16,
    pub body: Vec<u8>,
    headers: HashMap<String, String>,
    pub final_url: String,
}

impl GalleryResponse {
    pub fn new(status: u16, body: Vec<u8>, headers: &[(&str, &str)], final_url: &str) -> Self {
        Self { status, body, headers: headers.iter().map(|(name, value)| (name.to_ascii_lowercase(), (*value).to_owned())).collect(), final_url: final_url.to_owned() }
    }

    /// Case-insensitive header lookup.
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers.get(&name.to_ascii_lowercase()).map(String::as_str)
    }
}

/// Network access of the Gallery, injectable so tests run offline
/// (`GalleryTransport` in Swift). Implementations block and must be called
/// off the window's thread. An error means that no response was obtained.
pub trait GalleryTransport: Send + Sync {
    fn fetch(&self, request: &GalleryRequest) -> Result<GalleryResponse, GalleryError>;
}

/// The production transport: a bounded HTTPS GET through
/// [`FetchModule::perform`], which resolves the host, refuses private,
/// loopback and link-local addresses, and connects only to an address it
/// checked.
///
/// The start URL and every redirect hop must pass
/// [`validator::is_raw_github_url`]; a redirect anywhere else ends the
/// request instead of being followed. Responses are limited to
/// [`crate::api::fetch::MAXIMUM_RESPONSE_BYTES`].
pub struct FetchGalleryTransport {
    fetch: FetchModule,
}

impl FetchGalleryTransport {
    pub fn new() -> Self {
        Self::with_fetch(FetchModule::new())
    }

    /// The transport over another fetch module: tests give one whose resolver and sockets stay on this machine.
    pub fn with_fetch(fetch: FetchModule) -> Self {
        Self { fetch }
    }
}

impl Default for FetchGalleryTransport {
    fn default() -> Self {
        Self::new()
    }
}

/// The parsed form of a URL that passed the trust rule as text. The parsed
/// URL must say the same: HTTPS, the raw host, no port, user info, query or fragment.
fn trusted_url(text: &str) -> Option<Url> {
    if !validator::is_raw_github_url(text) {
        return None;
    }
    Url::parse(text).ok().filter(is_trusted)
}

fn is_trusted(url: &Url) -> bool {
    url.scheme() == "https" && url.host_str() == Some(validator::RAW_HOST) && url.port().is_none() && url.username().is_empty() && url.password().is_none() && url.query().is_none() && url.fragment().is_none()
}

impl GalleryTransport for FetchGalleryTransport {
    fn fetch(&self, request: &GalleryRequest) -> Result<GalleryResponse, GalleryError> {
        let start = trusted_url(&request.url).ok_or_else(|| GalleryError::network("Gallery requests must use raw.githubusercontent.com over HTTPS."))?;
        let last = Mutex::new(start.clone());
        let allow = |target: &Url| {
            let trusted = is_trusted(target) && validator::is_raw_github_url(target.as_str());
            if trusted {
                *last.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = target.clone();
            }
            trusted
        };
        let response = self.fetch.perform("GET", &start, &request.headers, None, request.timeout_milliseconds, &allow, None).map_err(|error| match error {
            // A rule or limit of the client, in its own words.
            FetchError::Failed(message) => GalleryError::network(message),
            // What the system said about a socket or a certificate is not passed on.
            FetchError::Transport(_) | FetchError::Cancelled => GalleryError::network("GitHub could not be reached."),
        })?;
        let final_url = last.into_inner().unwrap_or_else(|poisoned| poisoned.into_inner());
        Ok(GalleryResponse { status: response.status, body: response.body, headers: response.headers, final_url: final_url.into() })
    }
}

/// A validated index and where it came from. `is_offline` is true when the
/// network attempt failed and the last fully validated cache is shown
/// instead; `offline_reason` then says why.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GallerySnapshot {
    pub index: GalleryIndex,
    pub is_offline: bool,
    /// Milliseconds since the epoch.
    pub fetched_at: i64,
    pub offline_reason: Option<String>,
}

/// On-disk copy of the last index that passed validation, with its ETag and
/// fetch time (`GalleryIndexCache` in Swift). The cache holds bytes only;
/// they are validated again on every load, so a tampered or outdated cache
/// file is never trusted.
#[derive(Debug, Clone)]
pub struct GalleryIndexCache {
    directory: PathBuf,
}

pub struct CacheEntry {
    pub data: Vec<u8>,
    pub etag: Option<String>,
    pub fetched_at: i64,
}

const INDEX_FILE: &str = "index.json";
const METADATA_FILE: &str = "metadata.json";
const MAX_METADATA_BYTES: usize = 16 * 1024;

impl GalleryIndexCache {
    pub fn new(directory: impl AsRef<Path>) -> Self {
        Self { directory: safe_files::root(directory.as_ref()) }
    }

    pub fn directory(&self) -> &Path {
        &self.directory
    }

    /// The cached bytes and metadata, or `None` when either file is missing, oversized, a link or unreadable.
    pub fn load(&self) -> Option<CacheEntry> {
        let data = files::read_private(&self.directory, INDEX_FILE, validator::MAX_INDEX_BYTES)?;
        let metadata = files::read_private(&self.directory, METADATA_FILE, MAX_METADATA_BYTES).and_then(|bytes| String::from_utf8(bytes).ok()).and_then(|text| files::parse_object(&text))?;
        let fetched_at = metadata.get("fetchedAt").and_then(files::integer)?;
        Some(CacheEntry { data, etag: metadata.get("etag").and_then(Value::as_str).map(str::to_owned), fetched_at })
    }

    /// Stores a validated index. Each file is replaced atomically.
    pub fn save(&self, data: &[u8], etag: Option<&str>, fetched_at: i64) -> std::io::Result<()> {
        files::write_atomically(&safe_files::child(&self.directory, INDEX_FILE), data)?;
        let mut metadata = Map::new();
        metadata.insert("fetchedAt".into(), Value::from(fetched_at));
        if let Some(etag) = etag {
            metadata.insert("etag".into(), Value::String(etag.to_owned()));
        }
        files::write_atomically(&safe_files::child(&self.directory, METADATA_FILE), crate::json::stringify_object(&metadata).as_bytes())
    }
}

type Clock = Box<dyn Fn() -> i64 + Send + Sync>;

pub(crate) fn system_clock() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |elapsed| i64::try_from(elapsed.as_millis()).unwrap_or(i64::MAX))
}

/// Loads the Gallery index (`GalleryClient` in Swift).
///
/// Trust: the index URL must be an HTTPS `raw.githubusercontent.com` URL; the
/// response must be HTTP 200 from a URL that still passes that rule; and the
/// body must pass [`validator::decode`] before it is cached or returned. A
/// rate-limit or error status is reported, never treated as content. When the
/// network attempt fails for any reason, the last cache that still validates
/// is returned marked offline; without one the failure is returned.
pub struct GalleryRepository {
    transport: Arc<dyn GalleryTransport>,
    cache: GalleryIndexCache,
    index_url: String,
    now: Clock,
}

impl GalleryRepository {
    /// `GalleryClient.defaultIndexURL`: the curated index in this repository is the trust root.
    pub const DEFAULT_INDEX_URL: &'static str = "https://raw.githubusercontent.com/everettjf/scriptwidget/main/Gallery/index.json";
    pub const USER_AGENT: &'static str = "ScriptWidget-Gallery/1";
    /// The index is cached for 15 minutes.
    pub const CACHE_MILLISECONDS: i64 = 15 * 60 * 1000;
    pub const INDEX_TIMEOUT_MILLISECONDS: u64 = 20_000;

    pub fn new(transport: Arc<dyn GalleryTransport>, cache: GalleryIndexCache) -> Self {
        Self { transport, cache, index_url: Self::DEFAULT_INDEX_URL.to_owned(), now: Box::new(system_clock) }
    }

    /// Another index address. It is held to the same trust rule: anything but
    /// an HTTPS `raw.githubusercontent.com` URL is refused by [`GalleryRepository::load`].
    pub fn with_index_url(mut self, index_url: &str) -> Self {
        self.index_url = index_url.to_owned();
        self
    }

    pub fn with_clock(mut self, now: impl Fn() -> i64 + Send + Sync + 'static) -> Self {
        self.now = Box::new(now);
        self
    }

    pub fn index_url(&self) -> &str {
        &self.index_url
    }

    /// Returns a validated index. A cache younger than 15 minutes is used
    /// without a request unless `force_refresh` is set; otherwise the index
    /// is fetched with `If-None-Match` when an ETag is known. Blocking: call
    /// it off the window's thread.
    pub fn load(&self, force_refresh: bool) -> Result<GallerySnapshot, GalleryError> {
        if !validator::is_raw_github_url(&self.index_url) {
            return Err(GalleryError::new(GalleryErrorKind::InvalidIndex, "Gallery index must use raw.githubusercontent.com over HTTPS."));
        }
        // A cache counts only together with the index it still decodes to.
        let cached: Option<(CacheEntry, GalleryIndex)> = self.cache.load().and_then(|entry| validator::decode(&entry.data).ok().map(|index| (entry, index)));
        if let Some((entry, index)) = &cached
            && !force_refresh
            && (0..Self::CACHE_MILLISECONDS).contains(&((self.now)().saturating_sub(entry.fetched_at)))
        {
            return Ok(GallerySnapshot { index: index.clone(), is_offline: false, fetched_at: entry.fetched_at, offline_reason: None });
        }

        let mut headers = vec![("Accept".to_owned(), "application/json".to_owned()), ("User-Agent".to_owned(), Self::USER_AGENT.to_owned())];
        if let Some(etag) = cached.as_ref().and_then(|(entry, _)| entry.etag.clone()) {
            headers.push(("If-None-Match".to_owned(), etag));
        }
        let refreshed = (|| -> Result<GallerySnapshot, GalleryError> {
            let unwritable = |_: std::io::Error| GalleryError::network("The Gallery cache could not be written.");
            let response = self.transport.fetch(&GalleryRequest { url: self.index_url.clone(), headers, timeout_milliseconds: Self::INDEX_TIMEOUT_MILLISECONDS })?;
            if let (304, Some((entry, index))) = (response.status, &cached) {
                let date = (self.now)();
                self.cache.save(&entry.data, entry.etag.as_deref(), date).map_err(unwritable)?;
                return Ok(GallerySnapshot { index: index.clone(), is_offline: false, fetched_at: date, offline_reason: None });
            }
            if response.status != 200 {
                return Err(GalleryError::network(http_message(&response)));
            }
            if !validator::is_raw_github_url(&response.final_url) {
                return Err(GalleryError::network("Gallery redirected to an untrusted host."));
            }
            let index = validator::decode(&response.body)?;
            let date = (self.now)();
            self.cache.save(&response.body, response.header("ETag"), date).map_err(unwritable)?;
            Ok(GallerySnapshot { index, is_offline: false, fetched_at: date, offline_reason: None })
        })();
        match (refreshed, cached) {
            (Ok(snapshot), _) => Ok(snapshot),
            (Err(error), Some((entry, index))) => {
                let reason = if error.message.is_empty() { "The Gallery could not be refreshed.".to_owned() } else { error.message };
                Ok(GallerySnapshot { index, is_offline: true, fetched_at: entry.fetched_at, offline_reason: Some(reason) })
            }
            (Err(error), None) => Err(error),
        }
    }
}

fn http_message(response: &GalleryResponse) -> String {
    if response.status == 403 || response.status == 429 {
        return if response.header("X-RateLimit-Remaining") == Some("0") { "GitHub rate limit reached. Try again after the reset time.".into() } else { "GitHub temporarily limited Gallery requests. Try again later.".into() };
    }
    format!("GitHub returned HTTP {}.", response.status)
}
