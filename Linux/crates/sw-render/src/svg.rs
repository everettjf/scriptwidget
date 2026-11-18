//! Paints the inline SVG the shared renderer emits: icons, rings, gauges,
//! charts and shape strokes. Presentation attributes inherit from ancestors
//! as in SVG; `currentColor` resolves to the element's CSS color. Ported
//! from `Windows/src/ScriptWidget.Core/Render/SvgPainter.cs`; masks are
//! composited as in the Android original.

use std::collections::HashMap;

use skia_safe::canvas::SaveLayerRec;
use skia_safe::paint::{Cap, Join, Style};
use skia_safe::{BlendMode, Canvas, Color, ContourMeasureIter, Matrix, Paint, Path, PathBuilder, PathDirection, PathEffect, PathFillType, Point, Rect, luma_color_filter};

use crate::css;
use crate::dom::DomNode;
use crate::text::{TextEngine, TextStyle};

#[derive(Clone)]
struct Attributes {
    fill: String,
    stroke: String,
    stroke_width: f32,
    line_cap: String,
    line_join: String,
    fill_rule: String,
    font_size: f32,
    font_family: String,
    font_weight: i32,
    text_anchor: String,
}

impl Default for Attributes {
    fn default() -> Self {
        Self {
            fill: "black".into(),
            stroke: "none".into(),
            stroke_width: 1.0,
            line_cap: "butt".into(),
            line_join: "miter".into(),
            fill_rule: "nonzero".into(),
            font_size: 16.0,
            font_family: "sans-serif".into(),
            font_weight: 400,
            text_anchor: "start".into(),
        }
    }
}

impl Attributes {
    fn merged(&self, node: &DomNode) -> Self {
        if node.attributes.is_empty() {
            return self.clone();
        }
        let text = |name: &str, inherited: &String| node.attribute(name).map_or_else(|| inherited.clone(), str::to_owned);
        Self {
            fill: text("fill", &self.fill),
            stroke: text("stroke", &self.stroke),
            stroke_width: css::number(node.attribute("stroke-width")).unwrap_or(self.stroke_width),
            line_cap: text("stroke-linecap", &self.line_cap),
            line_join: text("stroke-linejoin", &self.line_join),
            fill_rule: text("fill-rule", &self.fill_rule),
            font_size: css::pixels(node.attribute("font-size")).unwrap_or(self.font_size),
            font_family: text("font-family", &self.font_family),
            font_weight: node.attribute("font-weight").and_then(|value| value.trim().parse().ok()).unwrap_or(self.font_weight),
            text_anchor: text("text-anchor", &self.text_anchor),
        }
    }
}

fn numbers(value: Option<&str>) -> Vec<f32> {
    value.map_or_else(Vec::new, |value| value.split(|character: char| character.is_whitespace() || character == ',').filter_map(|part| css::number(Some(part))).collect())
}

fn unit(value: Option<f32>) -> f32 {
    value.map_or(1.0, |value| value.clamp(0.0, 1.0))
}

fn with_opacity(color: Color, opacity: f32) -> Color {
    if opacity >= 1.0 { color } else { color.with_a((f32::from(color.a()) * opacity + 0.5) as u8) }
}

pub struct SvgPainter<'a> {
    text: &'a mut TextEngine,
    current_color: Color,
    masks: HashMap<String, &'a DomNode>,
}

