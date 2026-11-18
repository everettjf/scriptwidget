//! `fetch` and `$http`. Ported from
//! `Windows/src/ScriptWidget.Core/Api/FetchModule.cs`, which mirrors
//! ScriptWidgetRuntimeFetch: public HTTP(S) only, the package's declared hosts
//! only, bounded request and response sizes, a per-execution request budget,
//! and every redirect re-validated.
//!
//! Beyond the host-name rule, the resolved addresses are checked so a public
//! name cannot point at a private or loopback address, and the connection is
//! opened to the very address that was checked (see [`crate::api::http`]), so
//! a DNS answer that changes between the check and the connect cannot be used.
//!
//! Nothing here logs: URLs, headers and bodies can carry credentials.

use std::collections::HashMap;
use std::fmt;
use std::io::Read;
use std::net::{IpAddr, ToSocketAddrs};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::json;
pub use url::Url;

use crate::api::http::HttpTransport;
use crate::api::policy::{self, NetworkDeclaration};
use crate::api::workers::BoundedExecutor;
use crate::executor::{Completion, ExecutionRequest, NativeModule};
use crate::json::{Object, ObjectExt, quote, stringify};

pub const MAXIMUM_RESPONSE_BYTES: usize = 2 * 1024 * 1024;
pub const MAXIMUM_REQUEST_BODY_BYTES: usize = 1024 * 1024;
pub const MAXIMUM_REQUESTS: u32 = 32;
pub const MAXIMUM_CONCURRENT: usize = 8;
pub const MAXIMUM_REDIRECTS: usize = 5;
pub const MAXIMUM_TOTAL_MILLISECONDS: u64 = 10_000;
pub const EXPOSED_HEADERS: [&str; 6] = ["content-type", "cache-control", "expires", "last-modified", "date", "retry-after"];

pub const BLOCKED_MESSAGE: &str = "Local and private network hosts are not allowed";
pub const TIMED_OUT_MESSAGE: &str = "The request timed out.";

/// Sent when the script sets no User-Agent of its own. No user or device detail is included.
pub const DEFAULT_USER_AGENT: &str = concat!("ScriptWidget-Linux/", env!("CARGO_PKG_VERSION"));

/// Request headers that carry credentials; they stay with the origin the script addressed.
const CREDENTIAL_HEADERS: [&str; 3] = ["authorization", "proxy-authorization", "cookie"];
const METHODS: [&str; 8] = ["OPTIONS", "GET", "HEAD", "POST", "PUT", "DELETE", "PATCH", "TRACE"];

/// Why a request did not produce a response.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FetchError {
    /// A rule or limit of this module; the message is one of its own sentences and is shown to the script.
    Failed(String),
    /// A failure below it: the socket, TLS or a malformed response. The text
    /// comes from the system; callers that must not forward it replace it.
    Transport(String),
    /// The execution ended while the request was in flight.
    Cancelled,
}

impl FetchError {
    pub fn failed(message: impl Into<String>) -> Self {
        Self::Failed(message.into())
    }

    pub fn message(&self) -> &str {
        match self {
            Self::Failed(message) | Self::Transport(message) => message,
            Self::Cancelled => "The operation was canceled.",
        }
    }

    /// Carries the error through `std::io` interfaces such as decoders.
    pub fn into_io(self) -> std::io::Error {
        std::io::Error::other(self)
    }

    /// The error an I/O failure stands for: the one [`FetchError::into_io`] wrapped, or a transport failure.
    pub fn from_io(error: std::io::Error) -> Self {
        if error.get_ref().is_some_and(|inner| inner.is::<FetchError>()) {
            return *error.into_inner().and_then(|inner| inner.downcast::<FetchError>().ok()).expect("checked above");
        }
        Self::Transport(error.to_string())
    }
}

impl fmt::Display for FetchError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.message())
    }
}

impl std::error::Error for FetchError {}

/// Turns a host name (or address literal) into addresses.
pub type Resolver = Arc<dyn Fn(&str) -> std::io::Result<Vec<IpAddr>> + Send + Sync>;

/// True once the work is no longer wanted.
pub type Cancel = Arc<dyn Fn() -> bool + Send + Sync>;

