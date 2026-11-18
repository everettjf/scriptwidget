//! QuickJS-NG, as vendored in `Android/core/src/main/cpp/quickjs`, behind a
//! safe wrapper. This is the Linux counterpart of
//! `Windows/src/ScriptWidget.Core/Js/QuickJs.cs`.
//!
//! One [`Engine`] owns one runtime and one context and stays on the thread
//! that created it. JavaScript reaches the host only through the
//! `__swNative(operation, payload)` global, which calls the [`Host`] closure;
//! the engine exposes no file, process or network interface of its own.

use std::cell::Cell;
use std::ffi::{CString, c_char, c_int, c_void};
use std::fmt;
use std::marker::PhantomData;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::ptr;
use std::sync::Mutex;

/// Heap limit of an execution context, the same on every platform.
pub const DEFAULT_MEMORY_LIMIT: usize = 64 * 1024 * 1024;
/// JavaScript stack limit of an execution context. The thread that runs the
/// engine needs a larger native stack: see [`run_on_js_thread`].
pub const DEFAULT_STACK_LIMIT: usize = 3 * 1024 * 1024;
/// Native stack of the thread [`run_on_js_thread`] starts.
pub const JS_THREAD_STACK: usize = 8 * 1024 * 1024;

/// An uncaught JavaScript exception, or an interrupted execution.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct JsError {
    /// The exception converted to text, followed by a line break and the stack when there is one.
    pub message: String,
    /// True when the deadline stopped the script.
    pub interrupted: bool,
}

impl fmt::Display for JsError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for JsError {}

/// Answer of the host to `__swNative(operation, payload)`: text, null, or a
/// message that JavaScript receives as a thrown `Error`.
pub type HostResult = Result<Option<String>, String>;

/// The synchronous bridge behind `__swNative`. It may be called again while a
/// call is in progress only if it runs JavaScript itself, which the wrapper
/// does not allow, so interior state can live in `Cell` and `RefCell`.
pub type Host<'host> = dyn Fn(&str, Option<&str>) -> HostResult + 'host;

struct Shared<'host> {
    host: Box<Host<'host>>,
    engine: Cell<*mut ffi::Engine>,
}

/// One QuickJS-NG runtime and context.
///
/// Not `Send`: QuickJS measures its stack from the thread it runs on, and the
/// host closure need not be thread safe.
pub struct Engine<'host> {
    pointer: *mut ffi::Engine,
    shared: *mut Shared<'host>,
    _thread_bound: PhantomData<*mut ()>,
}

impl<'host> Engine<'host> {
    /// A context with the default limits of an execution.
    pub fn new(host: impl Fn(&str, Option<&str>) -> HostResult + 'host) -> Result<Self, JsError> {
        Self::with_limits(host, DEFAULT_MEMORY_LIMIT, DEFAULT_STACK_LIMIT)
    }

    pub fn with_limits(host: impl Fn(&str, Option<&str>) -> HostResult + 'host, memory_limit: usize, stack_limit: usize) -> Result<Self, JsError> {
        let shared = Box::into_raw(Box::new(Shared { host: Box::new(host), engine: Cell::new(ptr::null_mut()) }));
        // SAFETY: `shared` outlives the engine: it is freed in `drop` after `sw_destroy`.
        let pointer = unsafe { ffi::sw_create(memory_limit as i64, stack_limit as i64, host_call, shared.cast()) };
        if pointer.is_null() {
            // SAFETY: created above and not shared with anything.
            drop(unsafe { Box::from_raw(shared) });
            return Err(JsError { message: "QuickJS runtime could not be created".into(), interrupted: false });
        }
        // SAFETY: `shared` is valid and only this thread touches it.
        unsafe { (*shared).engine.set(pointer) };
        Ok(Self { pointer, shared, _thread_bound: PhantomData })
    }

    /// Stops running JavaScript after the given time; 0 clears the deadline.
    pub fn set_deadline(&mut self, milliseconds: u64) {
        // SAFETY: the engine is alive and used on its own thread.
        unsafe { ffi::sw_set_deadline(self.pointer, milliseconds.min(i64::MAX as u64 / 1_000_000) as i64) }
    }

    /// Evaluates a classic script in the global scope. Returns the completion
    /// value as text, or `None` for undefined and null.
    pub fn evaluate(&mut self, code: &str, file_name: &str) -> Result<Option<String>, JsError> {
        let (code, length) = terminated(code);
        let name = c_name(file_name);
        // SAFETY: `code` holds `length` bytes followed by a NUL, as JS_Eval requires.
        let status = unsafe { ffi::sw_evaluate(self.pointer, code.as_ptr().cast(), length as isize, name.as_ptr()) };
        self.finish(status)
    }

