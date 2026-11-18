//! One management window per user. The first start takes a lock under
//! `$XDG_RUNTIME_DIR/scriptwidget/` and listens on a socket there; a later
//! start (the service's "Edit…", a `.swt` file opened from the file manager)
//! hands its request to the first and exits.
//!
//! The folder and the socket are private to the user, the listener checks
//! the user of every peer, and a request is one short line that only names a
//! page, an installed widget or a file: nothing in it is ever executed.

use std::fs::File;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

const LOCK_FILE: &str = "studio.lock";
const SOCKET_FILE: &str = "studio.sock";
/// A request is a page name, a widget name or a path.
const MAXIMUM_REQUEST_BYTES: u64 = 8 * 1024;
const MAXIMUM_NAME_CHARACTERS: usize = 255;

/// What a start of the program asks the window to do.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Request {
    /// Come to the front.
    Show,
    /// Open an installed widget in the editor.
    Edit(String),
    /// Offer to import a `.swt` file.
    Open(PathBuf),
}

impl Request {
    fn to_line(&self) -> String {
        let value = match self {
            Request::Show => json!({ "request": "show" }),
            Request::Edit(name) => json!({ "request": "edit", "package": name }),
            Request::Open(path) => json!({ "request": "open", "path": path.to_string_lossy() }),
        };
        format!("{value}\n")
    }

    /// Reads one request line. Anything that is not exactly one of the three requests is refused.
    fn from_line(line: &str) -> Option<Self> {
        let value: Value = serde_json::from_str(line.trim_end_matches(['\r', '\n'])).ok()?;
        let object = value.as_object()?;
        let text = |key: &str| object.get(key).and_then(Value::as_str).filter(|text| !text.is_empty() && !text.chars().any(char::is_control));
        match (object.get("request")?.as_str()?, object.len()) {
            ("show", 1) => Some(Request::Show),
            ("edit", 2) => text("package").filter(|name| name.chars().count() <= MAXIMUM_NAME_CHARACTERS && !name.contains('/')).map(|name| Request::Edit(name.to_owned())),
            ("open", 2) => text("path").map(PathBuf::from).filter(|path| path.is_absolute()).map(Request::Open),
            _ => None,
        }
    }
}

/// The private folder for the lock and the socket: `scriptwidget` under
/// `runtime_directory` (the value of `XDG_RUNTIME_DIR`). It is created for
/// the user alone; a folder that belongs to someone else, is a link, or is
/// open to others is refused.
pub fn private_directory(runtime_directory: &Path) -> std::io::Result<PathBuf> {
    let refused = |reason: &str| std::io::Error::new(std::io::ErrorKind::PermissionDenied, reason.to_owned());
    if !runtime_directory.is_absolute() {
        return Err(refused("XDG_RUNTIME_DIR is not an absolute path"));
    }
    let directory = runtime_directory.join("scriptwidget");
    match std::fs::DirBuilder::new().mode(0o700).create(&directory) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(error) => return Err(error),
    }
    let metadata = std::fs::symlink_metadata(&directory)?;
    if !metadata.file_type().is_dir() {
        return Err(refused("the runtime folder is not a folder"));
    }
    if metadata.uid() != current_user() {
        return Err(refused("the runtime folder belongs to another user"));
    }
    if metadata.permissions().mode() & 0o077 != 0 {
        // The service may have created it; it is ours, so close it.
        std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700))?;
    }
    Ok(directory)
}

pub enum Claim {
    /// This process is the window. Keep the value for as long as it runs.
    Primary(Primary),
    /// A window was already running and has taken the request.
    Forwarded,
}

pub struct Primary {
    listener: UnixListener,
    socket: PathBuf,
    /// Held for the life of the process; the kernel releases it when the process ends, however it ends.
    _lock: File,
}

/// Becomes the window, or hands `request` to the one that is running.
pub fn claim(directory: &Path, request: &Request) -> std::io::Result<Claim> {
    let lock = std::fs::OpenOptions::new().read(true).write(true).create(true).truncate(false).mode(0o600).custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC).open(directory.join(LOCK_FILE))?;
    let socket = directory.join(SOCKET_FILE);
    // SAFETY: flock on a descriptor this function owns.
    if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
        // No window holds the lock, so a socket file here is left from one that ended.
        match std::fs::remove_file(&socket) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
        let listener = UnixListener::bind(&socket)?;
        std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o600))?;
        return Ok(Claim::Primary(Primary { listener, socket, _lock: lock }));
    }
    let error = std::io::Error::last_os_error();
    if error.kind() != std::io::ErrorKind::WouldBlock {
        return Err(error);
    }
    forward(&socket, request)?;
    Ok(Claim::Forwarded)
}

