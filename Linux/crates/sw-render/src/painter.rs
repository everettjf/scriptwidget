//! Paints a recorded element tree on a canvas. It implements exactly the
//! HTML/CSS and SVG subset that `Web/preview-engine/src/render/renderer.js`
//! writes: absolutely positioned boxes, text, images and inline SVG. Ported
//! from `Windows/src/ScriptWidget.Core/Render/DomPainter.cs`, with the
//! drawing calls of the Android original, which already painted on Skia.

use skia_safe::canvas::SaveLayerRec;
use skia_safe::paint::Style;
use skia_safe::{BlurStyle, Canvas, Color, Color4f, MaskFilter, Matrix, Paint, Path, PathEffect, RRect, Rect, image_filters};

use sw_core::json::parse_object;

use crate::css::{self, BoxShadow, Shadow};
use crate::dom::DomNode;
use crate::gif::GifTimeline;
use crate::images::{PackageImageSource, sampling};
use crate::svg::SvgPainter;
use crate::text::{TextEngine, TextStyle};
use crate::{Bounds, GifSlot, HitRegion};

#[derive(Clone)]
struct TextContext {
    family: String,
    size: f32,
    weight: i32,
    line_height: Option<f32>,
    align: String,
    wrap: bool,
    color: Color,
}

impl TextContext {
    fn style(&self) -> TextStyle {
        TextStyle { family: self.family.clone(), size: self.size, weight: self.weight, leading: self.line_height.unwrap_or(self.size * 1.2) }
    }
}

fn opacity(node: &DomNode) -> f32 {
    css::number(node.style("opacity")).map_or(1.0, |value| value.clamp(0.0, 1.0))
}

fn bounds_of(rect: Rect) -> Bounds {
    Bounds { left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom }
}

/// The standard deviation of Android's BlurMaskFilter for a radius, so
/// shadows are as soft as in the Android bitmap.
fn blur_sigma(radius: f32) -> f32 {
    if radius > 0.0 { 0.57735 * radius + 0.5 } else { 0.0 }
}

/// Pixels per unit of the canvas transform, at least 1.
fn device_scale(canvas: &Canvas) -> f32 {
    let matrix = canvas.local_to_device_as_3x3();
    matrix.scale_x().hypot(matrix.skew_y()).max(matrix.skew_x().hypot(matrix.scale_y())).max(1.0)
}

pub struct DomPainter<'a> {
    text: &'a mut TextEngine,
    images: &'a mut PackageImageSource,
    pub hit_regions: Vec<HitRegion>,
    pub gif_slots: Vec<GifSlot>,
}

impl<'a> DomPainter<'a> {
    pub fn new(text: &'a mut TextEngine, images: &'a mut PackageImageSource) -> Self {
        Self { text, images, hit_regions: Vec::new(), gif_slots: Vec::new() }
    }

    /// Paints `root` (the widget element). `scale` converts points to pixels.
    pub fn paint(&mut self, canvas: &Canvas, root: &DomNode, scale: f32) {
        self.hit_regions.clear();
        self.gif_slots.clear();
        canvas.save();
        canvas.scale((scale, scale));
        let width = css::pixels(root.style("width")).unwrap_or(0.0);
        let height = css::pixels(root.style("height")).unwrap_or(0.0);
        let context = TextContext { family: "sans-serif".into(), size: 17.0, weight: 400, line_height: None, align: "left".into(), wrap: true, color: Color::BLACK };
        self.element(canvas, root, width, height, &context, &Matrix::new_identity());
        canvas.restore();
    }

