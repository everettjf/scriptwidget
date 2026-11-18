//! The production transport of `fetch` over real sockets: the connect step,
//! HTTP/1.1 framing, TLS, limits, timeouts and redirects.
//!
//! Nothing here reaches the Internet. The servers listen on this machine,
//! which the transport refuses to connect to, as it must. The tests therefore
//! replace the two things the host application may replace: the resolver,
//! which answers the fixture names with public addresses, and the dialer,
//! which routes those addresses to the local listeners (the counterpart of
//! the replaceable resolver and handler of the Windows tests). Every address
//! check stays in force, and package code can reach neither hook.

mod api_common;

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use api_common::*;
use rustls::pki_types::pem::PemObject;
use rustls::pki_types::{CertificateDer, PrivateKeyDer};
use sw_core::api::fetch::{self, FetchError, FetchModule, Resolver, Wait, system_resolver};
use sw_core::api::http::{Dialer, HttpTransport, SystemDialer, client_config};

/// One request as a test server received it.
#[derive(Debug, Clone)]
struct Seen {
    head: String,
    body: Vec<u8>,
}

impl Seen {
    fn line(&self) -> &str {
        self.head.lines().next().unwrap_or("")
    }

    fn path(&self) -> &str {
        self.line().split(' ').nth(1).unwrap_or("")
    }

    fn header(&self, name: &str) -> Option<&str> {
        self.head.lines().skip(1).filter_map(|line| line.split_once(':')).find(|(known, _)| known.eq_ignore_ascii_case(name)).map(|(_, value)| value.trim())
    }
}

type Handler = Arc<dyn Fn(&Seen, &mut dyn Write) + Send + Sync>;

struct Server {
    port: u16,
    seen: Arc<Mutex<Vec<Seen>>>,
    connections: Arc<AtomicUsize>,
}

impl Server {
    fn seen(&self) -> Vec<Seen> {
        self.seen.lock().unwrap().clone()
    }
}

fn read_request(stream: &mut dyn Read) -> Option<Seen> {
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
    let seen = Seen { head, body: Vec::new() };
    let length: usize = seen.header("Content-Length").and_then(|text| text.parse().ok()).unwrap_or(0);
    let mut body = data[end..].to_vec();
    while body.len() < length {
        match stream.read(&mut chunk) {
            Ok(count) if count > 0 => body.extend_from_slice(&chunk[..count]),
            _ => break,
        }
    }
    Some(Seen { body, ..seen })
}

