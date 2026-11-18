//! What the session tells the service: locked and unlocked, going to sleep
//! and awake again, the wall clock set, and the request to stop.
//!
//! - **Lock and sleep** come from logind's D-Bus signals, read from a child
//!   `gdbus monitor --system --dest org.freedesktop.login1` (an argument
//!   vector, no shell). That needs no D-Bus library in this program; `gdbus`
//!   is part of GLib, which every desktop has. Without it, lock is only known
//!   when the display reports it (`scriptwidget session locked`), and
//!   waking is still noticed through the clock, below.
//! - **The clock**: a timer on the realtime clock that the kernel cancels
//!   whenever that clock is set. The kernel does the same when the machine
//!   wakes from sleep, so this is also how waking is noticed when logind
//!   says nothing.
//! - **Stopping**: `SIGTERM` and `SIGINT` write one byte to a pipe that a
//!   thread reads; the handler does nothing else.
//!
//! None of these threads polls: each one sleeps in a read until there is news.

use std::collections::BTreeSet;
use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicI32, Ordering};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionEvent {
    /// logind says the session is locked or unlocked.
    Locked(bool),
    /// The display says the session is locked or unlocked.
    DisplayLocked(bool),
    /// The machine is about to sleep.
    Sleeping,
    /// The machine woke up.
    Resumed,
    /// The wall clock was set, or the machine woke up.
    ClockChanged,
}

/// What one line of `gdbus monitor` says.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LogindSignal {
    /// `PrepareForSleep`: true before sleep, false after.
    PrepareForSleep(bool),
    /// `Lock`, `Unlock` or a change of `LockedHint` on the session with this identifier.
    Lock { session: String, locked: bool },
}

/// The session identifier in a logind object path. systemd escapes every
/// byte that is not a letter or a digit, and a leading digit, as `_` and two
/// hexadecimal digits: session `2` is `/org/freedesktop/login1/session/_32`.
fn session_of(path: &str) -> Option<String> {
    let label = path.strip_prefix("/org/freedesktop/login1/session/")?;
    let bytes = label.as_bytes();
    let mut text = Vec::new();
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'_' {
            let code = std::str::from_utf8(bytes.get(index + 1..index + 3)?).ok()?;
            text.push(u8::from_str_radix(code, 16).ok()?);
            index += 3;
        } else if bytes[index].is_ascii_alphanumeric() {
            text.push(bytes[index]);
            index += 1;
        } else {
            return None;
        }
    }
    String::from_utf8(text).ok().filter(|id| !id.is_empty() && id.len() <= 64)
}

/// Reads one line of `gdbus monitor --system --dest org.freedesktop.login1`, such as
/// `/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (false,)`.
pub fn parse_logind_line(line: &str) -> Option<LogindSignal> {
    let (path, rest) = line.trim().split_once(": ")?;
    let (member, arguments) = rest.split_once(' ').unwrap_or((rest, ""));
    match member {
        "org.freedesktop.login1.Manager.PrepareForSleep" if path == "/org/freedesktop/login1" => match arguments.trim() {
            "(true,)" => Some(LogindSignal::PrepareForSleep(true)),
            "(false,)" => Some(LogindSignal::PrepareForSleep(false)),
            _ => None,
        },
        "org.freedesktop.login1.Session.Lock" => Some(LogindSignal::Lock { session: session_of(path)?, locked: true }),
        "org.freedesktop.login1.Session.Unlock" => Some(LogindSignal::Lock { session: session_of(path)?, locked: false }),
        "org.freedesktop.DBus.Properties.PropertiesChanged" if arguments.starts_with("('org.freedesktop.login1.Session',") => {
            let session = session_of(path)?;
            if arguments.contains("'LockedHint': <true>") {
                Some(LogindSignal::Lock { session, locked: true })
            } else if arguments.contains("'LockedHint': <false>") {
                Some(LogindSignal::Lock { session, locked: false })
            } else {
                None
            }
        }
        _ => None,
    }
}

/// The logind sessions of this user, from `loginctl show-user <uid> --property=Sessions --value`.
fn own_sessions() -> BTreeSet<String> {
    // SAFETY: geteuid has no preconditions and cannot fail.
    let user = unsafe { libc::geteuid() };
    let output = Command::new("loginctl").args(["show-user", &user.to_string(), "--property=Sessions", "--value"]).stdin(Stdio::null()).stderr(Stdio::null()).output();
    output.ok().filter(|output| output.status.success()).map(|output| String::from_utf8_lossy(&output.stdout).split_whitespace().map(str::to_owned).collect()).unwrap_or_default()
}