    fn element(&mut self, canvas: &Canvas, node: &DomNode, parent_width: f32, parent_height: f32, inherited: &TextContext, to_widget: &Matrix) {
        if node.tag == "style" || node.tag.is_empty() {
            return;
        }
        if node.svg {
            let left = css::pixels(node.style("left")).unwrap_or(0.0);
            let top = css::pixels(node.style("top")).unwrap_or(0.0);
            canvas.save();
            canvas.translate((left, top));
            SvgPainter::paint(self.text, canvas, node, node.style("color").and_then(|color| css::color(Some(color))).unwrap_or(inherited.color));
            canvas.restore();
            return;
        }

        let absolute = node.style("position") == Some("absolute");
        let x = if absolute { css::length(node.style("left"), parent_width).unwrap_or(0.0) } else { 0.0 };
        let y = if absolute { css::length(node.style("top"), parent_height).unwrap_or(0.0) } else { 0.0 } + css::pixels(node.style("marginTop")).unwrap_or(0.0);
        let width = css::length(node.style("width"), parent_width).unwrap_or(parent_width);
        let height = css::length(node.style("height"), parent_height).unwrap_or(parent_height);
        let bounds = Rect::from_wh(width, height);

        let mut local = *to_widget;
        local.pre_translate((x, y));
        canvas.save();
        canvas.translate((x, y));
        if let Some(matrix) = transform(node, width, height) {
            // Skia draws through a matrix with perspective directly; no offscreen pass is needed.
            canvas.concat(&matrix);
            local.pre_concat(&matrix);
        }

        let shadow = css::drop_shadow(node.style("filter"));
        let opacity = opacity(node);
        if shadow.is_some() || opacity < 1.0 {
            // What is drawn until the layer is restored is blended as one group; a
            // drop shadow is cast by the silhouette of the whole group.
            let mut paint = Paint::default();
            paint.set_alpha_f(opacity);
            if let Some(Shadow { dx, dy, blur, color }) = shadow {
                let scale = device_scale(canvas);
                // The filter takes its lengths in the element's own units.
                let sigma = if blur > 0.0 { blur_sigma(blur * scale).clamp(0.1, 250.0) / scale } else { 0.0 };
                paint.set_image_filter(image_filters::drop_shadow((dx, dy), (sigma, sigma), Color4f::from(color), None, None, None));
            }
            canvas.save_layer(&SaveLayerRec::default().paint(&paint));
            self.content(canvas, node, bounds, inherited, &local);
            canvas.restore();
        } else {
            self.content(canvas, node, bounds, inherited, &local);
        }
        canvas.restore();
    }

    fn content(&mut self, canvas: &Canvas, node: &DomNode, bounds: Rect, inherited: &TextContext, to_widget: &Matrix) {
        let (width, height) = (bounds.width(), bounds.height());
        let radius = radius(node.style("borderRadius"), width, height);
        let outline = outline(node, bounds, radius);

        // An outer shadow lies under the box; an inset one is drawn over its background.
        let box_shadow = css::box_shadow(node.style("boxShadow"));
        if let Some(shadow) = box_shadow.filter(|shadow| !shadow.inset) {
            paint_box_shadow(canvas, shadow, bounds, radius);
        }
        background(canvas, node, bounds, &outline);
        if let Some(shadow) = box_shadow.filter(|shadow| shadow.inset) {
            paint_box_shadow(canvas, shadow, bounds, radius);
        }
        if let Some((_, color)) = node.style("border").and_then(|border| border.split_once("dashed")) {
            let mut stroke = Paint::default();
            stroke.set_anti_alias(true).set_style(Style::Stroke).set_stroke_width(1.0).set_color(css::color(Some(color)).unwrap_or(css::GRAY));
            if let Some(effect) = PathEffect::dash(&[3.0, 3.0], 0.0) {
                stroke.set_path_effect(effect);
            }
            canvas.draw_rect(Rect::from_ltrb(0.5, 0.5, (width - 0.5).max(0.5), (height - 0.5).max(0.5)), &stroke);
        }

        if let Some(interaction) = node.data("swInteraction").and_then(|text| parse_object(text).ok()) {
            self.hit_regions.push(HitRegion { bounds: bounds_of(to_widget.map_rect(bounds).0), interaction });
        }

        let clips = node.style("overflow") == Some("hidden") || node.style("clipPath").is_some();
        if clips {
            canvas.save();
            canvas.clip_path(&outline, None, true);
        }

        let context = text_context(node, inherited);
        if node.tag == "img" {
            self.image(canvas, node, bounds, to_widget);
        } else if let Some(text) = node.text.as_deref().filter(|_| node.children.is_empty()) {
            self.draw_text(canvas, text, node, bounds, &context);
        }
        if node.data("swList").is_none() {
            for child in &node.children {
                self.element(canvas, child, width, height, &context, to_widget);
            }
        } else {
            // A list is drawn in place: the rows that fit are visible, the rest are cut off, and so are their tap targets.
            let first_hit = self.hit_regions.len();
            let visible = to_widget.map_rect(bounds).0;
            canvas.save();
            canvas.clip_rect(bounds, None, true);
            for child in &node.children {
                self.element(canvas, child, width, height, &context, to_widget);
            }
            canvas.restore();
            let inside: Vec<HitRegion> = self.hit_regions.drain(first_hit..).filter_map(|hit| Some(HitRegion { bounds: hit.bounds.intersect(&bounds_of(visible))?, interaction: hit.interaction })).collect();
            self.hit_regions.extend(inside);
        }
        if clips {
            canvas.restore();
        }
    }