/// Sends `request` to the running window and waits for it to say it took it.
fn forward(socket: &Path, request: &Request) -> std::io::Result<()> {
    // The window that holds the lock may still be binding its socket.
    let deadline = Instant::now() + Duration::from_secs(3);
    let mut stream = loop {
        match UnixStream::connect(socket) {
            Ok(stream) => break stream,
            Err(error) if Instant::now() >= deadline => return Err(error),
            Err(_) => std::thread::sleep(Duration::from_millis(50)),
        }
    };
    if peer_user(&stream)? != current_user() {
        return Err(std::io::Error::new(std::io::ErrorKind::PermissionDenied, "the window belongs to another user"));
    }
    stream.set_read_timeout(Some(Duration::from_secs(5)))?;
    stream.set_write_timeout(Some(Duration::from_secs(5)))?;
    stream.write_all(request.to_line().as_bytes())?;
    let mut answer = String::new();
    BufReader::new(stream.take(16)).read_line(&mut answer)?;
    if answer.trim_end() == "ok" { Ok(()) } else { Err(std::io::Error::new(std::io::ErrorKind::InvalidData, "the running window refused the request")) }
}

impl Primary {
    /// Receives requests on a thread of its own for as long as the process
    /// runs; `handle` is called on that thread.
    pub fn listen(self, handle: impl Fn(Request) + Send + 'static) {
        std::thread::Builder::new()
            .name("studio-instance".into())
            .spawn(move || {
                // The whole value moves here: the lock is held for as long as the thread, which is as long as the process.
                let primary = self;
                for stream in primary.listener.incoming() {
                    let Ok(stream) = stream else { continue };
                    if let Some(request) = receive(stream) {
                        handle(request);
                    }
                }
            })
            .expect("the instance thread");
    }

    pub fn socket(&self) -> &Path {
        &self.socket
    }
}

fn receive(stream: UnixStream) -> Option<Request> {
    if peer_user(&stream).ok()? != current_user() {
        return None;
    }
    stream.set_read_timeout(Some(Duration::from_secs(2))).ok()?;
    stream.set_write_timeout(Some(Duration::from_secs(2))).ok()?;
    let mut line = String::new();
    BufReader::new((&stream).take(MAXIMUM_REQUEST_BYTES)).read_line(&mut line).ok()?;
    let request = line.ends_with('\n').then(|| Request::from_line(&line)).flatten();
    let _ = (&stream).write_all(if request.is_some() { b"ok\n" } else { b"refused\n" });
    request
}

fn current_user() -> u32 {
    // SAFETY: geteuid has no arguments and cannot fail.
    unsafe { libc::geteuid() }
}

/// The user at the other end of a connection, as the kernel recorded it.
#[cfg(target_os = "linux")]
fn peer_user(stream: &UnixStream) -> std::io::Result<u32> {
    let mut credentials = libc::ucred { pid: 0, uid: u32::MAX, gid: u32::MAX };
    let mut length = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    // SAFETY: the pointer and the length describe `credentials`, which outlives the call.
    let result = unsafe { libc::getsockopt(stream.as_raw_fd(), libc::SOL_SOCKET, libc::SO_PEERCRED, (&raw mut credentials).cast(), &raw mut length) };
    if result == 0 && length as usize == std::mem::size_of::<libc::ucred>() { Ok(credentials.uid) } else { Err(std::io::Error::last_os_error()) }
}