impl<'a> SvgPainter<'a> {
    /// Paints an `<svg>` element with its top-left corner at the canvas origin.
    pub fn paint(text: &'a mut TextEngine, canvas: &Canvas, root: &'a DomNode, css_color: Color) {
        let mut painter = Self { text, current_color: css_color, masks: HashMap::new() };
        collect_masks(root, &mut painter.masks);
        let (Some(width), Some(height)) = (css::number(root.attribute("width")), css::number(root.attribute("height"))) else { return };
        canvas.save();
        if let Some(degrees) = root.style("transform").and_then(root_rotation) {
            canvas.rotate(degrees, Some(Point::new(width / 2.0, height / 2.0)));
        }
        let view_box = numbers(root.attribute("viewBox"));
        if view_box.len() == 4 && view_box[2] > 0.0 && view_box[3] > 0.0 {
            let scale = (width / view_box[2]).min(height / view_box[3]);
            canvas.translate(((width - view_box[2] * scale) / 2.0, (height - view_box[3] * scale) / 2.0));
            canvas.scale((scale, scale));
            canvas.translate((-view_box[0], -view_box[1]));
        }
        let attributes = Attributes::default().merged(root);
        for child in &root.children {
            painter.draw(canvas, child, &attributes);
        }
        canvas.restore();
    }

    fn draw(&mut self, canvas: &Canvas, node: &DomNode, inherited: &Attributes) {
        if node.tag == "defs" || node.tag == "mask" || node.tag.is_empty() {
            return;
        }
        let attributes = inherited.merged(node);
        let mask = node.attribute("mask").and_then(mask_reference).and_then(|id| self.masks.get(id).copied());
        let opacity = unit(css::number(node.attribute("opacity")));

        canvas.save();
        if let Some(transform) = node.attribute("transform") {
            canvas.concat(&transform_list(transform));
        }
        let layered = mask.is_some() || opacity < 1.0;
        if layered {
            canvas.save_layer_alpha_f(None, opacity);
        }
        match node.tag.as_str() {
            "g" => {
                for child in &node.children {
                    self.draw(canvas, child, &attributes);
                }
            }
            "text" => self.draw_text(canvas, node, &attributes),
            _ => self.draw_path(canvas, node, &attributes),
        }
        if let Some(mask) = mask {
            // An SVG mask keeps the drawing where the mask is light: the mask's
            // luminance, drawn as a layer of its own, becomes the alpha of the drawing.
            let mut paint = Paint::default();
            paint.set_blend_mode(BlendMode::DstIn).set_color_filter(luma_color_filter::new());
            canvas.save_layer(&SaveLayerRec::default().paint(&paint));
            let mask_attributes = Attributes::default().merged(mask);
            for child in &mask.children {
                self.draw(canvas, child, &mask_attributes);
            }
            canvas.restore();
        }
        if layered {
            canvas.restore();
        }
        canvas.restore();
    }

    fn resolve_color(&self, value: &str) -> Option<Color> {
        if value == "currentColor" { Some(self.current_color) } else { css::color(Some(value)) }
    }

