//! Parsers for the small CSS subset the shared renderer writes. Ported from
//! `Windows/src/ScriptWidget.Core/Render/Css.cs`; gradients become Skia
//! shaders as in the Android original.

use skia_safe::gradient::interpolation::InPremul;
use skia_safe::gradient::{Colors, Gradient, Interpolation, shaders};
use skia_safe::{Color, Color4f, Matrix, Point, Shader, TileMode};

pub const GRAY: Color = Color::from_argb(255, 136, 136, 136);

/// A number as Kotlin's `toFloatOrNull` reads it: `None` when the text is not one.
pub fn number(text: Option<&str>) -> Option<f32> {
    let text = text?.trim();
    // `parse` also accepts "inf" and "nan", which are not CSS numbers.
    if text.is_empty() || !text.bytes().all(|byte| byte.is_ascii_digit() || matches!(byte, b'+' | b'-' | b'.' | b'e' | b'E')) {
        return None;
    }
    text.parse::<f32>().ok().filter(|value| value.is_finite())
}

fn channel(value: f32) -> u8 {
    (value as i32).clamp(0, 255) as u8
}

/// Parses rgba()/rgb()/#hex/named colors. Returns `None` for `none`, empty or unknown values.
pub fn color(value: Option<&str>) -> Option<Color> {
    let text = value?.trim().to_ascii_lowercase();
    match text.as_str() {
        "" | "none" => return None,
        "white" => return Some(Color::WHITE),
        "black" => return Some(Color::BLACK),
        "transparent" => return Some(Color::TRANSPARENT),
        "red" => return Some(Color::from_argb(255, 255, 0, 0)),
        "green" => return Some(Color::from_argb(255, 0, 128, 0)),
        "blue" => return Some(Color::from_argb(255, 0, 0, 255)),
        "gray" | "grey" => return Some(GRAY),
        _ => {}
    }
    if text.starts_with("rgb") {
        let inner = text.split_once('(').map_or(text.as_str(), |(_, rest)| rest);
        let inner = inner.split_once(')').map_or(inner, |(before, _)| before);
        let parts: Vec<&str> = inner.split([',', '/']).map(str::trim).collect();
        if parts.len() < 3 {
            return None;
        }
        let (red, green, blue) = (number(Some(parts[0]))?, number(Some(parts[1]))?, number(Some(parts[2]))?);
        let alpha = parts.get(3).and_then(|part| number(Some(part))).unwrap_or(1.0);
        return Some(Color::from_argb((alpha.clamp(0.0, 1.0) * 255.0 + 0.5) as u8, channel(red), channel(green), channel(blue)));
    }
    if let Some(hex) = text.strip_prefix('#') {
        if !hex.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return None;
        }
        let value = u32::from_str_radix(hex, 16).ok()?;
        return match hex.len() {
            3 => Some(Color::from_argb(255, ((value >> 8) & 0xF) as u8 * 17, ((value >> 4) & 0xF) as u8 * 17, (value & 0xF) as u8 * 17)),
            6 => Some(Color::from_argb(255, (value >> 16) as u8, (value >> 8) as u8, value as u8)),
            8 => Some(Color::from_argb(value as u8, (value >> 24) as u8, (value >> 16) as u8, (value >> 8) as u8)),
            _ => None,
        };
    }
    None
}

/// `12px`, `12` or a bare number. Returns `None` for auto, percentages and keywords.
pub fn pixels(value: Option<&str>) -> Option<f32> {
    let text = value?.trim();
    if text.is_empty() || text.ends_with('%') {
        return None;
    }
    number(Some(text.strip_suffix("px").unwrap_or(text)))
}

/// A length that may be a percentage of `basis`.
pub fn length(value: Option<&str>, basis: f32) -> Option<f32> {
    let text = value?.trim();
    match text.strip_suffix('%') {
        Some(percent) => number(Some(percent)).map(|percent| percent / 100.0 * basis),
        None => pixels(Some(text)),
    }
}

/// Splits on commas that are not inside parentheses.
pub fn split_top_level(value: &str) -> Vec<&str> {
    let mut parts = Vec::new();
    let (mut depth, mut start) = (0i32, 0usize);
    for (index, character) in value.char_indices() {
        match character {
            '(' => depth += 1,
            ')' => depth -= 1,
            ',' if depth == 0 => {
                parts.push(value[start..index].trim());
                start = index + 1;
            }
            _ => {}
        }
    }
    parts.push(value[start..].trim());
    parts.retain(|part| !part.is_empty());
    parts
}

