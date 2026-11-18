//! The one thread that runs package scripts and draws pictures, one widget
//! at a time, as the refresh thread of the Windows host does
//! (`Windows/src/ScriptWidget.App/AppHost.cs`). The service's main loop hands
//! it jobs and gets outcomes back; it never waits for it, so a slow script
//! or a slow download holds up neither the socket nor the other requests.
//!
//! Package code runs here, inside this process, in a fresh QuickJS context
//! with bounded memory, stack and time (plan, section 6).

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::mpsc::Receiver;

use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use sw_core::api::system::Screen;
use sw_core::executor::ExecutionError;
use sw_core::library::{InstalledPackage, Library};
use sw_core::{PackageFiles, RunRequest, WidgetRuntime};
use sw_render::gif_cache::FrameCacheScope;
use sw_render::{HitRegion, RenderError, RenderOutput, RenderRequest, WidgetRenderer, rounded_corners};

use crate::frames::FrameStore;
use crate::schedule::{self, Tick};
use crate::surfaces;

/// A widget shows at most this many pictures in a cycle (plan 4.8).
pub const MAXIMUM_GIF_FRAMES: usize = sw_render::gif::MAXIMUM_FRAMES;
/// All pictures of one cycle together have at most this many pixels; a widget that would need more shows its first frame only.
pub const MAXIMUM_CYCLE_PIXELS: u64 = 32 * 1024 * 1024;

/// What a tap asked for. Built by the service from its own action table, never from a request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Action {
    /// A declared action of the manifest (`actions[].id`).
    pub action_id: Option<String>,
    /// The legacy `onClick="name"` function of the element.
    pub handler: Option<String>,
    /// For a toggle: the storage key that holds its state, and the new state.
    pub state_key: Option<String>,
    pub value: Option<bool>,
}

/// What a finished run left behind: enough to draw the same tree again, at
/// another scale or a second later, without running the script.
pub struct Kept {
    pub family: String,
    pub dark: bool,
    tree: String,
    /// False when `tree` is a card of the service (an error, a missing package).
    own_tree: bool,
    files: Option<Arc<dyn PackageFiles>>,
    remote_images: HashMap<String, PathBuf>,
    /// When the package's timeline next changes slot, in milliseconds since 1970.
    pub next_transition: Option<i64>,
    pub tick: Option<Tick>,
    /// The error kind of the run, when it failed.
    pub error: Option<String>,
    /// False when the package is no longer installed.
    pub installed: bool,
    /// The package's name and the sizes it supports, for the list and the menu.
    pub name: String,
    pub families: Vec<String>,
}

pub struct Job {
    /// Unique in this run of the service; names the temporary files.
    pub token: u64,
    pub id: String,
    /// Installation identity of the package.
    pub package: String,
    pub family: String,
    pub dark: bool,
    pub scale: f32,
    pub screen: Screen,
    /// Run this before the script runs again.
    pub action: Option<Action>,
    /// Draw this again instead of running the script, when it still fits the family and theme.
    pub kept: Option<Arc<Kept>>,
    /// The picture now on screen; a job that produces the same one publishes nothing.
    pub current: Option<[u8; 32]>,
}

pub struct Picture {
    pub hash: [u8; 32],
    /// Logical size.
    pub width: u32,
    pub height: u32,
    pub scale: f32,
    /// The temporary files, in order, each with how long it is shown; one entry for a picture that does not move.
    pub frames: Vec<(PathBuf, u32)>,
    pub regions: Vec<HitRegion>,
}

pub struct Outcome {
    pub token: u64,
    pub id: String,
    pub kept: Option<Arc<Kept>>,
    /// True when the script ran (and not only the old tree was drawn again).
    pub ran: bool,
    /// `None` when the picture is the one already on screen, or when nothing could be drawn.
    pub picture: Option<Picture>,
}

pub enum WorkerMessage {
    Job(Box<Job>),
    /// Frees what only drawing needs; the next job creates it again.
    Release,
}

pub struct Worker {
    runtime: WidgetRuntime,
    renderer: WidgetRenderer,
    library: Library,
    frames: Arc<FrameStore>,
}

impl Worker {
    pub fn new(runtime: WidgetRuntime, renderer: WidgetRenderer, library: Library, frames: Arc<FrameStore>) -> Self {
        Self { runtime, renderer, library, frames }
    }

    /// Serves jobs until the sender is dropped.
    pub fn serve(self, jobs: Receiver<WorkerMessage>, finished: impl Fn(Outcome)) {
        for message in jobs {
            match message {
                WorkerMessage::Job(job) => finished(self.execute(*job)),
                WorkerMessage::Release => self.renderer.release(),
            }
        }
    }

