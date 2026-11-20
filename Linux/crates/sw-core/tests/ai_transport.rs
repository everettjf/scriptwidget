//! The AI transport over real sockets: HTTPS only, a streamed body as it
//! arrives, no redirects, limits, timeouts, cancellation, and failures that
//! never repeat what a lower layer said.
//!
//! Nothing here reaches the Internet: the servers listen on this machine, the
//! resolver of the tests answers their names with 127.0.0.1, and the
//! certificate is one made for these tests.

use std::io::{Read, Write};
use std::net::{IpAddr, SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use rustls::pki_types::pem::PemObject;
use rustls::pki_types::{CertificateDer, PrivateKeyDer};
use sw_core::ai::*;
use sw_core::api::fetch::Resolver;
use sw_core::api::http::{Dialer, SystemDialer, client_config};

const KEY: &str = "sk-transport-SECRET-55aa";

// A certificate for secure.example.com that signs itself, made for the tests
// of this crate only (the one of `api_http.rs`, valid until 2126). The key protects nothing.
const CERTIFICATE: &str = "-----BEGIN CERTIFICATE-----
MIIBhzCCAS2gAwIBAgIJAOotGN6ePOf3MAoGCCqGSM49BAMCMB0xGzAZBgNVBAMM
EnNlY3VyZS5leGFtcGxlLmNvbTAgFw0yNjExMTgwNDE0NDNaGA8yMTI2MTAyNTA0
MTQ0M1owHTEbMBkGA1UEAwwSc2VjdXJlLmV4YW1wbGUuY29tMFkwEwYHKoZIzj0C
AQYIKoZIzj0DAQcDQgAEUWTZstAJrWCtM8bb6oUDS/opdmumxe0NrEG5pvQ+IiJ4
Wl5sk/uESXV+WPy98bnqWcvcpDkI8tIU4uAxNMqxm6NUMFIwHQYDVR0RBBYwFIIS
c2VjdXJlLmV4YW1wbGUuY29tMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgeA
MBMGA1UdJQQMMAoGCCsGAQUFBwMBMAoGCCqGSM49BAMCA0gAMEUCIFjz65KVKyvh
UgjoRKWCEKSlKF6eJfB4Kc+irvbEdG4KAiEAkeLb1l+o2fK7h128sV+nYvhXOmfs
ooC8P7eLdL2emyg=
-----END CERTIFICATE-----
";
const TEST_ONLY_KEY: &str = "-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQg7499otSzGQP1kRG/
ieeAblKYaw4QFwFxAntSehzjmKOhRANCAARRZNmy0AmtYK0zxtvqhQNL+il2a6bF
7Q2sQbmm9D4iInhaXmyT+4RJdX5Y/L3xuepZy9ykOQjy0hTi4DE0yrGb
-----END PRIVATE KEY-----
";


fn server_config() -> Arc<rustls::ServerConfig> {
    let certificate = CertificateDer::from_pem_slice(CERTIFICATE.as_bytes()).expect("certificate");
    let key = PrivateKeyDer::from_pem_slice(TEST_ONLY_KEY.as_bytes()).expect("key");
    Arc::new(rustls::ServerConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider())).with_safe_default_protocol_versions().unwrap().with_no_client_auth().with_single_cert(vec![certificate], key).expect("server configuration"))
}

fn trusting() -> Arc<rustls::ClientConfig> {
    let mut roots = rustls::RootCertStore::empty();
    roots.add(CertificateDer::from_pem_slice(CERTIFICATE.as_bytes()).unwrap()).unwrap();
    client_config(roots).unwrap()
}

struct Server {
    port: u16,
    /// The head and body of each request, as text.
    seen: Arc<Mutex<Vec<String>>>,
}