    fn draw_text(&mut self, canvas: &Canvas, content: &str, node: &DomNode, bounds: Rect, context: &TextContext) {
        if content.is_empty() {
            return;
        }
        let style = context.style();
        let clipped_to_text = node.style("backgroundClip") == Some("text") || node.style("webkitBackgroundClip") == Some("text");
        let gradient = if clipped_to_text { css::gradient(node.style("backgroundImage"), bounds.width(), bounds.height(), (0.0, 0.0)) } else { None };
        if gradient.is_none() && context.color.a() == 0 {
            return;
        }
        let mut paint = Paint::default();
        paint.set_anti_alias(true);
        match gradient {
            Some(shader) => paint.set_color(Color::BLACK).set_shader(shader),
            None => paint.set_color(context.color),
        };
        let lines = self.text.lines(content, &style, context.wrap.then_some(bounds.width()));
        let baseline = self.text.baseline(&style);
        for (index, line) in lines.iter().enumerate() {
            let x = match context.align.as_str() {
                "center" => (bounds.width() - line.width) / 2.0,
                "right" => bounds.width() - line.width,
                _ => 0.0,
            };
            self.text.draw(canvas, &line.text, &style, x, baseline + index as f32 * style.leading, &paint);
        }
    }

    fn image(&mut self, canvas: &Canvas, node: &DomNode, bounds: Rect, to_widget: &Matrix) {
        let Some(source) = node.attribute("src") else { return };
        let scale = Some(canvas.local_to_device_as_3x3().scale_x()).filter(|scale| *scale > 0.0).unwrap_or(1.0);
        let pixels = (f64::from(bounds.width()) * f64::from(scale) * f64::from(bounds.height()) * f64::from(scale)).clamp(1.0, i32::MAX as f64) as i64;
        let Some(image) = self.images.image(source, pixels) else { return };
        if let Some(GifTimeline { delays, .. }) = self.images.animation(source) {
            // The display layer cycles the frames; this bitmap shows the one the request asked for.
            self.gif_slots.push(GifSlot { bounds: bounds_of(to_widget.map_rect(bounds).0), source: source.to_owned(), delays });
        }
        let mut destination = bounds;
        let fit = node.style("objectFit").unwrap_or("fill");
        if fit == "contain" || fit == "cover" {
            let ratio = image.width() as f32 / image.height().max(1) as f32;
            let box_ratio = bounds.width() / bounds.height().max(0.0001);
            let fit_width = if (fit == "contain") == (ratio > box_ratio) { bounds.width() } else { bounds.height() * ratio };
            let fit_height = fit_width / ratio;
            destination = Rect::from_ltrb((bounds.width() - fit_width) / 2.0, (bounds.height() - fit_height) / 2.0, (bounds.width() + fit_width) / 2.0, (bounds.height() + fit_height) / 2.0);
        }
        let mut paint = Paint::default();
        paint.set_anti_alias(true);
        canvas.save();
        canvas.clip_rect(bounds, None, true);
        canvas.draw_image_rect_with_sampling_options(&image, None, destination, sampling(), &paint);
        canvas.restore();
    }
}

fn text_context(node: &DomNode, inherited: &TextContext) -> TextContext {
    if !["fontFamily", "fontSize", "fontWeight", "lineHeight", "textAlign", "whiteSpace", "color"].iter().any(|name| node.style.contains_key(*name)) {
        return inherited.clone();
    }
    TextContext {
        family: node.style("fontFamily").map_or_else(|| inherited.family.clone(), str::to_owned),
        size: css::pixels(node.style("fontSize")).unwrap_or(inherited.size),
        weight: node.style("fontWeight").and_then(|weight| weight.trim().parse().ok()).unwrap_or(inherited.weight),
        line_height: css::pixels(node.style("lineHeight")).or(inherited.line_height),
        align: node.style("textAlign").map_or_else(|| inherited.align.clone(), str::to_owned),
        wrap: node.style("whiteSpace").map_or(inherited.wrap, |white_space| white_space != "pre"),
        color: node.style("color").and_then(|color| css::color(Some(color))).unwrap_or(inherited.color),
    }
}

