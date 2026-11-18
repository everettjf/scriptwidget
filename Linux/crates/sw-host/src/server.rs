//! The socket: `$XDG_RUNTIME_DIR/scriptwidget/host.sock`, for this user
//! alone. One line of JSON in, one line of JSON out; after `watch` the
//! connection carries events until either side closes it.
//!
//! Three things keep other users and runaway clients out: the directory and
//! the socket are private to the user, the user identifier of every peer is
//! asked from the kernel and compared with ours, and lines, connections and
//! waiting times are all bounded. Nothing received is executed or used as a
//! path; `protocol::Request::parse` decides what a line may say.

use std::io::{Read, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::mpsc::{Receiver, Sender, SyncSender, sync_channel};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// Hands a message to the service's main loop; false when the loop is gone.
pub type Deliver = Arc<dyn Fn(Inbound) -> bool + Send + Sync>;

use serde_json::Value;

use crate::paths::RuntimePaths;
use crate::protocol::{MAXIMUM_LINE_BYTES, Refusal, Request};

/// More connections than this at once are refused; a display holds one or two.
pub const MAXIMUM_CONNECTIONS: usize = 32;
/// Events that may wait for one watcher; one that falls further behind is dropped.
pub const WATCHER_QUEUE: usize = 1024;
/// A connection that sends this many lines that are not requests is closed.
const MAXIMUM_REFUSALS: usize = 8;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(10);
const WRITE_TIMEOUT: Duration = Duration::from_secs(5);

/// What a connection asks of the service's main loop.
pub enum Inbound {
    Request { request: Request, reply: SyncSender<Value> },
    /// A new watcher: the main loop queues `hello` and the current state on `events`, then every event that follows.
    Watch { watcher: u64, events: SyncSender<Arc<str>> },
    WatcherGone { watcher: u64 },
}

/// Holds the lock that makes this the only service of the session; dropping it removes the socket.
pub struct Listening {
    listener: UnixListener,
    socket: PathBuf,
    _lock: std::fs::File,
}

impl Listening {
    /// A second handle on the listening socket, for the thread that accepts.
    pub fn listener(&self) -> std::io::Result<UnixListener> {
        self.listener.try_clone()
    }

    pub fn socket(&self) -> &Path {
        &self.socket
    }
}

impl Drop for Listening {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.socket);
    }
}

#[derive(Debug)]
pub enum BindError {
    /// Another service holds the lock.
    AlreadyRunning,
    Io(std::io::Error),
}

impl From<std::io::Error> for BindError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error)
    }
}

/// Takes the lock and binds the socket. A socket file left by a service that
/// crashed is removed: holding the lock proves that no service is using it.
pub fn bind(paths: &RuntimePaths) -> Result<Listening, BindError> {
    paths.prepare()?;
    let lock = std::fs::OpenOptions::new().read(true).write(true).create(true).truncate(false).custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC).mode(0o600).open(paths.lock())?;
    use std::os::fd::AsRawFd;
    // SAFETY: the descriptor is open for the duration of the call.
    if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        let error = std::io::Error::last_os_error();
        return Err(if error.kind() == std::io::ErrorKind::WouldBlock { BindError::AlreadyRunning } else { BindError::Io(error) });
    }
    let socket = paths.socket();
    match std::fs::symlink_metadata(&socket) {
        // Whatever is at the name, a link included, is removed itself; nothing is followed.
        Ok(metadata) if !metadata.is_dir() => std::fs::remove_file(&socket)?,
        Ok(_) => return Err(BindError::Io(std::io::Error::new(std::io::ErrorKind::AlreadyExists, format!("{} is a directory", socket.display())))),
        Err(_) => {}
    }
    let listener = UnixListener::bind(&socket)?;
    // The directory already keeps everyone else out; the mode says the same of the socket itself.
    std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o600))?;
    Ok(Listening { listener, socket, _lock: lock })
}

