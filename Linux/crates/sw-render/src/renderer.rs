//! Turns a canonical element tree into a bitmap. Layout runs in the shared
//! web renderer inside a long-lived QuickJS context of its own, which only
//! ever sees the tree as data, never package code; the recorded elements are
//! painted with [`DomPainter`] on a CPU surface. Layout, text measurement and
//! painting all happen on one thread with a large stack. Ported from
//! `Windows/src/ScriptWidget.Core/Render/WidgetRenderer.cs`.

use std::cell::RefCell;
use std::collections::HashMap;
use std::fmt;
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::Arc;
use std::sync::mpsc::{self, Sender};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use skia_safe::{AlphaType, Color, ColorType, EncodedImageFormat, ImageInfo, images, surfaces};
use sw_core::json::{Object, ObjectExt, stringify};
use sw_core::{PackageFiles, SharedScripts, intl};
use sw_quickjs::Engine;

use crate::dom::DomNode;
use crate::fonts::FontRegistry;
use crate::images::PackageImageSource;
use crate::painter::DomPainter;
use crate::text::{TextEngine, TextStyle};
use crate::{GifSlot, HitRegion};

/// What to draw and at what size. Lengths are in points.
#[derive(Clone)]
pub struct RenderRequest {
    /// The canonical element tree, as JSON text.
    pub tree: String,
    pub width: f32,
    pub height: f32,
    /// Pixels per point.
    pub scale: f32,
    /// "small", "medium", "large" or "extraLarge".
    pub family: String,
    pub dark_mode: bool,
    pub files: Option<Arc<dyn PackageFiles>>,
    /// Remote image URLs that were fetched under the package's network policy, with the paths of their files.
    pub remote_images: HashMap<String, PathBuf>,
    /// Fixed clock for deterministic output, in milliseconds since 1970; `None` uses the real clock.
    pub now_milliseconds: Option<i64>,
    /// Bitmap budget in bytes for this render; the output is scaled down to fit.
    pub maximum_bitmap_bytes: u64,
    /// The moment of every GIF's animation to show, in milliseconds from its start; `None` shows the first frame.
    pub gif_time_milliseconds: Option<u64>,
    /// System theme colors behind the `material.<role>` names; `None` leaves them unknown. Android only; Linux hosts leave it off.
    pub colors: Option<Value>,
}

impl RenderRequest {
    /// A request for `tree` at the size of a widget family (see [`crate::family_size`]), or `None` for an unknown family.
    pub fn for_family(tree: impl Into<String>, family: &str, scale: f32) -> Option<Self> {
        let (width, height) = crate::family_size(family)?;
        Some(Self { family: family.to_owned(), ..Self::new(tree, width, height, scale) })
    }