    /// Compiles a classic script to bytecode for [`Engine::evaluate_bytecode`].
    pub fn compile(&mut self, code: &str, file_name: &str) -> Result<Vec<u8>, JsError> {
        let (code, length) = terminated(code);
        let name = c_name(file_name);
        // SAFETY: as in `evaluate`.
        let status = unsafe { ffi::sw_compile(self.pointer, code.as_ptr().cast(), length as isize, name.as_ptr()) };
        if status < 0 {
            return Err(self.failure());
        }
        let mut length = 0isize;
        // SAFETY: after a successful compile the result holds `length` bytes until the next call.
        let bytes = unsafe {
            let data = ffi::sw_result(self.pointer, &mut length).cast::<u8>();
            if length <= 0 || data.is_null() { &[][..] } else { std::slice::from_raw_parts(data, length as usize) }
        };
        Ok(bytes.to_vec())
    }

    /// Runs bytecode.
    ///
    /// # Safety
    /// `bytecode` must come from [`Engine::compile`] of this build of the
    /// program. QuickJS does not verify bytecode: anything else, and above
    /// all anything read from a package or another untrusted source, can
    /// corrupt memory.
    pub unsafe fn evaluate_bytecode(&mut self, bytecode: &[u8]) -> Result<Option<String>, JsError> {
        // SAFETY: the caller vouches for the bytecode; the pointer and length describe it.
        let status = unsafe { ffi::sw_evaluate_bytecode(self.pointer, bytecode.as_ptr(), bytecode.len() as isize) };
        self.finish(status)
    }

    /// Calls a global function with string arguments; `None` passes null.
    pub fn call(&mut self, function: &str, arguments: &[Option<&str>]) -> Result<Option<String>, JsError> {
        let name = c_name(function);
        let pointers: Vec<*const c_char> = arguments.iter().map(|argument| argument.map_or(ptr::null(), |text| text.as_ptr().cast())).collect();
        let lengths: Vec<isize> = arguments.iter().map(|argument| argument.map_or(-1, |text| text.len() as isize)).collect();
        // SAFETY: both arrays have `arguments.len()` entries that stay alive for the call.
        let status = unsafe { ffi::sw_call(self.pointer, name.as_ptr(), pointers.as_ptr(), lengths.as_ptr(), arguments.len() as c_int) };
        self.finish(status)
    }

    /// Runs queued promise jobs, at most `maximum`; returns how many ran.
    pub fn run_jobs(&mut self, maximum: usize) -> Result<usize, JsError> {
        // SAFETY: the engine is alive and used on its own thread.
        let executed = unsafe { ffi::sw_run_jobs(self.pointer, maximum.min(c_int::MAX as usize) as c_int) };
        if executed < 0 { Err(self.failure()) } else { Ok(executed as usize) }
    }

    /// Bytes the engine has allocated.
    pub fn memory_used(&self) -> usize {
        // SAFETY: the engine is alive and used on its own thread.
        unsafe { ffi::sw_memory_used(self.pointer) }.max(0) as usize
    }

    fn finish(&mut self, status: c_int) -> Result<Option<String>, JsError> {
        match status {
            status if status < 0 => Err(self.failure()),
            0 => Ok(None),
            _ => Ok(Some(self.result_text())),
        }
    }

    fn result_text(&self) -> String {
        let mut length = 0isize;
        // SAFETY: the result holds `length` UTF-16 code units until the next call; malloc aligns it.
        unsafe {
            let data = ffi::sw_result(self.pointer, &mut length).cast::<u16>();
            text_from_engine(data, length).unwrap_or_default()
        }
    }

    fn failure(&self) -> JsError {
        // SAFETY: the engine is alive and used on its own thread.
        let interrupted = unsafe { ffi::sw_interrupted(self.pointer) } != 0;
        JsError { message: self.result_text(), interrupted }
    }
}

impl Drop for Engine<'_> {
    fn drop(&mut self) {
        // SAFETY: both pointers were created in `with_limits` and are released once, the engine first.
        unsafe {
            ffi::sw_destroy(self.pointer);
            drop(Box::from_raw(self.shared));
        }
    }
}

/// UTF-8 bytes followed by the NUL that JS_Eval requires, and the length without it.
fn terminated(code: &str) -> (Vec<u8>, usize) {
    let mut bytes = Vec::with_capacity(code.len() + 1);
    bytes.extend_from_slice(code.as_bytes());
    bytes.push(0);
    (bytes, code.len())
}

/// File and function names are chosen by the host; a NUL would be a programming error and is dropped.
fn c_name(name: &str) -> CString {
    CString::new(name.replace('\0', "")).expect("NUL bytes were removed")
}

/// Text the engine hands over as UTF-16. A lone surrogate, which a Rust
/// string cannot hold, becomes U+FFFD.
///
/// # Safety
/// `data` must point to `length` code units, or `length` must be negative.
unsafe fn text_from_engine(data: *const u16, length: isize) -> Option<String> {
    if length < 0 {
        return None;
    }
    if length == 0 || data.is_null() {
        return Some(String::new());
    }
    // SAFETY: guaranteed by the caller.
    Some(String::from_utf16_lossy(unsafe { std::slice::from_raw_parts(data, length as usize) }))
}