/// An HTTPS server on this machine; `plain` makes it speak HTTP without TLS.
fn serve(plain: bool, handler: impl Fn(&str, &mut dyn Write) + Send + Sync + 'static) -> Server {
    let listener = TcpListener::bind("127.0.0.1:0").expect("listener");
    let port = listener.local_addr().unwrap().port();
    let seen: Arc<Mutex<Vec<String>>> = Arc::default();
    let record = seen.clone();
    let handler = Arc::new(handler);
    std::thread::spawn(move || {
        for socket in listener.incoming().flatten() {
            let (handler, record) = (handler.clone(), record.clone());
            std::thread::spawn(move || {
                let _ = socket.set_read_timeout(Some(Duration::from_secs(10)));
                let serve_on = |stream: &mut dyn ReadWrite| {
                    if let Some(request) = read_request(stream) {
                        record.lock().unwrap().push(request.clone());
                        handler(&request, stream.as_write());
                    }
                };
                if plain {
                    let mut socket = socket;
                    serve_on(&mut socket);
                } else if let Ok(connection) = rustls::ServerConnection::new(server_config()) {
                    let mut stream = rustls::StreamOwned::new(connection, socket);
                    serve_on(&mut stream);
                    stream.conn.send_close_notify();
                    let _ = stream.flush();
                }
            });
        }
    });
    Server { port, seen }
}

trait ReadWrite: Read + Write {
    fn as_write(&mut self) -> &mut dyn Write;
}

impl<T: Read + Write> ReadWrite for T {
    fn as_write(&mut self) -> &mut dyn Write {
        self
    }
}

fn read_request(stream: &mut dyn ReadWrite) -> Option<String> {
    let mut data = Vec::new();
    let mut chunk = [0u8; 4096];
    let end = loop {
        if let Some(end) = data.windows(4).position(|window| window == b"\r\n\r\n") {
            break end + 4;
        }
        match stream.read(&mut chunk) {
            Ok(count) if count > 0 => data.extend_from_slice(&chunk[..count]),
            _ => return None,
        }
    };
    let head = String::from_utf8_lossy(&data[..end]).into_owned();
    let length: usize = head.lines().filter_map(|line| line.split_once(':')).find(|(name, _)| name.eq_ignore_ascii_case("content-length")).and_then(|(_, value)| value.trim().parse().ok()).unwrap_or(0);
    while data.len() < end + length {
        match stream.read(&mut chunk) {
            Ok(count) if count > 0 => data.extend_from_slice(&chunk[..count]),
            _ => break,
        }
    }
    Some(String::from_utf8_lossy(&data).into_owned())
}

fn respond(status: &str, headers: &[(&str, &str)], body: &[u8]) -> Vec<u8> {
    let mut response = format!("HTTP/1.1 {status}\r\n");
    for (name, value) in headers {
        response.push_str(&format!("{name}: {value}\r\n"));
    }
    response.push_str(&format!("Content-Length: {}\r\n\r\n", body.len()));
    let mut bytes = response.into_bytes();
    bytes.extend_from_slice(body);
    bytes
}

fn chunk(text: &str) -> Vec<u8> {
    format!("{:x}\r\n{text}\r\n", text.len()).into_bytes()
}

/// Every name is this machine, as an endpoint in the user's own network would be.
fn local() -> Resolver {
    Arc::new(|host: &str| if host == "unknown.example.com" { Err(std::io::Error::other("no such host")) } else { Ok(vec![IpAddr::from([127, 0, 0, 1])]) })
}

fn transport() -> HttpsAiTransport {
    HttpsAiTransport::with_parts(local(), Arc::new(SystemDialer), Some(trusting()), Duration::from_secs(20))
}

fn request(method: &str, url: String, body: Option<&str>) -> AiHttpRequest {
    AiHttpRequest {
        method: method.into(),
        url,
        headers: vec![("x-api-key".into(), KEY.into()), ("Content-Type".into(), "application/json".into())],
        body: body.map(|text| text.as_bytes().to_vec()),
        connect_timeout_milliseconds: 2_000,
        read_timeout_milliseconds: 5_000,
        maximum_response_bytes: 256 * 1024,
    }
}

fn url(server: &Server, path: &str) -> String {
    format!("https://secure.example.com:{}{path}", server.port)
}

fn assert_no_key(error: &AiClientError) {
    assert!(!error.message.contains(KEY) && !format!("{error:?}").contains(KEY), "{error:?}");
}

