//! The HTTPS transport of the AI client, its errors and cancellation. Port of
//! `AiTransport.kt`.
//!
//! Network rules, the ones Android has:
//! - HTTPS only, for every host. `http://` is refused before anything is
//!   resolved or sent, also for `localhost` (an Ollama on this machine needs
//!   a TLS front, as on Android): the request carries the API key.
//! - The host is the user's own choice in the application's settings, so it
//!   is not subject to a package's `networkDomains` and may be a server in the
//!   user's network. Nothing a package does reaches this transport, and the
//!   rules of `fetch` are unchanged (see [`HttpTransport::for_user_endpoint`]).
//! - No redirects at all (a redirect could forward the key to another host),
//!   no proxy, no cookies; TLS verified against the host name with the
//!   system's certificate authorities.
//! - Bounded: a time to connect, a time for every read, a total time for the
//!   exchange, and a largest response.
//!
//! The exchange itself is the hand-written HTTP/1.1 client of
//! [`crate::api::http`], so there is one TLS and HTTP implementation.

use std::fmt;
use std::io::Read;
use std::net::{SocketAddr, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use rustls::ClientConfig;

use crate::api::fetch::{self, FetchError, Resolver, Transport, TransportRequest, Url, Wait};
use crate::api::http::{Dialer, HttpTransport, SystemDialer, system_tls_config};

type Action = Arc<dyn Fn() + Send + Sync>;

#[derive(Default)]
struct CancellationState {
    cancelled: AtomicBool,
    next: AtomicU64,
    actions: Mutex<Vec<(u64, Action)>>,
}

/// Cooperative cancellation shared by the agent loop and the transport. A
/// clone is the same cancellation. Safe to use from any thread.
#[derive(Clone, Default)]
pub struct AiCancellation(Arc<CancellationState>);

impl AiCancellation {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn is_cancelled(&self) -> bool {
        self.0.cancelled.load(Ordering::SeqCst)
    }

    /// Cancels once; registered actions run on the calling thread.
    pub fn cancel(&self) {
        if self.0.cancelled.swap(true, Ordering::SeqCst) {
            return;
        }
        let actions: Vec<Action> = self.0.actions.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).iter().map(|(_, action)| action.clone()).collect();
        for action in actions {
            action();
        }
    }

    /// Runs `action` when cancelled (immediately if already cancelled). Close or drop the result to unregister.
    #[must_use = "dropping the registration unregisters the action"]
    pub fn on_cancel(&self, action: impl Fn() + Send + Sync + 'static) -> CancelRegistration {
        let action: Action = Arc::new(action);
        let id = self.0.next.fetch_add(1, Ordering::SeqCst);
        self.0.actions.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).push((id, action.clone()));
        if self.is_cancelled() {
            action();
        }
        CancelRegistration { state: self.0.clone(), id }
    }
}

impl fmt::Debug for AiCancellation {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "AiCancellation(cancelled={})", self.is_cancelled())
    }
}

/// What [`AiCancellation::on_cancel`] returns.
pub struct CancelRegistration {
    state: Arc<CancellationState>,
    id: u64,
}

impl CancelRegistration {
    pub fn close(self) {}
}

impl Drop for CancelRegistration {
    fn drop(&mut self) {
        self.state.actions.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).retain(|(id, _)| *id != self.id);
    }
}

/// Failure categories of the AI client; messages never contain the API key or a response body.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AiErrorKind {
    MissingApiKey,
    InvalidProfile,
    Network,
    Timeout,
    Http,
    ResponseTooLarge,
    MalformedResponse,
    EmptyResponse,
    Refused,
    Cancelled,
}

/// The only error the AI client returns. Port of `AiClientException` (`AIClientError` in Swift).
/// It has no source: what a lower layer said is never carried along.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AiClientError {
    pub kind: AiErrorKind,
    pub message: String,
    pub http_status: Option<u16>,
}

impl AiClientError {
    pub fn new(kind: AiErrorKind, message: impl Into<String>) -> Self {
        Self { kind, message: message.into(), http_status: None }
    }

    pub fn with_status(kind: AiErrorKind, message: impl Into<String>, status: u16) -> Self {
        Self { kind, message: message.into(), http_status: Some(status) }
    }

    pub fn cancelled() -> Self {
        Self::new(AiErrorKind::Cancelled, "Cancelled.")
    }
}

impl fmt::Display for AiClientError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for AiClientError {}

/// One HTTPS request. `headers` may hold the API key, so the `Debug` text
/// has the header names only and never the body.
#[derive(Clone)]
pub struct AiHttpRequest {
    pub method: String,
    pub url: String,
    pub headers: Vec<(String, String)>,
    pub body: Option<Vec<u8>>,
    pub connect_timeout_milliseconds: u64,
    pub read_timeout_milliseconds: u64,
    pub maximum_response_bytes: usize,
}

impl AiHttpRequest {
    /// The value of a header, by its exact name.
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers.iter().rev().find(|(known, _)| known == name).map(|(_, value)| value.as_str())
    }
}

