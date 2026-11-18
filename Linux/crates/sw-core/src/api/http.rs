//! The production transport of `fetch`: one HTTP/1.1 exchange over a socket
//! this module opened itself. The Linux counterpart of the
//! `SocketsHttpHandler` with a connect callback in
//! `Windows/src/ScriptWidget.Core/Api/FetchModule.cs`.
//!
//! Rules, all of them tested:
//! - the host is refused by name first; then every address it resolves to must
//!   be public, and the socket connects to one of exactly those addresses. The
//!   name is never resolved a second time by a lower layer;
//! - TLS is verified against the host name of the URL, whatever address the
//!   socket is connected to, with the certificate authorities of the system;
//! - no redirects, cookies, credentials or proxy. The proxy variables of the
//!   environment are not read: the address a proxy would reach cannot be
//!   checked here;
//! - every wait (connecting, the handshake and the response head, then each
//!   read of the body) is bounded by the caller's [`Wait`];
//! - the response head is at most 64 KiB; the body is delimited by
//!   `Content-Length`, by chunks, or by the end of the connection, and is
//!   handed on undecoded except for gzip and deflate.
//!
//! One connection serves one request (`Connection: close`). Widgets make a
//! handful of requests per refresh, and a connection that is never reused
//! cannot be reused for another host by mistake.