#[test]
fn a_request_goes_out_over_https_with_its_headers_and_body() {
    let server = serve(false, |_, output| {
        let _ = output.write_all(&respond("200 OK", &[("Content-Type", "application/json")], b"{\"ok\":true}"));
    });
    let response = transport().execute(&request("POST", url(&server, "/v1/messages"), Some("{\"model\":\"m\"}")), &AiCancellation::new()).unwrap();
    assert_eq!((response.status, response.body.as_slice()), (200, &b"{\"ok\":true}"[..]));
    let seen = server.seen.lock().unwrap().remove(0);
    let head = seen.split("\r\n\r\n").next().unwrap().to_lowercase();
    assert!(seen.starts_with("POST /v1/messages HTTP/1.1\r\n"), "{seen}");
    for line in [format!("host: secure.example.com:{}", server.port), format!("x-api-key: {}", KEY.to_lowercase()), "content-length: 13".into(), "accept-encoding: identity".into(), "connection: close".into()] {
        assert!(head.contains(&line), "{line} in {head}");
    }
    assert!(head.contains("user-agent: scriptwidget-linux/"));
    assert!(seen.ends_with("{\"model\":\"m\"}"));
}

/// A streamed reply is handed on while the server is still writing it.
#[test]
fn a_streamed_body_arrives_piece_by_piece() {
    let first_read = Arc::new(AtomicBool::new(false));
    let waiting = first_read.clone();
    let server = serve(false, move |_, output| {
        let _ = output.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n");
        let _ = output.write_all(&chunk("data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello \"}}\n\n"));
        let _ = output.flush();
        // The rest is written only once the client has read the first piece.
        let started = Instant::now();
        while !waiting.load(Ordering::SeqCst) && started.elapsed() < Duration::from_secs(10) {
            std::thread::sleep(Duration::from_millis(5));
        }
        let rest = if waiting.load(Ordering::SeqCst) { "there" } else { "TOO LATE" };
        let _ = output.write_all(&chunk(&format!("data: {{\"type\":\"content_block_delta\",\"delta\":{{\"type\":\"text_delta\",\"text\":\"{rest}\"}}}}\n\n")));
        let _ = output.write_all(&chunk("data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n"));
        let _ = output.write_all(b"0\r\n\r\n");
    });
    // Through the client, as the applications use it.
    let settings = AiSettings::new(AiProfile::new(AiProviderKind::Anthropic, format!("https://secure.example.com:{}", server.port), "m"));
    let mut seen: Vec<String> = Vec::new();
    let result = AiClient::new(transport())
        .chat_stream(&[AiMessage::new(Role::User, "hi")], &settings, KEY, &AiCancellation::new(), &mut |text| {
            first_read.store(true, Ordering::SeqCst);
            seen.push(text.to_owned());
        })
        .unwrap();
    assert_eq!(result.content, "Hello there");
    assert_eq!(seen.first().map(String::as_str), Some("Hello "), "the first piece was reported before the reply was complete");
    let sent = server.seen.lock().unwrap().remove(0);
    assert!(sent.starts_with("POST /v1/messages HTTP/1.1") && sent.contains("\"stream\":true") && sent.to_lowercase().contains("accept: text/event-stream"));
}

/// A dialer that must never be reached.
struct NoDialer(AtomicUsize);

impl Dialer for NoDialer {
    fn dial(&self, _: SocketAddr, _: Duration) -> std::io::Result<TcpStream> {
        self.0.fetch_add(1, Ordering::SeqCst);
        Err(std::io::ErrorKind::ConnectionRefused.into())
    }
}

/// As on Android: plain HTTP is refused for every host, this machine included, before anything is resolved or sent.
#[test]
fn plain_http_is_refused_without_connecting() {
    let dialer = Arc::new(NoDialer(AtomicUsize::new(0)));
    let resolved = Arc::new(AtomicUsize::new(0));
    let counted = resolved.clone();
    let resolver: Resolver = Arc::new(move |_: &str| {
        counted.fetch_add(1, Ordering::SeqCst);
        Ok(vec![IpAddr::from([127, 0, 0, 1])])
    });
    let transport = HttpsAiTransport::with_parts(resolver, dialer.clone(), Some(trusting()), Duration::from_secs(5));
    for address in ["http://127.0.0.1:9/v1/models", "http://localhost:11434/v1/chat/completions", "http://api.example.com/v1/models", "ftp://example.com/x", "not a url", "https://user:pass@secure.example.com/v1/models"] {
        let error = transport.execute(&request("GET", address.into(), None), &AiCancellation::new()).unwrap_err();
        assert_eq!(error.kind, AiErrorKind::InvalidProfile, "{address}");
        assert_no_key(&error);
        let streamed = transport.execute_streaming(&request("POST", address.into(), Some("{}")), &AiCancellation::new(), &mut |_| Ok(())).unwrap_err();
        assert_eq!(streamed.kind, AiErrorKind::InvalidProfile, "{address}");
    }
    assert_eq!((dialer.0.load(Ordering::SeqCst), resolved.load(Ordering::SeqCst)), (0, 0));
    // The production transport itself, with no network at all.
    let error = HttpsAiTransport::new().execute(&request("GET", "http://127.0.0.1:9/v1/models".into(), None), &AiCancellation::new()).unwrap_err();
    assert_eq!(error.kind, AiErrorKind::InvalidProfile);
}