/// A server on this machine. `tls` makes it speak HTTPS with that configuration.
fn serve(tls: Option<Arc<rustls::ServerConfig>>, handler: impl Fn(&Seen, &mut dyn Write) + Send + Sync + 'static) -> Server {
    let listener = TcpListener::bind("127.0.0.1:0").expect("listener");
    let port = listener.local_addr().unwrap().port();
    let seen: Arc<Mutex<Vec<Seen>>> = Arc::default();
    let connections: Arc<AtomicUsize> = Arc::default();
    let handler: Handler = Arc::new(handler);
    let (record, count) = (seen.clone(), connections.clone());
    std::thread::spawn(move || {
        for socket in listener.incoming().flatten() {
            count.fetch_add(1, Ordering::SeqCst);
            let (handler, record, tls) = (handler.clone(), record.clone(), tls.clone());
            std::thread::spawn(move || {
                let _ = socket.set_read_timeout(Some(Duration::from_secs(10)));
                let mut socket = socket;
                match tls {
                    None => {
                        if let Some(request) = read_request(&mut socket) {
                            record.lock().unwrap().push(request.clone());
                            handler(&request, &mut socket);
                        }
                    }
                    Some(config) => {
                        let Ok(connection) = rustls::ServerConnection::new(config) else { return };
                        let mut stream = rustls::StreamOwned::new(connection, socket);
                        if let Some(request) = read_request(&mut stream) {
                            record.lock().unwrap().push(request.clone());
                            handler(&request, &mut stream);
                            stream.conn.send_close_notify();
                            let _ = stream.flush();
                        }
                    }
                }
            });
        }
    });
    Server { port, seen, connections }
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

/// Routes every address to a listener on this machine and records what it was asked for.
struct Routed {
    port: u16,
    dialed: Mutex<Vec<SocketAddr>>,
    /// Addresses that refuse the connection.
    dead: Vec<SocketAddr>,
}

impl Routed {
    fn to(port: u16) -> Arc<Self> {
        Arc::new(Self { port, dialed: Mutex::default(), dead: Vec::new() })
    }

    fn dialed(&self) -> Vec<String> {
        self.dialed.lock().unwrap().iter().map(SocketAddr::to_string).collect()
    }
}

impl Dialer for Routed {
    fn dial(&self, address: SocketAddr, timeout: Duration) -> std::io::Result<TcpStream> {
        self.dialed.lock().unwrap().push(address);
        if self.dead.contains(&address) {
            return Err(std::io::ErrorKind::ConnectionRefused.into());
        }
        TcpStream::connect_timeout(&SocketAddr::from(([127, 0, 0, 1], self.port)), timeout)
    }
}

/// A dialer that must never be reached.
struct NoDialer(AtomicUsize);

impl Dialer for NoDialer {
    fn dial(&self, _: SocketAddr, _: Duration) -> std::io::Result<TcpStream> {
        self.0.fetch_add(1, Ordering::SeqCst);
        Err(std::io::ErrorKind::ConnectionRefused.into())
    }
}

/// The names of the fixtures: public ones, and one that points into a private network.
fn fixture_resolver() -> Resolver {
    Arc::new(|host: &str| match host {
        "internal.example.com" => Ok(addresses(&["10.0.0.8"])),
        "six.example.com" => Ok(addresses(&["2606:2800:220:1:248:1893:25c8:1946"])),
        "unknown.example.com" => Err(std::io::Error::other("no such host")),
        // An address literal is itself, as with the system resolver.
        literal if literal.parse::<std::net::IpAddr>().is_ok() => Ok(addresses(&[literal])),
        _ => Ok(addresses(&[PUBLIC])),
    })
}

fn module(routed: &Arc<Routed>) -> FetchModule {
    FetchModule::with_parts(fixture_resolver(), Arc::new(HttpTransport::with_parts(fixture_resolver(), routed.clone(), None)))
}

fn get_from(module: &FetchModule, address: &str) -> Result<fetch::Response, FetchError> {
    module.perform("GET", &url(address), &[], None, 5000, &any_redirect, None)
}

fn transport_error<T: std::fmt::Debug>(result: Result<T, FetchError>) -> String {
    match result {
        Err(FetchError::Transport(message)) => message,
        other => panic!("expected a transport failure, got {other:?}"),
    }
}

#[test]
fn the_request_goes_to_the_checked_address_and_is_plain_http_1_1() {
    let server = serve(None, |_, output| {
        let _ = output.write_all(&respond("200 OK", &[("Content-Type", "text/plain"), ("X-Reply", "one"), ("x-reply", "two")], b"hello"));
    });
    let routed = Routed::to(server.port);
    let module = module(&routed);
    let sent = headers(&[("X-Token", "t"), ("Connection", "keep-alive"), ("Transfer-Encoding", "chunked"), ("Upgrade", "websocket")]);
    let response = module.perform("POST", &url("http://example.com/items?x=1&y=%20#fragment"), &sent, Some(b"payload"), 5000, &any_redirect, None).unwrap();
    assert_eq!((response.status, response.body.as_slice()), (200, &b"hello"[..]));
    assert_eq!(response.headers.get("content-type").map(String::as_str), Some("text/plain"));
    assert_eq!(response.headers.get("x-reply").map(String::as_str), Some("two"), "the last value wins");
    // The socket was opened to the address the resolver returned and the check accepted.
    assert_eq!(routed.dialed(), [format!("{PUBLIC}:80")]);

    let seen = server.seen().remove(0);
    assert_eq!(seen.line(), "POST /items?x=1&y=%20 HTTP/1.1");
    assert_eq!(seen.header("Host"), Some("example.com"));
    assert_eq!(seen.header("X-Token"), Some("t"));
    assert_eq!(seen.header("User-Agent"), Some(fetch::DEFAULT_USER_AGENT));
    assert_eq!(seen.header("Content-Length"), Some("7"));
    assert_eq!(seen.header("Accept-Encoding"), Some("gzip, deflate"));
    // One request per connection; a script does not get to say otherwise.
    assert_eq!(seen.header("Connection"), Some("close"));
    assert_eq!(seen.header("Transfer-Encoding"), None);
    assert_eq!(seen.header("Upgrade"), None);
    assert_eq!(seen.body, b"payload");
    // Nothing identifies a proxy, a cookie store or stored credentials.
    for absent in ["Cookie", "Authorization", "Proxy-Authorization", "Proxy-Connection", "Via", "Forwarded"] {
        assert_eq!(seen.header(absent), None, "{absent}");
    }

    // Another port and an IPv6 answer are dialed as resolved.
    get_from(&module, "http://example.com:8080/").unwrap();
    get_from(&module, "http://six.example.com/").unwrap();
    assert_eq!(routed.dialed()[1..], [format!("{PUBLIC}:8080"), "[2606:2800:220:1:248:1893:25c8:1946]:80".to_owned()]);
    assert_eq!(server.seen()[1].header("Host"), Some("example.com:8080"));
    assert_eq!(server.seen()[1].line(), "GET / HTTP/1.1");
    assert_eq!(server.seen()[1].header("Content-Length"), None);
}

#[test]
fn the_connect_step_refuses_blocked_names_and_addresses_without_connecting() {
    let dialer = NoDialer(AtomicUsize::new(0));
    let wait = || {
        let wait = Wait::new(Duration::from_secs(10), Duration::from_secs(5), None);
        wait.arm().unwrap();
        wait
    };
    let refusal = |host: &str, answers: &[&str]| -> String {
        let resolved = Arc::new(AtomicUsize::new(0));
        let (counter, answer) = (resolved.clone(), addresses(answers));
        let resolver: Resolver = Arc::new(move |_| {
            counter.fetch_add(1, Ordering::SeqCst);
            Ok(answer.clone())
        });
        let error = HttpTransport::connect(&resolver, &dialer, host, 443, &wait()).unwrap_err();
        format!("{}|{}", error.message(), resolved.load(Ordering::SeqCst))
    };
    for address in ["127.0.0.1", "10.1.2.3", "169.254.169.254", "::1", "fc00::1", "fd00::1", "::ffff:127.0.0.1", "192.168.1.1", "172.16.0.1", "0.0.0.0", "100.64.0.1", "fe80::1", "64:ff9b::a00:1", "2002:a00:1::1", "224.0.0.1"] {
        assert_eq!(refusal("public.example.com", &[address]), format!("{BLOCKED}|1"), "{address}");
        assert_eq!(refusal("public.example.com", &[PUBLIC, address]), format!("{BLOCKED}|1"), "{address}");
    }
    assert_eq!(refusal("public.example.com", &[]), format!("{BLOCKED}|1"));
    // A blocked name is refused without asking the resolver.
    for host in ["localhost", "LOCALHOST", "printer.local", "127.0.0.1", "10.0.0.1", "192.168.1.1", "172.16.0.1", "::1", "[::1]", ""] {
        assert_eq!(refusal(host, &[PUBLIC]), format!("{BLOCKED}|0"), "{host}");
    }
    let unknown: Resolver = Arc::new(|_| Err(std::io::Error::other("no such host")));
    assert_eq!(HttpTransport::connect(&unknown, &dialer, "public.example.com", 443, &wait()).unwrap_err(), FetchError::failed("Could not resolve public.example.com"));
    assert_eq!(dialer.0.load(Ordering::SeqCst), 0, "nothing was dialed");
    // A public answer is dialed, and only then.
    assert!(matches!(HttpTransport::connect(&public_resolver(), &dialer, "public.example.com", 443, &wait()), Err(FetchError::Transport(_))));
    assert_eq!(dialer.0.load(Ordering::SeqCst), 1);
}

/// A service on this machine is not reachable by any spelling, with the production dialer.
#[test]
fn this_machine_is_not_reachable_without_the_test_network() {
    let server = serve(None, |_, output| {
        let _ = output.write_all(&respond("200 OK", &[], b"secret"));
    });
    let port = server.port;
    let production = FetchModule::new();
    for address in [format!("http://127.0.0.1:{port}/"), format!("http://localhost:{port}/"), format!("http://[::1]:{port}/"), format!("http://[::ffff:127.0.0.1]:{port}/"), format!("http://2130706433:{port}/"), format!("http://127.1:{port}/")] {
        assert_eq!(failure(get_from(&production, &address)), BLOCKED, "{address}");
        let package = Package::legacy();
        assert_eq!(rejection(&production, &package.request(), "http.request", &get(&address)), BLOCKED, "{address}");
    }
    // A public name that resolves to this machine is refused at the pre-check and again at the connect step.
    let pointing_here = FetchModule::with_resolver(fixed_resolver(&["127.0.0.1"]));
    assert_eq!(failure(get_from(&pointing_here, &format!("http://public.example.com:{port}/"))), BLOCKED);
    let wait = Wait::new(Duration::from_secs(5), Duration::from_secs(5), None);
    wait.arm().unwrap();
    assert_eq!(HttpTransport::connect(&fixed_resolver(&["127.0.0.1"]), &SystemDialer, "public.example.com", port, &wait).unwrap_err(), FetchError::failed(BLOCKED));
    assert_eq!(HttpTransport::connect(&(Arc::new(system_resolver) as Resolver), &SystemDialer, "localhost", port, &wait).unwrap_err(), FetchError::failed(BLOCKED));
    std::thread::sleep(Duration::from_millis(100));
    assert_eq!(server.connections.load(Ordering::SeqCst), 0, "no connection reached the local service");
}

#[test]
fn the_next_address_is_tried_when_one_does_not_answer() {
    let server = serve(None, |_, output| {
        let _ = output.write_all(&respond("200 OK", &[], b"ok"));
    });
    let first: SocketAddr = "198.51.100.7:80".parse().unwrap();
    let routed = Arc::new(Routed { port: server.port, dialed: Mutex::default(), dead: vec![first] });
    let resolver = fixed_resolver(&["198.51.100.7", PUBLIC]);
    let module = FetchModule::with_parts(resolver.clone(), Arc::new(HttpTransport::with_parts(resolver, routed.clone(), None)));
    assert_eq!(get_from(&module, "http://example.com/").unwrap().body, b"ok");
    assert_eq!(routed.dialed(), ["198.51.100.7:80".to_owned(), format!("{PUBLIC}:80")]);
}

fn gzip(data: &[u8]) -> Vec<u8> {
    let mut encoder = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
    encoder.write_all(data).unwrap();
    encoder.finish().unwrap()
}

fn zlib(data: &[u8]) -> Vec<u8> {
    let mut encoder = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::default());
    encoder.write_all(data).unwrap();
    encoder.finish().unwrap()
}