/// The operating system's resolver. An address literal is returned as is.
pub fn system_resolver(host: &str) -> std::io::Result<Vec<IpAddr>> {
    if let Ok(literal) = host.parse::<IpAddr>() {
        return Ok(vec![literal]);
    }
    let mut addresses: Vec<IpAddr> = Vec::new();
    for address in (host, 0u16).to_socket_addrs()? {
        if !addresses.contains(&address.ip()) {
            addresses.push(address.ip());
        }
    }
    Ok(addresses)
}

/// The addresses of `host`, all of them public, or the refusal. With
/// `check_name` the host is refused by name first, without asking the
/// resolver. One private address among public ones is enough to refuse: the
/// connection could go to it.
pub fn vetted_addresses(resolver: &Resolver, host: &str, check_name: bool) -> Result<Vec<IpAddr>, FetchError> {
    let name = unbracket(host);
    if check_name && (name.is_empty() || policy::blocked_host_name(name)) {
        return Err(FetchError::failed(BLOCKED_MESSAGE));
    }
    let addresses = resolver(name).map_err(|_| FetchError::Failed(format!("Could not resolve {host}")))?;
    if addresses.is_empty() || addresses.iter().any(|address| policy::blocked_address(*address)) {
        return Err(FetchError::failed(BLOCKED_MESSAGE));
    }
    Ok(addresses)
}

pub fn unbracket(host: &str) -> &str {
    host.strip_prefix('[').and_then(|rest| rest.strip_suffix(']')).unwrap_or(host)
}

/// The waits of one request. Each wait (connect and response head, then every
/// read of the body) gets the request timeout, inside a total deadline, and
/// ends early when the execution does.
#[derive(Clone)]
pub struct Wait(Arc<WaitState>);

struct WaitState {
    deadline: Instant,
    timeout: Duration,
    until: Mutex<Instant>,
    cancel: Option<Cancel>,
}

impl Wait {
    pub fn new(total: Duration, timeout: Duration, cancel: Option<Cancel>) -> Self {
        let now = Instant::now();
        Self(Arc::new(WaitState { deadline: now + total, timeout, until: Mutex::new(now), cancel }))
    }

    /// Starts the next wait. Fails when the total deadline has passed.
    pub fn arm(&self) -> Result<(), FetchError> {
        let now = Instant::now();
        if now >= self.0.deadline {
            return Err(FetchError::failed(TIMED_OUT_MESSAGE));
        }
        *self.0.until.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = (now + self.0.timeout).min(self.0.deadline);
        Ok(())
    }

    pub fn cancelled(&self) -> bool {
        self.0.cancel.as_ref().is_some_and(|cancel| cancel())
    }

    /// Time left in the current wait, or why there is none.
    pub fn remaining(&self) -> Result<Duration, FetchError> {
        if self.cancelled() {
            return Err(FetchError::Cancelled);
        }
        let until = *self.0.until.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let left = until.saturating_duration_since(Instant::now());
        if left.is_zero() { Err(FetchError::failed(TIMED_OUT_MESSAGE)) } else { Ok(left) }
    }

    /// Blocks until the current wait is over and says how it ended: what an
    /// exchange that never answers amounts to.
    pub fn expire(&self) -> FetchError {
        loop {
            match self.remaining() {
                Ok(left) => std::thread::sleep(left.min(Duration::from_millis(20))),
                Err(error) => return error,
            }
        }
    }
}

/// One request as the transport sends it. Nothing in it is trusted to be safe to resolve again.
pub struct TransportRequest<'a> {
    /// Upper-case method.
    pub method: &'a str,
    pub url: &'a Url,
    /// Validated names and values, without `Host` and `Content-Length`.
    pub headers: &'a [(String, String)],
    pub body: Option<&'a [u8]>,
}

/// The head of a response and its body, still unread.
pub struct TransportResponse {
    pub status: u16,
    /// In the order received; names as received.
    pub headers: Vec<(String, String)>,
    /// Fails with [`FetchError::into_io`] errors for timeouts and cancellation.
    pub body: Box<dyn Read>,
}

