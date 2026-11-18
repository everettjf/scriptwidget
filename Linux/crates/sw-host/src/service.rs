//! The service itself: one loop that owns all state.
//!
//! Threads and channels, no asynchronous runtime: the service does a handful
//! of things at human speed, and every one of them is a blocking call that a
//! thread expresses directly.
//!
//! - The **main loop** (this file) owns the widgets, the schedule and the
//!   watchers. It handles one message at a time and never does anything
//!   slow: no script, no drawing, no waiting for a client.
//! - The **worker** (`worker.rs`) runs scripts and draws, one widget at a time.
//! - The **socket** (`server.rs`) has a thread that accepts, and one thread
//!   for each connection (two for a watcher).
//! - Small threads wait for signals, for logind and for the clock (`session.rs`).
//!
//! Between refreshes every thread sleeps in a blocking call: the main loop
//! in a wait for its next deadline, which is 15 minutes away when no widget
//! shows a clock.

use std::path::{Path, PathBuf};
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender, SyncSender, channel};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

use serde_json::{Map, Value, json};
use sw_core::api::system::Screen;
use sw_core::library::Library;
use sw_core::{DataPaths, Resources, SharedScripts, WidgetRuntime};
use sw_render::{HitRegion, WidgetRenderer};

use crate::clock::{Clock, SystemClock};
use crate::frames::FrameStore;
use crate::launcher::{Launcher, LinkTarget, SystemLauncher, checked_link};
use crate::paths::RuntimePaths;
use crate::placements::{DisplayMemory, MAXIMUM_SCREENS, Placement, Placements, ScreenInfo, Settings};
use crate::protocol::{self, Refusal, Request};
use crate::schedule;
use crate::server::{self, Acceptor, BindError, Inbound, Listening};
use crate::session::SessionEvent;
use crate::worker::{Action, Job, Kept, Outcome, Worker, WorkerMessage, interaction_text};

/// A picture that was replaced stays on disk this long, so that a display that is still loading it finds it.
pub const DEFAULT_FRAME_GRACE: u64 = 5000;
/// The layout engine is freed when nothing was drawn for this long.
const RELEASE_AFTER: u64 = 2 * 60_000;
/// Waking from sleep is reported by more than one source; they count as one within this time.
const REFRESH_ALL_DEBOUNCE: u64 = 2000;
/// The wall clock moved against the steady one by more than this: it was set.
const CLOCK_JUMP: i64 = 5000;
/// Room for the JSON of the deepest element tree the runtime contract allows.
const WORKER_STACK: usize = 64 * 1024 * 1024;
/// More tappable areas than this in one picture are not told to the display.
pub const MAXIMUM_REGIONS: usize = 256;

pub struct ServiceOptions {
    pub runtime: RuntimePaths,
    pub data: DataPaths,
    pub resources: Resources,
    pub clock: Arc<dyn Clock>,
    pub launcher: Arc<dyn Launcher>,
    /// The only user whose connections are served; `None` is the user of this process.
    pub expected_user: Option<u32>,
    /// See [`DEFAULT_FRAME_GRACE`].
    pub frame_grace: u64,
}

impl ServiceOptions {
    pub fn new(runtime: RuntimePaths, data: DataPaths, resources: Resources) -> Self {
        Self { runtime, data, resources, clock: Arc::new(SystemClock::new()), launcher: Arc::new(SystemLauncher), expected_user: None, frame_grace: DEFAULT_FRAME_GRACE }
    }
}

#[derive(Debug)]
pub enum StartError {
    /// A service of this session already holds the lock.
    AlreadyRunning,
    Io(std::io::Error),
}

impl std::fmt::Display for StartError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::AlreadyRunning => write!(formatter, "the ScriptWidget service is already running in this session"),
            Self::Io(error) => write!(formatter, "{error}"),
        }
    }
}

impl From<std::io::Error> for StartError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error)
    }
}

enum Message {
    Client(Inbound),
    Outcome(Box<Outcome>),
    Session(SessionEvent),
    /// Look at the clock again; for tests that move it by hand.
    Poke,
    Stop(String),
}

/// Talks to a running service from other threads of the same process.
#[derive(Clone)]
pub struct Controller(Sender<Message>);

impl Controller {
    pub fn session(&self, event: SessionEvent) {
        let _ = self.0.send(Message::Session(event));
    }

    pub fn poke(&self) {
        let _ = self.0.send(Message::Poke);
    }

    /// Asks the service to say `bye` with this reason and end.
    pub fn stop(&self, reason: &str) {
        let _ = self.0.send(Message::Stop(reason.to_owned()));
    }
}

/// A running service.
pub struct Service {
    controller: Controller,
    thread: Option<JoinHandle<()>>,
    socket: PathBuf,
}