struct Stop {
    color: Color,
    position: f32,
}

/// `<color> <position>` where position is in px or deg.
fn parse_stop(text: &str) -> Option<Stop> {
    let text = text.trim();
    let split = text.rfind(' ').filter(|&at| at > 0)?;
    let color = color(Some(&text[..split]))?;
    let position = &text[split + 1..];
    let position = position.strip_suffix("px").unwrap_or(position);
    let position = number(Some(position.strip_suffix("deg").unwrap_or(position)))?;
    Some(Stop { color, position })
}

fn colors_of(stops: &[Stop]) -> Vec<Color4f> {
    stops.iter().map(|stop| Color4f::from(stop.color)).collect()
}

/// CSS interpolates gradient colors premultiplied: a stop that fades to transparent keeps its hue.
fn premultiplied() -> Interpolation {
    Interpolation { in_premul: InPremul::Yes, ..Default::default() }
}

/// Skia, like Android, wants non-decreasing positions.
fn monotonic(positions: impl Iterator<Item = f32>) -> Vec<f32> {
    let mut previous = 0f32;
    positions
        .map(|position| {
            previous = if position.is_nan() { previous } else { previous.max(position) };
            previous
        })
        .collect()
}

/// The number that follows `keyword` and whitespace, and the text after it.
fn number_after<'a>(text: &'a str, keyword: &str) -> Option<(f32, &'a str)> {
    let rest = text[text.find(keyword)? + keyword.len()..].trim_start();
    let end = rest.find(|character: char| !(character.is_ascii_digit() || matches!(character, '-' | '+' | '.' | 'e' | 'E'))).unwrap_or(rest.len());
    Some((number(Some(&rest[..end]))?, &rest[end..]))
}

/// `at <x>px <y>px`.
fn center_of(argument: &str) -> Option<Point> {
    let (x, rest) = number_after(argument, "at ")?;
    let (y, rest) = number_after(rest.strip_prefix("px")?, "")?;
    rest.starts_with("px").then_some(Point::new(x, y))
}