impl fmt::Debug for AiHttpRequest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let place = Url::parse(&self.url).map(|url| format!("{}://{}{}", url.scheme(), url.host_str().unwrap_or(""), url.path())).unwrap_or_default();
        let mut names: Vec<&str> = self.headers.iter().map(|(name, _)| name.as_str()).collect();
        names.sort_unstable();
        write!(formatter, "AiHttpRequest({} {place}, headers={names:?}, bodyBytes={})", self.method, self.body.as_ref().map_or(0, Vec::len))
    }
}

/// Status and bounded body of a response. The `Debug` text never has the body.
#[derive(Clone, PartialEq, Eq)]
pub struct AiHttpResponse {
    pub status: u16,
    pub body: Vec<u8>,
}

impl AiHttpResponse {
    pub fn new(status: u16, body: impl Into<Vec<u8>>) -> Self {
        Self { status, body: body.into() }
    }

    pub fn is_success(&self) -> bool {
        (200..=299).contains(&self.status)
    }
}

impl fmt::Debug for AiHttpResponse {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "AiHttpResponse(status={}, bodyBytes={})", self.status, self.body.len())
    }
}

/// Takes the pieces of a body as they arrive; an error ends the exchange.
pub type OnBody<'a> = &'a mut dyn FnMut(&[u8]) -> Result<(), AiClientError>;

/// Performs one request. Injected into [`super::AiClient`] so tests never touch the network.
pub trait AiTransport: Send + Sync {
    /// Every failure, cancellation included, is an [`AiClientError`].
    fn execute(&self, request: &AiHttpRequest, cancellation: &AiCancellation) -> Result<AiHttpResponse, AiClientError>;

    /// Like [`AiTransport::execute`], and hands the body of a successful response to `on_body` piece
    /// by piece as it arrives. The returned response still holds the whole body, under the same size
    /// limit. A transport that can not do this hands the body over once, at the end.
    fn execute_streaming(&self, request: &AiHttpRequest, cancellation: &AiCancellation, on_body: OnBody<'_>) -> Result<AiHttpResponse, AiClientError> {
        let response = self.execute(request, cancellation)?;
        if response.is_success() {
            on_body(&response.body)?;
        }
        Ok(response)
    }
}

/// Error bodies are only inspected for a short error code, so they get a much smaller budget.
const MAXIMUM_ERROR_BODY_BYTES: usize = 64 * 1024;
/// The longest one exchange may take, whatever arrives: a reply that is still being written after this is given up.
pub const MAXIMUM_TOTAL_MILLISECONDS: u64 = 15 * 60 * 1000;

/// Gives a connection no longer than `limit` to open, inside the wait it is opened in.
struct ConnectWithin {
    inner: Arc<dyn Dialer>,
    limit: Duration,
}

impl Dialer for ConnectWithin {
    fn dial(&self, address: SocketAddr, timeout: Duration) -> std::io::Result<TcpStream> {
        self.inner.dial(address, timeout.min(self.limit))
    }
}

/// The production transport: HTTPS only, explicit timeouts, a bounded
/// response and no redirects at all. It is separate from the widget `fetch`
/// module, whose budgets and package host policy are meant for untrusted
/// scripts.
pub struct HttpsAiTransport {
    resolver: Resolver,
    dialer: Arc<dyn Dialer>,
    tls: OnceLock<Result<Arc<ClientConfig>, String>>,
    total: Duration,
}

impl Default for HttpsAiTransport {
    fn default() -> Self {
        Self::new()
    }
}

impl HttpsAiTransport {
    /// The system resolver, direct connections and the certificate authorities of the system.
    pub fn new() -> Self {
        Self { resolver: Arc::new(fetch::system_resolver), dialer: Arc::new(SystemDialer), tls: OnceLock::new(), total: Duration::from_millis(MAXIMUM_TOTAL_MILLISECONDS) }
    }

    /// The transport over another network, for tests: their resolver, their
    /// dialer and the certificate authority of their fixtures.
    pub fn with_parts(resolver: Resolver, dialer: Arc<dyn Dialer>, tls: Option<Arc<ClientConfig>>, total: Duration) -> Self {
        let cell = OnceLock::new();
        if let Some(config) = tls {
            let _ = cell.set(Ok(config));
        }
        Self { resolver, dialer, tls: cell, total }
    }