/// A server that speaks plain HTTP on the port is a failure, never a downgrade: the key is not sent.
#[test]
fn a_server_without_tls_gets_no_request() {
    let server = serve(true, |_, output| {
        let _ = output.write_all(&respond("200 OK", &[], b"plain"));
    });
    let mut request = request("POST", url(&server, "/v1/messages"), Some("{}"));
    request.read_timeout_milliseconds = 500;
    let error = transport().execute(&request, &AiCancellation::new()).unwrap_err();
    // Such a server waits for a request line while this side waits for its TLS answer, or it answers with what is not TLS.
    assert!(matches!(error.kind, AiErrorKind::Timeout | AiErrorKind::Network), "{error:?}");
    assert_no_key(&error);
    assert!(server.seen.lock().unwrap().iter().all(|request| !request.contains(KEY)), "the key never left in the clear");
}

#[test]
fn a_redirect_is_not_followed() {
    let elsewhere = serve(false, |_, output| {
        let _ = output.write_all(&respond("200 OK", &[], b"stolen"));
    });
    let target = format!("https://other.example.com:{}/collect", elsewhere.port);
    let server = serve(false, move |_, output| {
        let _ = output.write_all(&respond("307 Temporary Redirect", &[("Location", target.as_str())], b""));
    });
    for streamed in [false, true] {
        let request = request("POST", url(&server, "/v1/messages"), Some("{}"));
        let result = if streamed { transport().execute_streaming(&request, &AiCancellation::new(), &mut |_| Ok(())) } else { transport().execute(&request, &AiCancellation::new()) };
        let error = result.unwrap_err();
        assert_eq!((error.kind, error.http_status), (AiErrorKind::Http, Some(307)));
        assert!(error.message.contains("redirect"));
    }
    assert!(elsewhere.seen.lock().unwrap().is_empty(), "the key was not carried to another host");
}

#[test]
fn responses_are_bounded() {
    let server = serve(false, |request, output| {
        let status = if request.contains("/error") { "500 Internal Server Error" } else { "200 OK" };
        let _ = output.write_all(&respond(status, &[], &vec![b'x'; 300 * 1024]));
    });
    let large = transport().execute(&request("GET", url(&server, "/large"), None), &AiCancellation::new()).unwrap_err();
    assert_eq!(large.kind, AiErrorKind::ResponseTooLarge);
    let mut received = 0;
    let streamed = transport()
        .execute_streaming(&request("GET", url(&server, "/large"), None), &AiCancellation::new(), &mut |piece| {
            received += piece.len();
            Ok(())
        })
        .unwrap_err();
    assert_eq!(streamed.kind, AiErrorKind::ResponseTooLarge);
    assert!(received <= 256 * 1024);
    // An error body is cut short, not refused: only a short code is ever read from it.
    let error = transport().execute(&request("GET", url(&server, "/error"), None), &AiCancellation::new()).unwrap();
    assert_eq!((error.status, error.body.len()), (500, 64 * 1024));
    // What the reader of a stream refuses ends the exchange with its own error.
    let refused = transport().execute_streaming(&request("GET", url(&server, "/large"), None), &AiCancellation::new(), &mut |_| Err(AiClientError::new(AiErrorKind::MalformedResponse, "stop"))).unwrap_err();
    assert_eq!((refused.kind, refused.message.as_str()), (AiErrorKind::MalformedResponse, "stop"));
}