    pub fn new(tree: impl Into<String>, width: f32, height: f32, scale: f32) -> Self {
        Self {
            tree: tree.into(),
            width,
            height,
            scale,
            family: "medium".into(),
            dark_mode: false,
            files: None,
            remote_images: HashMap::new(),
            now_milliseconds: None,
            maximum_bitmap_bytes: u64::MAX,
            gif_time_milliseconds: None,
            colors: None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct RenderOutput {
    /// Premultiplied RGBA pixels, `pixel_width` x `pixel_height`, rows from the top, no padding.
    pub pixels: Vec<u8>,
    pub pixel_width: u32,
    pub pixel_height: u32,
    /// Pixels per point actually used (lower than requested when the budget forced a smaller bitmap).
    pub scale: f32,
    /// Tappable areas, in the order they were painted: a later one lies on top of an earlier one.
    pub hit_regions: Vec<HitRegion>,
    /// The animated GIFs in the bitmap, for a display layer that cycles their frames.
    pub gif_slots: Vec<GifSlot>,
    /// What the layout could not show as on iPhone, as the shared renderer reports it.
    pub diagnostics: Vec<Value>,
    pub layout_time: Duration,
    pub paint_time: Duration,
}

impl RenderOutput {
    /// The bitmap as PNG data, with straight alpha as PNG stores it.
    pub fn encode_png(&self) -> Result<Vec<u8>, RenderError> {
        encode_png(&self.pixels, self.pixel_width, self.pixel_height)
    }

    /// The pixels with straight (not premultiplied) alpha.
    pub fn straight_pixels(&self) -> Vec<u8> {
        let mut pixels = self.pixels.clone();
        for pixel in pixels.chunks_exact_mut(4) {
            let alpha = u32::from(pixel[3]);
            if alpha != 0 && alpha != 255 {
                for channel in &mut pixel[..3] {
                    *channel = ((u32::from(*channel) * 255 + alpha / 2) / alpha).min(255) as u8;
                }
            }
        }
        pixels
    }
}

/// Writes premultiplied RGBA pixels as a PNG.
pub fn encode_png(pixels: &[u8], width: u32, height: u32) -> Result<Vec<u8>, RenderError> {
    let mismatch = || RenderError::new("Pixel data does not match the size");
    if width == 0 || height == 0 || width > i32::MAX as u32 || height > i32::MAX as u32 {
        return Err(mismatch());
    }
    let info = ImageInfo::new((width as i32, height as i32), ColorType::RGBA8888, AlphaType::Premul, None);
    if pixels.len() != info.compute_byte_size(info.min_row_bytes()) {
        return Err(mismatch());
    }
    let image = images::raster_from_data(&info, skia_safe::Data::new_copy(pixels), info.min_row_bytes()).ok_or_else(mismatch)?;
    let data = image.encode(None, EncodedImageFormat::PNG, None).ok_or_else(|| RenderError::new("The bitmap could not be encoded as PNG"))?;
    Ok(data.as_bytes().to_vec())
}

/// A layout or paint failure.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RenderError {
    pub message: String,
}

impl RenderError {
    fn new(message: impl Into<String>) -> Self {
        Self { message: message.into() }
    }
}

impl fmt::Display for RenderError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for RenderError {}

/// Which fonts the renderer found; for diagnosis and tests.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FontReport {
    pub locale: String,
    /// True when the bundled Inter could be loaded.
    pub bundled: bool,
    /// The installed CJK families, in the order they are tried.
    pub cjk_families: Vec<String>,
    /// The system families behind the monospaced and the serif design; empty when the machine has none.
    pub monospace: String,
    pub serif: String,
}

enum Job {
    Render(Box<RenderRequest>, Sender<Result<RenderOutput, RenderError>>),
    Layout(Box<RenderRequest>, Sender<Result<String, RenderError>>),
    SetLocale(String),
    SetUseSystemFont(bool),
    Fonts(Sender<FontReport>),
    FamiliesUsed(String, TextStyle, Sender<Vec<String>>),
    Release,
}

/// The renderer. One instance owns one thread, on which the layout context,
/// the fonts and every canvas live; calls from any thread are queued to it.
pub struct WidgetRenderer {
    jobs: Option<Sender<Job>>,
    worker: Option<JoinHandle<()>>,
}

impl WidgetRenderer {
    /// A renderer whose CJK font order follows the locale of the process
    /// (see [`sw_core::intl::default_locale_tag`] and [`crate::cjk_region_order`]).
    pub fn new(scripts: Arc<SharedScripts>) -> std::io::Result<Self> {
        Self::with_locale(scripts, &intl::default_locale_tag())
    }

    pub fn with_locale(scripts: Arc<SharedScripts>, locale: &str) -> std::io::Result<Self> {
        let (jobs, queue) = mpsc::channel::<Job>();
        let locale = locale.to_owned();
        let worker = std::thread::Builder::new().name("scriptwidget-render".into()).stack_size(RENDER_THREAD_STACK).spawn(move || {
            let mut worker = Worker { scripts, shared: Rc::new(Shared { text: RefCell::new(TextEngine::new(FontRegistry::new(&locale))), images: RefCell::new(None) }), engine: None };
            for job in queue {
                match job {
                    Job::Render(request, reply) => {
                        let _ = reply.send(worker.render(&request));
                    }
                    Job::Layout(request, reply) => {
                        let _ = reply.send(worker.with_images(&request, |worker| worker.layout(&request)).map(|layout| stringify(&Value::Object(layout))));
                    }
                    Job::SetLocale(locale) => worker.shared.text.borrow_mut().fonts_mut().set_locale(&locale),
                    Job::SetUseSystemFont(value) => worker.shared.text.borrow_mut().fonts_mut().set_use_system_font(value),
                    Job::Fonts(reply) => {
                        let mut text = worker.shared.text.borrow_mut();
                        let (monospace, serif) = (text.primary_family("ui-monospace", 400), text.primary_family("ui-serif", 400));
                        let fonts = text.fonts();
                        let _ = reply.send(FontReport { locale: fonts.locale().to_owned(), bundled: fonts.has_bundled_font(), cjk_families: fonts.cjk_families().to_vec(), monospace, serif });
                    }
                    Job::FamiliesUsed(text, style, reply) => {
                        let _ = reply.send(worker.shared.text.borrow_mut().families_used(&text, &style));
                    }
                    Job::Release => worker.engine = None,
                }
            }
        })?;
        Ok(Self { jobs: Some(jobs), worker: Some(worker) })
    }