/// Shader for a CSS gradient painted in a `width` x `height` box moved by
/// `offset`, or `None` when `value` is not a gradient this renderer emits.
/// Colors are interpolated premultiplied, as CSS does.
pub fn gradient(value: Option<&str>, width: f32, height: f32, offset: (f32, f32)) -> Option<Shader> {
    let text = value?.trim();
    let open = text.find('(')?;
    if !text.ends_with(')') {
        return None;
    }
    let arguments = split_top_level(&text[open + 1..text.len() - 1]);
    let first = *arguments.first()?;
    let translation = Matrix::translate(offset);
    match &text[..open] {
        "linear-gradient" => {
            let angled = first.ends_with("deg");
            let degrees = if angled { number(first.strip_suffix("deg")).unwrap_or(180.0) } else { 180.0 };
            let stop_texts = if angled { &arguments[1..] } else { &arguments[..] };
            let radians = f64::from(degrees).to_radians();
            let (direction_x, direction_y) = (radians.sin() as f32, -(radians.cos() as f32));
            let line_length = (width * direction_x).abs() + (height * direction_y).abs();
            let parsed: Vec<Option<Stop>> = stop_texts.iter().map(|text| parse_stop(text)).collect();
            let stops: Vec<Stop> = if parsed.iter().all(Option::is_some) {
                parsed.into_iter().flatten().collect()
            } else {
                // Stops without positions (a solid two-stop fallback) span the gradient line.
                let last = stop_texts.len().saturating_sub(1).max(1) as f32;
                stop_texts.iter().enumerate().filter_map(|(index, text)| Some(Stop { color: color(Some(text))?, position: line_length * index as f32 / last })).collect()
            };
            if stops.len() < 2 {
                return None;
            }
            let (start, end) = (stops[0].position, stops[stops.len() - 1].position);
            if !(end - start > 0.0) {
                return None;
            }
            let point = |distance: f32| Point::new(width / 2.0 + (distance - line_length / 2.0) * direction_x, height / 2.0 + (distance - line_length / 2.0) * direction_y);
            let positions = monotonic(stops.iter().map(|stop| (stop.position - start) / (end - start)));
            shaders::linear_gradient((point(start), point(end)), &Gradient::new(Colors::new(&colors_of(&stops), Some(&positions), TileMode::Clamp, None), premultiplied()), &translation)
        }
        "radial-gradient" => {
            let center = center_of(first)?;
            let stops: Vec<Stop> = arguments[1..].iter().filter_map(|text| parse_stop(text)).collect();
            if stops.len() < 2 {
                return None;
            }
            let radius = stops[stops.len() - 1].position;
            if !(radius > 0.0) {
                return None;
            }
            let positions = monotonic(stops.iter().map(|stop| (stop.position / radius).clamp(0.0, 1.0)));
            shaders::radial_gradient((center, radius), &Gradient::new(Colors::new(&colors_of(&stops), Some(&positions), TileMode::Clamp, None), premultiplied()), &translation)
        }
        "conic-gradient" => {
            let center = center_of(first)?;
            let from = number_after(first, "from ").filter(|(_, rest)| rest.starts_with("deg")).map_or(0.0, |(degrees, _)| degrees);
            let stops: Vec<Stop> = arguments[1..].iter().filter_map(|text| parse_stop(text)).collect();
            if stops.len() < 2 {
                return None;
            }
            let positions = monotonic(stops.iter().map(|stop| (stop.position / 360.0).clamp(0.0, 1.0)));
            // CSS measures conic angles clockwise from 12 o'clock; a sweep gradient starts at 3 o'clock.
            let mut matrix = translation;
            matrix.pre_concat(&Matrix::rotate_deg_pivot(from - 90.0, center));
            shaders::sweep_gradient(center, (0.0, 360.0), &Gradient::new(Colors::new(&colors_of(&stops), Some(&positions), TileMode::Clamp, None), premultiplied()), &matrix)
        }
        _ => None,
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Shadow {
    pub dx: f32,
    pub dy: f32,
    pub blur: f32,
    pub color: Color,
}

/// `drop-shadow(Xpx Ypx Rpx color)` from a filter list; the color is a functional one.
pub fn drop_shadow(filter: Option<&str>) -> Option<Shadow> {
    let filter = filter?;
    let inner = &filter[filter.find("drop-shadow(")? + "drop-shadow(".len()..];
    let mut rest = inner.trim_start();
    let mut values = [0f32; 3];
    for value in &mut values {
        let end = rest.find("px")?;
        *value = number(Some(&rest[..end]))?;
        let after = &rest[end + 2..];
        // The lengths are separated by whitespace.
        if !after.starts_with(char::is_whitespace) {
            return None;
        }
        rest = after.trim_start();
    }
    let close = rest.find(')')?;
    if !rest[close + 1..].trim_start().starts_with(')') {
        return None;
    }
    Some(Shadow { dx: values[0], dy: values[1], blur: values[2], color: color(Some(&rest[..=close]))? })
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct BoxShadow {
    pub inset: bool,
    pub dx: f32,
    pub dy: f32,
    pub blur: f32,
    pub spread: f32,
    pub color: Color,
}

/// `[inset] X Y blur [spread] color`.
pub fn box_shadow(value: Option<&str>) -> Option<BoxShadow> {
    let mut text = value?.trim();
    let inset = text.starts_with("inset");
    if inset {
        text = text["inset".len()..].trim();
    }
    let color_start = text.find(|character: char| character.is_alphabetic() && character != 'p' && character != 'x')?;
    let numbers: Vec<f32> = text[..color_start].split_whitespace().filter_map(|part| pixels(Some(part))).collect();
    let color = color(Some(&text[color_start..]))?;
    if numbers.len() < 2 {
        return None;
    }
    Some(BoxShadow { inset, dx: numbers[0], dy: numbers[1], blur: numbers.get(2).copied().unwrap_or(0.0), spread: numbers.get(3).copied().unwrap_or(0.0), color })
}

/// Every `name(arguments)` of a transform list, in order.
pub fn functions(value: &str) -> Vec<(&str, &str)> {
    let mut result = Vec::new();
    let mut rest = value;
    while let Some(open) = rest.find('(') {
        let Some(close) = rest[open..].find(')') else { break };
        let name_start = rest[..open].rfind(|character: char| !character.is_ascii_alphanumeric()).map_or(0, |at| at + 1);
        if name_start < open {
            result.push((&rest[name_start..open], &rest[open + 1..open + close]));
        }
        rest = &rest[open + close + 1..];
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_colors() {
        assert_eq!(color(Some("#f00")), Some(Color::from_argb(255, 255, 0, 0)));
        assert_eq!(color(Some("#11223380")), Some(Color::from_argb(0x80, 0x11, 0x22, 0x33)));
        assert_eq!(color(Some("rgba(10, 20, 30, 0.5)")), Some(Color::from_argb(128, 10, 20, 30)));
        assert_eq!(color(Some("rgb(10 , 20,30)")), Some(Color::from_argb(255, 10, 20, 30)));
        assert_eq!(color(Some(" White ")), Some(Color::WHITE));
        for unknown in ["", "none", "#12", "#gggggg", "rgb(1,2)", "papayawhip", "rgb(a,b,c)"] {
            assert_eq!(color(Some(unknown)), None, "{unknown}");
        }
        assert_eq!(color(None), None);
    }

    #[test]
    fn reads_lengths() {
        assert_eq!(pixels(Some("12px")), Some(12.0));
        assert_eq!(pixels(Some(" -1.5 ")), Some(-1.5));
        assert_eq!(pixels(Some("50%")), None);
        assert_eq!(pixels(Some("auto")), None);
        assert_eq!(pixels(Some("inf")), None);
        assert_eq!(pixels(Some("nan")), None);
        assert_eq!(length(Some("50%"), 80.0), Some(40.0));
        assert_eq!(length(Some("7px"), 80.0), Some(7.0));
        assert_eq!(number(Some("1e2")), Some(100.0));
    }

    #[test]
    fn reads_shadows() {
        assert_eq!(drop_shadow(Some("drop-shadow(1px -2px 3.5px rgba(0, 0, 0, 0.5))")), Some(Shadow { dx: 1.0, dy: -2.0, blur: 3.5, color: Color::from_argb(128, 0, 0, 0) }));
        assert_eq!(drop_shadow(Some("blur(2px)")), None);
        assert_eq!(drop_shadow(Some("drop-shadow(1px 2px red)")), None);
        let outer = box_shadow(Some("0px 4px 12px rgba(0,0,0,0.25)")).unwrap();
        assert_eq!((outer.inset, outer.dx, outer.dy, outer.blur, outer.spread), (false, 0.0, 4.0, 12.0, 0.0));
        let inner = box_shadow(Some("inset 0 0 0 1px rgba(255,255,255,0.2)")).unwrap();
        assert_eq!((inner.inset, inner.spread, inner.color), (true, 1.0, Color::from_argb(51, 255, 255, 255)));
        assert_eq!(box_shadow(Some("1px")), None);
    }

    #[test]
    fn splits_arguments_and_functions() {
        assert_eq!(split_top_level("90deg, rgba(1, 2, 3, 1) 0px, #fff 10px"), ["90deg", "rgba(1, 2, 3, 1) 0px", "#fff 10px"]);
        assert_eq!(functions("perspective(400px) rotate3d(0, 1, 0, 30deg) scale(1.5)"), [("perspective", "400px"), ("rotate3d", "0, 1, 0, 30deg"), ("scale", "1.5")]);
        assert_eq!(center_of("from 90deg at 10px 20.5px"), Some(Point::new(10.0, 20.5)));
        assert_eq!(center_of("circle at 1e1px -3px"), Some(Point::new(10.0, -3.0)));
        assert_eq!(center_of("circle"), None);
    }

    #[test]
    fn builds_the_gradients_the_renderer_writes() {
        assert!(gradient(Some("linear-gradient(90deg, rgba(255, 0, 0, 1) 0px, rgba(0, 0, 255, 1) 100px)"), 100.0, 50.0, (0.0, 0.0)).is_some());
        assert!(gradient(Some("linear-gradient(#ff0000, #0000ff)"), 100.0, 50.0, (0.0, 0.0)).is_some());
        assert!(gradient(Some("radial-gradient(circle at 50px 25px, rgba(255, 0, 0, 1) 0px, rgba(0, 0, 255, 1) 40px)"), 100.0, 50.0, (0.0, 0.0)).is_some());
        assert!(gradient(Some("conic-gradient(from 90deg at 50px 25px, rgba(255, 0, 0, 1) 0deg, rgba(0, 0, 255, 1) 360deg)"), 100.0, 50.0, (3.0, 4.0)).is_some());
        for other in ["none", "url(a.png)", "linear-gradient(90deg, red 0px)", "linear-gradient(90deg, red 5px, blue 5px)", "radial-gradient(circle, red 0px, blue 4px)"] {
            assert!(gradient(Some(other), 100.0, 50.0, (0.0, 0.0)).is_none(), "{other}");
        }
    }
}