#[test]
fn a_server_that_does_not_answer_times_out() {
    let server = serve(false, |_, _| std::thread::sleep(Duration::from_secs(4)));
    let mut request = request("POST", url(&server, "/v1/messages"), Some("{}"));
    request.read_timeout_milliseconds = 400;
    let started = Instant::now();
    let error = transport().execute(&request, &AiCancellation::new()).unwrap_err();
    assert_eq!(error.kind, AiErrorKind::Timeout);
    assert!(started.elapsed() < Duration::from_secs(3), "{:?}", started.elapsed());
    // The total time is a limit of its own, whatever keeps arriving.
    let dripping = serve(false, |_, output| {
        let _ = output.write_all(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n");
        for _ in 0..200 {
            if output.write_all(&chunk("data: {}\n\n")).and_then(|()| output.flush()).is_err() {
                break;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    });
    let limited = HttpsAiTransport::with_parts(local(), Arc::new(SystemDialer), Some(trusting()), Duration::from_millis(700));
    let started = Instant::now();
    let error = limited.execute_streaming(&self::request("POST", url(&dripping, "/v1/messages"), Some("{}")), &AiCancellation::new(), &mut |_| Ok(())).unwrap_err();
    assert_eq!(error.kind, AiErrorKind::Timeout);
    assert!(started.elapsed() < Duration::from_secs(4), "{:?}", started.elapsed());
}

#[test]
fn cancelling_ends_a_request_that_is_waiting() {
    let server = serve(false, |_, _| std::thread::sleep(Duration::from_secs(5)));
    let cancellation = AiCancellation::new();
    let later = cancellation.clone();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(250));
        later.cancel();
    });
    let started = Instant::now();
    let error = transport().execute(&request("POST", url(&server, "/v1/messages"), Some("{}")), &cancellation).unwrap_err();
    assert_eq!(error.kind, AiErrorKind::Cancelled);
    assert!(started.elapsed() < Duration::from_secs(3), "{:?}", started.elapsed());
    // Cancelled before it starts: nothing is sent.
    let before = server.seen.lock().unwrap().len();
    assert_eq!(transport().execute(&request("POST", url(&server, "/v1/messages"), Some("{}")), &cancellation).unwrap_err().kind, AiErrorKind::Cancelled);
    assert_eq!(server.seen.lock().unwrap().len(), before);
}

#[test]
fn failures_below_are_fixed_sentences_without_the_key() {
    let server = serve(false, |_, output| {
        let _ = output.write_all(&respond("200 OK", &[], b"ok"));
    });
    // The certificate of the tests is not one the system trusts.
    let system = HttpsAiTransport::with_parts(local(), Arc::new(SystemDialer), None, Duration::from_secs(10));
    let untrusted = system.execute(&request("POST", url(&server, "/v1/messages"), Some("{}")), &AiCancellation::new()).unwrap_err();
    assert_eq!((untrusted.kind, untrusted.message.as_str()), (AiErrorKind::Network, "A secure connection to the AI server could not be established."));
    // The certificate does not cover another name, whatever address answers.
    let other = transport().execute(&request("POST", format!("https://other.example.com:{}/v1/messages", server.port), Some("{}")), &AiCancellation::new()).unwrap_err();
    assert_eq!(other.message, "A secure connection to the AI server could not be established.");
    let unknown = transport().execute(&request("POST", "https://unknown.example.com/v1/messages".into(), Some("{}")), &AiCancellation::new()).unwrap_err();
    assert_eq!((unknown.kind, unknown.message.as_str()), (AiErrorKind::Network, "The AI server could not be found. Check the API base URL and your connection."));
    // Nobody listens on this port.
    let closed = TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    let refused = transport().execute(&request("POST", format!("https://secure.example.com:{closed}/v1/messages"), Some("{}")), &AiCancellation::new()).unwrap_err();
    assert_eq!((refused.kind, refused.message.as_str()), (AiErrorKind::Network, "The AI server could not be reached. Check your connection and try again."));
    for error in [&untrusted, &other, &unknown, &refused] {
        assert_no_key(error);
        assert!(std::error::Error::source(error).is_none());
    }
    assert!(server.seen.lock().unwrap().is_empty(), "no request was sent over a connection that failed verification");
}
