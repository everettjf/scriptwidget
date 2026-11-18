//! The two clocks the service schedules with, behind a trait so that tests
//! can move time by hand.

use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};

pub trait Clock: Send + Sync {
    /// Milliseconds that only go forward, for deadlines. On Linux this
    /// counts the time the machine was asleep, so a deadline that passed
    /// during sleep is overdue at once when the machine wakes.
    fn now(&self) -> u64;
    /// Milliseconds since 1970 on the wall clock, which the user and the network can set.
    fn wall(&self) -> i64;
}

pub struct SystemClock {
    #[cfg(not(target_os = "linux"))]
    started: std::time::Instant,
}

impl SystemClock {
    pub fn new() -> Self {
        Self {
            #[cfg(not(target_os = "linux"))]
            started: std::time::Instant::now(),
        }
    }
}

impl Default for SystemClock {
    fn default() -> Self {
        Self::new()
    }
}

impl Clock for SystemClock {
    #[cfg(target_os = "linux")]
    fn now(&self) -> u64 {
        let mut time = libc::timespec { tv_sec: 0, tv_nsec: 0 };
        // SAFETY: `time` is a valid timespec to write to; CLOCK_BOOTTIME exists on every kernel Rust supports.
        unsafe { libc::clock_gettime(libc::CLOCK_BOOTTIME, &mut time) };
        (time.tv_sec as u64) * 1000 + (time.tv_nsec as u64) / 1_000_000
    }

    #[cfg(not(target_os = "linux"))]
    fn now(&self) -> u64 {
        self.started.elapsed().as_millis() as u64
    }

    fn wall(&self) -> i64 {
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |elapsed| elapsed.as_millis() as i64)
    }
}

/// A clock that stands still until it is moved, for tests.
pub struct ManualClock {
    now: AtomicU64,
    wall: AtomicI64,
}

impl ManualClock {
    pub fn new(wall_milliseconds: i64) -> Self {
        Self { now: AtomicU64::new(1_000_000), wall: AtomicI64::new(wall_milliseconds) }
    }

    /// Lets time pass: both clocks move.
    pub fn advance(&self, milliseconds: u64) {
        self.now.fetch_add(milliseconds, Ordering::SeqCst);
        self.wall.fetch_add(milliseconds as i64, Ordering::SeqCst);
    }

    /// Sets the wall clock, as a user or a time server would: only it moves.
    pub fn set_wall(&self, milliseconds: i64) {
        self.wall.store(milliseconds, Ordering::SeqCst);
    }
}

impl Clock for ManualClock {
    fn now(&self) -> u64 {
        self.now.load(Ordering::SeqCst)
    }

    fn wall(&self) -> i64 {
        self.wall.load(Ordering::SeqCst)
    }
}