/// The user the kernel says is at the other end of a connection.
pub fn peer_user(stream: &UnixStream) -> std::io::Result<u32> {
    use std::os::fd::AsRawFd;
    #[cfg(any(target_os = "linux", target_os = "android"))]
    {
        let mut credentials = libc::ucred { pid: 0, uid: u32::MAX, gid: u32::MAX };
        let mut length = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
        // SAFETY: `credentials` and `length` are valid for writing and describe each other's size.
        let result = unsafe { libc::getsockopt(stream.as_raw_fd(), libc::SOL_SOCKET, libc::SO_PEERCRED, (&raw mut credentials).cast(), &raw mut length) };
        if result != 0 || length as usize != std::mem::size_of::<libc::ucred>() {
            return Err(std::io::Error::last_os_error());
        }
        Ok(credentials.uid)
    }
    #[cfg(not(any(target_os = "linux", target_os = "android")))]
    {
        let (mut user, mut group) = (u32::MAX, u32::MAX);
        // SAFETY: both pointers are valid for writing.
        if unsafe { libc::getpeereid(stream.as_raw_fd(), &raw mut user, &raw mut group) } != 0 {
            return Err(std::io::Error::last_os_error());
        }
        Ok(user)
    }
}

/// Reads lines of at most [`MAXIMUM_LINE_BYTES`] bytes.
struct Lines {
    stream: UnixStream,
    buffer: Vec<u8>,
}

enum Line {
    Text(String),
    /// Too long, or not UTF-8: nothing more is read from this connection.
    Unreadable(&'static str),
    Closed,
}

impl Lines {
    fn next(&mut self) -> Line {
        loop {
            if let Some(end) = self.buffer.iter().position(|byte| *byte == b'\n') {
                let line: Vec<u8> = self.buffer.drain(..=end).collect();
                return match String::from_utf8(line) {
                    Ok(text) => Line::Text(text.trim_end_matches(['\n', '\r']).to_owned()),
                    Err(_) => Line::Unreadable("request.invalid"),
                };
            }
            if self.buffer.len() > MAXIMUM_LINE_BYTES {
                return Line::Unreadable("request.too_long");
            }
            let mut chunk = [0u8; 1024];
            match self.stream.read(&mut chunk) {
                Ok(0) | Err(_) => return Line::Closed,
                Ok(count) => self.buffer.extend_from_slice(&chunk[..count]),
            }
        }
    }
}

fn send(stream: &mut UnixStream, value: &Value) -> bool {
    let mut line = value.to_string();
    line.push('\n');
    stream.write_all(line.as_bytes()).is_ok()
}

struct Shared {
    deliver: Deliver,
    connections: AtomicUsize,
    next_watcher: AtomicUsize,
    expected_user: u32,
    stopping: AtomicBool,
    /// Told when the writer of a watcher has written its last line.
    drained: Mutex<Sender<()>>,
}

/// Accepts connections until [`Acceptor::stop`].
pub struct Acceptor {
    shared: Arc<Shared>,
    socket: PathBuf,
    /// One message for every watcher whose last line has been written.
    pub drained: Receiver<()>,
}

impl Acceptor {
    pub fn start(listener: UnixListener, socket: PathBuf, deliver: Deliver, expected_user: u32) -> std::io::Result<Self> {
        let (drained_sender, drained) = std::sync::mpsc::channel();
        let shared = Arc::new(Shared {
            deliver,
            connections: AtomicUsize::new(0),
            next_watcher: AtomicUsize::new(1),
            expected_user,
            stopping: AtomicBool::new(false),
            drained: Mutex::new(drained_sender),
        });
        let accepting = shared.clone();
        std::thread::Builder::new().name("scriptwidget-accept".into()).spawn(move || {
            for stream in listener.incoming() {
                if accepting.stopping.load(Ordering::SeqCst) {
                    break;
                }
                let Ok(stream) = stream else { continue };
                if accepting.connections.fetch_add(1, Ordering::SeqCst) >= MAXIMUM_CONNECTIONS {
                    accepting.connections.fetch_sub(1, Ordering::SeqCst);
                    let mut stream = stream;
                    let _ = stream.set_write_timeout(Some(WRITE_TIMEOUT));
                    send(&mut stream, &Refusal::new("service.busy", "Too many connections.").reply());
                    continue;
                }
                let shared = accepting.clone();
                let spawned = std::thread::Builder::new().name("scriptwidget-client".into()).spawn(move || {
                    serve(stream, &shared);
                    shared.connections.fetch_sub(1, Ordering::SeqCst);
                });
                if spawned.is_err() {
                    accepting.connections.fetch_sub(1, Ordering::SeqCst);
                }
            }
        })?;
        Ok(Self { shared, socket, drained })
    }