/// Performs one HTTP exchange and nothing more: no redirects, cookies,
/// credentials or proxy. The production transport connects only to addresses
/// the resolver returned and [`policy::blocked_address`] accepted.
pub trait Transport: Send + Sync {
    fn send(&self, request: &TransportRequest<'_>, wait: &Wait) -> Result<TransportResponse, FetchError>;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Response {
    pub status: u16,
    pub body: Vec<u8>,
    /// Response headers by lower-case name; the last value wins.
    pub headers: HashMap<String, String>,
}

struct Client {
    resolver: Resolver,
    transport: Arc<dyn Transport>,
}

pub struct FetchModule {
    client: Arc<Client>,
    pool: BoundedExecutor,
}

impl Default for FetchModule {
    fn default() -> Self {
        Self::new()
    }
}

impl FetchModule {
    /// The production module: the system resolver and the vetted-address transport.
    pub fn new() -> Self {
        Self::with_resolver(Arc::new(system_resolver))
    }

    /// The production transport over another resolver.
    pub fn with_resolver(resolver: Resolver) -> Self {
        let transport = Arc::new(HttpTransport::new(resolver.clone()));
        Self::with_parts(resolver, transport)
    }

    /// `resolver` turns a host name into addresses; `transport` sends the
    /// request and must not follow redirects itself. Only the host
    /// application constructs modules: package code cannot reach this.
    pub fn with_parts(resolver: Resolver, transport: Arc<dyn Transport>) -> Self {
        Self { client: Arc::new(Client { resolver, transport }), pool: BoundedExecutor::new(MAXIMUM_CONCURRENT) }
    }

    /// Performs one request, following up to five redirects that
    /// `allow_redirect` accepts. Blocks the calling thread; call it from a worker.
    ///
    /// Every hop is resolved and its addresses checked before anything is
    /// sent. The response body is counted while it is read, never trusting
    /// `Content-Length`, and reading stops at the limit.
    #[allow(clippy::too_many_arguments)]
    pub fn perform(
        &self,
        method: &str,
        start: &Url,
        headers: &[(String, String)],
        body: Option<&[u8]>,
        timeout_milliseconds: u64,
        allow_redirect: &dyn Fn(&Url) -> bool,
        cancel: Option<Cancel>,
    ) -> Result<Response, FetchError> {
        self.client.perform(method, start, headers, body, timeout_milliseconds, allow_redirect, cancel)
    }
}

impl Client {
    #[allow(clippy::too_many_arguments)]
    fn perform(
        &self,
        method: &str,
        start: &Url,
        headers: &[(String, String)],
        body: Option<&[u8]>,
        timeout_milliseconds: u64,
        allow_redirect: &dyn Fn(&Url) -> bool,
        cancel: Option<Cancel>,
    ) -> Result<Response, FetchError> {
        let mut current = start.clone();
        let mut current_method = method.to_uppercase();
        let mut current_body = body;
        if !METHODS.contains(&current_method.as_str()) {
            return Err(FetchError::Failed(format!("Unknown method '{current_method}'")));
        }
        let wait = Wait::new(Duration::from_millis(MAXIMUM_TOTAL_MILLISECONDS), Duration::from_millis(timeout_milliseconds), cancel);
        for hop in 0..=MAXIMUM_REDIRECTS {
            if wait.cancelled() {
                return Err(FetchError::Cancelled);
            }
            let host = current.host_str().unwrap_or("");
            vetted_addresses(&self.resolver, host, false)?;
            wait.arm()?;

            // A redirect to another origin does not get the credentials meant for the first one, as in
            // browsers and curl. (The Android transport this was first ported from sends them on.)
            let other_origin = start.origin() != current.origin();
            let mut unique: Vec<(String, String)> = Vec::new();
            for (name, value) in headers {
                if other_origin && CREDENTIAL_HEADERS.iter().any(|credential| name.eq_ignore_ascii_case(credential)) {
                    continue;
                }
                match unique.iter_mut().find(|(known, _)| known.eq_ignore_ascii_case(name)) {
                    Some(entry) => entry.1 = value.clone(),
                    None => unique.push((name.clone(), value.clone())),
                }
            }
            let mut sent: Vec<(String, String)> = Vec::new();
            for (name, value) in &unique {
                if name.eq_ignore_ascii_case("Host") || name.eq_ignore_ascii_case("Content-Length") {
                    continue;
                }
                // A value can never start a new header line, whatever the transport would do with it.
                if !valid_header_name(name) || value.chars().any(|character| matches!(character, '\r' | '\n' | '\0')) {
                    // The name is the script's own; the value is not repeated.
                    return Err(FetchError::Failed(format!("Request header {} is not valid", printable(name))));
                }
                sent.push((name.clone(), value.clone()));
            }
            // The system network stacks on iPhone and Android name the client by themselves; services
            // such as the GitHub API refuse a request without a user agent. A script's own
            // User-Agent header wins.
            if !unique.iter().any(|(name, _)| name.eq_ignore_ascii_case("User-Agent")) {
                sent.push(("User-Agent".into(), DEFAULT_USER_AGENT.into()));
            }
            let request = TransportRequest { method: &current_method, url: &current, headers: &sent, body: current_body.filter(|_| current_method != "GET") };
            let mut response = self.transport.send(&request, &wait)?;

            let status = response.status;
            if (300..=399).contains(&status) && status != 304 {
                let location = last_header(&response.headers, "location").ok_or_else(|| FetchError::failed("Redirect without a location"))?;
                let next = current.join(location).ok().filter(|next| hop != MAXIMUM_REDIRECTS && allow_redirect(next));
                let Some(next) = next else { return Err(FetchError::failed("Redirect target is not allowed")) };
                if status == 303 || ((status == 301 || status == 302) && current_method == "POST") {
                    current_method = "GET".into();
                    current_body = None;
                }
                current = next;
                continue;
            }
            let too_large = || FetchError::Failed(format!("Response exceeds the {MAXIMUM_RESPONSE_BYTES}-byte limit"));
            if last_header(&response.headers, "content-length").and_then(|text| text.trim().parse::<u64>().ok()).is_some_and(|length| length > MAXIMUM_RESPONSE_BYTES as u64) {
                return Err(too_large());
            }
            let mut buffer: Vec<u8> = Vec::new();
            let mut chunk = vec![0u8; 16 * 1024];
            loop {
                wait.arm()?;
                let read = response.body.read(&mut chunk).map_err(FetchError::from_io)?;
                if read == 0 {
                    break;
                }
                if buffer.len() + read > MAXIMUM_RESPONSE_BYTES {
                    return Err(too_large());
                }
                buffer.extend_from_slice(&chunk[..read]);
            }
            if wait.cancelled() {
                return Err(FetchError::Cancelled);
            }
            let mut response_headers = HashMap::new();
            for (name, value) in response.headers {
                response_headers.insert(name.to_ascii_lowercase(), value);
            }
            return Ok(Response { status, body: buffer, headers: response_headers });
        }
        Err(FetchError::failed("Too many redirects"))
    }
}

impl NativeModule for FetchModule {
    fn handles(&self, operation: &str) -> bool {
        operation == "http.request"
    }