    fn draw_path(&mut self, canvas: &Canvas, node: &DomNode, attributes: &Attributes) {
        let Some(path) = shape(node, attributes) else { return };
        let fill_opacity = unit(css::number(node.attribute("fill-opacity")));
        let stroke_opacity = unit(css::number(node.attribute("stroke-opacity")));
        if node.tag != "line"
            && let Some(fill) = self.resolve_color(&attributes.fill).filter(|color| color.a() != 0)
        {
            let mut paint = Paint::default();
            paint.set_anti_alias(true).set_color(with_opacity(fill, fill_opacity));
            canvas.draw_path(&path, &paint);
        }
        let Some(stroke) = self.resolve_color(&attributes.stroke).filter(|color| color.a() != 0) else { return };
        if !(attributes.stroke_width > 0.0) {
            return;
        }
        let mut paint = Paint::default();
        paint
            .set_anti_alias(true)
            .set_style(Style::Stroke)
            .set_stroke_width(attributes.stroke_width)
            .set_stroke_miter(4.0)
            .set_stroke_cap(match attributes.line_cap.as_str() {
                "round" => Cap::Round,
                "square" => Cap::Square,
                _ => Cap::Butt,
            })
            .set_stroke_join(match attributes.line_join.as_str() {
                "round" => Join::Round,
                "bevel" => Join::Bevel,
                _ => Join::Miter,
            })
            .set_color(with_opacity(stroke, stroke_opacity));
        let dashes = numbers(node.attribute("stroke-dasharray"));
        if !dashes.is_empty() && dashes.iter().any(|value| *value > 0.0) {
            // pathLength rescales dash lengths to the real outline length.
            let unit = match css::number(node.attribute("pathLength")) {
                Some(path_length) if path_length > 0.0 => path_length_of(&path) / path_length,
                _ => 1.0,
            };
            let even = if dashes.len().is_multiple_of(2) { dashes.clone() } else { [dashes.as_slice(), dashes.as_slice()].concat() };
            // A zero-length dash with round caps would still draw a dot.
            if even[0] <= 0.0 {
                return;
            }
            let intervals: Vec<f32> = even.iter().enumerate().map(|(index, value)| (value * unit).max(if index % 2 == 0 { 0.0001 } else { 0.0 })).collect();
            let total: f32 = intervals.iter().sum();
            let offset = css::number(node.attribute("stroke-dashoffset")).unwrap_or(0.0) * unit;
            let mut phase = if total > 0.0 { (offset % total + total) % total } else { 0.0 };
            // An offset that ends exactly on a dash would start the outline with a dash of no
            // length, which is stroked as a blot of the stroke's width: start in the gap after it.
            let mut dash_end = 0.0;
            for pair in intervals.chunks_exact(2) {
                dash_end += pair[0];
                if phase <= dash_end && dash_end - phase < total * 1.0e-4 {
                    phase = dash_end + total * 1.0e-5;
                    break;
                }
                dash_end += pair[1];
            }
            if let Some(effect) = PathEffect::dash(&intervals, phase) {
                paint.set_path_effect(effect);
            }
        }
        canvas.draw_path(&path, &paint);
    }

    fn draw_text(&mut self, canvas: &Canvas, node: &DomNode, attributes: &Attributes) {
        let Some(content) = node.text.as_deref() else { return };
        let Some(fill) = self.resolve_color(&attributes.fill) else { return };
        let style = TextStyle { family: attributes.font_family.clone(), size: attributes.font_size, weight: attributes.font_weight, leading: attributes.font_size * 1.2 };
        let mut x = css::number(node.attribute("x")).unwrap_or(0.0);
        match attributes.text_anchor.as_str() {
            "middle" => x -= self.text.measure(content, &style) / 2.0,
            "end" => x -= self.text.measure(content, &style),
            _ => {}
        }
        let mut paint = Paint::default();
        paint.set_anti_alias(true).set_color(fill);
        self.text.draw(canvas, content, &style, x, css::number(node.attribute("y")).unwrap_or(0.0), &paint);
    }
}

fn collect_masks<'a>(node: &'a DomNode, into: &mut HashMap<String, &'a DomNode>) {
    if node.tag == "mask"
        && let Some(id) = node.attribute("id")
    {
        into.insert(id.to_owned(), node);
    }
    for child in &node.children {
        collect_masks(child, into);
    }
}

/// `rotate(<n>deg)` on the root element.
fn root_rotation(value: &str) -> Option<f32> {
    css::functions(value).into_iter().find(|(name, _)| *name == "rotate").and_then(|(_, argument)| css::number(argument.trim().strip_suffix("deg")))
}

/// The id in `url(#id)`.
fn mask_reference(value: &str) -> Option<&str> {
    let rest = &value[value.find("url(#")? + "url(#".len()..];
    rest.find(')').filter(|end| *end > 0).map(|end| &rest[..end])
}

