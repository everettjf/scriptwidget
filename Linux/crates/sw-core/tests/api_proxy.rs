//! The transport does not use a proxy, whatever the environment says. This is
//! a file of its own because it changes the environment of the process.

mod api_common;

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use api_common::*;
use sw_core::api::fetch::FetchModule;
use sw_core::api::http::{Dialer, HttpTransport};

/// Accepts connections, counts them, and answers each with `reply` after reading the request.
fn listen(reply: &'static [u8]) -> (u16, Arc<AtomicUsize>, Arc<std::sync::Mutex<Vec<String>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let (count, lines): (Arc<AtomicUsize>, Arc<std::sync::Mutex<Vec<String>>>) = Default::default();
    let (counter, record) = (count.clone(), lines.clone());
    std::thread::spawn(move || {
        for mut socket in listener.incoming().flatten() {
            counter.fetch_add(1, Ordering::SeqCst);
            let _ = socket.set_read_timeout(Some(Duration::from_secs(5)));
            let mut data = Vec::new();
            let mut chunk = [0u8; 1024];
            while !data.windows(4).any(|window| window == b"\r\n\r\n") {
                match socket.read(&mut chunk) {
                    Ok(count) if count > 0 => data.extend_from_slice(&chunk[..count]),
                    _ => break,
                }
            }
            record.lock().unwrap().push(String::from_utf8_lossy(&data).lines().next().unwrap_or("").to_owned());
            let _ = socket.write_all(reply);
        }
    });
    (port, count, lines)
}

struct ToPort(u16);

impl Dialer for ToPort {
    fn dial(&self, _: SocketAddr, timeout: Duration) -> std::io::Result<TcpStream> {
        TcpStream::connect_timeout(&SocketAddr::from(([127, 0, 0, 1], self.0)), timeout)
    }
}

#[test]
fn proxy_settings_of_the_environment_are_not_used() {
    let (origin, origin_connections, origin_lines) = listen(b"HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\norigin");
    let (proxy, proxy_connections, _) = listen(b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nproxy");
    let address = format!("http://127.0.0.1:{proxy}");
    // SAFETY: this is the only test of this program, and nothing else is running yet.
    unsafe {
        for name in ["http_proxy", "https_proxy", "all_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"] {
            std::env::set_var(name, &address);
        }
        std::env::remove_var("no_proxy");
        std::env::remove_var("NO_PROXY");
    }
    let module = FetchModule::with_parts(public_resolver(), Arc::new(HttpTransport::with_parts(public_resolver(), Arc::new(ToPort(origin)), None)));
    let response = module.perform("GET", &url("http://example.com/direct?x=1"), &[], None, 5000, &any_redirect, None).unwrap();
    assert_eq!(response.body, b"origin");
    assert_eq!(origin_connections.load(Ordering::SeqCst), 1);
    // The request line names a path, as for an origin server, not a whole URL, as for a proxy.
    assert_eq!(*origin_lines.lock().unwrap(), ["GET /direct?x=1 HTTP/1.1"]);
    assert_eq!(proxy_connections.load(Ordering::SeqCst), 0, "the proxy was not contacted");

    // The production module does not reach the proxy either: it is a local address like any other.
    let production = FetchModule::new();
    assert_eq!(failure(production.perform("GET", &url(&address), &[], None, 2000, &any_redirect, None)), BLOCKED);
    assert_eq!(proxy_connections.load(Ordering::SeqCst), 0);
}
