//! Worker threads for native operations, so the JavaScript thread never
//! blocks on the network or the disk. The counterpart of `BoundedExecutor` in
//! `Windows/src/ScriptWidget.Core/Api/FetchModule.cs`.

use std::collections::VecDeque;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::{Arc, Mutex};

type Work = Box<dyn FnOnce() + Send + 'static>;

#[derive(Default)]
struct State {
    queue: VecDeque<Work>,
    running: usize,
}

/// Runs work on background threads, at most a fixed number at a time; the
/// rest waits in order. Threads end when there is nothing left to do.
pub struct BoundedExecutor {
    maximum: usize,
    state: Arc<Mutex<State>>,
}

impl BoundedExecutor {
    pub fn new(maximum_concurrent: usize) -> Self {
        Self { maximum: maximum_concurrent.max(1), state: Arc::default() }
    }

    pub fn execute(&self, work: impl FnOnce() + Send + 'static) {
        let mut work: Work = Box::new(work);
        {
            let mut state = self.state.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
            if state.running >= self.maximum {
                state.queue.push_back(work);
                return;
            }
            state.running += 1;
        }
        let shared = self.state.clone();
        let drain = move || {
            loop {
                // Work reports its own failures; one that still panics must not end the worker.
                let _ = catch_unwind(AssertUnwindSafe(work));
                let mut state = shared.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
                match state.queue.pop_front() {
                    Some(next) => work = next,
                    None => {
                        state.running -= 1;
                        return;
                    }
                }
            }
        };
        if let Err(error) = std::thread::Builder::new().name("scriptwidget-native".into()).spawn(drain) {
            // No thread could be started: the work is dropped, which rejects its operation.
            drop(error);
            let mut state = self.state.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
            state.running -= 1;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::mpsc;
    use std::time::Duration;

    #[test]
    fn runs_everything_with_bounded_concurrency() {
        let pool = BoundedExecutor::new(3);
        let active = Arc::new(AtomicUsize::new(0));
        let highest = Arc::new(AtomicUsize::new(0));
        let (done, finished) = mpsc::channel();
        for index in 0..20 {
            let (active, highest, done) = (active.clone(), highest.clone(), done.clone());
            pool.execute(move || {
                let now = active.fetch_add(1, Ordering::SeqCst) + 1;
                highest.fetch_max(now, Ordering::SeqCst);
                std::thread::sleep(Duration::from_millis(5));
                active.fetch_sub(1, Ordering::SeqCst);
                if index == 7 {
                    done.send(index).unwrap();
                    panic!("a failing job does not stop the pool");
                }
                done.send(index).unwrap();
            });
        }
        let mut seen: Vec<i32> = (0..20).map(|_| finished.recv_timeout(Duration::from_secs(10)).expect("job")).collect();
        seen.sort_unstable();
        assert_eq!(seen, (0..20).collect::<Vec<_>>());
        assert!(highest.load(Ordering::SeqCst) <= 3);
    }
}
