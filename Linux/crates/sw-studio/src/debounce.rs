//! Runs the latest of a burst of requests once the burst is over, on a
//! thread of its own: the live preview compiles and runs the script shortly
//! after typing stops, never on the window's thread and never once per key.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::time::Duration;

struct Job<T> {
    ticket: u64,
    value: T,
    /// Run without waiting for the burst to end.
    immediate: bool,
}

/// `T` is a request, `R` its result.
pub struct Debouncer<T> {
    // A Mutex only so that the type is Sync; sending never blocks.
    jobs: Mutex<Sender<Job<T>>>,
    latest: Arc<AtomicU64>,
}

impl<T: Send + 'static> Debouncer<T> {
    /// `run` does the work on the worker thread; `deliver` receives the
    /// ticket of the request and its result, also on the worker thread.
    /// A request that was replaced before its turn is never run. A result
    /// may still arrive for a request that was replaced while it ran: compare
    /// its ticket with [`Debouncer::latest`].
    pub fn start<R: 'static>(delay: Duration, run: impl Fn(T) -> R + Send + 'static, deliver: impl Fn(u64, R) + Send + 'static) -> Self {
        let (jobs, queue) = mpsc::channel::<Job<T>>();
        std::thread::Builder::new()
            .name("studio-preview".into())
            .spawn(move || {
                while let Ok(mut job) = queue.recv() {
                    // Wait until nothing newer arrives for `delay`.
                    loop {
                        if job.immediate {
                            // Still take what is already waiting: only the newest matters.
                            match queue.try_recv() {
                                Ok(newer) => job = Job { immediate: true, ..newer },
                                Err(_) => break,
                            }
                        } else {
                            match queue.recv_timeout(delay) {
                                Ok(newer) => job = newer,
                                Err(RecvTimeoutError::Timeout) => break,
                                Err(RecvTimeoutError::Disconnected) => return,
                            }
                        }
                    }
                    deliver(job.ticket, run(job.value));
                }
            })
            .expect("the preview thread");
        Self { jobs: Mutex::new(jobs), latest: Arc::new(AtomicU64::new(0)) }
    }

    /// Asks for `value` once the burst is over. Returns the ticket its result will carry.
    pub fn request(&self, value: T) -> u64 {
        self.send(value, false)
    }

    /// Asks for `value` now: for a change that is one deliberate step, such as another size.
    pub fn request_now(&self, value: T) -> u64 {
        self.send(value, true)
    }

    /// The ticket of the newest request.
    pub fn latest(&self) -> u64 {
        self.latest.load(Ordering::SeqCst)
    }

    fn send(&self, value: T, immediate: bool) -> u64 {
        let jobs = self.jobs.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        // Tickets are given in the order the jobs are queued.
        let ticket = self.latest.fetch_add(1, Ordering::SeqCst) + 1;
        let _ = jobs.send(Job { ticket, value, immediate });
        ticket
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc::channel;
    use std::time::Instant;

    fn collector() -> (Debouncer<u32>, mpsc::Receiver<(u64, u32)>, Arc<AtomicU64>) {
        let (results, received) = channel();
        let runs = Arc::new(AtomicU64::new(0));
        let counted = runs.clone();
        let debouncer = Debouncer::start(
            Duration::from_millis(120),
            move |value: u32| {
                counted.fetch_add(1, Ordering::SeqCst);
                value * 2
            },
            move |ticket, result| {
                let _ = results.send((ticket, result));
            },
        );
        (debouncer, received, runs)
    }

    #[test]
    fn a_burst_runs_once_with_the_last_request() {
        let (debouncer, received, runs) = collector();
        let started = Instant::now();
        let mut last = 0;
        for value in 1..=8 {
            last = debouncer.request(value);
            std::thread::sleep(Duration::from_millis(10));
        }
        let (ticket, result) = received.recv_timeout(Duration::from_secs(5)).unwrap();
        assert!(started.elapsed() >= Duration::from_millis(120 + 70), "it waited for the burst to end");
        assert_eq!((ticket, result), (last, 16));
        assert_eq!(ticket, debouncer.latest());
        assert!(received.recv_timeout(Duration::from_millis(300)).is_err(), "nothing else was run");
        assert_eq!(runs.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn separate_requests_each_run() {
        let (debouncer, received, runs) = collector();
        let first = debouncer.request(1);
        assert_eq!(received.recv_timeout(Duration::from_secs(5)).unwrap(), (first, 2));
        let second = debouncer.request(5);
        assert_eq!(received.recv_timeout(Duration::from_secs(5)).unwrap(), (second, 10));
        assert!(second > first);
        assert_eq!(runs.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn an_immediate_request_does_not_wait() {
        let (debouncer, received, _) = collector();
        let started = Instant::now();
        let ticket = debouncer.request_now(21);
        assert_eq!(received.recv_timeout(Duration::from_secs(5)).unwrap(), (ticket, 42));
        assert!(started.elapsed() < Duration::from_millis(100), "{:?}", started.elapsed());
    }

    #[test]
    fn a_result_for_a_replaced_request_can_be_told_apart() {
        let (results, received) = channel();
        let (entered, running) = channel();
        let debouncer = Debouncer::start(
            Duration::from_millis(20),
            move |value: u32| {
                let _ = entered.send(());
                std::thread::sleep(Duration::from_millis(150));
                value
            },
            move |ticket, result| {
                let _ = results.send((ticket, result));
            },
        );
        let stale = debouncer.request(1);
        running.recv_timeout(Duration::from_secs(5)).unwrap();
        let fresh = debouncer.request(2);
        let first = received.recv_timeout(Duration::from_secs(5)).unwrap();
        assert_eq!(first, (stale, 1));
        assert_ne!(first.0, debouncer.latest(), "the window drops this one");
        assert_eq!(received.recv_timeout(Duration::from_secs(5)).unwrap(), (fresh, 2));
    }

    #[test]
    fn the_thread_ends_with_the_debouncer() {
        let (debouncer, received, _) = collector();
        debouncer.request(1);
        drop(debouncer);
        // The pending request is dropped with the queue and the thread returns: the channel closes.
        assert!(matches!(received.recv_timeout(Duration::from_secs(5)), Err(mpsc::RecvTimeoutError::Disconnected)));
    }
}