/// SVG transform list: translate, scale, rotate.
fn transform_list(value: &str) -> Matrix {
    let mut matrix = Matrix::new_identity();
    for (name, arguments) in css::functions(value) {
        let arguments = numbers(Some(arguments));
        let argument = |index: usize, fallback: f32| arguments.get(index).copied().unwrap_or(fallback);
        let step = match name {
            "translate" => Matrix::translate((argument(0, 0.0), argument(1, 0.0))),
            "scale" => Matrix::scale((argument(0, 1.0), argument(1, argument(0, 1.0)))),
            "rotate" if arguments.len() >= 3 => Matrix::rotate_deg_pivot(arguments[0], (arguments[1], arguments[2])),
            "rotate" => Matrix::rotate_deg(argument(0, 0.0)),
            _ => continue,
        };
        matrix.pre_concat(&step);
    }
    matrix
}

/// The length of the outline, measured finely: the default resolution cuts
/// curves into so few lines that a small circle comes out 2% short, and a
/// full ring drawn as one dash of its `pathLength` would not close.
fn path_length_of(path: &Path) -> f32 {
    ContourMeasureIter::new(path, false, MEASURE_RESOLUTION).map(|contour| contour.length()).sum()
}

const MEASURE_RESOLUTION: f32 = 64.0;

fn shape(node: &DomNode, attributes: &Attributes) -> Option<Path> {
    let number = |name: &str| css::number(node.attribute(name)).unwrap_or(0.0);
    let fill_type = if attributes.fill_rule == "evenodd" { PathFillType::EvenOdd } else { PathFillType::Winding };
    match node.tag.as_str() {
        "path" => Path::from_svg(node.attribute("d")?).map(|path| path.with_fill_type(fill_type)),
        "rect" => {
            let (x, y, width, height) = (number("x"), number("y"), number("width"), number("height"));
            if width <= 0.0 || height <= 0.0 {
                return None;
            }
            let rx = css::number(node.attribute("rx")).or_else(|| css::number(node.attribute("ry"))).unwrap_or(0.0).min(width / 2.0);
            let ry = css::number(node.attribute("ry")).unwrap_or(rx).min(height / 2.0);
            Some(rounded_rect(x, y, width, height, rx, ry))
        }
        "circle" => Some(oval(number("cx"), number("cy"), number("r"), number("r"))),
        "ellipse" => Some(oval(number("cx"), number("cy"), number("rx"), number("ry"))),
        "line" => Some(Path::line((number("x1"), number("y1")), (number("x2"), number("y2")))),
        "polyline" | "polygon" => {
            let values = numbers(node.attribute("points"));
            if values.len() < 4 {
                return None;
            }
            let points: Vec<Point> = values.chunks_exact(2).map(|pair| Point::new(pair[0], pair[1])).collect();
            let mut builder = PathBuilder::new_with_fill_type(fill_type);
            builder.add_polygon(&points, node.tag == "polygon");
            Some(builder.detach())
        }
        _ => None,
    }
}

/// An oval that starts at 3 o'clock and runs clockwise, as SVG circles do; dash offsets depend on it.
fn oval(cx: f32, cy: f32, rx: f32, ry: f32) -> Path {
    let mut builder = PathBuilder::new();
    if rx > 0.0 && ry > 0.0 {
        builder.add_oval(Rect::from_ltrb(cx - rx, cy - ry, cx + rx, cy + ry), PathDirection::CW, 1);
    } else {
        builder.move_to((cx + rx, cy)).close();
    }
    builder.detach()
}