impl Service {
    /// Takes the lock, binds the socket, starts the threads and begins drawing the saved widgets.
    pub fn start(options: ServiceOptions) -> Result<Self, StartError> {
        let listening = match server::bind(&options.runtime) {
            Ok(listening) => listening,
            Err(BindError::AlreadyRunning) => return Err(StartError::AlreadyRunning),
            Err(BindError::Io(error)) => return Err(StartError::Io(error)),
        };
        let frames = Arc::new(FrameStore::new(options.runtime.frames())?);
        let scripts = Arc::new(SharedScripts::new(&options.resources.runtime)?);
        let runtime = WidgetRuntime::new(scripts.clone(), &options.data)?;
        let renderer = WidgetRenderer::new(scripts)?;
        let templates = options.resources.templates.clone();
        let worker = Worker::new(runtime, renderer, Library::new(&options.data, templates.clone()), frames.clone());

        let (sender, messages) = channel::<Message>();
        let (jobs, job_queue) = channel::<WorkerMessage>();
        let outcomes = sender.clone();
        std::thread::Builder::new().name("scriptwidget-worker".into()).stack_size(WORKER_STACK).spawn(move || {
            worker.serve(job_queue, |outcome| {
                let _ = outcomes.send(Message::Outcome(Box::new(outcome)));
            });
        })?;

        let deliver = Mutex::new(sender.clone());
        let deliver: server::Deliver = Arc::new(move |inbound| deliver.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).send(Message::Client(inbound)).is_ok());
        // SAFETY: geteuid has no preconditions and cannot fail.
        let user = options.expected_user.unwrap_or_else(|| unsafe { libc::geteuid() });
        let acceptor = Acceptor::start(listening.listener()?, listening.socket().to_owned(), deliver, user)?;

        let socket = listening.socket().to_owned();
        let display_file = options.data.cache().join("display.json");
        let mut host = Host {
            clock: options.clock,
            launcher: options.launcher,
            frames,
            library: Library::new(&options.data, templates),
            placements: Placements::load(options.data.widgets()),
            settings: Settings::new(options.data.settings()),
            display: DisplayMemory::load(&display_file),
            display_file,
            widgets: Vec::new(),
            arrange: false,
            peek: false,
            peek_before_arrange: None,
            locked_by_logind: false,
            locked_by_display: false,
            watchers: Vec::new(),
            jobs,
            next_token: 1,
            retired: Vec::new(),
            frame_grace: options.frame_grace,
            clock_offset: 0,
            last_refresh_all: None,
            last_job: 0,
            renderer_live: false,
        };
        let thread = std::thread::Builder::new().name("scriptwidget-host".into()).spawn(move || host.run(messages, acceptor, listening))?;
        Ok(Self { controller: Controller(sender), thread: Some(thread), socket })
    }

    pub fn socket(&self) -> &Path {
        &self.socket
    }

    pub fn controller(&self) -> Controller {
        self.controller.clone()
    }

    /// Waits until the service has ended.
    pub fn wait(mut self) {
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }

    /// Stops the service and waits until the socket is gone.
    pub fn stop(self, reason: &str) {
        self.controller.stop(reason);
        self.wait();
    }
}

impl Drop for Service {
    fn drop(&mut self) {
        if let Some(thread) = self.thread.take() {
            self.controller.stop("shutdown");
            let _ = thread.join();
        }
    }
}

/// A tappable area of a published picture, in logical pixels from the widget's top-left corner.
struct Region {
    x: i64,
    y: i64,
    width: i64,
    height: i64,
    /// What the shared renderer recorded for the element. It comes from the package; it is validated when it is used.
    interaction: Map<String, Value>,
}

/// The picture of a widget that the display has been told about.
struct Published {
    version: u64,
    hash: [u8; 32],
    width: u32,
    height: u32,
    scale: f32,
    /// The files in order with their durations; one entry for a picture that does not move.
    frames: Vec<(PathBuf, u32)>,
    regions: Arc<Vec<Region>>,
}

struct Pending {
    run: bool,
    action: Option<Action>,
}

struct Widget {
    id: String,
    version: u64,
    published: Option<Published>,
    /// The action tables of pictures that were replaced, for a tap that names its version, each with the time it is forgotten.
    previous: Vec<(u64, Arc<Vec<Region>>, u64)>,
    /// The token of the job that is running for this widget.
    busy: Option<u64>,
    /// What was asked for while that job ran.
    pending: Option<Pending>,
    kept: Option<Arc<Kept>>,
    /// When the script runs again, on the steady clock.
    next_run: Option<u64>,
    /// When the same tree is drawn again because a date in it changed.
    next_redraw: Option<u64>,
    /// How often the script has run; for the list and for tests.
    runs: u64,
}