#[test]
fn bodies_are_delimited_by_length_chunks_or_the_end_of_the_connection() {
    let server = serve(None, |request, output| {
        let reply: Vec<u8> = match request.path() {
            "/chunked" => b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n1;ext=1\r\n \r\n6\r\nworld!\r\n0\r\nX-Trailer: 1\r\n\r\nignored".to_vec(),
            "/close" => b"HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nuntil the end".to_vec(),
            "/gzip" => respond("200 OK", &[("Content-Encoding", "gzip")], &gzip(b"compressed text")),
            "/deflate" => respond("200 OK", &[("Content-Encoding", "deflate")], &zlib(b"deflated text")),
            "/brotli" => respond("200 OK", &[("Content-Encoding", "br")], b"\x0b\x02\x80raw"),
            "/chunked-gzip" => {
                let packed = gzip(b"both at once");
                let mut reply = b"HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nTransfer-Encoding: chunked\r\n\r\n".to_vec();
                reply.extend_from_slice(format!("{:x}\r\n", packed.len()).as_bytes());
                reply.extend_from_slice(&packed);
                reply.extend_from_slice(b"\r\n0\r\n\r\n");
                reply
            }
            "/short" => b"HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort".to_vec(),
            "/short-chunk" => b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n10\r\nshort".to_vec(),
            "/bad-chunk" => b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nhello\r\n0\r\n\r\n".to_vec(),
            "/two-lengths" => b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 5\r\n\r\nhello".to_vec(),
            "/negative" => b"HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\nhello".to_vec(),
            "/head" => b"HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n\r\n".to_vec(),
            "/empty" => b"HTTP/1.1 204 No Content\r\n\r\nstray".to_vec(),
            "/continue" => b"HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 103 Early Hints\r\nLink: </a>\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\ndone".to_vec(),
            "/garbage" => b"SSH-2.0-OpenSSH_9.9\r\n\r\n".to_vec(),
            "/silent" => Vec::new(),
            "/huge-head" => {
                let mut reply = b"HTTP/1.1 200 OK\r\n".to_vec();
                for index in 0..40 {
                    reply.extend_from_slice(format!("X-Pad-{index}: {}\r\n", "p".repeat(2000)).as_bytes());
                }
                reply.extend_from_slice(b"Content-Length: 2\r\n\r\nok");
                reply
            }
            _ => respond("404 Not Found", &[], b"missing"),
        };
        let _ = output.write_all(&reply);
    });
    let module = module(&Routed::to(server.port));
    let body = |path: &str| String::from_utf8(get_from(&module, &format!("http://example.com{path}")).unwrap().body).unwrap();
    assert_eq!(body("/chunked"), "hello world!");
    assert_eq!(body("/close"), "until the end");
    assert_eq!(body("/gzip"), "compressed text");
    assert_eq!(body("/deflate"), "deflated text");
    assert_eq!(body("/chunked-gzip"), "both at once");
    assert_eq!(body("/empty"), "");
    assert_eq!(body("/continue"), "done");
    assert_eq!(body("/nothing-here"), "missing");
    // A decoded body no longer has its encoded length or encoding; an unknown encoding is handed on as it came.
    let decoded = get_from(&module, "http://example.com/gzip").unwrap();
    assert_eq!((decoded.headers.get("content-encoding"), decoded.headers.get("content-length")), (None, None));
    let raw = get_from(&module, "http://example.com/brotli").unwrap();
    assert_eq!((raw.body.as_slice(), raw.headers.get("content-encoding").map(String::as_str)), (&b"\x0b\x02\x80raw"[..], Some("br")));
    // HEAD has no body, whatever length it declares.
    let head = module.perform("HEAD", &url("http://example.com/head"), &[], None, 5000, &any_redirect, None).unwrap();
    assert_eq!((head.status, head.body.len()), (200, 0));

    let broken = |path: &str| transport_error(get_from(&module, &format!("http://example.com{path}")));
    assert_eq!(broken("/short"), "The response ended early");
    assert_eq!(broken("/short-chunk"), "The response ended early");
    assert_eq!(broken("/bad-chunk"), "The server sent an invalid response");
    assert_eq!(broken("/two-lengths"), "The server sent an invalid response");
    assert_eq!(broken("/negative"), "The server sent an invalid response");
    assert_eq!(broken("/garbage"), "The server sent an invalid response");
    assert_eq!(broken("/silent"), "The connection closed before a response arrived");
    assert_eq!(broken("/huge-head"), "The response headers are too large");
}