/// Watches logind on a thread of its own and reports what concerns this
/// user's sessions. Returns at once; when `gdbus` is missing or ends, the
/// thread tries again a few times and then gives up, and the service runs on
/// without these signals.
pub fn watch_logind(report: impl Fn(SessionEvent) + Send + 'static) {
    let _ = std::thread::Builder::new().name("scriptwidget-logind".into()).spawn(move || {
        for attempt in 0..5 {
            if attempt > 0 {
                std::thread::sleep(std::time::Duration::from_secs(30));
            }
            let mut command = Command::new("gdbus");
            command.args(["monitor", "--system", "--dest", "org.freedesktop.login1"]).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null());
            #[cfg(target_os = "linux")]
            {
                use std::os::unix::process::CommandExt;
                // SAFETY: prctl is async-signal-safe and touches no memory of this process; it runs in the child before exec.
                // The child ends when this thread does, so no monitor is left behind by a service that was killed.
                unsafe {
                    command.pre_exec(|| {
                        libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM);
                        Ok(())
                    })
                };
            }
            let Ok(mut child) = command.spawn() else {
                crate::log("gdbus is not installed: lock and sleep are not reported by logind");
                return;
            };
            let Some(output) = child.stdout.take() else { return };
            let mut sessions = own_sessions();
            for line in BufReader::new(output).lines() {
                let Ok(line) = line else { break };
                match parse_logind_line(&line) {
                    Some(LogindSignal::PrepareForSleep(true)) => report(SessionEvent::Sleeping),
                    Some(LogindSignal::PrepareForSleep(false)) => report(SessionEvent::Resumed),
                    Some(LogindSignal::Lock { session, locked }) => {
                        // A session that started after this service did is asked for once.
                        if !sessions.contains(&session) {
                            sessions = own_sessions();
                        }
                        // Another user's session on the same machine is not ours to follow.
                        if sessions.contains(&session) {
                            report(SessionEvent::Locked(locked));
                        }
                    }
                    None => {}
                }
            }
            let _ = child.kill();
            let _ = child.wait();
        }
    });
}

/// Reports every time the wall clock is set and every time the machine wakes
/// from sleep, on a thread of its own. Linux only; elsewhere the service
/// notices a jump of the wall clock the next time it wakes for something else.
#[cfg(target_os = "linux")]
pub fn watch_clock(report: impl Fn(SessionEvent) + Send + 'static) {
    const TFD_TIMER_ABSTIME: libc::c_int = 1;
    const TFD_TIMER_CANCEL_ON_SET: libc::c_int = 2;
    let _ = std::thread::Builder::new().name("scriptwidget-clock".into()).spawn(move || {
        // SAFETY: plain system calls on a descriptor this thread owns; every buffer is valid for its length.
        unsafe {
            let timer = libc::timerfd_create(libc::CLOCK_REALTIME, libc::TFD_CLOEXEC);
            if timer < 0 {
                return;
            }
            loop {
                // A time that never comes: the read below only returns when the kernel cancels the timer.
                let far = libc::itimerspec { it_interval: libc::timespec { tv_sec: 0, tv_nsec: 0 }, it_value: libc::timespec { tv_sec: libc::time_t::MAX / 2, tv_nsec: 0 } };
                if libc::timerfd_settime(timer, TFD_TIMER_ABSTIME | TFD_TIMER_CANCEL_ON_SET, &far, std::ptr::null_mut()) != 0 {
                    break;
                }
                let mut expirations = 0u64;
                let read = libc::read(timer, (&raw mut expirations).cast(), 8);
                if read < 0 && std::io::Error::last_os_error().raw_os_error() == Some(libc::ECANCELED) {
                    report(SessionEvent::ClockChanged);
                } else if read < 0 && std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
                    continue;
                } else {
                    break;
                }
            }
            libc::close(timer);
        }
    });
}