impl Widget {
    fn new(id: &str) -> Self {
        Self { id: id.to_owned(), version: 0, published: None, previous: Vec::new(), busy: None, pending: None, kept: None, next_run: None, next_redraw: None, runs: 0 }
    }
}

struct Host {
    clock: Arc<dyn Clock>,
    launcher: Arc<dyn Launcher>,
    frames: Arc<FrameStore>,
    library: Library,
    placements: Placements,
    settings: Settings,
    display: DisplayMemory,
    display_file: PathBuf,
    widgets: Vec<Widget>,
    arrange: bool,
    peek: bool,
    /// What `peek` was before arranging turned it on; `None` when not arranging or when the user set it since.
    peek_before_arrange: Option<bool>,
    locked_by_logind: bool,
    locked_by_display: bool,
    watchers: Vec<(u64, SyncSender<Arc<str>>)>,
    jobs: Sender<WorkerMessage>,
    next_token: u64,
    /// Files of replaced pictures, with the time they are deleted.
    retired: Vec<(u64, Vec<PathBuf>)>,
    frame_grace: u64,
    /// Wall clock minus steady clock when last looked at; a change means the wall clock was set.
    clock_offset: i64,
    last_refresh_all: Option<u64>,
    last_job: u64,
    /// True while the worker may hold a layout engine.
    renderer_live: bool,
}

fn ok() -> Value {
    json!({ "ok": true })
}

fn regions_of(hit_regions: Vec<HitRegion>, width: u32, height: u32) -> Vec<Region> {
    // A display reads at most this many regions of a widget.
    hit_regions
        .into_iter()
        .take(MAXIMUM_REGIONS)
        .map(|region| {
            let clamp = |value: f32, maximum: u32| (value as i64).clamp(0, i64::from(maximum));
            let (left, top) = (clamp(region.bounds.left.floor(), width), clamp(region.bounds.top.floor(), height));
            let (right, bottom) = (clamp(region.bounds.right.ceil(), width), clamp(region.bounds.bottom.ceil(), height));
            Region { x: left, y: top, width: (right - left).max(0), height: (bottom - top).max(0), interaction: region.interaction }
        })
        .collect()
}

impl Host {
    fn locked(&self) -> bool {
        self.locked_by_logind || self.locked_by_display
    }

    fn widget(&mut self, id: &str) -> Option<&mut Widget> {
        self.widgets.iter_mut().find(|widget| widget.id == id)
    }

    /// The screen a placement is drawn for: its own when the display has reported it, otherwise the first one known.
    fn screen_of(&self, placement: &Placement) -> ScreenInfo {
        self.display.screens.get(&placement.screen).or_else(|| self.display.screens.values().next()).copied().unwrap_or(ScreenInfo { scale: 1000, width: 1920, height: 1080 })
    }

    // The loop

    fn run(&mut self, messages: Receiver<Message>, acceptor: Acceptor, listening: Listening) {
        self.clock_offset = self.clock.wall() - self.clock.now() as i64;
        self.last_job = self.clock.now();
        for placement in self.placements.all().to_vec() {
            self.widgets.push(Widget::new(&placement.id));
            self.queue(&placement.id, true, None);
        }
        crate::log(&format!("listening on {}", listening.socket().display()));
        let reason = loop {
            self.on_time();
            let message = match self.next_deadline() {
                Some(deadline) => match messages.recv_timeout(Duration::from_millis(deadline.saturating_sub(self.clock.now()).max(1))) {
                    Ok(message) => message,
                    Err(RecvTimeoutError::Timeout) => continue,
                    Err(RecvTimeoutError::Disconnected) => break "shutdown".to_owned(),
                },
                None => match messages.recv() {
                    Ok(message) => message,
                    Err(_) => break "shutdown".to_owned(),
                },
            };
            match message {
                Message::Client(Inbound::Request { request, reply }) => {
                    let answer = self.handle(request).unwrap_or_else(|refusal| refusal.reply());
                    let _ = reply.try_send(answer);
                }
                Message::Client(Inbound::Watch { watcher, events }) => self.add_watcher(watcher, events),
                Message::Client(Inbound::WatcherGone { watcher }) => self.watchers.retain(|(id, _)| *id != watcher),
                Message::Outcome(outcome) => self.apply(*outcome),
                Message::Session(event) => self.session(event),
                Message::Poke => {}
                Message::Stop(reason) => break reason,
            }
        };

        // Every watcher gets `bye` as its last line; the socket goes away before the process does.
        self.broadcast(&protocol::bye(&reason));
        while acceptor.drained.try_recv().is_ok() {}
        let watchers = std::mem::take(&mut self.watchers).len();
        let deadline = std::time::Instant::now() + Duration::from_secs(1);
        for _ in 0..watchers {
            if acceptor.drained.recv_timeout(deadline.saturating_duration_since(std::time::Instant::now())).is_err() {
                break;
            }
        }
        acceptor.stop();
        drop(listening);
        let _ = self.frames.clear();
        crate::log(&format!("stopped ({reason})"));
    }