#[test]
fn bodies_over_the_limit_are_cut_off_on_the_wire() {
    let stopped = Arc::new(AtomicBool::new(false));
    let flag = stopped.clone();
    let server = serve(None, move |request, output| match request.path() {
        "/endless" => {
            let _ = output.write_all(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n");
            let chunk = [b"10000\r\n".as_slice(), &vec![0u8; 0x10000], b"\r\n"].concat();
            // The client hangs up at the limit; the server notices on a later write.
            for _ in 0..4096 {
                if output.write_all(&chunk).is_err() {
                    flag.store(true, Ordering::SeqCst);
                    return;
                }
            }
        }
        "/bomb" => {
            let _ = output.write_all(&respond("200 OK", &[("Content-Encoding", "gzip")], &gzip(&vec![0u8; 16 * 1024 * 1024])));
        }
        "/declared" => {
            let _ = output.write_all(format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n", fetch::MAXIMUM_RESPONSE_BYTES + 1).as_bytes());
        }
        _ => {
            let _ = output.write_all(&respond("200 OK", &[], &vec![b'x'; fetch::MAXIMUM_RESPONSE_BYTES]));
        }
    });
    let module = module(&Routed::to(server.port));
    let limit = "Response exceeds the 2097152-byte limit";
    assert_eq!(failure(get_from(&module, "http://example.com/endless")), limit);
    // A small compressed body that expands past the limit is stopped while it is decoded.
    assert_eq!(failure(get_from(&module, "http://example.com/bomb")), limit);
    assert_eq!(failure(get_from(&module, "http://example.com/declared")), limit);
    assert_eq!(get_from(&module, "http://example.com/exact").unwrap().body.len(), fetch::MAXIMUM_RESPONSE_BYTES);
    let deadline = Instant::now() + Duration::from_secs(10);
    while !stopped.load(Ordering::SeqCst) && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(stopped.load(Ordering::SeqCst), "the endless response was not abandoned");
}

#[test]
fn slow_servers_time_out_and_cancellation_hangs_up() {
    let server = serve(None, |request, output| match request.path() {
        "/stalled-body" => {
            let _ = output.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\npartial");
            let _ = output.flush();
            std::thread::sleep(Duration::from_secs(4));
        }
        "/trickle" => {
            // Each read arrives in time, but the whole exchange may not outlast the total deadline.
            let _ = output.write_all(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n");
            for _ in 0..200 {
                if output.write_all(b"1\r\nx\r\n").and_then(|()| output.flush()).is_err() {
                    return;
                }
                std::thread::sleep(Duration::from_millis(100));
            }
        }
        _ => std::thread::sleep(Duration::from_secs(4)),
    });
    let module = module(&Routed::to(server.port));
    let timed = |path: &str, timeout: u64| {
        let started = Instant::now();
        let result = module.perform("GET", &url(&format!("http://example.com{path}")), &[], None, timeout, &any_redirect, None);
        (failure(result), started.elapsed())
    };
    let (message, elapsed) = timed("/no-answer", 300);
    assert_eq!(message, "The request timed out.");
    assert!(elapsed < Duration::from_secs(3), "{elapsed:?}");
    let (message, elapsed) = timed("/stalled-body", 300);
    assert_eq!(message, "The request timed out.");
    assert!(elapsed < Duration::from_secs(3), "{elapsed:?}");
    let (message, elapsed) = timed("/trickle", 2000);
    assert_eq!(message, "The request timed out.");
    assert!(elapsed >= Duration::from_millis(fetch::MAXIMUM_TOTAL_MILLISECONDS - 500) && elapsed < Duration::from_secs(15), "{elapsed:?}");

    // The end of the execution stops a request that is waiting for its answer.
    let ended = Arc::new(AtomicBool::new(false));
    let flag = ended.clone();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(200));
        flag.store(true, Ordering::SeqCst);
    });
    let started = Instant::now();
    let flag = ended.clone();
    let result = module.perform("GET", &url("http://example.com/no-answer"), &[], None, 5000, &any_redirect, Some(Arc::new(move || flag.load(Ordering::SeqCst))));
    assert_eq!(result, Err(FetchError::Cancelled));
    assert!(started.elapsed() < Duration::from_secs(2), "{:?}", started.elapsed());
}