/// The same on the systems the tests also run on.
#[cfg(not(target_os = "linux"))]
fn peer_user(stream: &UnixStream) -> std::io::Result<u32> {
    let (mut user, mut group) = (u32::MAX, u32::MAX);
    // SAFETY: both pointers are to locals that outlive the call.
    if unsafe { libc::getpeereid(stream.as_raw_fd(), &raw mut user, &raw mut group) } == 0 { Ok(user) } else { Err(std::io::Error::last_os_error()) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::Scratch;
    use std::sync::mpsc::channel;

    #[test]
    fn requests_survive_the_line_format_and_nothing_else_is_accepted() {
        for request in [Request::Show, Request::Edit("My Widget 小组件".into()), Request::Edit("--help".into()), Request::Open("/home/u/Down loads/a \"b\".swt".into())] {
            let line = request.to_line();
            assert!(line.ends_with('\n') && line.matches('\n').count() == 1, "{line:?}");
            assert_eq!(Request::from_line(&line), Some(request));
        }
        for line in [
            "",
            "show",
            "[]",
            r#"{"request":"quit"}"#,
            r#"{"request":"show","extra":1}"#,
            r#"{"request":"edit"}"#,
            r#"{"request":"edit","package":""}"#,
            r#"{"request":"edit","package":"a/b"}"#,
            r#"{"request":"edit","package":"a\nb"}"#,
            r#"{"request":"edit","package":7}"#,
            r#"{"request":"open","path":"relative.swt"}"#,
            r#"{"request":"open","path":"/a","run":"sh"}"#,
            r#"{"request":"edit","path":"/a"}"#,
        ] {
            assert_eq!(Request::from_line(line), None, "{line}");
        }
        assert_eq!(Request::from_line(&format!(r#"{{"request":"edit","package":"{}"}}"#, "a".repeat(256))), None);
    }

    #[test]
    fn the_private_folder_is_closed_to_others() {
        let scratch = Scratch::short("folder");
        let directory = private_directory(scratch.root()).unwrap();
        assert_eq!(directory, scratch.path("scriptwidget"));
        assert_eq!(std::fs::metadata(&directory).unwrap().permissions().mode() & 0o777, 0o700);
        // An existing folder that is open to others is closed.
        std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o755)).unwrap();
        private_directory(scratch.root()).unwrap();
        assert_eq!(std::fs::metadata(&directory).unwrap().permissions().mode() & 0o777, 0o700);
        // A link in its place is refused.
        std::fs::remove_dir(&directory).unwrap();
        std::fs::create_dir(scratch.path("elsewhere")).unwrap();
        std::os::unix::fs::symlink(scratch.path("elsewhere"), &directory).unwrap();
        assert!(private_directory(scratch.root()).is_err());
        assert!(private_directory(Path::new("relative")).is_err());
    }

    #[test]
    fn a_second_start_hands_its_request_to_the_first() {
        let scratch = Scratch::short("one");
        let directory = private_directory(scratch.root()).unwrap();
        let Claim::Primary(primary) = claim(&directory, &Request::Show).unwrap() else { panic!("the first start is the window") };
        assert_eq!(std::fs::metadata(primary.socket()).unwrap().permissions().mode() & 0o777, 0o600);
        let (requests, received) = channel();
        primary.listen(move |request| {
            let _ = requests.send(request);
        });

        for request in [Request::Edit("Clock".into()), Request::Open("/tmp/a.swt".into()), Request::Show] {
            assert!(matches!(claim(&directory, &request).unwrap(), Claim::Forwarded));
            assert_eq!(received.recv_timeout(Duration::from_secs(5)).unwrap(), request);
        }

        // What is not a request is answered with a refusal and never reaches the window.
        let mut stream = UnixStream::connect(directory.join(SOCKET_FILE)).unwrap();
        stream.write_all(b"{\"request\":\"edit\",\"package\":\"../x\"}\n").unwrap();
        let mut answer = String::new();
        stream.read_to_string(&mut answer).unwrap();
        assert_eq!(answer, "refused\n");
        // A line without an end, and one that is too long, are refused too.
        let mut stream = UnixStream::connect(directory.join(SOCKET_FILE)).unwrap();
        // The window stops reading at its limit, so the rest of the write may fail.
        let _ = stream.write_all(&vec![b'a'; 20_000]);
        let _ = stream.shutdown(std::net::Shutdown::Write);
        let mut answer = String::new();
        let _ = stream.read_to_string(&mut answer);
        assert_ne!(answer, "ok\n");
        assert!(received.recv_timeout(Duration::from_millis(200)).is_err());
    }

    #[test]
    fn a_socket_left_by_a_window_that_ended_is_replaced() {
        let scratch = Scratch::short("stale");
        let directory = private_directory(scratch.root()).unwrap();
        // A window that ended without cleaning up: the socket file is there, nobody holds the lock.
        drop(UnixListener::bind(directory.join(SOCKET_FILE)).unwrap());
        std::fs::write(directory.join(LOCK_FILE), "").unwrap();
        assert!(matches!(claim(&directory, &Request::Show).unwrap(), Claim::Primary(_)));
    }

    #[test]
    fn the_lock_is_free_again_when_the_window_is_gone() {
        let scratch = Scratch::short("again");
        let directory = private_directory(scratch.root()).unwrap();
        let first = claim(&directory, &Request::Show).unwrap();
        assert!(matches!(first, Claim::Primary(_)));
        drop(first);
        assert!(matches!(claim(&directory, &Request::Show).unwrap(), Claim::Primary(_)));
    }
}