use std::io::{self, Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use rustls::pki_types::ServerName;
use rustls::{ClientConfig, ClientConnection, RootCertStore};

use crate::api::fetch::{FetchError, Resolver, Transport, TransportRequest, TransportResponse, Wait, unbracket, vetted_addresses};

/// Largest response head (status line and headers) accepted.
pub const MAXIMUM_HEAD_BYTES: usize = 64 * 1024;
const MAXIMUM_HEADERS: usize = 128;
const MAXIMUM_CHUNK_LINE_BYTES: usize = 1024;
/// How often a blocked socket operation looks at the clock and at cancellation.
const POLL: Duration = Duration::from_millis(100);
/// Headers that describe the connection itself; a script does not get to set them.
const CONNECTION_HEADERS: [&str; 8] = ["connection", "keep-alive", "proxy-connection", "transfer-encoding", "te", "trailer", "upgrade", "expect"];

/// Opens the TCP connection to an address that has been checked.
pub trait Dialer: Send + Sync {
    fn dial(&self, address: SocketAddr, timeout: Duration) -> io::Result<TcpStream>;
}

/// Connects to the address it is given, directly.
pub struct SystemDialer;

impl Dialer for SystemDialer {
    fn dial(&self, address: SocketAddr, timeout: Duration) -> io::Result<TcpStream> {
        TcpStream::connect_timeout(&address, timeout)
    }
}

pub struct HttpTransport {
    resolver: Resolver,
    dialer: Arc<dyn Dialer>,
    tls: OnceLock<Result<Arc<ClientConfig>, String>>,
}

impl HttpTransport {
    pub fn new(resolver: Resolver) -> Self {
        Self { resolver, dialer: Arc::new(SystemDialer), tls: OnceLock::new() }
    }

    /// The transport over another network: tests route the public addresses
    /// of their fixtures to listeners on this machine and trust their own
    /// certificate authority. The address checks stay in force. Only the host
    /// application constructs transports: package code cannot reach this.
    pub fn with_parts(resolver: Resolver, dialer: Arc<dyn Dialer>, tls: Option<Arc<ClientConfig>>) -> Self {
        let cell = OnceLock::new();
        if let Some(config) = tls {
            let _ = cell.set(Ok(config));
        }
        Self { resolver, dialer, tls: cell }
    }

    /// Opens the TCP connection for one request. The host is refused by name
    /// first; then every address it resolves to must be public, and the
    /// socket connects to one of exactly those addresses.
    pub fn connect(resolver: &Resolver, dialer: &dyn Dialer, host: &str, port: u16, wait: &Wait) -> Result<TcpStream, FetchError> {
        let addresses = vetted_addresses(resolver, host, true)?;
        let mut last = None;
        for address in addresses {
            match dialer.dial(SocketAddr::new(address, port), wait.remaining()?) {
                Ok(socket) => return Ok(socket),
                Err(error) => last = Some(error),
            }
        }
        Err(match last {
            Some(error) if error.kind() == io::ErrorKind::TimedOut => wait.remaining().err().unwrap_or_else(|| FetchError::Transport(error.to_string())),
            Some(error) => FetchError::Transport(error.to_string()),
            None => FetchError::Transport("No address to connect to".into()),
        })
    }

    fn tls_config(&self) -> Result<Arc<ClientConfig>, FetchError> {
        self.tls.get_or_init(system_tls_config).clone().map_err(FetchError::Transport)
    }
}

/// TLS 1.2 and 1.3 with the certificate authorities the system trusts.
fn system_tls_config() -> Result<Arc<ClientConfig>, String> {
    let mut roots = RootCertStore::empty();
    let found = rustls_native_certs::load_native_certs();
    let (added, _ignored) = roots.add_parsable_certificates(found.certs);
    if added == 0 {
        return Err("No trusted certificate authorities were found on this system".into());
    }
    client_config(roots)
}

/// A client configuration that trusts exactly `roots`.
pub fn client_config(roots: RootCertStore) -> Result<Arc<ClientConfig>, String> {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let mut config = ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .map_err(|error| error.to_string())?
        .with_root_certificates(roots)
        .with_no_client_auth();
    config.alpn_protocols = vec![b"http/1.1".to_vec()];
    Ok(Arc::new(config))
}

impl Transport for HttpTransport {
    fn send(&self, request: &TransportRequest<'_>, wait: &Wait) -> Result<TransportResponse, FetchError> {
        let url = request.url;
        let secure = match url.scheme() {
            "https" => true,
            "http" => false,
            _ => return Err(FetchError::failed("Only HTTP and HTTPS URLs are allowed")),
        };
        let host = url.host_str().unwrap_or("");
        let port = url.port_or_known_default().unwrap_or(if secure { 443 } else { 80 });
        // Read before connecting, so a missing certificate store is reported without touching the network.
        let tls = if secure { Some(self.tls_config()?) } else { None };

        let socket = Self::connect(&self.resolver, self.dialer.as_ref(), host, port, wait)?;
        let prepare = || -> io::Result<()> {
            socket.set_nodelay(true)?;
            socket.set_read_timeout(Some(POLL))?;
            socket.set_write_timeout(Some(POLL))
        };
        prepare().map_err(FetchError::from_io)?;
        let mut channel = Channel { socket, tls: None, wait: wait.clone() };
        if let Some(config) = tls {
            // The certificate must be valid for the name in the URL, not for the address.
            let name = ServerName::try_from(unbracket(host).to_owned()).map_err(|_| FetchError::Transport("The host name is not valid for TLS".into()))?;
            let connection = ClientConnection::new(config, name).map_err(|error| FetchError::Transport(error.to_string()))?;
            channel.tls = Some(Box::new(connection));
            channel.handshake().map_err(FetchError::from_io)?;
        }

        channel.write_all(&encode_head(request)).map_err(FetchError::from_io)?;
        if let Some(body) = request.body {
            channel.write_all(body).map_err(FetchError::from_io)?;
        }
        let mut source = Source { channel, buffer: Vec::new(), position: 0 };
        let (status, headers) = loop {
            let (status, headers) = read_head(&mut source)?;
            // Interim responses (100 Continue, 103 Early Hints) precede the real one.
            if !(100..200).contains(&status) || status == 101 {
                break (status, headers);
            }
        };
        respond(request.method, status, headers, source)
    }
}

/// The request line and headers, ending with the empty line.
fn encode_head(request: &TransportRequest<'_>) -> Vec<u8> {
    let url = request.url;
    let mut head = format!("{} {}", request.method, url.path());
    if let Some(query) = url.query() {
        head.push('?');
        head.push_str(query);
    }
    head.push_str(" HTTP/1.1\r\nHost: ");
    head.push_str(url.host_str().unwrap_or(""));
    if let Some(port) = url.port() {
        head.push_str(&format!(":{port}"));
    }
    head.push_str("\r\n");
    let mut accepts = false;
    for (name, value) in request.headers {
        let lower = name.to_ascii_lowercase();
        if lower == "host" || lower == "content-length" || CONNECTION_HEADERS.contains(&lower.as_str()) {
            continue;
        }
        // The caller validated both; this is the last line of defence against a second header line.
        if name.is_empty() || name.bytes().any(|byte| byte <= b' ' || byte >= 0x7f || byte == b':') || value.bytes().any(|byte| matches!(byte, b'\r' | b'\n' | 0)) {
            continue;
        }
        accepts |= lower == "accept-encoding";
        head.push_str(&format!("{name}: {value}\r\n"));
    }
    if !accepts {
        head.push_str("Accept-Encoding: gzip, deflate\r\n");
    }
    match request.body {
        Some(body) => head.push_str(&format!("Content-Length: {}\r\n", body.len())),
        None if matches!(request.method, "POST" | "PUT" | "PATCH") => head.push_str("Content-Length: 0\r\n"),
        None => {}
    }
    head.push_str("Connection: close\r\n\r\n");
    head.into_bytes()
}

fn invalid_response() -> FetchError {
    FetchError::Transport("The server sent an invalid response".into())
}

fn read_head(source: &mut Source) -> Result<(u16, Vec<(String, String)>), FetchError> {
    loop {
        let available = &source.buffer[source.position..];
        if !available.is_empty() {
            let mut slots = [httparse::EMPTY_HEADER; MAXIMUM_HEADERS];
            let mut response = httparse::Response::new(&mut slots);
            match response.parse(available) {
                Ok(httparse::Status::Complete(length)) => {
                    let status = response.code.ok_or_else(invalid_response)?;
                    let headers = response.headers.iter().map(|header| (header.name.to_owned(), String::from_utf8_lossy(header.value).trim().to_owned())).collect();
                    source.position += length;
                    return Ok((status, headers));
                }
                Ok(httparse::Status::Partial) => {}
                Err(_) => return Err(invalid_response()),
            }
            if available.len() > MAXIMUM_HEAD_BYTES {
                return Err(FetchError::Transport("The response headers are too large".into()));
            }
        }
        if source.fill().map_err(FetchError::from_io)? == 0 {
            return Err(FetchError::Transport("The connection closed before a response arrived".into()));
        }
    }
}

fn header<'a>(headers: &'a [(String, String)], name: &str) -> Option<&'a str> {
    headers.iter().rev().find(|(known, _)| known.eq_ignore_ascii_case(name)).map(|(_, value)| value.as_str())
}