    /// Does what is due now.
    fn on_time(&mut self) {
        let now = self.clock.now();
        // The wall clock was set while nothing reported it (the fallback where the kernel does not tell).
        let offset = self.clock.wall() - now as i64;
        if (offset - self.clock_offset).abs() > CLOCK_JUMP {
            self.session(SessionEvent::ClockChanged);
        }
        let frames = self.frames.clone();
        self.retired.retain(|(at, files)| {
            if *at <= now {
                frames.remove(files);
            }
            *at > now
        });
        for widget in &mut self.widgets {
            widget.previous.retain(|(_, _, forgotten)| *forgotten > now);
        }
        // While the session is locked nothing runs and nothing is drawn.
        if !self.locked() {
            let due: Vec<(String, bool)> = self
                .widgets
                .iter()
                .filter(|widget| widget.busy.is_none())
                .filter_map(|widget| {
                    if widget.next_run.is_some_and(|at| at <= now) {
                        Some((widget.id.clone(), true))
                    } else if widget.next_redraw.is_some_and(|at| at <= now) {
                        Some((widget.id.clone(), false))
                    } else {
                        None
                    }
                })
                .collect();
            for (id, run) in due {
                self.queue(&id, run, None);
            }
        }
        if self.renderer_live && self.widgets.iter().all(|widget| widget.busy.is_none()) && now >= self.last_job + RELEASE_AFTER {
            let _ = self.jobs.send(WorkerMessage::Release);
            self.renderer_live = false;
        }
    }

    /// The next moment something is due, or `None` when only a message can bring work.
    fn next_deadline(&self) -> Option<u64> {
        let idle = self.widgets.iter().all(|widget| widget.busy.is_none());
        let retiring = self.retired.iter().map(|(at, _)| *at);
        let forgetting = self.widgets.iter().flat_map(|widget| widget.previous.iter().map(|(_, _, forgotten)| *forgotten));
        let scheduled = self.widgets.iter().filter(|widget| widget.busy.is_none() && !self.locked()).flat_map(|widget| [widget.next_run, widget.next_redraw]).flatten();
        let release = (self.renderer_live && idle).then_some(self.last_job + RELEASE_AFTER);
        retiring.chain(forgetting).chain(scheduled).chain(release).min()
    }

    // Jobs

    /// Starts a job for a widget, or notes it for when the running one is done.
    /// `run` runs the script; without it the last tree is drawn again.
    fn queue(&mut self, id: &str, run: bool, action: Option<Action>) {
        let Some(placement) = self.placements.find(id).cloned() else { return };
        let screen = self.screen_of(&placement);
        let dark = self.display.dark;
        let token = self.next_token;
        let Some(widget) = self.widget(id) else { return };
        if widget.busy.is_some() {
            let pending = widget.pending.get_or_insert(Pending { run: false, action: None });
            pending.run |= run || action.is_some();
            if action.is_some() {
                pending.action = action;
            }
            return;
        }
        let run = run || action.is_some();
        if run {
            widget.next_run = None;
        }
        widget.next_redraw = None;
        widget.busy = Some(token);
        let job = Job {
            token,
            id: id.to_owned(),
            package: placement.package,
            family: placement.family,
            dark,
            scale: screen.factor(),
            screen: Screen { width: screen.width as f64, height: screen.height as f64, scale: f64::from(screen.factor()) },
            action,
            kept: if run { None } else { widget.kept.clone() },
            current: widget.published.as_ref().map(|published| published.hash),
        };
        self.next_token += 1;
        self.renderer_live = true;
        let _ = self.jobs.send(WorkerMessage::Job(Box::new(job)));
    }