fn background(canvas: &Canvas, node: &DomNode, bounds: Rect, outline: &Path) {
    let mut fill = Paint::default();
    fill.set_anti_alias(true);
    if let Some(color) = css::color(node.style("backgroundColor")).filter(|color| color.a() != 0) {
        fill.set_color(color);
        canvas.draw_path(outline, &fill);
    }
    let Some(image) = node.style("backgroundImage").filter(|image| *image != "none") else { return };
    if node.style("backgroundClip") == Some("text") || node.style("webkitBackgroundClip") == Some("text") {
        return;
    }
    // Shapes paint a gradient sized for the whole view behind a smaller outline.
    let lengths = |name: &str| node.style(name).map(|value| value.split(' ').filter_map(|part| css::pixels(Some(part))).collect::<Vec<f32>>()).unwrap_or_default();
    let size = lengths("backgroundSize");
    let position = lengths("backgroundPosition");
    let width = size.first().copied().unwrap_or(bounds.width());
    let height = size.get(1).copied().unwrap_or(bounds.height());
    let offset = if position.len() == 2 { (position[0], position[1]) } else { (0.0, 0.0) };
    if let Some(shader) = css::gradient(Some(image), width, height, offset) {
        fill.set_color(Color::BLACK).set_shader(shader);
        canvas.draw_path(outline, &fill);
    } else if let Some(solid) = css::color(Some(image)) {
        fill.set_color(solid);
        canvas.draw_path(outline, &fill);
    }
}

fn paint_box_shadow(canvas: &Canvas, shadow: BoxShadow, bounds: Rect, radius: f32) {
    let mut paint = Paint::default();
    paint.set_anti_alias(true).set_color(shadow.color);
    if shadow.inset {
        // `inset 0 0 0 <spread> color` is the renderer's one-point inner border.
        let width = if shadow.spread > 0.0 { shadow.spread } else { 1.0 };
        let inset = width / 2.0;
        let corner = (radius - inset).max(0.0);
        paint.set_style(Style::Stroke).set_stroke_width(width);
        let rect = Rect::from_ltrb(inset, inset, (bounds.width() - inset).max(inset), (bounds.height() - inset).max(inset));
        canvas.draw_rrect(RRect::new_rect_xy(rect, corner, corner), &paint);
        return;
    }
    // Outer shadow under an opaque shape: the blurred shape is drawn first.
    if shadow.blur > 0.0 {
        paint.set_mask_filter(MaskFilter::blur(BlurStyle::Normal, blur_sigma(shadow.blur / 2.0 + 0.1), true));
    }
    canvas.save();
    canvas.translate((shadow.dx, shadow.dy));
    canvas.draw_rrect(RRect::new_rect_xy(bounds, radius, radius), &paint);
    canvas.restore();
}

fn radius(value: Option<&str>, width: f32, height: f32) -> f32 {
    let Some(text) = value.map(str::trim) else { return 0.0 };
    match text.strip_suffix('%') {
        Some(percent) => width.min(height) * css::number(Some(percent)).unwrap_or(0.0) / 100.0,
        None => css::pixels(Some(text)).unwrap_or(0.0).min(width.min(height) / 2.0).max(0.0),
    }
}

fn outline(node: &DomNode, bounds: Rect, radius: f32) -> Path {
    let rect = Rect::from_ltrb(bounds.left, bounds.top, bounds.left + bounds.width().max(0.0), bounds.top + bounds.height().max(0.0));
    let clip = node.style("clipPath").unwrap_or("");
    if clip.starts_with("circle") {
        Path::circle((rect.center_x(), rect.center_y()), rect.width().min(rect.height()) / 2.0, None)
    } else if clip.starts_with("ellipse") {
        Path::oval(rect, None)
    } else if clip.starts_with("inset") {
        let round = rect.width().min(rect.height()) / 2.0;
        Path::rrect(RRect::new_rect_xy(rect, round, round), None)
    } else if node.style("borderRadius").is_some_and(|value| value.trim().ends_with('%')) {
        Path::oval(rect, None)
    } else if radius > 0.0 {
        Path::rrect(RRect::new_rect_xy(rect, radius, radius), None)
    } else {
        Path::rect(rect, None)
    }
}