    fn start(&self, request: &ExecutionRequest<'_>, _operation: &str, payload: Option<&Object>, done: Completion) {
        let job = payload.cloned().unwrap_or_default();
        let fail = |done: Completion, message: &str| done.complete(false, Some(quote(message)));
        if policy::is_live_activity(request) {
            return fail(done, "[live_activity_unavailable] Live Activity presentations cannot request network data; update their state from the app");
        }
        if policy::is_timeline_projection(request) {
            return fail(done, "[timeline_read_only] Future entries cannot make live network requests; read a saved snapshot");
        }
        let url_text = job.opt_string("url");
        let url = match parse_request_url(&url_text) {
            Ok(url) => url,
            Err(message) => return fail(done, &message),
        };
        if let Some(invalid) = validation_error(&url) {
            return fail(done, invalid);
        }
        let declaration = NetworkDeclaration::of(request);
        if !declaration.allows_host(url.host_str().unwrap_or("")) {
            return fail(done, "Network host is not declared in widget.json");
        }
        if request.session.add_network_request() > MAXIMUM_REQUESTS {
            return fail(done, "Network request budget exceeded");
        }

        let client = self.client.clone();
        let session = request.session.clone();
        self.pool.execute(move || {
            let outcome = (|| -> Result<Option<String>, FetchError> {
                let mut headers: Vec<(String, String)> = Vec::new();
                if let Some(map) = job.opt_object("headers") {
                    headers.extend(map.keys().map(|name| (name.clone(), map.opt_string(name))));
                }
                let body = job.has("body").then(|| job.opt_string("body").into_bytes());
                if body.is_some() && job.opt_bool("jsonBody", false) && !headers.iter().any(|(name, _)| name.eq_ignore_ascii_case("Content-Type")) {
                    headers.push(("Content-Type".into(), "application/json".into()));
                }
                if body.as_ref().is_some_and(|body| body.len() > MAXIMUM_REQUEST_BODY_BYTES) {
                    return Err(FetchError::Failed(format!("Request body exceeds the {MAXIMUM_REQUEST_BODY_BYTES}-byte limit")));
                }
                let timeout = normalized_timeout(job.has("timeout").then(|| job.opt_f64("timeout")));
                let method = match job.opt_string("method") {
                    method if method.is_empty() => "GET".to_owned(),
                    method => method,
                };
                let live = session.clone();
                let allow_redirect = |redirected: &Url| !live.finished() && validation_error(redirected).is_none() && declaration.allows_host(redirected.host_str().unwrap_or(""));
                let ended = session.clone();
                let response = client.perform(&method, &url, &headers, body.as_deref(), timeout, &allow_redirect, Some(Arc::new(move || ended.finished())))?;
                if session.finished() {
                    return Ok(None);
                }
                let text = if job.opt_bool("base64", false) { Some(base64(&response.body)) } else { String::from_utf8(response.body).ok() };
                if job.opt_bool("metadata", false) {
                    let text = text.ok_or_else(|| FetchError::failed("Response is not HTTP or has invalid UTF-8"))?;
                    let mut allowed = Object::new();
                    for name in EXPOSED_HEADERS {
                        if let Some(value) = response.headers.get(name).filter(|value| value.len() <= 2048) {
                            allowed.insert(name.to_owned(), value.clone().into());
                        }
                    }
                    Ok(Some(stringify(&json!({ "status": response.status, "body": text, "headers": allowed }))))
                } else {
                    let text = text.ok_or_else(|| FetchError::Failed(format!("{url_text} is empty")))?;
                    Ok(Some(quote(&text)))
                }
            })();
            match outcome {
                Ok(Some(json)) => done.complete(true, Some(json)),
                // The execution ended: there is nobody to answer.
                Ok(None) => drop(done),
                Err(error) => done.complete(false, Some(quote(if error.message().is_empty() { "Request failed" } else { error.message() }))),
            }
        });
    }
}

/// The URL a script asked for, or the message it is refused with. A URL that
/// is not absolute, or not HTTP(S), is refused as such; one that has no
/// authority of its own (`https:///x`, `https:x`) is not a URL here, although
/// a browser would repair it.
pub fn parse_request_url(text: &str) -> Result<Url, String> {
    const SCHEME: &str = "Only HTTP and HTTPS URLs are allowed";
    let url = match Url::parse(text) {
        Ok(url) => url,
        Err(url::ParseError::RelativeUrlWithoutBase) => return Err(SCHEME.into()),
        Err(_) => return Err(format!("{text} is not url")),
    };
    if !matches!(url.scheme(), "http" | "https") {
        return Err(SCHEME.into());
    }
    let written = text.trim_matches(|character: char| character <= ' ');
    let authority = written.split_once(':').map(|(_, rest)| rest).and_then(|rest| rest.strip_prefix("//"));
    match authority.and_then(|rest| rest.chars().next()) {
        Some(first) if !matches!(first, '/' | '\\' | '?' | '#') => Ok(url),
        _ => Err(format!("{text} is not url")),
    }
}

/// HTTP(S), a host, no credentials, not local or private by name.
pub fn validation_error(url: &Url) -> Option<&'static str> {
    if !matches!(url.scheme(), "http" | "https") {
        return Some("Only HTTP and HTTPS URLs are allowed");
    }
    let host = unbracket(url.host_str().unwrap_or(""));
    if host.is_empty() {
        return Some("URL host is required");
    }
    if !url.username().is_empty() || url.password().is_some() {
        return Some("URL credentials are not allowed");
    }
    policy::blocked_host_name(host).then_some(BLOCKED_MESSAGE)
}