    /// Shows a finished job and schedules the next one.
    fn apply(&mut self, outcome: Outcome) {
        let now = self.clock.now();
        let wall = self.clock.wall();
        self.last_job = now;
        let temporaries = |outcome: &Outcome| outcome.picture.as_ref().map(|picture| picture.frames.iter().map(|(file, _)| file.clone()).collect::<Vec<_>>()).unwrap_or_default();
        if !self.widgets.iter().any(|widget| widget.id == outcome.id && widget.busy == Some(outcome.token)) {
            // The widget was removed while its job ran.
            self.frames.remove(&temporaries(&outcome));
            return;
        }
        let refresh_minutes = self.settings.refresh_minutes();
        let frames = self.frames.clone();
        let grace = self.frame_grace;
        let mut retired = None;
        let mut changed = false;
        let Some(widget) = self.widget(&outcome.id) else { return };
        widget.busy = None;
        if let Some(picture) = outcome.picture {
            let version = widget.version + 1;
            let moving = picture.frames.len() > 1;
            let mut published = Vec::new();
            let mut failed = false;
            for (index, (temporary, duration)) in picture.frames.iter().enumerate() {
                let name = frames.published(&widget.id, version, moving.then_some(index));
                failed |= frames.publish(temporary, &name).is_err();
                published.push((name, *duration));
            }
            if failed {
                crate::log(&format!("the picture of widget {} could not be published", widget.id));
                frames.remove(&picture.frames.iter().map(|(file, _)| file.clone()).chain(published.iter().map(|(file, _)| file.clone())).collect::<Vec<_>>());
            } else {
                widget.version = version;
                let regions = Arc::new(regions_of(picture.regions, picture.width, picture.height));
                let new = Published { version, hash: picture.hash, width: picture.width, height: picture.height, scale: picture.scale, frames: published, regions };
                if let Some(old) = widget.published.replace(new) {
                    widget.previous.push((old.version, old.regions, now + grace));
                    retired = Some((now + grace, old.frames.into_iter().map(|(file, _)| file).collect::<Vec<_>>()));
                }
                changed = true;
            }
        }
        if let Some(kept) = outcome.kept {
            if outcome.ran {
                widget.runs += 1;
                widget.next_run = Some(now + schedule::run_delay(refresh_minutes, kept.next_transition, wall));
            }
            widget.next_redraw = kept.tick.map(|tick| now + schedule::tick_delay(tick, wall));
            widget.kept = Some(kept);
        }
        let pending = widget.pending.take();
        self.retired.extend(retired);
        if changed && let Some(event) = self.widget_event(&outcome.id) {
            self.broadcast(&event);
        }
        if let Some(pending) = pending {
            self.queue(&outcome.id, pending.run, pending.action);
        }
    }

    fn refresh_all(&mut self) {
        let ids: Vec<String> = self.widgets.iter().map(|widget| widget.id.clone()).collect();
        for id in ids {
            self.queue(&id, true, None);
        }
    }

    fn session(&mut self, event: SessionEvent) {
        let was_locked = self.locked();
        let now = self.clock.now();
        match event {
            SessionEvent::Locked(locked) => self.locked_by_logind = locked,
            SessionEvent::DisplayLocked(locked) => self.locked_by_display = locked,
            SessionEvent::Sleeping => {}
            SessionEvent::Resumed | SessionEvent::ClockChanged => {
                self.clock_offset = self.clock.wall() - now as i64;
                // Everything may be stale: time passed that no timer counted, or the time itself changed.
                // While locked the unlock does it.
                if !self.locked() && self.last_refresh_all.is_none_or(|last| now >= last + REFRESH_ALL_DEBOUNCE) {
                    self.last_refresh_all = Some(now);
                    self.refresh_all();
                }
            }
        }
        if was_locked && !self.locked() {
            self.last_refresh_all = Some(now);
            self.refresh_all();
        }
    }

    // Watchers

    fn broadcast(&mut self, event: &Value) {
        let line: Arc<str> = Arc::from(event.to_string());
        // A watcher that is this far behind is dropped; its connection closes and the display connects again.
        self.watchers.retain(|(_, events)| events.try_send(line.clone()).is_ok());
    }

    /// A watcher that connects later receives the whole current state before anything else.
    fn add_watcher(&mut self, watcher: u64, events: SyncSender<Arc<str>>) {
        let mut lines = vec![protocol::hello(self.display.dark, self.arrange, self.peek)];
        lines.extend(self.widgets.iter().filter_map(|widget| self.widget_event(&widget.id)));
        if lines.into_iter().all(|line| events.try_send(Arc::from(line.to_string())).is_ok()) {
            self.watchers.push((watcher, events));
        }
    }

    /// The `widget` event for the picture now published, or `None` when the widget has none yet.
    fn widget_event(&self, id: &str) -> Option<Value> {
        let placement = self.placements.find(id)?;
        let widget = self.widgets.iter().find(|widget| widget.id == id)?;
        let published = widget.published.as_ref()?;
        let path = |file: &PathBuf| file.display().to_string();
        let mut event = json!({
            "event": "widget",
            "id": id,
            "screen": placement.screen,
            "x": placement.x,
            "y": placement.y,
            "width": published.width,
            "height": published.height,
            "image": path(&published.frames.first()?.0),
            "version": published.version,
            "regions": published.regions.iter().enumerate().map(|(n, region)| json!({ "n": n, "x": region.x, "y": region.y, "width": region.width, "height": region.height })).collect::<Vec<_>>(),
        });
        if published.frames.len() > 1 {
            event["frames"] = published.frames.iter().map(|(file, duration)| json!({ "image": path(file), "ms": duration })).collect();
        }
        event["family"] = json!(placement.family);
        let families = widget.kept.as_ref().map(|kept| kept.families.clone()).filter(|families| !families.is_empty());
        event["families"] = json!(families.unwrap_or_else(|| protocol::FAMILIES.iter().map(|family| (*family).to_owned()).collect()));
        Some(event)
    }