/// Redirects are followed by this code, hop by hop, never by the transport.
#[test]
fn redirects_are_checked_at_every_hop_and_credentials_stay_with_their_origin() {
    let port = Arc::new(AtomicUsize::new(0));
    let own_port = port.clone();
    let server = serve(None, move |request, output| {
        let host = request.header("Host").unwrap_or("").to_owned();
        let redirect = |to: &str| respond("302 Found", &[("Location", to), ("Set-Cookie", "tracker=1")], b"");
        let reply = match (host.as_str(), request.path()) {
            ("example.com", "/start") => redirect("/second"),
            ("example.com", "/second") => redirect("http://other.example.net/third"),
            ("other.example.net", "/third") => respond("200 OK", &[], b"arrived"),
            ("example.com", "/to-this-machine") => redirect(&format!("http://127.0.0.1:{}/secret", own_port.load(Ordering::SeqCst))),
            ("example.com", "/to-localhost") => redirect(&format!("http://localhost:{}/secret", own_port.load(Ordering::SeqCst))),
            ("example.com", "/to-private-name") => redirect("http://internal.example.com/secret"),
            ("example.com", "/to-file") => redirect("file:///etc/passwd"),
            _ => respond("200 OK", &[], b"secret"),
        };
        let _ = output.write_all(&reply);
    });
    port.store(server.port as usize, Ordering::SeqCst);
    let routed = Routed::to(server.port);
    let module = module(&routed);
    let sent = headers(&[("Authorization", "Bearer secret"), ("Cookie", "session=1"), ("Accept", "application/json")]);

    // The transport alone reports the redirect; it does not follow it.
    let transport = HttpTransport::with_parts(fixture_resolver(), routed.clone(), None);
    let wait = Wait::new(Duration::from_secs(10), Duration::from_secs(5), None);
    wait.arm().unwrap();
    let address = url("http://example.com/start");
    let single = sw_core::api::fetch::Transport::send(&transport, &sw_core::api::fetch::TransportRequest { method: "GET", url: &address, headers: &[], body: None }, &wait).unwrap();
    assert_eq!(single.status, 302);
    assert_eq!(server.seen().len(), 1);

    let response = module.perform("GET", &address, &sent, None, 5000, &any_redirect, None).unwrap();
    assert_eq!(response.body, b"arrived");
    let seen = server.seen();
    let hops: Vec<String> = seen[1..].iter().map(|request| format!("{}{}", request.header("Host").unwrap_or(""), request.path())).collect();
    assert_eq!(hops, ["example.com/start", "example.com/second", "other.example.net/third"]);
    assert_eq!(seen[2].header("Authorization"), Some("Bearer secret"));
    assert_eq!(seen[2].header("Cookie"), Some("session=1"), "the script's own cookie, not the one the server set");
    let elsewhere = &seen[3];
    assert_eq!((elsewhere.header("Authorization"), elsewhere.header("Cookie"), elsewhere.header("Accept")), (None, None, Some("application/json")));

    // The script's rule, the fetch policy of a package, sees every target; local ones never get a connection.
    let before = server.seen().len();
    let dialed = routed.dialed().len();
    let package = Package::legacy();
    for path in ["/to-this-machine", "/to-localhost", "/to-file"] {
        assert_eq!(rejection(&module, &package.request(), "http.request", &get(&format!("http://example.com{path}"))), "Redirect target is not allowed", "{path}");
    }
    assert_eq!(rejection(&module, &package.request(), "http.request", &get("http://example.com/to-private-name")), BLOCKED);
    assert_eq!(server.seen().len(), before + 4, "only the four first hops were sent");
    assert_eq!(routed.dialed().len(), dialed + 4);
    assert!(server.seen().iter().all(|request| request.path() != "/secret"));
    // Even a caller that allows every redirect cannot reach a local address: the hop is checked again.
    assert_eq!(failure(get_from(&module, "http://example.com/to-this-machine")), BLOCKED);
    assert_eq!(failure(get_from(&module, "http://example.com/to-private-name")), BLOCKED);
    assert!(server.seen().iter().all(|request| request.path() != "/secret"));
}