/// Seconds from the script, clamped to 1...10; 5 by default. Returns milliseconds.
pub fn normalized_timeout(seconds: Option<f64>) -> u64 {
    let value = match seconds {
        Some(given) if !given.is_nan() && given > 0.0 => given.clamp(1.0, 10.0),
        _ => 5.0,
    };
    (value * 1000.0) as u64
}

/// A header name is a token (RFC 9110): visible ASCII without separators.
fn valid_header_name(name: &str) -> bool {
    !name.is_empty() && name.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"!#$%&'*+-.^_`|~".contains(&byte))
}

fn printable(name: &str) -> String {
    name.chars().filter(|character| *character > ' ' && *character < '\u{7f}').take(64).collect()
}

fn last_header<'a>(headers: &'a [(String, String)], name: &str) -> Option<&'a str> {
    headers.iter().rev().find(|(known, _)| known.eq_ignore_ascii_case(name)).map(|(_, value)| value.as_str())
}

/// Standard base64 with padding.
pub fn base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut output = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for group in bytes.chunks(3) {
        let value = u32::from(group[0]) << 16 | u32::from(*group.get(1).unwrap_or(&0)) << 8 | u32::from(*group.get(2).unwrap_or(&0));
        output.push(ALPHABET[(value >> 18) as usize & 63] as char);
        output.push(ALPHABET[(value >> 12) as usize & 63] as char);
        output.push(if group.len() > 1 { ALPHABET[(value >> 6) as usize & 63] as char } else { '=' });
        output.push(if group.len() > 2 { ALPHABET[value as usize & 63] as char } else { '=' });
    }
    output
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_matches_the_standard_alphabet() {
        for (bytes, expected) in [(&b""[..], ""), (b"f", "Zg=="), (b"fo", "Zm8="), (b"foo", "Zm9v"), (b"foob", "Zm9vYg=="), (&[0xFF, 0x00, 0x10], "/wAQ"), (&[0xFB, 0xEF, 0xBE], "++++")] {
            assert_eq!(base64(bytes), expected);
        }
    }

    #[test]
    fn timeouts_are_clamped_to_one_to_ten_seconds() {
        assert_eq!(normalized_timeout(None), 5000);
        assert_eq!(normalized_timeout(Some(f64::NAN)), 5000);
        assert_eq!(normalized_timeout(Some(0.0)), 5000);
        assert_eq!(normalized_timeout(Some(-3.0)), 5000);
        assert_eq!(normalized_timeout(Some(0.2)), 1000);
        assert_eq!(normalized_timeout(Some(2.5)), 2500);
        assert_eq!(normalized_timeout(Some(60.0)), 10000);
        assert_eq!(normalized_timeout(Some(f64::INFINITY)), 10000);
        assert_eq!(MAXIMUM_RESPONSE_BYTES, 2 * 1024 * 1024);
        assert_eq!(MAXIMUM_REQUESTS, 32);
        assert_eq!(MAXIMUM_REDIRECTS, 5);
    }

    #[test]
    fn request_urls_need_a_scheme_and_an_authority_of_their_own() {
        for text in ["https://example.com/", "http://example.com:8080/a?b=c", "HTTPS://EXAMPLE.com", "http://[::1]/", "https://user:pw@example.com/"] {
            assert!(parse_request_url(text).is_ok(), "{text}");
        }
        for text in ["ftp://example.com/x", "file:///etc/passwd", "example.com/x", "", "/relative", "javascript:alert(1)", "data:text/plain,x"] {
            assert_eq!(parse_request_url(text).unwrap_err(), "Only HTTP and HTTPS URLs are allowed", "{text}");
        }
        for text in ["https:///status", "https:example.com", "https:/example.com", "http:\\\\example.com", "https://", "http://exa mple.com/", "https://example.com:port/"] {
            assert_eq!(parse_request_url(text).unwrap_err(), format!("{text} is not url"), "{text}");
        }
    }

    #[test]
    fn io_errors_carry_fetch_errors_through() {
        assert_eq!(FetchError::from_io(FetchError::failed(TIMED_OUT_MESSAGE).into_io()), FetchError::failed(TIMED_OUT_MESSAGE));
        assert_eq!(FetchError::from_io(FetchError::Cancelled.into_io()), FetchError::Cancelled);
        assert!(matches!(FetchError::from_io(std::io::Error::from(std::io::ErrorKind::ConnectionReset)), FetchError::Transport(_)));
    }
}