/// Chooses how the body is delimited and decoded.
fn respond(method: &str, status: u16, mut headers: Vec<(String, String)>, source: Source) -> Result<TransportResponse, FetchError> {
    let chunked = headers
        .iter()
        .filter(|(name, _)| name.eq_ignore_ascii_case("transfer-encoding"))
        .flat_map(|(_, value)| value.split(','))
        .any(|coding| coding.trim().eq_ignore_ascii_case("chunked"));
    let mut lengths = headers.iter().filter(|(name, _)| name.eq_ignore_ascii_case("content-length")).map(|(_, value)| value.as_str());
    let length = match lengths.next() {
        None => None,
        Some(first) => {
            // Two different lengths describe two different bodies: neither is believed.
            if lengths.any(|other| other != first) || first.is_empty() || !first.bytes().all(|byte| byte.is_ascii_digit()) {
                return Err(invalid_response());
            }
            Some(first.parse::<u64>().map_err(|_| invalid_response())?)
        }
    };
    let framing = if method == "HEAD" || status == 204 || status == 304 || (100..200).contains(&status) {
        Framing::Done
    } else if chunked {
        Framing::ChunkSize
    } else if let Some(length) = length {
        if length == 0 { Framing::Done } else { Framing::Length(length) }
    } else {
        Framing::UntilClose
    };
    let empty = matches!(framing, Framing::Done);
    let raw = RawBody { source, framing };
    let coding = header(&headers, "content-encoding").map(|value| value.trim().to_ascii_lowercase()).unwrap_or_default();
    let body: Box<dyn Read> = match coding.as_str() {
        _ if empty => Box::new(raw),
        "gzip" | "x-gzip" => Box::new(flate2::read::GzDecoder::new(raw)),
        "deflate" => Box::new(flate2::read::ZlibDecoder::new(raw)),
        _ => return Ok(TransportResponse { status, headers, body: Box::new(raw) }),
    };
    if !empty {
        // The body is handed on decoded: its encoding and its encoded length no longer describe it.
        headers.retain(|(name, _)| !name.eq_ignore_ascii_case("content-encoding") && !name.eq_ignore_ascii_case("content-length"));
    }
    Ok(TransportResponse { status, headers, body })
}