    fn execute(&self, job: Job) -> Outcome {
        let reusable = job.action.is_none();
        let mut kept = job.kept.clone().filter(|kept| reusable && kept.installed && kept.family == job.family && kept.dark == job.dark);
        let ran = kept.is_none();
        if kept.is_none() {
            kept = Some(Arc::new(self.run(&job)));
        }
        let picture = kept.as_deref().and_then(|kept| match self.picture(&job, kept) {
            Ok(picture) => picture,
            Err(error) => {
                crate::log(&format!("widget {} could not be drawn: {}", job.id, error.message));
                None
            }
        });
        Outcome { token: job.token, id: job.id, kept, ran, picture }
    }

    /// Runs the tapped action, then the script.
    fn run(&self, job: &Job) -> Kept {
        let Some(installed) = self.library.find_by_installation(&job.package) else {
            return Kept {
                family: job.family.clone(),
                dark: job.dark,
                tree: WidgetRuntime::notice_tree("Widget not found", "Its package was removed. Remove this widget from the desktop."),
                own_tree: false,
                files: None,
                remote_images: HashMap::new(),
                next_transition: None,
                tick: None,
                error: None,
                installed: false,
                name: String::new(),
                families: Vec::new(),
            };
        };
        let files: Arc<dyn PackageFiles> = Arc::new(installed.files());
        let request = |files: &Arc<dyn PackageFiles>| RunRequest {
            family: job.family.clone(),
            dark_mode: job.dark,
            build_directory: Some(installed.build_directory()),
            screen: job.screen,
            ..RunRequest::new(files.clone(), installed.installation.clone())
        };
        if let Some(action) = &job.action {
            self.perform(&installed, action, request(&files));
        }
        let request = request(&files);
        let result = self.runtime.run(&request);
        if let Some(error) = &result.execution.error {
            // The kind only: a message may quote what the script handled.
            crate::log(&format!("widget {}: {}", job.id, error.kind));
        }
        let remote_images = match (&result.execution.tree, &result.remote_images) {
            (Some(tree), Some(scope)) => self.runtime.fetch_remote_images(tree, scope),
            _ => HashMap::new(),
        };
        let (tree, own_tree) = match result.execution.tree {
            Some(tree) => (tree, true),
            None => (self.runtime.error_tree(result.execution.error.as_ref()), false),
        };
        Kept {
            family: job.family.clone(),
            dark: job.dark,
            tick: if own_tree { schedule::tick_of(&tree) } else { None },
            tree,
            own_tree,
            files: Some(files),
            remote_images,
            next_transition: result.next_timeline_transition,
            error: result.execution.error.map(|error| error.kind),
            installed: true,
            name: installed.name.clone(),
            families: installed.families().iter().map(|family| (*family).to_owned()).collect(),
        }
    }

    /// Runs what a tap selected. Ported from `AppHost.Perform` of the Windows host.
    fn perform(&self, installed: &InstalledPackage, action: &Action, mut request: RunRequest) {
        // A manifest that is present but unreadable fails closed: nothing is stored and nothing runs.
        if installed.manifest_present && installed.manifest.is_none() {
            crate::log("action refused: the manifest cannot be read");
            return;
        }
        let mut environments = vec![("action-source".to_owned(), "widget".to_owned())];
        if let Some(value) = action.value {
            let text = if value { "true" } else { "false" };
            // The toggle's new state is saved first, then offered to the action as action-value.
            if let Some(key) = action.state_key.as_deref().filter(|key| surfaces::is_valid_state_key(key))
                && installed.permissions().iter().any(|permission| permission == "storage")
            {
                self.runtime.storage().set_string(&installed.installation, key, text);
            }
            environments.push(("action-value".to_owned(), text.to_owned()));
            environments.push(("control-value".to_owned(), text.to_owned()));
        }
        if let Some(id) = action.action_id.as_deref().filter(|id| !id.is_empty()) {
            // Only an action the manifest declares can be selected by a tap.
            let declared = match surfaces::parse(installed.manifest.as_ref()) {
                Ok(surfaces) => surfaces.action(id).cloned(),
                Err(error) => {
                    crate::log(&format!("action refused: {}", error.0));
                    return;
                }
            };
            let Some(declared) = declared else {
                crate::log("action refused: not declared in the manifest");
                return;
            };
            environments.push(("action-id".to_owned(), declared.id.clone()));
            request.action_id = Some(declared.id);
        } else if let Some(function) = action.handler.as_deref().filter(|function| surfaces::is_valid_function(function)) {
            request.call_function = Some(function.to_owned());
        } else {
            return;
        }
        request.extra_environments = environments;
        let result = self.runtime.run(&request);
        crate::log(&format!("action of {}: {}", installed.installation, result.execution.error.map_or("ok".to_owned(), |error| error.kind)));
    }