extern "C" fn host_call(user: *mut c_void, operation: *const u16, operation_length: isize, payload: *const u16, payload_length: isize) {
    // SAFETY: `user` is the `Shared` of the engine that is making this call,
    // alive until the engine is dropped; the text pointers are valid for the call.
    let (shared, operation, payload) = unsafe {
        let shared = &*user.cast::<Shared<'_>>();
        let payload = if payload.is_null() { None } else { text_from_engine(payload, payload_length) };
        (shared, text_from_engine(operation, operation_length).unwrap_or_default(), payload)
    };
    let engine = shared.engine.get();
    // A panic must not unwind through the C frames of the interpreter: hand it to JavaScript as an error.
    let answer = catch_unwind(AssertUnwindSafe(|| (shared.host)(&operation, payload.as_deref()))).unwrap_or_else(|_| Err("native host error".into()));
    // SAFETY: `engine` is the engine in the middle of this host call; the text outlives the call.
    unsafe {
        match answer {
            Ok(None) => {}
            Ok(Some(text)) => ffi::sw_host_return(engine, text.as_ptr().cast(), text.len() as isize),
            Err(message) => {
                let message = if message.is_empty() { "native host error" } else { message.as_str() };
                ffi::sw_host_throw(engine, message.as_ptr().cast(), message.len() as isize);
            }
        }
    }
}

/// Runs `work` on a fresh thread whose stack is large enough for the
/// JavaScript stack limit, and returns its result. A panic in `work` resumes
/// on the calling thread.
pub fn run_on_js_thread<T: Send>(name: &str, stack_bytes: usize, work: impl FnOnce() -> T + Send) -> T {
    std::thread::scope(|scope| {
        let thread = std::thread::Builder::new()
            .name(name.to_owned())
            .stack_size(stack_bytes)
            .spawn_scoped(scope, work)
            .expect("JavaScript thread could not be started");
        match thread.join() {
            Ok(value) => value,
            Err(panic) => std::panic::resume_unwind(panic),
        }
    })
}

static TIME_ZONE: Mutex<Option<Option<std::ffi::OsString>>> = Mutex::new(None);

/// Sets the time zone of JavaScript's local time (`Date`'s getters,
/// `toString`, `getTimezoneOffset`) for every engine in the process: an IANA
/// name such as "America/Los_Angeles", or `None` to go back to the zone the
/// process started with.
///
/// QuickJS asks the C library for local time, so this sets the `TZ` variable
/// and calls `tzset`. It also changes local time for everything else in the
/// process. Tests use it to pin the zone; the service leaves the system zone
/// alone.
///
/// # Safety
/// The environment is process-wide and not synchronized: no other thread may
/// read or write environment variables, or convert local time, while this
/// runs. Call it before the threads that run engines start.
pub unsafe fn set_process_time_zone(iana_name: Option<&str>) {
    unsafe extern "C" {
        fn tzset();
    }
    let mut original = TIME_ZONE.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let start = original.get_or_insert_with(|| std::env::var_os("TZ")).clone();
    // SAFETY: the caller guarantees that nothing else uses the environment or local time now.
    unsafe {
        match (iana_name, start) {
            // A leading colon tells the C library that this is a zone file name, not a POSIX rule.
            (Some(name), _) => std::env::set_var("TZ", format!(":{name}")),
            (None, Some(value)) => std::env::set_var("TZ", value),
            (None, None) => std::env::remove_var("TZ"),
        }
        tzset();
    }
}

mod ffi {
    use std::ffi::{c_char, c_int, c_void};

    #[repr(C)]
    pub struct Engine {
        _opaque: [u8; 0],
    }

    pub type HostFn = extern "C" fn(user: *mut c_void, operation: *const u16, operation_length: isize, payload: *const u16, payload_length: isize);

    unsafe extern "C" {
        pub fn sw_create(memory_limit: i64, stack_size: i64, host: HostFn, user: *mut c_void) -> *mut Engine;
        pub fn sw_destroy(engine: *mut Engine);
        pub fn sw_set_deadline(engine: *mut Engine, milliseconds_from_now: i64);
        pub fn sw_interrupted(engine: *mut Engine) -> c_int;
        pub fn sw_result(engine: *mut Engine, length: *mut isize) -> *const c_void;
        pub fn sw_host_return(engine: *mut Engine, utf8: *const c_char, length: isize);
        pub fn sw_host_throw(engine: *mut Engine, utf8: *const c_char, length: isize);
        pub fn sw_evaluate(engine: *mut Engine, code: *const c_char, length: isize, file_name: *const c_char) -> c_int;
        pub fn sw_compile(engine: *mut Engine, code: *const c_char, length: isize, file_name: *const c_char) -> c_int;
        pub fn sw_evaluate_bytecode(engine: *mut Engine, bytes: *const u8, length: isize) -> c_int;
        pub fn sw_call(engine: *mut Engine, function_name: *const c_char, arguments: *const *const c_char, lengths: *const isize, count: c_int) -> c_int;
        pub fn sw_run_jobs(engine: *mut Engine, maximum: c_int) -> c_int;
        pub fn sw_memory_used(engine: *mut Engine) -> i64;
    }
}