/// The socket, with TLS when the URL asks for it. Every operation waits no
/// longer than the current wait allows.
struct Channel {
    socket: TcpStream,
    tls: Option<Box<ClientConnection>>,
    wait: Wait,
}

/// The socket as a blocking stream that gives up when the wait is over or the execution ended.
struct Patient<'a> {
    socket: &'a TcpStream,
    wait: &'a Wait,
}

fn timed_out(error: &io::Error) -> bool {
    matches!(error.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut | io::ErrorKind::Interrupted)
}

impl Read for Patient<'_> {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        loop {
            self.wait.remaining().map_err(FetchError::into_io)?;
            match self.socket.read(buffer) {
                Err(error) if timed_out(&error) => {}
                other => return other,
            }
        }
    }
}

impl Write for Patient<'_> {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        loop {
            self.wait.remaining().map_err(FetchError::into_io)?;
            match self.socket.write(buffer) {
                Err(error) if timed_out(&error) => {}
                other => return other,
            }
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        self.socket.flush()
    }
}

impl Channel {
    fn handshake(&mut self) -> io::Result<()> {
        let Some(connection) = self.tls.as_mut() else { return Ok(()) };
        let mut patient = Patient { socket: &self.socket, wait: &self.wait };
        while connection.is_handshaking() {
            connection.complete_io(&mut patient)?;
        }
        Ok(())
    }

    fn write_all(&mut self, data: &[u8]) -> io::Result<()> {
        let mut patient = Patient { socket: &self.socket, wait: &self.wait };
        match self.tls.as_mut() {
            None => patient.write_all(data),
            Some(connection) => {
                // Encrypt everything first, then send: a write that times out halfway is not repeated.
                connection.set_buffer_limit(None);
                connection.writer().write_all(data)?;
                while connection.wants_write() {
                    connection.write_tls(&mut patient)?;
                }
                Ok(())
            }
        }
    }

    /// Bytes of the response, or 0 at the end of the connection.
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        let mut patient = Patient { socket: &self.socket, wait: &self.wait };
        let Some(connection) = self.tls.as_mut() else { return patient.read(buffer) };
        loop {
            match connection.reader().read(buffer) {
                Ok(count) => return Ok(count),
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
                // The peer closed the connection without saying so. Like the Windows transport this
                // counts as the end of the data; a body with a declared length that is cut short is
                // still an error, because its length is checked.
                Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => return Ok(0),
                Err(error) => return Err(error),
            }
            connection.read_tls(&mut patient)?;
            connection.process_new_packets().map_err(io::Error::other)?;
            while connection.wants_write() {
                connection.write_tls(&mut patient)?;
            }
        }
    }
}