    /// Stops accepting. Connections that are open end by themselves when their peer closes or the main loop is gone.
    pub fn stop(&self) {
        self.shared.stopping.store(true, Ordering::SeqCst);
        // Wakes the thread out of `accept`.
        let _ = UnixStream::connect(&self.socket);
    }
}

fn serve(mut stream: UnixStream, shared: &Arc<Shared>) {
    let _ = stream.set_write_timeout(Some(WRITE_TIMEOUT));
    let _ = stream.set_read_timeout(Some(REQUEST_TIMEOUT));
    match peer_user(&stream) {
        Ok(user) if user == shared.expected_user => {}
        _ => {
            send(&mut stream, &Refusal::new("peer.refused", "This socket serves one user only.").reply());
            return;
        }
    }
    let Ok(reading) = stream.try_clone() else { return };
    let mut lines = Lines { stream: reading, buffer: Vec::new() };
    let mut refusals = 0;
    loop {
        let text = match lines.next() {
            Line::Text(text) => text,
            Line::Unreadable(code) => {
                send(&mut stream, &Refusal::new(code, "A request is one line of JSON, at most 4096 bytes long.").reply());
                return;
            }
            Line::Closed => return,
        };
        if text.is_empty() {
            continue;
        }
        let request = match Request::parse(&text) {
            Ok(request) => request,
            Err(refusal) => {
                refusals += 1;
                if !send(&mut stream, &refusal.reply()) || refusals >= MAXIMUM_REFUSALS {
                    return;
                }
                continue;
            }
        };
        if request == Request::Watch {
            watch(stream, lines, shared);
            return;
        }
        let (reply, answer) = sync_channel(1);
        if !(shared.deliver)(Inbound::Request { request, reply }) {
            return;
        }
        match answer.recv_timeout(REQUEST_TIMEOUT) {
            Ok(value) if send(&mut stream, &value) => {}
            _ => return,
        }
    }
}

/// Carries events to one watcher. A second thread writes, so that this one
/// can notice the peer closing while no event is waiting.
fn watch(stream: UnixStream, mut lines: Lines, shared: &Arc<Shared>) {
    let watcher = shared.next_watcher.fetch_add(1, Ordering::SeqCst) as u64;
    let (events, queue) = sync_channel::<Arc<str>>(WATCHER_QUEUE);
    let drained = shared.drained.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).clone();
    let mut writing = stream;
    let writer = std::thread::Builder::new().name("scriptwidget-watch".into()).spawn(move || {
        for line in queue {
            if writing.write_all(line.as_bytes()).and_then(|()| writing.write_all(b"\n")).is_err() {
                break;
            }
        }
        // Everything queued has been written (or the peer is gone): the reader wakes and the connection ends.
        let _ = writing.shutdown(std::net::Shutdown::Both);
        let _ = drained.send(());
    });
    if writer.is_err() || !(shared.deliver)(Inbound::Watch { watcher, events }) {
        return;
    }
    // A watcher has nothing more to say; what it sends is read and dropped until it closes.
    let _ = lines.stream.set_read_timeout(None);
    let mut discard = [0u8; 256];
    while matches!(lines.stream.read(&mut discard), Ok(count) if count > 0) {}
    (shared.deliver)(Inbound::WatcherGone { watcher });
}

/// For callers that only need the path check of a socket file in tests and diagnostics.
pub fn is_socket(path: &Path) -> bool {
    use std::os::unix::fs::FileTypeExt;
    std::fs::symlink_metadata(path).is_ok_and(|metadata| metadata.file_type().is_socket())
}