/// SVG rectangles start at (x + rx, y) and run clockwise; dash offsets depend on it.
fn rounded_rect(x: f32, y: f32, width: f32, height: f32, rx: f32, ry: f32) -> Path {
    let mut builder = PathBuilder::new();
    let (right, bottom) = (x + width, y + height);
    if rx <= 0.0 || ry <= 0.0 {
        builder.move_to((x, y)).line_to((right, y)).line_to((right, bottom)).line_to((x, bottom)).close();
        return builder.detach();
    }
    // A conic with this weight through the corner point is an exact quarter of an ellipse.
    let quarter = std::f32::consts::FRAC_1_SQRT_2;
    builder
        .move_to((x + rx, y))
        .line_to((right - rx, y))
        .conic_to((right, y), (right, y + ry), quarter)
        .line_to((right, bottom - ry))
        .conic_to((right, bottom), (right - rx, bottom), quarter)
        .line_to((x + rx, bottom))
        .conic_to((x, bottom), (x, bottom - ry), quarter)
        .line_to((x, y + ry))
        .conic_to((x, y), (x + rx, y), quarter)
        .close();
    builder.detach()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_references_and_transforms() {
        assert_eq!(mask_reference("url(#m1)"), Some("m1"));
        assert_eq!(mask_reference("url(#)"), None);
        assert_eq!(mask_reference("none"), None);
        assert_eq!(root_rotation("rotate(-90deg)"), Some(-90.0));
        assert_eq!(root_rotation("scale(2)"), None);
        let matrix = transform_list("translate(10, 20) scale(2)");
        assert_eq!(matrix.map_point((1.0, 1.0)), Point::new(12.0, 22.0));
        let turned = transform_list("rotate(90 10 10)").map_point((20.0, 10.0));
        assert!((turned.x - 10.0).abs() < 0.001 && (turned.y - 20.0).abs() < 0.001, "{turned:?}");
        assert_eq!(numbers(Some("1,2  3\n4.5")), [1.0, 2.0, 3.0, 4.5]);
    }

    #[test]
    fn outlines_start_where_svg_says() {
        // Dash offsets are measured from the start of the outline.
        let circle = oval(10.0, 10.0, 5.0, 5.0);
        let mut contours = ContourMeasureIter::new(&circle, false, None);
        let start = contours.next().and_then(|contour| contour.pos_tan(0.0)).expect("start").0;
        assert!((start.x - 15.0).abs() < 0.01 && (start.y - 10.0).abs() < 0.01, "{start:?}");
        let length = path_length_of(&circle);
        assert!((length - 2.0 * std::f32::consts::PI * 5.0).abs() < 0.02, "{length}");

        let rect = rounded_rect(0.0, 0.0, 20.0, 10.0, 2.0, 2.0);
        let mut contours = ContourMeasureIter::new(&rect, false, MEASURE_RESOLUTION);
        let contour = contours.next().expect("contour");
        let (start, direction) = contour.pos_tan(0.0).expect("start");
        assert!((start.x - 2.0).abs() < 0.01 && start.y.abs() < 0.01 && direction.x > 0.9, "{start:?} {direction:?}");
        let expected = 2.0 * (16.0 + 6.0) + 2.0 * std::f32::consts::PI * 2.0;
        assert!((contour.length() - expected).abs() < 0.1, "{}", contour.length());
    }

    #[test]
    fn path_data_is_parsed_by_skia() {
        let node = |tag: &str, attributes: &[(&str, &str)]| DomNode { tag: tag.into(), svg: true, attributes: attributes.iter().map(|(name, value)| ((*name).to_owned(), (*value).to_owned())).collect(), ..Default::default() };
        let attributes = Attributes::default();
        let path = shape(&node("path", &[("d", "M0 0h10v10H0z")]), &attributes).expect("path");
        assert_eq!(*path.bounds(), Rect::from_ltrb(0.0, 0.0, 10.0, 10.0));
        // Arc flags written without separators, as icon sets do.
        assert!(shape(&node("path", &[("d", "M2 12a10 10 0 1020 0")]), &attributes).is_some());
        assert!(shape(&node("path", &[("d", "M0 0 L")]), &attributes).is_none());
        assert!(shape(&node("path", &[]), &attributes).is_none());
        assert!(shape(&node("rect", &[("width", "0"), ("height", "4")]), &attributes).is_none());
        assert!(shape(&node("polyline", &[("points", "0,0 4,4")]), &attributes).is_some());
        assert!(shape(&node("polyline", &[("points", "0,0")]), &attributes).is_none());
        assert!(shape(&node("unknown", &[]), &attributes).is_none());
    }
}