    fn send(&self, job: Job) -> Result<(), RenderError> {
        self.jobs.as_ref().and_then(|jobs| jobs.send(job).ok()).ok_or_else(stopped)
    }

    /// Lays out and paints one widget.
    pub fn render(&self, request: RenderRequest) -> Result<RenderOutput, RenderError> {
        let (reply, answer) = mpsc::channel();
        self.send(Job::Render(Box::new(request), reply))?;
        answer.recv().map_err(|_| stopped())?
    }

    /// The element tree the layout records for a request, as JSON text; for tests and diagnosis.
    pub fn layout(&self, request: RenderRequest) -> Result<String, RenderError> {
        let (reply, answer) = mpsc::channel();
        self.send(Job::Layout(Box::new(request), reply))?;
        answer.recv().map_err(|_| stopped())?
    }

    /// Changes the locale that orders the CJK fonts, for the renders that follow.
    pub fn set_locale(&self, locale: &str) {
        let _ = self.send(Job::SetLocale(locale.to_owned()));
    }

    /// When true, default-design text uses the machine's own sans-serif face instead of the bundled Inter.
    pub fn set_use_system_font(&self, value: bool) {
        let _ = self.send(Job::SetUseSystemFont(value));
    }

    pub fn fonts(&self) -> Result<FontReport, RenderError> {
        let (reply, answer) = mpsc::channel();
        self.send(Job::Fonts(reply))?;
        answer.recv().map_err(|_| stopped())
    }

    /// The font families `text` is drawn with in the default face at `weight`, in order of first use.
    pub fn families_used(&self, text: &str, weight: i32) -> Result<Vec<String>, RenderError> {
        let (reply, answer) = mpsc::channel();
        self.send(Job::FamiliesUsed(text.to_owned(), TextStyle { family: "sans-serif".into(), size: 17.0, weight, leading: 22.0 }, reply))?;
        answer.recv().map_err(|_| stopped())
    }