// A certificate for secure.example.com that signs itself, made for these tests
// only (valid until 2126). The key protects nothing.
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

fn tls_server_config() -> Arc<rustls::ServerConfig> {
    let certificate = CertificateDer::from_pem_slice(CERTIFICATE.as_bytes()).expect("certificate");
    let key = PrivateKeyDer::from_pem_slice(TEST_ONLY_KEY.as_bytes()).expect("key");
    let config = rustls::ServerConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
        .with_safe_default_protocol_versions()
        .unwrap()
        .with_no_client_auth()
        .with_single_cert(vec![certificate], key)
        .expect("server configuration");
    Arc::new(config)
}

/// The connection goes to an address, but the certificate must be valid for the name in the URL.
#[test]
fn tls_is_verified_against_the_host_name() {
    let server = serve(Some(tls_server_config()), |request, output| {
        let _ = output.write_all(&respond("200 OK", &[("Content-Type", "text/plain")], format!("secure {}", request.path()).as_bytes()));
    });
    let routed = Routed::to(server.port);
    let mut roots = rustls::RootCertStore::empty();
    roots.add(CertificateDer::from_pem_slice(CERTIFICATE.as_bytes()).unwrap()).unwrap();
    let trusting = FetchModule::with_parts(fixture_resolver(), Arc::new(HttpTransport::with_parts(fixture_resolver(), routed.clone(), Some(client_config(roots).unwrap()))));

    let response = trusting.perform("POST", &url("https://secure.example.com/data"), &headers(&[("X-Token", "t")]), Some(b"{}"), 5000, &any_redirect, None).unwrap();
    assert_eq!((response.status, response.body.as_slice()), (200, &b"secure /data"[..]));
    assert_eq!(routed.dialed(), [format!("{PUBLIC}:443")]);
    let seen = server.seen().remove(0);
    assert_eq!((seen.line(), seen.header("Host"), seen.header("X-Token"), seen.body.as_slice()), ("POST /data HTTP/1.1", Some("secure.example.com"), Some("t"), &b"{}"[..]));

    // The same server, the same address, another name: the certificate does not cover it.
    let other = transport_error(get_from(&trusting, "https://other.example.com/data"));
    assert!(other.to_lowercase().contains("certificate"), "{other}");
    // The address itself is not a name the certificate covers either.
    let literal = transport_error(get_from(&trusting, "https://93.184.216.34/data"));
    assert!(literal.to_lowercase().contains("certificate"), "{literal}");
    // With the certificate authorities of the system the test certificate is not trusted at all.
    let system = module(&routed);
    let untrusted = transport_error(get_from(&system, "https://secure.example.com/data"));
    assert!(untrusted.to_lowercase().contains("certificate"), "{untrusted}");
    // A server that does not speak TLS is a failure, not a downgrade.
    let plain = serve(None, |_, output| {
        let _ = output.write_all(&respond("200 OK", &[], b"plain"));
    });
    let downgraded = FetchModule::with_parts(fixture_resolver(), Arc::new(HttpTransport::with_parts(fixture_resolver(), Routed::to(plain.port), None)));
    assert!(downgraded.perform("GET", &url("https://secure.example.com/data"), &[], None, 500, &any_redirect, None).is_err());
    assert_eq!(server.seen().len(), 1, "no request was sent over a connection that failed verification");
    assert!(plain.seen().is_empty());
}