/// CSS transform list with its transform-origin, as a matrix in element coordinates.
fn transform(node: &DomNode, width: f32, height: f32) -> Option<Matrix> {
    let value = node.style("transform")?;
    let mut origin = node.style("transformOrigin").unwrap_or("").split(' ');
    let origin_x = css::length(origin.next(), width).unwrap_or(width / 2.0);
    let origin_y = css::length(origin.next(), height).unwrap_or(height / 2.0);
    let degrees = |text: &str| css::number(Some(text.strip_suffix("deg").unwrap_or(text)));
    let mut matrix = Matrix::new_identity();
    let mut perspective = 0f32;
    for (name, arguments) in css::functions(value) {
        let arguments: Vec<&str> = arguments.split(',').map(str::trim).collect();
        let argument = |index: usize| arguments.get(index).copied();
        let step = match name {
            "rotate" => Matrix::rotate_deg(argument(0).and_then(degrees).unwrap_or(0.0)),
            "translateX" => Matrix::translate((css::pixels(argument(0)).unwrap_or(0.0), 0.0)),
            "translateY" => Matrix::translate((0.0, css::pixels(argument(0)).unwrap_or(0.0))),
            "translate" => Matrix::translate((css::pixels(argument(0)).unwrap_or(0.0), css::pixels(argument(1)).unwrap_or(0.0))),
            "scale" => {
                let sx = css::number(argument(0)).unwrap_or(1.0);
                Matrix::scale((sx, css::number(argument(1)).unwrap_or(sx)))
            }
            "perspective" => {
                perspective = css::pixels(argument(0)).unwrap_or(0.0);
                continue;
            }
            "rotate3d" => {
                if arguments.len() < 4 {
                    continue;
                }
                let axis_x = css::number(argument(0)).unwrap_or(0.0);
                let axis_y = css::number(argument(1)).unwrap_or(0.0);
                let axis_z = css::number(argument(2)).unwrap_or(0.0);
                let angle = argument(3).and_then(degrees).unwrap_or(0.0);
                let length = (axis_x * axis_x + axis_y * axis_y + axis_z * axis_z).sqrt();
                if length == 0.0 {
                    continue;
                }
                // The CSS rotate3d() matrix itself, applied to the element's plane (z = 0) and
                // followed by the perspective division w = 1 - z / distance, as on Windows.
                let (ux, uy, uz) = (axis_x / length, axis_y / length, axis_z / length);
                let half = angle.to_radians() / 2.0;
                let sc = half.sin() * half.cos();
                let sq = half.sin() * half.sin();
                let r00 = 1.0 - 2.0 * (uy * uy + uz * uz) * sq;
                let r01 = 2.0 * (ux * uy * sq - uz * sc);
                let r10 = 2.0 * (ux * uy * sq + uz * sc);
                let r11 = 1.0 - 2.0 * (ux * ux + uz * uz) * sq;
                let r20 = 2.0 * (ux * uz * sq - uy * sc);
                let r21 = 2.0 * (uy * uz * sq + ux * sc);
                let depth = if perspective > 0.0 { 1.0 / perspective } else { 0.0 };
                Matrix::new_all(r00, r01, 0.0, r10, r11, 0.0, -r20 * depth, -r21 * depth, 1.0)
            }
            _ => continue,
        };
        matrix.pre_concat(&step);
    }
    matrix.pre_translate((-origin_x, -origin_y));
    matrix.post_translate((origin_x, origin_y));
    Some(matrix)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn styled(style: &[(&str, &str)]) -> DomNode {
        DomNode { tag: "div".into(), style: style.iter().map(|(name, value)| ((*name).to_owned(), (*value).to_owned())).collect(), ..Default::default() }
    }

    fn close(point: skia_safe::Point, x: f32, y: f32) -> bool {
        (point.x - x).abs() < 0.01 && (point.y - y).abs() < 0.01
    }

    #[test]
    fn transforms_turn_about_their_origin() {
        // A quarter turn about the centre of a 100 x 40 box.
        let quarter = transform(&styled(&[("transform", "rotate(90deg)")]), 100.0, 40.0).expect("matrix");
        assert!(close(quarter.map_point((50.0, 20.0)), 50.0, 20.0));
        assert!(close(quarter.map_point((100.0, 20.0)), 50.0, 70.0), "{:?}", quarter.map_point((100.0, 20.0)));
        // About the top-left corner, then moved: the list applies right to left.
        let moved = transform(&styled(&[("transform", "translate(10px, 5px) scale(2)"), ("transformOrigin", "0px 0px")]), 100.0, 40.0).expect("matrix");
        assert!(close(moved.map_point((3.0, 4.0)), 16.0, 13.0));
        let percent = transform(&styled(&[("transform", "scale(2, 3)"), ("transformOrigin", "100% 50%")]), 100.0, 40.0).expect("matrix");
        assert!(close(percent.map_point((100.0, 20.0)), 100.0, 20.0));
        assert!(close(percent.map_point((90.0, 30.0)), 80.0, 50.0));
        assert!(transform(&styled(&[]), 1.0, 1.0).is_none());
    }

    #[test]
    fn a_turn_in_depth_narrows_the_far_side() {
        let node = styled(&[("transform", "perspective(200px) rotate3d(0, 1, 0, 60deg)")]);
        let matrix = transform(&node, 100.0, 100.0).expect("matrix");
        assert!(matrix.has_perspective());
        // The axis through the centre stays where it is.
        assert!(close(matrix.map_point((50.0, 50.0)), 50.0, 50.0));
        let (near, far) = (matrix.map_point((0.0, 0.0)), matrix.map_point((100.0, 0.0)));
        let (near_bottom, far_bottom) = (matrix.map_point((0.0, 100.0)), matrix.map_point((100.0, 100.0)));
        // Turned about the vertical axis, the box is narrower, and its two sides have different heights.
        assert!(far.x - near.x < 70.0, "{near:?} {far:?}");
        let (left_height, right_height) = (near_bottom.y - near.y, far_bottom.y - far.y);
        assert!((left_height - right_height).abs() > 10.0, "{left_height} {right_height}");
        // Without a perspective the same turn only squeezes the box.
        let flat = transform(&styled(&[("transform", "rotate3d(0, 1, 0, 60deg)")]), 100.0, 100.0).expect("matrix");
        assert!(!flat.has_perspective());
        assert!(close(flat.map_point((100.0, 0.0)), 75.0, 0.0), "{:?}", flat.map_point((100.0, 0.0)));
    }

    #[test]
    fn corner_radii_stay_inside_the_box() {
        assert_eq!(radius(Some("8px"), 100.0, 40.0), 8.0);
        assert_eq!(radius(Some("999px"), 100.0, 40.0), 20.0);
        assert_eq!(radius(Some("50%"), 100.0, 40.0), 20.0);
        assert_eq!(radius(Some("-4px"), 100.0, 40.0), 0.0);
        assert_eq!(radius(None, 100.0, 40.0), 0.0);
    }

    #[test]
    fn outlines_follow_the_clip_and_the_radius() {
        let bounds = Rect::from_wh(100.0, 40.0);
        let inside = |node: &DomNode, x: f32, y: f32| outline(node, bounds, radius(node.style("borderRadius"), 100.0, 40.0)).contains((x, y));
        let plain = styled(&[]);
        assert!(inside(&plain, 1.0, 1.0));
        let round = styled(&[("borderRadius", "20px")]);
        assert!(!inside(&round, 1.0, 1.0) && inside(&round, 50.0, 1.0) && inside(&round, 8.0, 8.0));
        let ellipse = styled(&[("borderRadius", "50%")]);
        assert!(!inside(&ellipse, 4.0, 4.0) && inside(&ellipse, 50.0, 20.0));
        let circle = styled(&[("clipPath", "circle(50%)")]);
        assert!(!inside(&circle, 10.0, 20.0) && inside(&circle, 50.0, 20.0) && inside(&circle, 32.0, 20.0));
        let capsule = styled(&[("clipPath", "inset(0 round 999px)")]);
        assert!(!inside(&capsule, 2.0, 2.0) && inside(&capsule, 2.0, 20.0));
    }

    #[test]
    fn text_properties_are_inherited() {
        let root = TextContext { family: "a".into(), size: 17.0, weight: 400, line_height: None, align: "left".into(), wrap: true, color: Color::BLACK };
        let same = text_context(&styled(&[("left", "0px")]), &root);
        assert_eq!((same.family.as_str(), same.size, same.weight), ("a", 17.0, 400));
        let child = text_context(&styled(&[("fontSize", "12px"), ("fontWeight", "700"), ("color", "rgba(255, 0, 0, 1)"), ("whiteSpace", "pre"), ("lineHeight", "16px")]), &root);
        assert_eq!((child.size, child.weight, child.wrap, child.color), (12.0, 700, false, Color::from_argb(255, 255, 0, 0)));
        assert_eq!(child.style().leading, 16.0);
        assert_eq!(root.style().leading, 17.0 * 1.2);
        let clear = text_context(&styled(&[("color", "transparent")]), &child);
        assert_eq!((clear.color.a(), clear.size, clear.wrap), (0, 12.0, false));
    }
}