    /// One frame of `kept`: the package's tree, or a card that says why it could not be drawn.
    fn draw(&self, kept: &Kept, scale: f32, gif_time: Option<u64>) -> Result<RenderOutput, RenderError> {
        let (width, height) = sw_render::family_size(&kept.family).unwrap_or((329.0, 170.0));
        let request = |tree: String| RenderRequest { family: kept.family.clone(), dark_mode: kept.dark, gif_time_milliseconds: gif_time, ..RenderRequest::new(tree, width, height, scale) };
        let drawn = self.renderer.render(RenderRequest { files: kept.files.clone(), remote_images: kept.remote_images.clone(), ..request(kept.tree.clone()) });
        let mut output = match drawn {
            Ok(output) => output,
            Err(error) if kept.own_tree => {
                let message = if error.message.is_empty() { "Rendering failed".to_owned() } else { error.message };
                self.renderer.render(request(self.runtime.error_tree(Some(&ExecutionError { kind: "internalError".into(), message }))))?
            }
            Err(error) => return Err(error),
        };
        rounded_corners::apply(&mut output.pixels, output.pixel_width as usize, output.pixel_height as usize, rounded_corners::DEFAULT_RADIUS * output.scale);
        Ok(output)
    }

    /// Draws every frame and writes the PNG files, unless the result is the picture already on screen.
    fn picture(&self, job: &Job, kept: &Kept) -> Result<Option<Picture>, RenderError> {
        let first = self.draw(kept, job.scale, None)?;
        let (width, height) = sw_render::family_size(&kept.family).unwrap_or((329.0, 170.0));
        let mut digest = Sha256::new();
        digest.update(first.pixel_width.to_le_bytes());
        digest.update(first.pixel_height.to_le_bytes());
        digest.update(job.scale.to_le_bytes());
        for region in &first.hit_regions {
            for edge in [region.bounds.left, region.bounds.top, region.bounds.right, region.bounds.bottom] {
                digest.update(edge.to_le_bytes());
            }
            digest.update(Value::Object(region.interaction.clone()).to_string().as_bytes());
            digest.update([0u8]);
        }

        // The moments at which one of the GIFs changes; empty when nothing moves.
        let mut sources: Vec<&str> = Vec::new();
        let mut delays: Vec<Vec<u32>> = Vec::new();
        for slot in &first.gif_slots {
            if !sources.contains(&slot.source.as_str()) {
                sources.push(&slot.source);
                delays.push(slot.delays.clone());
            }
        }
        let mut moments = schedule::gif_frames(&delays, MAXIMUM_GIF_FRAMES);
        if moments.len() as u64 * u64::from(first.pixel_width) * u64::from(first.pixel_height) > MAXIMUM_CYCLE_PIXELS {
            moments.clear();
        }

        let fail = |error: std::io::Error| RenderError { message: format!("the picture could not be written: {error}") };
        if moments.len() < 2 {
            digest.update(&first.pixels);
            let hash: [u8; 32] = digest.finalize().into();
            if job.current == Some(hash) {
                return Ok(None);
            }
            let file = self.frames.temporary(job.token, 0);
            self.frames.write(&file, &first.encode_png()?).map_err(fail)?;
            return Ok(Some(Picture { hash, width: width as u32, height: height as u32, scale: first.scale, frames: vec![(file, 0)], regions: first.hit_regions }));
        }

        // Each frame is hashed, encoded and written before the next one is drawn, so only one bitmap is held at a time.
        let _cache = FrameCacheScope::new();
        let mut files: Vec<(PathBuf, u32)> = Vec::new();
        let written = (|| {
            for (index, (start, duration)) in moments.iter().enumerate() {
                let output = if index == 0 { None } else { Some(self.draw(kept, job.scale, Some(*start))?) };
                let output = output.as_ref().unwrap_or(&first);
                digest.update(&output.pixels);
                digest.update(duration.to_le_bytes());
                let file = self.frames.temporary(job.token, index);
                self.frames.write(&file, &output.encode_png()?).map_err(fail)?;
                files.push((file, *duration));
            }
            Ok(())
        })();
        let discard = |files: &[(PathBuf, u32)]| self.frames.remove(&files.iter().map(|(file, _)| file.clone()).collect::<Vec<_>>());
        if let Err(error) = written {
            discard(&files);
            return Err(error);
        }
        let hash: [u8; 32] = digest.finalize().into();
        if job.current == Some(hash) {
            discard(&files);
            return Ok(None);
        }
        Ok(Some(Picture { hash, width: width as u32, height: height as u32, scale: first.scale, frames: files, regions: first.hit_regions }))
    }
}

/// The text member `name` of a region's interaction, when it is a non-empty string.
pub fn interaction_text(interaction: &Map<String, Value>, name: &str) -> Option<String> {
    interaction.get(name).and_then(Value::as_str).filter(|text| !text.is_empty()).map(str::to_owned)
}