/// The channel with the bytes that were read past the response head.
struct Source {
    channel: Channel,
    buffer: Vec<u8>,
    position: usize,
}

impl Source {
    /// Reads more into the buffer; 0 at the end of the connection.
    fn fill(&mut self) -> io::Result<usize> {
        if self.position > 0 && self.position == self.buffer.len() {
            self.buffer.clear();
            self.position = 0;
        }
        let start = self.buffer.len();
        self.buffer.resize(start + 8 * 1024, 0);
        let result = self.channel.read(&mut self.buffer[start..]);
        self.buffer.truncate(start + *result.as_ref().unwrap_or(&0));
        result
    }

    fn read(&mut self, target: &mut [u8]) -> io::Result<usize> {
        if self.position == self.buffer.len() && self.fill()? == 0 {
            return Ok(0);
        }
        let count = target.len().min(self.buffer.len() - self.position);
        target[..count].copy_from_slice(&self.buffer[self.position..self.position + count]);
        self.position += count;
        Ok(count)
    }

    /// One line without its line break, at most `MAXIMUM_CHUNK_LINE_BYTES` long.
    fn line(&mut self) -> io::Result<String> {
        let mut line = Vec::new();
        loop {
            let mut byte = [0u8; 1];
            if self.read(&mut byte)? == 0 {
                return Err(ended_early());
            }
            if byte[0] == b'\n' {
                if line.last() == Some(&b'\r') {
                    line.pop();
                }
                return String::from_utf8(line).map_err(|_| invalid_response().into_io());
            }
            line.push(byte[0]);
            if line.len() > MAXIMUM_CHUNK_LINE_BYTES {
                return Err(invalid_response().into_io());
            }
        }
    }
}

fn ended_early() -> io::Error {
    FetchError::Transport("The response ended early".into()).into_io()
}

enum Framing {
    Done,
    Length(u64),
    ChunkSize,
    ChunkData(u64),
    UntilClose,
}

/// The body as the server delimited it, before any decoding.
struct RawBody {
    source: Source,
    framing: Framing,
}

impl Read for RawBody {
    fn read(&mut self, target: &mut [u8]) -> io::Result<usize> {
        if target.is_empty() {
            return Ok(0);
        }
        loop {
            match self.framing {
                Framing::Done => return Ok(0),
                Framing::UntilClose => return self.source.read(target),
                Framing::Length(left) | Framing::ChunkData(left) => {
                    let limit = target.len().min(usize::try_from(left).unwrap_or(usize::MAX));
                    let count = self.source.read(&mut target[..limit])?;
                    if count == 0 {
                        return Err(ended_early());
                    }
                    let left = left - count as u64;
                    self.framing = match self.framing {
                        Framing::Length(_) if left == 0 => Framing::Done,
                        Framing::Length(_) => Framing::Length(left),
                        _ if left == 0 => {
                            if !self.source.line()?.is_empty() {
                                return Err(invalid_response().into_io());
                            }
                            Framing::ChunkSize
                        }
                        _ => Framing::ChunkData(left),
                    };
                    return Ok(count);
                }
                Framing::ChunkSize => {
                    let line = self.source.line()?;
                    let digits = line.split(';').next().unwrap_or("").trim();
                    if digits.is_empty() || digits.len() > 16 || !digits.bytes().all(|byte| byte.is_ascii_hexdigit()) {
                        return Err(invalid_response().into_io());
                    }
                    let size = u64::from_str_radix(digits, 16).map_err(|_| invalid_response().into_io())?;
                    if size == 0 {
                        // Trailers are read and dropped.
                        while !self.source.line()?.is_empty() {}
                        self.framing = Framing::Done;
                    } else {
                        self.framing = Framing::ChunkData(size);
                    }
                }
            }
        }
    }
}