    /// Frees the layout context; the next render recreates it.
    pub fn release(&self) {
        let _ = self.send(Job::Release);
    }
}

impl Drop for WidgetRenderer {
    fn drop(&mut self) {
        // Closing the queue ends the worker, which releases the engine and the fonts on its own thread.
        self.jobs = None;
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

fn stopped() -> RenderError {
    RenderError::new("The render thread has stopped")
}

/// What the layout context's host calls reach.
struct Shared {
    text: RefCell<TextEngine>,
    /// The images of the render in progress.
    images: RefCell<Option<PackageImageSource>>,
}

struct Worker {
    scripts: Arc<SharedScripts>,
    shared: Rc<Shared>,
    engine: Option<Engine<'static>>,
}

fn number(value: f32) -> String {
    if value.is_finite() { value.to_string() } else { "0".into() }
}

fn style_of(json: &Object) -> TextStyle {
    let or = |name: &str, fallback: f64| Some(json.opt_f64(name)).filter(|value| !value.is_nan()).unwrap_or(fallback);
    TextStyle { family: json.opt_string("family"), size: or("size", 17.0) as f32, weight: json.opt_i32("weight", 400), leading: or("leading", 20.0) as f32 }
}

/// The synchronous bridge of the layout context: text measurement by the engine that draws, image sizes, and Intl.
fn host(shared: &Shared, operation: &str, payload: Option<&str>) -> Result<Option<String>, String> {
    match operation {
        "text.measure" => {
            let json = sw_core::json::parse_object(payload.unwrap_or(""))?;
            let width = if json.is_null("width") { None } else { Some(json.opt_f64("width") as f32).filter(|width| !width.is_nan()) };
            let lines = shared.text.borrow_mut().lines(&json.opt_string("text"), &style_of(&json), width);
            let widest = lines.iter().map(|line| line.width).fold(0f32, f32::max);
            Ok(Some(format!("{{\"width\":{},\"lines\":{}}}", number(widest), lines.len().max(1))))
        }
        "text.baseline" => Ok(Some(number(shared.text.borrow_mut().baseline(&style_of(&sw_core::json::parse_object(payload.unwrap_or(""))?))))),
        "image.size" => Ok(Some(match shared.images.borrow_mut().as_mut().and_then(|images| images.size(payload.unwrap_or(""))) {
            Some((width, height)) => format!("[{width},{height}]"),
            None => "null".into(),
        })),
        _ => intl::call(operation, payload),
    }
}

impl Worker {
    fn engine(&mut self) -> Result<&mut Engine<'static>, RenderError> {
        if self.engine.is_none() {
            let failed = |error: sw_quickjs::JsError| RenderError::new(format!("The layout context could not be created: {}", error.message));
            let shared = self.shared.clone();
            let mut engine = Engine::with_limits(move |operation, payload| host(&shared, operation, payload), LAYOUT_MEMORY, LAYOUT_JS_STACK).map_err(failed)?;
            // Keep the native entry point for the trusted render bundle before the host file removes it.
            engine.evaluate("globalThis.__swRenderNative = globalThis.__swNative;", "render-prelude.js").map_err(failed)?;
            for name in ["host.js", "render.js"] {
                let text = self.scripts.text(name).map_err(|error| RenderError::new(format!("ScriptWidget runtime asset could not be read: {error}")))?;
                engine.evaluate(&text, name).map_err(failed)?;
            }
            engine.evaluate(RENDER_DRIVER, "render-driver.js").map_err(failed)?;
            self.engine = Some(engine);
        }
        Ok(self.engine.as_mut().expect("created above"))
    }

    /// Runs `work` with the images of `request` available to the layout and the painter.
    fn with_images<T>(&mut self, request: &RenderRequest, work: impl FnOnce(&mut Self) -> Result<T, RenderError>) -> Result<T, RenderError> {
        *self.shared.images.borrow_mut() = Some(PackageImageSource::new(request.files.clone(), request.remote_images.clone(), request.gif_time_milliseconds));
        let result = work(self);
        *self.shared.images.borrow_mut() = None;
        result
    }

    /// Runs the shared layout; the images must be set.
    fn layout(&mut self, request: &RenderRequest) -> Result<Object, RenderError> {
        let mut resources = Object::new();
        if let Some(files) = &request.files {
            for path in files.paths() {
                if is_image_file(&path) {
                    resources.insert(path.clone(), Value::String(format!("res:{path}")));
                }
            }
        }
        let mut job = json!({
            "tree": request.tree, "width": f64::from(request.width), "height": f64::from(request.height),
            "family": request.family, "dark": request.dark_mode, "resources": resources,
            "images": request.remote_images.keys().collect::<Vec<_>>(),
        });
        if let Some(now) = request.now_milliseconds {
            job["now"] = json!(now);
        }
        if let Some(colors) = &request.colors {
            job["colors"] = colors.clone();
        }
        let job = stringify(&job);

        let result = self.engine().and_then(|engine| {
            engine.set_deadline(LAYOUT_TIMEOUT_MILLISECONDS);
            let outcome = run_layout(engine, &job);
            engine.set_deadline(0);
            outcome
        });
        if result.is_err() {
            // A failed or interrupted context may hold partial state; start fresh next time.
            self.engine = None;
        }
        result
    }

    fn render(&mut self, request: &RenderRequest) -> Result<RenderOutput, RenderError> {
        if !(request.width > 0.0 && request.height > 0.0 && request.scale > 0.0) || !request.width.is_finite() || !request.height.is_finite() || !request.scale.is_finite() {
            return Err(RenderError::new("The size and the scale of a render must be positive numbers"));
        }
        self.with_images(request, |worker| {
            let layout_start = Instant::now();
            let rendered = worker.layout(request)?;
            let layout_time = layout_start.elapsed();

            let paint_start = Instant::now();
            let mut scale = request.scale;
            let bytes_at_requested_scale = (f64::from(request.width * scale).ceil() * f64::from(request.height * scale).ceil() * 4.0).max(1.0);
            if bytes_at_requested_scale > request.maximum_bitmap_bytes as f64 {
                scale *= (request.maximum_bitmap_bytes as f64 / bytes_at_requested_scale).sqrt() as f32;
            }
            let pixel_width = ((request.width * scale).ceil() as i32).clamp(1, MAXIMUM_BITMAP_SIDE);
            let pixel_height = ((request.height * scale).ceil() as i32).clamp(1, MAXIMUM_BITMAP_SIDE);
            let root = DomNode::from_json(rendered.opt_object("root").ok_or_else(|| RenderError::new("Layout returned no element tree"))?).map_err(RenderError::new)?;

            let info = ImageInfo::new((pixel_width, pixel_height), ColorType::RGBA8888, AlphaType::Premul, None);
            let mut surface = surfaces::raster(&info, None, None).ok_or_else(|| RenderError::new("The bitmap could not be allocated"))?;
            surface.canvas().clear(Color::TRANSPARENT);
            let (hit_regions, gif_slots) = {
                let mut text = worker.shared.text.borrow_mut();
                let mut images = worker.shared.images.borrow_mut();
                let mut painter = DomPainter::new(&mut text, images.as_mut().expect("set by with_images"));
                painter.paint(surface.canvas(), &root, scale);
                (painter.hit_regions, painter.gif_slots)
            };
            let pixels = surface.peek_pixels().and_then(|pixmap| pixmap.bytes().map(<[u8]>::to_vec)).ok_or_else(|| RenderError::new("The bitmap could not be read"))?;
            Ok(RenderOutput {
                pixels,
                pixel_width: pixel_width as u32,
                pixel_height: pixel_height as u32,
                scale,
                hit_regions,
                gif_slots,
                diagnostics: rendered.opt_array("diagnostics").cloned().unwrap_or_default(),
                layout_time,
                paint_time: paint_start.elapsed(),
            })
        })
    }
}

fn run_layout(engine: &mut Engine<'static>, job: &str) -> Result<Object, RenderError> {
    let failed = |error: sw_quickjs::JsError| RenderError::new(if error.interrupted { "Layout took too long".to_owned() } else { format!("Layout failed: {}", error.message) });
    engine.call("__swRenderStart", &[Some(job)]).map_err(failed)?;
    while engine.run_jobs(JOB_BATCH).map_err(failed)? > 0 {}
    if let Some(failure) = engine.call("__swRenderTake", &[Some("__swRenderError")]).map_err(failed)? {
        return Err(RenderError::new(format!("Layout failed: {failure}")));
    }
    let text = engine.call("__swRenderTake", &[Some("__swRenderResult")]).map_err(failed)?.ok_or_else(|| RenderError::new("Layout did not finish"))?;
    // The recorded tree nests an object and an array for every element: deeper than serde_json reads by default.
    let mut deserializer = serde_json::Deserializer::from_str(&text);
    deserializer.disable_recursion_limit();
    match serde::de::Deserialize::deserialize(&mut deserializer) {
        Ok(Value::Object(object)) => Ok(object),
        Ok(_) => Err(RenderError::new("Layout returned something that is not an object")),
        Err(error) => Err(RenderError::new(format!("Layout returned invalid JSON: {error}"))),
    }
}

/// The package files handed to the layout as images.
fn is_image_file(path: &str) -> bool {
    let lower = path.to_ascii_lowercase();
    [".png", ".jpg", ".jpeg", ".webp", ".gif", ".heic", ".bmp"].iter().any(|extension| lower.ends_with(extension))
}

const RENDER_DRIVER: &str = "globalThis.__swRenderStart = function (request) { globalThis.__swRenderResult = null; globalThis.__swRenderError = null;\
 __swRenderBundle.render(globalThis.__swRenderNative, request).then(function (value) { globalThis.__swRenderResult = value; },\
 function (error) { globalThis.__swRenderError = (error && error.stack ? String(error.message || error) + '\\n' + error.stack : String(error)); }); };\
 globalThis.__swRenderTake = function (name) { var value = globalThis[name]; globalThis[name] = null; return value; };";

/// The layout context is larger than an execution context: it holds the whole web renderer.
const LAYOUT_MEMORY: usize = 96 * 1024 * 1024;
const LAYOUT_JS_STACK: usize = 6 * 1024 * 1024;
/// Room for the JavaScript stack and, on top of it, text shaping called from the deepest layout frame.
const RENDER_THREAD_STACK: usize = 16 * 1024 * 1024;
const LAYOUT_TIMEOUT_MILLISECONDS: u64 = 8000;
const JOB_BATCH: usize = 100_000;
/// A side longer than this is not allocated, whatever the request says.
const MAXIMUM_BITMAP_SIDE: i32 = 16384;
