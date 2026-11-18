//! The last step of showing a package: the result of
//! [`sw_core::WidgetRuntime::run`] as a bitmap. Together with that type this
//! is the port of `Windows/src/ScriptWidget.Core/WidgetRuntime.cs`; the
//! painting half lives here because this crate depends on `sw-core`, which
//! stays free of Skia.

use std::collections::HashMap;

use sw_core::executor::ExecutionError;
use sw_core::{RunRequest, RunResult, WidgetRuntime};

use crate::renderer::{RenderError, RenderOutput, RenderRequest, WidgetRenderer};
use crate::rounded_corners;

/// How to draw one run. Lengths are in points.
#[derive(Debug, Clone, PartialEq)]
pub struct Presentation {
    pub width: f32,
    pub height: f32,
    /// Pixels per point of the display the widget is on.
    pub scale: f32,
    /// The theme to draw in; `None` uses the one the package ran under.
    pub dark_mode: Option<bool>,
    /// Fixed clock for dates, in milliseconds since 1970; `None` uses the real clock.
    pub now_milliseconds: Option<i64>,
    pub maximum_bitmap_bytes: u64,
    /// Corner radius in points; 0 leaves the widget square.
    pub corner_radius: f32,
}

impl Presentation {
    /// A widget family at its size in points (see [`crate::family_size`]), or `None` for an unknown family.
    pub fn for_family(family: &str, scale: f32) -> Option<Self> {
        let (width, height) = crate::family_size(family)?;
        Some(Self { width, height, scale, dark_mode: None, now_milliseconds: None, maximum_bitmap_bytes: u64::MAX, corner_radius: rounded_corners::DEFAULT_RADIUS })
    }
}

/// The picture of one run.
#[derive(Debug, Clone)]
pub struct RenderedRun {
    pub output: RenderOutput,
    /// Why the package's own tree could not be drawn; the picture then shows a card with this message.
    pub failure: Option<RenderError>,
}

/// Renders the result of a run. An execution error becomes a visible card,
/// and so does a failure to draw the package's own tree, so a widget is never
/// blank; only a failure to draw that card is returned as an error. Remote
/// images are fetched first, under the same network policy as `fetch`.
pub fn render_run(renderer: &WidgetRenderer, runtime: &WidgetRuntime, request: &RunRequest, result: &RunResult, presentation: &Presentation) -> Result<RenderedRun, RenderError> {
    let dark_mode = presentation.dark_mode.unwrap_or(request.dark_mode);
    let base = |tree: String| RenderRequest {
        family: request.family.clone(),
        dark_mode,
        now_milliseconds: presentation.now_milliseconds,
        maximum_bitmap_bytes: presentation.maximum_bitmap_bytes,
        ..RenderRequest::new(tree, presentation.width, presentation.height, presentation.scale)
    };
    let drawn = match &result.execution.tree {
        Some(tree) => {
            let remote_images = result.remote_images.as_ref().map(|scope| runtime.fetch_remote_images(tree, scope)).unwrap_or_default();
            renderer.render(RenderRequest { files: Some(request.files.clone()), remote_images, ..base(tree.clone()) })
        }
        None => renderer.render(RenderRequest { remote_images: HashMap::new(), ..base(runtime.error_tree(result.execution.error.as_ref())) }),
    };
    let (mut output, failure) = match drawn {
        Ok(output) => (output, None),
        Err(error) if result.execution.tree.is_some() => {
            let message = if error.message.is_empty() { "Rendering failed".to_owned() } else { error.message.clone() };
            (renderer.render(base(runtime.error_tree(Some(&ExecutionError { kind: "internalError".into(), message }))))?, Some(error))
        }
        Err(error) => return Err(error),
    };
    round(&mut output, presentation.corner_radius);
    Ok(RenderedRun { output, failure })
}

/// Renders a canonical tree that is not the output of a package, such as a message card.
pub fn render_tree(renderer: &WidgetRenderer, tree: &str, family: &str, presentation: &Presentation) -> Result<RenderOutput, RenderError> {
    let mut output = renderer.render(RenderRequest {
        family: family.to_owned(),
        dark_mode: presentation.dark_mode.unwrap_or(false),
        now_milliseconds: presentation.now_milliseconds,
        maximum_bitmap_bytes: presentation.maximum_bitmap_bytes,
        ..RenderRequest::new(tree, presentation.width, presentation.height, presentation.scale)
    })?;
    round(&mut output, presentation.corner_radius);
    Ok(output)
}

fn round(output: &mut RenderOutput, corner_radius: f32) {
    rounded_corners::apply(&mut output.pixels, output.pixel_width as usize, output.pixel_height as usize, corner_radius * output.scale);
}