    fn perform(&self, request: &AiHttpRequest, cancellation: &AiCancellation, mut on_body: Option<OnBody<'_>>) -> Result<AiHttpResponse, AiClientError> {
        let invalid = || AiClientError::new(AiErrorKind::InvalidProfile, "The API base URL is invalid.");
        let needs_https = || AiClientError::new(AiErrorKind::InvalidProfile, "The API base URL must start with https://.");
        let url = Url::parse(&request.url).map_err(|_| invalid())?;
        if url.scheme() != "https" || url.host_str().is_none_or(str::is_empty) {
            return Err(needs_https());
        }
        if !url.username().is_empty() || url.password().is_some() {
            return Err(invalid());
        }
        if cancellation.is_cancelled() {
            return Err(AiClientError::cancelled());
        }
        // Read before connecting, so a missing certificate store is reported without touching the network.
        let tls = self.tls.get_or_init(system_tls_config).clone().map_err(|_| secure_connection_failed())?;
        let dialer = Arc::new(ConnectWithin { inner: self.dialer.clone(), limit: Duration::from_millis(request.connect_timeout_milliseconds) });
        let transport = HttpTransport::for_user_endpoint(self.resolver.clone(), dialer, Some(tls));

        let mut headers = request.headers.clone();
        // A compressed stream would arrive in bursts; a streamed reply is read line by line as it is written.
        headers.push(("Accept-Encoding".into(), "identity".into()));
        headers.push(("User-Agent".into(), fetch::DEFAULT_USER_AGENT.into()));
        let method = request.method.to_ascii_uppercase();
        let exchange = TransportRequest { method: &method, url: &url, headers: &headers, body: request.body.as_deref() };
        let cancel = cancellation.clone();
        let wait = Wait::new(self.total, Duration::from_millis(request.read_timeout_milliseconds), Some(Arc::new(move || cancel.is_cancelled())));

        let outcome = (|| -> Result<AiHttpResponse, Failure> {
            wait.arm()?;
            let mut response = transport.send(&exchange, &wait)?;
            let status = response.status;
            if cancellation.is_cancelled() {
                return Err(Failure::Client(AiClientError::cancelled()));
            }
            if (300..=399).contains(&status) {
                return Err(Failure::Client(AiClientError::with_status(AiErrorKind::Http, "The AI server answered with a redirect, which is not followed. Check the API base URL.", status)));
            }
            let success = (200..=299).contains(&status);
            let limit = if success { request.maximum_response_bytes } else { request.maximum_response_bytes.min(MAXIMUM_ERROR_BODY_BYTES) };
            let mut body: Vec<u8> = Vec::new();
            let mut chunk = vec![0u8; 16 * 1024];
            loop {
                wait.arm()?;
                let count = match response.body.read(&mut chunk) {
                    Ok(count) => count,
                    // An error body that breaks off is still an error response; what arrived is enough.
                    Err(_) if !success && !wait.cancelled() => 0,
                    Err(error) => return Err(Failure::Fetch(FetchError::from_io(error))),
                };
                if count == 0 {
                    break;
                }
                if body.len() + count > limit {
                    if success {
                        return Err(Failure::Client(AiClientError::new(AiErrorKind::ResponseTooLarge, "The AI response exceeded the size limit.")));
                    }
                    body.extend_from_slice(&chunk[..limit - body.len()]);
                    break;
                }
                body.extend_from_slice(&chunk[..count]);
                if success && let Some(on_body) = on_body.as_mut() {
                    on_body(&chunk[..count]).map_err(Failure::Client)?;
                }
            }
            Ok(AiHttpResponse { status, body })
        })();
        match outcome {
            _ if cancellation.is_cancelled() => Err(AiClientError::cancelled()),
            Ok(response) => Ok(response),
            Err(Failure::Client(error)) => Err(error),
            Err(Failure::Fetch(error)) => Err(describe(&error)),
        }
    }
}

enum Failure {
    Client(AiClientError),
    Fetch(FetchError),
}

impl From<FetchError> for Failure {
    fn from(error: FetchError) -> Self {
        Self::Fetch(error)
    }
}

fn secure_connection_failed() -> AiClientError {
    AiClientError::new(AiErrorKind::Network, "A secure connection to the AI server could not be established.")
}

/// A fixed sentence for what went wrong below. The text of the lower layer is
/// not forwarded: it can echo request details.
fn describe(error: &FetchError) -> AiClientError {
    match error {
        FetchError::Cancelled => AiClientError::cancelled(),
        FetchError::Failed(message) if message == fetch::TIMED_OUT_MESSAGE => AiClientError::new(AiErrorKind::Timeout, "The AI server did not answer in time. Try again."),
        FetchError::Failed(message) if message.starts_with("Could not resolve") => AiClientError::new(AiErrorKind::Network, "The AI server could not be found. Check the API base URL and your connection."),
        FetchError::Transport(message) => {
            let lower = message.to_lowercase();
            if ["certificate", "tls", "handshake", "alert"].iter().any(|word| lower.contains(word)) { secure_connection_failed() } else { AiClientError::new(AiErrorKind::Network, "The AI server could not be reached. Check your connection and try again.") }
        }
        FetchError::Failed(_) => AiClientError::new(AiErrorKind::Network, "The AI request could not be sent."),
    }
}

impl AiTransport for HttpsAiTransport {
    fn execute(&self, request: &AiHttpRequest, cancellation: &AiCancellation) -> Result<AiHttpResponse, AiClientError> {
        self.perform(request, cancellation, None)
    }

    fn execute_streaming(&self, request: &AiHttpRequest, cancellation: &AiCancellation, on_body: OnBody<'_>) -> Result<AiHttpResponse, AiClientError> {
        self.perform(request, cancellation, Some(on_body))
    }
}