    // Requests

    fn handle(&mut self, request: Request) -> Result<Value, Refusal> {
        let unknown = || Refusal::new("widget.unknown", "No widget has this identifier.");
        match request {
            // The socket layer turns `watch` into a stream before it gets here.
            Request::Watch => Err(Refusal::invalid("watch is not a request with a reply.")),
            Request::Status => Ok(json!({
                "ok": true,
                "protocol": protocol::PROTOCOL,
                "service": env!("CARGO_PKG_VERSION"),
                "pid": std::process::id(),
                "widgets": self.widgets.len(),
                "watchers": self.watchers.len(),
                "dark": self.display.dark,
                "arrange": self.arrange,
                "peek": self.peek,
                "locked": self.locked(),
                "refreshMinutes": self.settings.refresh_minutes(),
                "screens": self.display.screens.iter().map(|(name, screen)| (name.clone(), json!({ "scale": screen.scale, "width": screen.width, "height": screen.height }))).collect::<Map<String, Value>>(),
            })),
            Request::Widgets => {
                let widgets: Vec<Value> = self
                    .widgets
                    .iter()
                    .filter_map(|widget| {
                        let placement = self.placements.find(&widget.id)?;
                        let (width, height) = sw_render::family_size(&placement.family)?;
                        let kept = widget.kept.as_deref();
                        Some(json!({
                            "id": widget.id,
                            "package": kept.map(|kept| kept.name.clone()).filter(|name| !name.is_empty()),
                            "installation": placement.package,
                            "installed": kept.is_none_or(|kept| kept.installed),
                            "family": placement.family,
                            "screen": placement.screen,
                            "x": placement.x,
                            "y": placement.y,
                            "width": width as u32,
                            "height": height as u32,
                            "version": widget.version,
                            "image": widget.published.as_ref().and_then(|published| published.frames.first()).map(|(file, _)| file.display().to_string()),
                            "frames": widget.published.as_ref().map_or(0, |published| published.frames.len()),
                            "regions": widget.published.as_ref().map_or(0, |published| published.regions.len()),
                            "scale": widget.published.as_ref().map(|published| published.scale),
                            "runs": widget.runs,
                            "busy": widget.busy.is_some(),
                            "error": kept.and_then(|kept| kept.error.clone()),
                        }))
                    })
                    .collect();
                Ok(json!({ "ok": true, "widgets": widgets }))
            }
            Request::Add { package, family } => {
                let installed = self.library.find(&package).ok_or_else(|| Refusal::new("package.unknown", "No installed package has this name. scriptwidget list shows them."))?;
                let families = installed.families();
                let family = match family {
                    Some(family) if families.contains(&family.as_str()) => family,
                    Some(_) => return Err(Refusal::new("family.unsupported", format!("This package supports: {}.", families.join(", ")))),
                    None => (*families.iter().find(|family| **family == "medium").or(families.first()).unwrap_or(&"medium")).to_owned(),
                };
                let id = protocol::new_identifier().map_err(|_| Refusal::new("service.internal", "No random source."))?;
                // Each new widget a little further down and right, so that they do not hide each other.
                let step = 40 + 28 * (self.placements.all().len() as i64 % 8);
                let placement = Placement { id: id.clone(), package: installed.installation.clone(), family: family.clone(), screen: String::new(), x: step, y: step };
                if self.placements.add(placement).is_none() {
                    return Err(Refusal::new("widgets.limit", "The desktop already holds the most widgets it can."));
                }
                self.widgets.push(Widget::new(&id));
                self.queue(&id, true, None);
                Ok(json!({ "ok": true, "id": id, "package": installed.name, "family": family }))
            }
            Request::Remove { id } => {
                if !self.remove(&id) {
                    return Err(unknown());
                }
                Ok(ok())
            }
            Request::Refresh { id, package } => {
                let ids: Vec<String> = match (id, package) {
                    (Some(id), _) => vec![self.widget(&id).ok_or_else(unknown)?.id.clone()],
                    (None, Some(package)) => {
                        let installed = self.library.find(&package).ok_or_else(|| Refusal::new("package.unknown", "No installed package has this name."))?;
                        self.placements.all().iter().filter(|placement| placement.package == installed.installation).map(|placement| placement.id.clone()).collect()
                    }
                    (None, None) => self.widgets.iter().map(|widget| widget.id.clone()).collect(),
                };
                for id in &ids {
                    self.queue(id, true, None);
                }
                Ok(json!({ "ok": true, "refreshed": ids.len() }))
            }
            Request::Peek(switch) => {
                let peek = switch.apply(self.peek);
                // Said during arranging, it is the user's choice and stays when arranging ends.
                self.peek_before_arrange = None;
                self.set_mode(self.arrange, peek);
                Ok(json!({ "ok": true, "arrange": self.arrange, "peek": self.peek }))
            }
            Request::Arrange(switch) => {
                let arrange = switch.apply(self.arrange);
                // On the bottom layer a drag ends where the pointer reaches a window, so arranging raises the
                // widgets above the windows; ending it puts them back where they were.
                let mut peek = self.peek;
                if arrange && !self.arrange {
                    self.peek_before_arrange = Some(self.peek);
                    peek = true;
                } else if !arrange && self.arrange {
                    peek = self.peek_before_arrange.take().unwrap_or(self.peek);
                }
                self.set_mode(arrange, peek);
                Ok(json!({ "ok": true, "arrange": self.arrange, "peek": self.peek }))
            }
            Request::Tap { id, n, version } => self.tap(&id, n as usize, version),
            Request::Move { id, screen, x, y } => {
                let family = self.placements.find(&id).ok_or_else(unknown)?.family.clone();
                let (mut x, mut y) = (x, y);
                // On a screen whose size is known the widget stays on it; the display does the snapping.
                if let (Some(known), Some((width, height))) = (self.display.screens.get(&screen), sw_render::family_size(&family)) {
                    x = x.clamp(0, (known.width - width as i64).max(0));
                    y = y.clamp(0, (known.height - height as i64).max(0));
                }
                self.placements.update(&id, |placement| {
                    placement.screen = screen.clone();
                    placement.x = x;
                    placement.y = y;
                });
                self.redraw_if_scale_changed(&id);
                if let Some(event) = self.widget_event(&id) {
                    self.broadcast(&event);
                }
                Ok(json!({ "ok": true, "screen": screen, "x": x, "y": y }))
            }
            Request::Screen { name, scale, width, height } => {
                if !self.display.screens.contains_key(&name) && self.display.screens.len() >= MAXIMUM_SCREENS {
                    return Err(Refusal::new("screens.limit", "Too many screens."));
                }
                let screen = ScreenInfo { scale, width, height };
                if self.display.screens.insert(name, screen) != Some(screen) {
                    self.display.save(&self.display_file);
                    let ids: Vec<String> = self.widgets.iter().map(|widget| widget.id.clone()).collect();
                    for id in ids {
                        self.redraw_if_scale_changed(&id);
                    }
                }
                Ok(ok())
            }
            Request::Theme { dark } => {
                if self.display.dark != dark {
                    self.display.dark = dark;
                    self.display.save(&self.display_file);
                    self.refresh_all();
                }
                Ok(json!({ "ok": true, "dark": dark }))
            }
            Request::Menu { id, word } => {
                let placement = self.placements.find(&id).ok_or_else(unknown)?.clone();
                match word.as_str() {
                    "remove" => {
                        self.remove(&id);
                    }
                    "refresh" => self.queue(&id, true, None),
                    "edit" => {
                        // The name is looked up from the installation; nothing of the request is passed on.
                        let installed = self.library.find_by_installation(&placement.package).ok_or_else(|| Refusal::new("package.unknown", "The package of this widget is no longer installed."))?;
                        if !self.launcher.open_studio(Some(&installed.name)) {
                            return Err(Refusal::new("studio.unavailable", "scriptwidget-studio is not installed."));
                        }
                    }
                    resize => {
                        let family = resize.strip_prefix("resize-").filter(|family| protocol::is_family(family)).ok_or_else(|| Refusal::invalid("Unknown menu word."))?;
                        if let Some(installed) = self.library.find_by_installation(&placement.package)
                            && !installed.families().contains(&family)
                        {
                            return Err(Refusal::new("family.unsupported", format!("This package supports: {}.", installed.families().join(", "))));
                        }
                        if placement.family != family {
                            self.placements.update(&id, |placement| placement.family = family.to_owned());
                            self.queue(&id, true, None);
                        } else if let Some(event) = self.widget_event(&id) {
                            // The display waits for an answer to a resize: the size it already has.
                            self.broadcast(&event);
                        }
                    }
                }
                Ok(ok())
            }
            Request::Session { locked } => {
                self.session(SessionEvent::DisplayLocked(locked));
                Ok(json!({ "ok": true, "locked": self.locked() }))
            }
        }
    }