#[cfg(not(target_os = "linux"))]
pub fn watch_clock(_report: impl Fn(SessionEvent) + Send + 'static) {}

static SIGNAL_PIPE: AtomicI32 = AtomicI32::new(-1);

extern "C" fn on_signal(_signal: libc::c_int) {
    let pipe = SIGNAL_PIPE.load(Ordering::Relaxed);
    if pipe >= 0 {
        // SAFETY: write is async-signal-safe; the descriptor stays open for the life of the process.
        unsafe { libc::write(pipe, [1u8].as_ptr().cast(), 1) };
    }
}

/// Calls `stop` once, on a thread of its own, when the process receives `SIGTERM` or `SIGINT`.
pub fn on_termination(stop: impl FnOnce() + Send + 'static) -> std::io::Result<()> {
    let mut ends = [0 as libc::c_int; 2];
    // SAFETY: `ends` has room for the two descriptors; the handler only writes to a pipe.
    unsafe {
        if libc::pipe(ends.as_mut_ptr()) != 0 {
            return Err(std::io::Error::last_os_error());
        }
        for end in ends {
            libc::fcntl(end, libc::F_SETFD, libc::FD_CLOEXEC);
        }
        SIGNAL_PIPE.store(ends[1], Ordering::SeqCst);
        let handler = on_signal as extern "C" fn(libc::c_int) as *const () as libc::sighandler_t;
        libc::signal(libc::SIGTERM, handler);
        libc::signal(libc::SIGINT, handler);
    }
    let read_end = ends[0];
    std::thread::Builder::new().name("scriptwidget-signal".into()).spawn(move || {
        let mut byte = [0u8; 1];
        loop {
            // SAFETY: `byte` is valid for one byte; the descriptor is open.
            let count = unsafe { libc::read(read_end, byte.as_mut_ptr().cast(), 1) };
            if count == 1 {
                break;
            }
            if count < 0 && std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            return;
        }
        stop();
    })?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_lines_gdbus_prints() {
        let lock = |session: &str, locked| Some(LogindSignal::Lock { session: session.into(), locked });
        assert_eq!(parse_logind_line("/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (true,)"), Some(LogindSignal::PrepareForSleep(true)));
        assert_eq!(parse_logind_line("/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (false,)\n"), Some(LogindSignal::PrepareForSleep(false)));
        assert_eq!(parse_logind_line("/org/freedesktop/login1/session/_32: org.freedesktop.login1.Session.Lock ()"), lock("2", true));
        assert_eq!(parse_logind_line("/org/freedesktop/login1/session/_32: org.freedesktop.login1.Session.Unlock ()"), lock("2", false));
        assert_eq!(parse_logind_line("/org/freedesktop/login1/session/c1: org.freedesktop.login1.Session.Lock ()"), lock("c1", true));
        assert_eq!(parse_logind_line("/org/freedesktop/login1/session/_3142: org.freedesktop.login1.Session.Lock ()"), lock("142", true));
        assert_eq!(
            parse_logind_line("/org/freedesktop/login1/session/_34: org.freedesktop.DBus.Properties.PropertiesChanged ('org.freedesktop.login1.Session', {'LockedHint': <true>}, @as [])"),
            lock("4", true)
        );
        assert_eq!(
            parse_logind_line("/org/freedesktop/login1/session/_34: org.freedesktop.DBus.Properties.PropertiesChanged ('org.freedesktop.login1.Session', {'IdleHint': <true>, 'LockedHint': <false>}, @as [])"),
            lock("4", false)
        );
    }

    #[test]
    fn other_lines_say_nothing() {
        for line in [
            "",
            "Monitoring signals from all objects owned by org.freedesktop.login1",
            "The name org.freedesktop.login1 is owned by :1.4",
            "/org/freedesktop/login1: org.freedesktop.login1.Manager.SessionNew ('7', objectpath '/org/freedesktop/login1/session/_37')",
            "/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForShutdown (true,)",
            "/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (maybe,)",
            // The signal on an object that is not the manager, or not a session.
            "/somewhere/else: org.freedesktop.login1.Manager.PrepareForSleep (true,)",
            "/org/freedesktop/login1/seat/seat0: org.freedesktop.login1.Session.Lock ()",
            "/org/freedesktop/login1/session/: org.freedesktop.login1.Session.Lock ()",
            "/org/freedesktop/login1/session/_3: org.freedesktop.login1.Session.Lock ()",
            "/org/freedesktop/login1/session/a/b: org.freedesktop.login1.Session.Lock ()",
            "/org/freedesktop/login1/session/_34: org.freedesktop.DBus.Properties.PropertiesChanged ('org.freedesktop.login1.Session', {'IdleHint': <true>}, @as [])",
            "/org/freedesktop/login1/user/_1000: org.freedesktop.DBus.Properties.PropertiesChanged ('org.freedesktop.login1.User', {'LockedHint': <true>}, @as [])",
        ] {
            assert_eq!(parse_logind_line(line), None, "{line}");
        }
    }
}
