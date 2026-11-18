//! The ScriptWidget painter for Linux: turns the element tree a package
//! produces into a bitmap with per-pixel transparency plus the list of tap
//! regions, on a CPU surface, with no graphical session.
//!
//! Ported from `Windows/src/ScriptWidget.Core/Render` (itself a port of
//! `Android/core/.../render`). The shared web renderer (`render.js`) lays the
//! tree out in a QuickJS context of its own and asks this crate to measure
//! text; the laid-out result is painted with Skia. Text is measured and
//! drawn by the same Skia paragraph code, so wrapping and truncation agree.
//!
//! What a tree may reference is untrusted: images and GIFs come from
//! packages and the network, and their sizes are bounded before decoding.

mod css;
mod dom;
mod fonts;
pub mod gif;
mod images;
mod painter;
#[cfg(test)]
mod painter_tests;
mod renderer;
pub mod rounded_corners;
mod svg;
mod text;

use serde_json::{Map, Value};

pub use fonts::{CjkRegion, cjk_region_order};
pub use images::{MAXIMUM_IMAGE_BYTES, MAXIMUM_IMAGE_PIXELS};
pub use renderer::{FontReport, RenderError, RenderOutput, RenderRequest, WidgetRenderer, encode_png};

/// The widget sizes in points; a display multiplies them by its scale.
/// The same as on Mac and Windows; there are no lock screen sizes.
pub const FAMILY_SIZES: [(&str, f32, f32); 4] = [("small", 170.0, 170.0), ("medium", 329.0, 170.0), ("large", 329.0, 345.0), ("extraLarge", 639.0, 345.0)];

/// Width and height in points of a widget family, or `None` for an unknown name.
pub fn family_size(family: &str) -> Option<(f32, f32)> {
    FAMILY_SIZES.iter().find(|(name, _, _)| *name == family).map(|(_, width, height)| (*width, *height))
}

/// A rectangle in points from the widget's top-left corner.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Bounds {
    pub left: f32,
    pub top: f32,
    pub right: f32,
    pub bottom: f32,
}

impl Bounds {
    pub fn width(&self) -> f32 {
        self.right - self.left
    }

    pub fn height(&self) -> f32 {
        self.bottom - self.top
    }

    /// The part shared with `other`, or `None` when the two do not overlap.
    pub fn intersect(&self, other: &Bounds) -> Option<Bounds> {
        if !(self.left < other.right && other.left < self.right && self.top < other.bottom && other.top < self.bottom) {
            return None;
        }
        Some(Bounds { left: self.left.max(other.left), top: self.top.max(other.top), right: self.right.min(other.right), bottom: self.bottom.min(other.bottom) })
    }
}

/// A tappable area of the widget: a button, a toggle or a link.
/// `interaction` is what the shared renderer recorded for it: `type` is
/// "button" (with `action`, `actionID`, `handler`), "toggle" (with `on`,
/// `actionID`, `stateKey`, `handler`) or "link" (with `url`). The host decides
/// what a tap does, and validates the values: they come from the package.
#[derive(Debug, Clone, PartialEq)]
pub struct HitRegion {
    pub bounds: Bounds,
    pub interaction: Map<String, Value>,
}

/// An animated GIF in the bitmap. The bitmap shows the frame that
/// [`RenderRequest::gif_time_milliseconds`] selects; a display layer renders
/// the widget again at the times the delays give, or decodes the frames
/// itself with [`gif::decode`].
#[derive(Debug, Clone, PartialEq)]
pub struct GifSlot {
    pub bounds: Bounds,
    /// The `src` of the image: `res:<path>` for a package file.
    pub source: String,
    /// How long each frame is shown, in milliseconds.
    pub delays: Vec<u32>,
}