    fn set_mode(&mut self, arrange: bool, peek: bool) {
        if (arrange, peek) != (self.arrange, self.peek) {
            self.arrange = arrange;
            self.peek = peek;
            self.broadcast(&protocol::mode(arrange, peek));
        }
    }

    fn redraw_if_scale_changed(&mut self, id: &str) {
        let Some(placement) = self.placements.find(id) else { return };
        let wanted = self.screen_of(placement).factor();
        let drawn = self.widgets.iter().find(|widget| widget.id == id).and_then(|widget| widget.published.as_ref()).map(|published| published.scale);
        if drawn.is_some_and(|drawn| (drawn - wanted).abs() > 0.001) {
            self.queue(id, false, None);
        }
    }

    fn remove(&mut self, id: &str) -> bool {
        if !self.placements.remove(id) {
            return false;
        }
        let now = self.clock.now();
        if let Some(index) = self.widgets.iter().position(|widget| widget.id == id) {
            let widget = self.widgets.remove(index);
            if let Some(published) = widget.published {
                self.retired.push((now + self.frame_grace, published.frames.into_iter().map(|(file, _)| file).collect()));
            }
        }
        self.broadcast(&protocol::removed(id));
        true
    }

    /// Runs what region `n` of a picture stands for. The number selects an
    /// entry of the service's own table; nothing else of the request is used.
    fn tap(&mut self, id: &str, n: usize, version: Option<u64>) -> Result<Value, Refusal> {
        let widget = self.widgets.iter().find(|widget| widget.id == id).ok_or_else(|| Refusal::new("widget.unknown", "No widget has this identifier."))?;
        let published = widget.published.as_ref().ok_or_else(|| Refusal::new("region.unknown", "This widget has no picture yet."))?;
        let regions = match version {
            None => published.regions.clone(),
            Some(version) if version == published.version => published.regions.clone(),
            Some(version) => widget.previous.iter().find(|(previous, _, _)| *previous == version).map(|(_, regions, _)| regions.clone()).ok_or_else(|| Refusal::new("version.stale", "That picture is no longer on screen."))?,
        };
        let interaction = &regions.get(n).ok_or_else(|| Refusal::new("region.unknown", "This picture has no region with that number."))?.interaction;
        let text = |name: &str| interaction_text(interaction, name);
        match text("type").as_deref() {
            Some("link") => match text("url").as_deref().and_then(checked_link) {
                Some(LinkTarget::Open(url)) => {
                    if !self.launcher.open_link(&url) {
                        return Err(Refusal::new("link.unavailable", "The link could not be opened: xdg-open did not start."));
                    }
                    Ok(json!({ "ok": true, "action": "link" }))
                }
                Some(LinkTarget::Application) => {
                    if !self.launcher.open_studio(None) {
                        return Err(Refusal::new("studio.unavailable", "scriptwidget-studio is not installed."));
                    }
                    Ok(json!({ "ok": true, "action": "application" }))
                }
                None => Err(Refusal::new("link.refused", "Only http, https and mailto links are opened.")),
            },
            Some("button") if text("action").is_some_and(|action| action.eq_ignore_ascii_case("reload")) => {
                self.queue(id, true, None);
                Ok(json!({ "ok": true, "action": "reload" }))
            }
            Some("button") => {
                self.queue(id, true, Some(Action { action_id: text("actionID"), handler: text("handler"), state_key: None, value: None }));
                Ok(json!({ "ok": true, "action": "button" }))
            }
            Some("toggle") => {
                let on = interaction.get("on").and_then(Value::as_bool).unwrap_or(false);
                self.queue(id, true, Some(Action { action_id: text("actionID"), handler: text("handler"), state_key: text("stateKey"), value: Some(!on) }));
                Ok(json!({ "ok": true, "action": "toggle", "value": !on }))
            }
            _ => Err(Refusal::new("region.unknown", "This region does nothing.")),
        }
    }
}

/// Runs the service for this session until it is told to stop: the body of
/// `scriptwidget host run`. Returns the exit code.
pub fn run_process(data: Option<&Path>) -> i32 {
    let fail = |message: String| {
        eprintln!("error: [service.start] {message}");
        2
    };
    let runtime = match RuntimePaths::from_environment() {
        Ok(runtime) => runtime,
        Err(error) => return fail(error.to_string()),
    };
    let data = match DataPaths::new(data) {
        Ok(data) => data,
        Err(error) => return fail(format!("The data folder cannot be used: {error}")),
    };
    let resources = match Resources::locate() {
        Ok(resources) => resources,
        Err(error) => return fail(error.to_string()),
    };
    let service = match Service::start(ServiceOptions::new(runtime, data, resources)) {
        Ok(service) => service,
        Err(error) => return fail(error.to_string()),
    };
    let controller = service.controller();
    if let Err(error) = crate::session::on_termination(move || controller.stop("shutdown")) {
        crate::log(&format!("signals cannot be handled: {error}"));
    }
    let controller = service.controller();
    crate::session::watch_logind(move |event| controller.session(event));
    let controller = service.controller();
    crate::session::watch_clock(move |event| controller.session(event));
    service.wait();
    0
}
