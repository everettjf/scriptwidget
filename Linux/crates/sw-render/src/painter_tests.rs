//! The painter, the text engine and the image source on their own, without
//! the layout engine. Ported from
//! `Windows/tests/ScriptWidget.Core.Tests/Render/PainterTests.cs`; pixels are
//! premultiplied RGBA here.

use std::collections::HashMap;
use std::sync::Arc;

use skia_safe::{AlphaType, Color, ColorType, ImageInfo, surfaces};
use sw_core::MemoryPackageFiles;
use sw_core::json::{ObjectExt, parse_object, quote};

use crate::dom::DomNode;
use crate::fonts::FontRegistry;
use crate::images::PackageImageSource;
use crate::painter::DomPainter;
use crate::text::{TextEngine, TextStyle};
use crate::{GifSlot, HitRegion};

const INTER: &str = "\"ScriptWidget Inter\", Arial, sans-serif";

struct Painted {
    pixels: Vec<u8>,
    width: usize,
    hit_regions: Vec<HitRegion>,
    gif_slots: Vec<GifSlot>,
}

impl Painted {
    /// Red, green, blue, alpha of one pixel.
    fn pixel(&self, x: usize, y: usize) -> (u8, u8, u8, u8) {
        let at = (y * self.width + x) * 4;
        (self.pixels[at], self.pixels[at + 1], self.pixels[at + 2], self.pixels[at + 3])
    }

    fn inked(&self) -> usize {
        self.pixels.chunks_exact(4).filter(|pixel| pixel[3] != 0).count()
    }

    /// Left, top, right, bottom of the pixels that are not transparent.
    fn ink_bounds(&self) -> (i32, i32, i32, i32) {
        let (mut left, mut top, mut right, mut bottom) = (i32::MAX, i32::MAX, -1, -1);
        for (index, pixel) in self.pixels.chunks_exact(4).enumerate() {
            if pixel[3] == 0 {
                continue;
            }
            let (x, y) = ((index % self.width) as i32, (index / self.width) as i32);
            (left, top, right, bottom) = (left.min(x), top.min(y), right.max(x), bottom.max(y));
        }
        (left, top, right, bottom)
    }
}

fn engine() -> TextEngine {
    TextEngine::new(FontRegistry::new("en-US"))
}

fn no_images() -> PackageImageSource {
    PackageImageSource::new(None, HashMap::new(), None)
}

/// Paints a recorded element tree (JSON as render/entry.mjs writes it).
fn paint_with(json: &str, width: i32, height: i32, scale: f32, text: &mut TextEngine, images: &mut PackageImageSource) -> Painted {
    let root = DomNode::from_json(&parse_object(json).expect("element JSON")).expect("element tree");
    let mut surface = surfaces::raster(&ImageInfo::new((width, height), ColorType::RGBA8888, AlphaType::Premul, None), None, None).expect("surface");
    surface.canvas().clear(Color::TRANSPARENT);
    let mut painter = DomPainter::new(text, images);
    painter.paint(surface.canvas(), &root, scale);
    let (hit_regions, gif_slots) = (std::mem::take(&mut painter.hit_regions), std::mem::take(&mut painter.gif_slots));
    let pixels = surface.peek_pixels().and_then(|pixmap| pixmap.bytes().map(<[u8]>::to_vec)).expect("pixels");
    Painted { pixels, width: width as usize, hit_regions, gif_slots }
}

fn paint(json: &str, width: i32, height: i32, scale: f32) -> Painted {
    paint_with(json, width, height, scale, &mut engine(), &mut no_images())
}

fn root(width: i32, height: i32, children: &str) -> String {
    format!("{{\"t\":\"div\",\"s\":{{\"width\":\"{width}px\",\"height\":\"{height}px\"}},\"c\":[{children}]}}")
}

fn text_box(text: &str, left: f32, top: f32, width: f32, height: f32, extra_style: &str) -> String {
    format!(
        "{{\"t\":\"div\",\"s\":{{\"position\":\"absolute\",\"left\":\"{left}px\",\"top\":\"{top}px\",\"width\":\"{width}px\",\"height\":\"{height}px\",\"fontFamily\":{},\"fontSize\":\"17px\",\"fontWeight\":\"400\",\"lineHeight\":\"22px\",\"color\":\"rgb(0, 0, 0)\"{extra_style}}},\"x\":{}}}",
        quote(INTER),
        quote(text)
    )
}

fn boxed(style: &str, extra: &str) -> String {
    format!("{{\"t\":\"div\",\"s\":{{\"position\":\"absolute\",{style}}}{extra}}}")
}

fn svg(attributes: &str, children: &str, style: &str) -> String {
    format!("{{\"t\":\"svg\",\"g\":1,\"s\":{{\"position\":\"absolute\",\"left\":\"0px\",\"top\":\"0px\"{style}}},\"a\":{{{attributes}}},\"c\":[{children}]}}")
}

fn shape(tag: &str, attributes: &str) -> String {
    format!("{{\"t\":\"{tag}\",\"g\":1,\"a\":{{{attributes}}}}}")
}

fn style(family: &str, size: f32, weight: i32) -> TextStyle {
    TextStyle { family: family.into(), size, weight, leading: size * 1.2 }
}

fn texts(lines: &[crate::text::TextLine]) -> Vec<&str> {
    lines.iter().map(|line| line.text.as_str()).collect()
}

const RED: (u8, u8, u8, u8) = (255, 0, 0, 255);
const GREEN: (u8, u8, u8, u8) = (0, 255, 0, 255);
const BLUE: (u8, u8, u8, u8) = (0, 0, 255, 255);

// MARK: - Fonts and text

#[test]
fn the_bundled_inter_is_loaded_and_its_weights_and_the_display_fonts_differ() {
    let mut engine = engine();
    let regular = TextStyle { family: INTER.into(), size: 20.0, weight: 400, leading: 24.0 };
    let sample = "Hello world, Widget 123";
    let inter = engine.measure(sample, &regular);
    assert!(inter > 100.0, "{inter}");
    // Inter's metrics: ascent 0.96875 and descent 0.2412 of the size, placed with CSS half-leading.
    let expected = (24.0 - (0.96875 + 0.241_210_94) * 20.0) / 2.0 + 0.96875 * 20.0;
    assert!((engine.baseline(&regular) - expected).abs() < 0.01, "{} vs {expected}", engine.baseline(&regular));
    // The weight changes the advance: each weight is a real instance of the variable font, not a smeared regular.
    let bold = engine.measure(sample, &TextStyle { weight: 700, ..regular.clone() });
    assert!(bold > inter + 2.0, "regular {inter}, bold {bold}");
    let light = engine.measure(sample, &TextStyle { weight: 200, ..regular.clone() });
    assert!(light < inter - 1.0, "regular {inter}, light {light}");
    // The display fonts are their own families.
    for family in ["Apple ][", "Larabiefont Free", "Monofonto", "White Rabbit", "OneSlot", "Unispace"] {
        let custom = engine.measure(sample, &TextStyle { family: format!("\"{family}\", -apple-system, \"ScriptWidget Inter\", system-ui, sans-serif"), ..regular.clone() });
        assert!((custom - inter).abs() > 1.0, "{family} measures {custom}, the same as Inter");
    }
    // The system's own sans-serif is another face again, when it has one.
    let mut system = engine;
    system.fonts_mut().set_use_system_font(true);
    let face = system.fonts_mut().face(INTER, 400);
    if face.primary.is_empty() || face.primary == "Inter" {
        println!("no system sans-serif face was found here ({:?}); skipped", face.primary);
    } else {
        // Which face it is, not how wide: on Arch Linux the system's Noto Sans sets this sample within half a pixel of Inter.
        assert!(system.measure(sample, &regular) > 100.0);
        assert_eq!(system.families_used(sample, &regular), [face.primary.clone()]);
    }
}

#[test]
fn a_monospace_face_has_one_advance() {
    let mut engine = engine();
    let mono = TextStyle { family: "ui-monospace, \"SF Mono\", SFMono-Regular, Menlo, Consolas, monospace".into(), size: 20.0, weight: 400, leading: 24.0 };
    let face = engine.fonts_mut().face(&mono.family, 400);
    if face.primary.is_empty() {
        println!("no monospace font is installed here; skipped");
        return;
    }
    // The text is drawn with the face that was resolved, not with a substitute.
    assert_eq!(engine.families_used("Hello world, Widget 123", &mono), [face.primary.clone()]);
    let (one, sample) = (engine.measure("0", &mono), engine.measure("Hello world, Widget 123", &mono));
    assert!((sample - 23.0 * one).abs() < 0.5, "{sample} is not 23 x {one} in {}", face.primary);
}

#[test]
fn width_includes_trailing_spaces() {
    let mut engine = engine();
    let style = style(INTER, 17.0, 400);
    let (word, spaced) = (engine.measure("alpha", &style), engine.measure("alpha  ", &style));
    assert!(spaced > word + 4.0, "{word} {spaced}");
    assert_eq!(engine.measure("", &style), 0.0);
    // A size the layout should never send still measures instead of failing.
    assert!(engine.measure("x", &TextStyle { size: f32::NAN, ..style.clone() }).is_finite());
    assert!(engine.measure("x", &TextStyle { size: -3.0, ..style }).is_finite());
}

#[test]
fn lines_break_like_pre_wrap_with_break_word() {
    let mut engine = engine();
    let style = TextStyle { family: INTER.into(), size: 17.0, weight: 400, leading: 22.0 };
    // Explicit newlines always break, and an empty line stays.
    assert_eq!(texts(&engine.lines("one\n\ntwo", &style, None)), ["one", "", "two"]);
    // Without a width nothing wraps.
    assert_eq!(engine.lines("a long line of text that would never fit a narrow box", &style, None).len(), 1);
    // With a width, words wrap and trailing spaces are trimmed.
    let limit = engine.measure("alpha beta gam", &style);
    let wrapped = engine.lines("alpha beta gamma delta epsilon", &style, Some(limit));
    assert_eq!(texts(&wrapped), ["alpha beta", "gamma delta", "epsilon"]);
    for line in &wrapped {
        assert!((engine.measure(&line.text, &style) - line.width).abs() < 0.001);
    }
    // A word breaks inside only when it does not fit on a line of its own.
    let narrow = engine.measure("abcdef", &style);
    let broken = engine.lines("hi abcdefghijkl", &style, Some(narrow + 0.5));
    assert_eq!(broken[0].text, "hi");
    assert!(broken.len() >= 3 && broken[1..].iter().map(|line| line.text.as_str()).collect::<String>() == "abcdefghijkl", "{:?}", texts(&broken));
    for line in &broken {
        assert!(line.width <= narrow + 0.51, "{line:?}");
    }
    // Chinese breaks between characters, and never inside one.
    let sentence = "这是一个很长的中文句子用来测试换行";
    let limit = engine.measure("这是一个很长", &style) + 1.0;
    let chinese = engine.lines(sentence, &style, Some(limit));
    // Six characters fit a line: seventeen take three lines, each as full as it can be.
    assert_eq!(chinese.iter().map(|line| line.text.chars().count()).collect::<Vec<_>>(), [6, 6, 5], "{:?}", texts(&chinese));
    // Mixed text: line ends are found by character, not by byte or by UTF-16 unit.
    let limit = engine.measure("今天 weather 多", &style) + 0.5;
    let mixed = engine.lines("今天 weather 多云 😀😀 fine", &style, Some(limit));
    assert_eq!(texts(&mixed), ["今天 weather 多", "云 😀😀 fine"]);
    assert_eq!(chinese.iter().map(|line| line.text.as_str()).collect::<String>(), sentence);
    // Emoji made of several code points stay whole.
    let family = "👨‍👩‍👧‍👦";
    let limit = engine.measure(family, &style) * 1.5;
    let emoji = engine.lines(&format!("{family}{family}{family}{family}"), &style, Some(limit));
    assert!(emoji.len() >= 3 && emoji.iter().all(|line| line.text.chars().count() % family.chars().count() == 0), "{:?}", texts(&emoji));
}

/// A line measured without a width is one line again when laid out in a box of exactly that width.
#[test]
fn a_measured_line_is_not_wrapped_in_a_box_of_its_measured_width() {
    let mut engine = engine();
    let samples = ["Hello widget world", "Tuesday, November 17", "72°F · Partly Cloudy", "1,234,567.89 kWh", "你好，世界 hello", "Steps 🚶 8,432 today", "AV To. WAVE fi ffl", "a b c d e f g h i j k l m n o p"];
    let families = [INTER, "ui-monospace, Consolas, monospace", "\"New York\", ui-serif, Georgia, serif", "\"Unispace\", -apple-system, sans-serif"];
    for family in families {
        for size in [9.0f32, 12.0, 13.5, 17.0, 28.0, 51.3] {
            for weight in [300, 400, 600, 700, 900] {
                for sample in samples {
                    let style = style(family, size, weight);
                    let measured = engine.lines(sample, &style, None);
                    assert_eq!(measured.len(), 1);
                    let laid_out = engine.lines(sample, &style, Some(measured[0].width));
                    assert!(laid_out.len() == 1 && laid_out[0].text == sample, "{family} {size} {weight} '{sample}' wrapped into {} lines at its own width {}", laid_out.len(), measured[0].width);
                    assert_eq!(measured[0].width, laid_out[0].width);
                }
            }
        }
    }
}

/// The layout sizes a text box to the widest line it was told, then asks again at that width:
/// the lines must be the same ones, or text that fits would be truncated.
#[test]
fn wrapped_text_keeps_its_lines_in_a_box_of_its_widest_line() {
    let mut engine = engine();
    let samples = ["Build with primitives", "Good morning, Friend and welcome back", "Partly cloudy with a chance of rain later today", "今天多云，气温十八度，适合出门散步", "Steps 🚶 8,432 today and counting", "Tuesday, November 17 2026"];
    for family in [INTER, "ui-monospace, Consolas, monospace", "\"Monofonto\", sans-serif"] {
        for size in [11.0f32, 13.0, 17.0, 22.0, 34.0] {
            for weight in [400, 700] {
                for sample in samples {
                    let style = style(family, size, weight);
                    let whole = engine.measure(sample, &style);
                    for fraction in [0.31f32, 0.45, 0.5, 0.62, 0.84] {
                        let first = engine.lines(sample, &style, Some(whole * fraction));
                        let widest = first.iter().map(|line| line.width).fold(0.0, f32::max);
                        let again = engine.lines(sample, &style, Some(widest));
                        assert!(texts(&again) == texts(&first), "{family} {size} {weight} '{sample}': {:?} at {} became {:?} at its widest line {widest}", texts(&first), whole * fraction, texts(&again));
                        // No line is wider than the box, unless it is a single character that cannot be divided.
                        for line in &first {
                            assert!(line.width <= whole * fraction + 0.01 || line.text.chars().count() <= 2, "{family} {size} '{}' is {} wide in {}", line.text, line.width, whole * fraction);
                        }
                    }
                }
            }
        }
    }
    // The case that showed it: "primitives" is 107.2 wide and was broken in a box of 107.5.
    let bold = TextStyle { family: INTER.into(), size: 22.0, weight: 700, leading: 28.0 };
    let word = engine.measure("primitives", &bold);
    assert_eq!(texts(&engine.lines("Build with primitives", &bold, Some(word + 0.3))), ["Build with", "primitives"]);
}

/// What is drawn in a box of the measured width is, pixel for pixel, what is drawn with room to spare.
#[test]
fn text_drawn_at_its_measured_width_is_not_wrapped_or_cut() {
    let mut engine = engine();
    let style = TextStyle { family: INTER.into(), size: 17.0, weight: 400, leading: 22.0 };
    for sample in ["Hello widget world", "Weather in 北京 ☀ 23°", "Wavy AVATAR Type"] {
        let width = engine.measure(sample, &style);
        let exact = paint(&root(400, 60, &text_box(sample, 10.0, 10.0, width, 22.0, "")), 800, 120, 2.0);
        let roomy = paint(&root(400, 60, &text_box(sample, 10.0, 10.0, 380.0, 22.0, ",\"whiteSpace\":\"pre\"")), 800, 120, 2.0);
        assert!(exact.inked() > 200, "{sample}");
        assert!(exact.pixels == roomy.pixels, "'{sample}' is drawn differently in a box of its measured width");
        // One line: the ink stays inside the 22-point line box, and inside the measured width.
        let (left, top, right, bottom) = exact.ink_bounds();
        assert!(top >= 20 - 4 && bottom <= (10 + 22) * 2 + 4, "'{sample}' ink rows {top}..{bottom}");
        assert!(left >= 20 - 4 && right as f32 <= (10.0 + width) * 2.0 + 4.0, "'{sample}' ink columns {left}..{right} for width {width}");
    }
}

#[test]
fn text_alignment_places_the_line_in_its_box() {
    let left = paint(&root(200, 30, &text_box("Hi", 0.0, 0.0, 200.0, 22.0, "")), 200, 30, 1.0).ink_bounds();
    let center = paint(&root(200, 30, &text_box("Hi", 0.0, 0.0, 200.0, 22.0, ",\"textAlign\":\"center\"")), 200, 30, 1.0).ink_bounds();
    let right = paint(&root(200, 30, &text_box("Hi", 0.0, 0.0, 200.0, 22.0, ",\"textAlign\":\"right\"")), 200, 30, 1.0).ink_bounds();
    assert!(left.0 < 4 && left.2 < 30, "{left:?}");
    assert!(((center.0 + center.2) as f32 / 2.0 - 100.0).abs() < 2.0, "{center:?}");
    assert!(right.2 >= 196 && right.0 > 170, "{right:?}");
    // Wrapped text takes one line box per line.
    let wrapped = paint(&root(60, 100, &text_box("alpha beta gamma", 0.0, 0.0, 60.0, 66.0, "")), 60, 100, 1.0).ink_bounds();
    assert!(wrapped.3 > 44 && wrapped.3 < 66, "{wrapped:?}");
    // The baseline is where the style says, whatever the glyphs: a capital H stands on it.
    let mut engine = engine();
    let baseline = engine.baseline(&TextStyle { family: INTER.into(), size: 17.0, weight: 400, leading: 22.0 });
    let capital = paint(&root(200, 30, &text_box("H", 0.0, 0.0, 200.0, 22.0, "")), 400, 60, 2.0).ink_bounds();
    assert!((capital.3 as f32 + 1.0 - baseline * 2.0).abs() <= 1.5, "ink bottom {} for baseline {baseline}", capital.3);
}

#[test]
fn text_is_drawn_in_its_color_or_its_gradient() {
    let latin = paint(&root(200, 40, &text_box("Widget", 4.0, 4.0, 190.0, 22.0, "")), 400, 80, 2.0);
    assert!(latin.pixels.chunks_exact(4).any(|pixel| pixel == [0, 0, 0, 255]), "default-color text is black");
    let clear = paint(&root(200, 40, &text_box("Widget", 4.0, 4.0, 190.0, 22.0, ",\"color\":\"transparent\"")), 400, 80, 2.0);
    assert_eq!(clear.inked(), 0);
    // A gradient clipped to the text colors the glyphs from left to right; the box itself stays empty.
    let gradient = paint(&root(200, 40, &text_box("WWWWWWWWWWWWWWWW", 0.0, 4.0, 200.0, 22.0, ",\"color\":\"transparent\",\"backgroundClip\":\"text\",\"backgroundImage\":\"linear-gradient(90deg, rgb(255, 0, 0) 0px, rgb(0, 0, 255) 200px)\"")), 400, 80, 2.0);
    let solid: Vec<(usize, &[u8])> = gradient.pixels.chunks_exact(4).enumerate().filter(|(_, pixel)| pixel[3] == 255).collect();
    assert!(solid.len() > 200, "{}", solid.len());
    assert!(solid.iter().any(|(index, pixel)| index % 400 < 60 && pixel[0] > 200 && pixel[2] < 60), "red at the left");
    assert!(solid.iter().any(|(index, pixel)| index % 400 > 300 && pixel[2] > 180 && pixel[0] < 80), "blue at the right");
    assert_eq!(gradient.pixel(399, 79).3, 0);
}

#[test]
fn chinese_and_emoji_text_is_drawn() {
    let mut engine = engine();
    if engine.fonts().cjk_families().is_empty() {
        println!("no CJK font is installed here; Chinese text is not checked");
    } else {
        let chinese = paint(&root(200, 40, &text_box("你好世界", 4.0, 4.0, 190.0, 22.0, "")), 400, 80, 2.0);
        assert!(chinese.inked() > 400, "Chinese ink {}", chinese.inked());
        // Every character has a glyph of its own: no row of identical missing-glyph boxes.
        let style = style(INTER, 17.0, 400);
        assert!((engine.measure("你好世界", &style) - 4.0 * 17.0).abs() < 4.0, "{}", engine.measure("你好世界", &style));
    }
    let emoji = paint(&root(200, 40, &text_box("😀🌈🔥", 4.0, 4.0, 190.0, 22.0, "")), 400, 80, 2.0);
    let colored = emoji.pixels.chunks_exact(4).filter(|pixel| pixel[3] > 200 && pixel[..3].iter().max().unwrap() - pixel[..3].iter().min().unwrap() > 60).count();
    let families = engine.families_used("😀🌈🔥", &style(INTER, 17.0, 400));
    if families.iter().any(|family| family.to_lowercase().contains("emoji")) {
        assert!(emoji.inked() > 400, "emoji ink {}", emoji.inked());
        // Emoji are drawn in color, not as black outlines.
        assert!(colored > 100, "colored emoji pixels {colored}");
        // A heart and a sun with the emoji selector are emoji too, though Inter has plain glyphs for both;
        // without the selector they stay text, in the text color.
        let is_colored = |painted: &Painted| painted.pixels.chunks_exact(4).filter(|pixel| pixel[3] > 200 && pixel[..3].iter().max().unwrap() - pixel[..3].iter().min().unwrap() > 60).count();
        let selected = paint(&root(200, 40, &text_box("\u{2764}\u{fe0f} \u{2600}\u{fe0f}", 4.0, 4.0, 190.0, 22.0, "")), 400, 80, 2.0);
        assert!(is_colored(&selected) > 100, "colored pixels {}", is_colored(&selected));
        let bare = paint(&root(200, 40, &text_box("\u{2764} \u{2600}", 4.0, 4.0, 190.0, 22.0, "")), 400, 80, 2.0);
        assert_eq!(is_colored(&bare), 0);
        assert_eq!(engine.families_used("I \u{2764}\u{fe0f} it", &style(INTER, 17.0, 400)), ["Inter".to_owned(), families.iter().find(|family| family.to_lowercase().contains("emoji")).cloned().unwrap_or_default()]);
        // Measured as drawn: the line with the emoji is wider than the one with the narrow text glyph, or as wide.
        let style = style(INTER, 17.0, 400);
        assert!(engine.measure("\u{2764}\u{fe0f}", &style) > 10.0);
        assert_eq!(texts(&engine.lines("a \u{2764}\u{fe0f} b", &style, None)), ["a \u{2764}\u{fe0f} b"]);
    } else {
        println!("no emoji font is installed here ({families:?}); emoji are not checked");
    }
}

// MARK: - Boxes

#[test]
fn boxes_are_filled_clipped_and_rounded() {
    let child = boxed("\"left\":\"-10px\",\"top\":\"-10px\",\"width\":\"50px\",\"height\":\"50px\",\"backgroundColor\":\"#ff0000\"", "");
    let painted = paint(&root(100, 100, &boxed("\"left\":\"10px\",\"top\":\"10px\",\"width\":\"80px\",\"height\":\"80px\",\"backgroundColor\":\"rgb(0, 0, 255)\",\"borderRadius\":\"20px\",\"overflow\":\"hidden\"", &format!(",\"c\":[{child}]"))), 200, 200, 2.0);
    // Outside the box, and in the cut-off corner of the rounded outline.
    assert_eq!(painted.pixel(10, 10).3, 0);
    assert_eq!(painted.pixel(24, 24).3, 0);
    // The child is clipped by the rounded corner but shows inside it.
    assert_eq!(painted.pixel(60, 60), RED);
    // The rest of the box is blue.
    assert_eq!(painted.pixel(140, 140), BLUE);
    // A percentage radius is an ellipse.
    let circle = paint(&root(100, 100, &boxed("\"left\":\"0px\",\"top\":\"0px\",\"width\":\"100px\",\"height\":\"100px\",\"backgroundColor\":\"#00ff00\",\"borderRadius\":\"50%\"", "")), 100, 100, 1.0);
    assert_eq!(circle.pixel(5, 5).3, 0);
    assert_eq!(circle.pixel(50, 50), GREEN);
    // Percentages place and size a box against its parent; a dashed border is drawn on its edge.
    let nested = boxed("\"left\":\"50%\",\"top\":\"25%\",\"width\":\"50%\",\"height\":\"50%\",\"backgroundColor\":\"#ff0000\"", "");
    let percent = paint(&root(100, 100, &boxed("\"left\":\"0px\",\"top\":\"0px\",\"width\":\"80px\",\"height\":\"40px\",\"border\":\"1px dashed rgb(0, 0, 255)\"", &format!(",\"c\":[{nested}]"))), 100, 100, 1.0);
    assert_eq!(percent.pixel(60, 20), RED);
    assert_eq!(percent.pixel(30, 20).3, 0);
    assert!((0..80).filter(|x| percent.pixel(*x, 0).2 > 100).count() > 20, "dashes along the top edge");
    assert!((0..80).filter(|x| percent.pixel(*x, 0).3 == 0).count() > 20, "gaps along the top edge");
    // An element the layout did not write is skipped, and so is a style element.
    let skipped = paint(&root(10, 10, "{\"t\":\"style\",\"x\":\"div{}\"},{\"t\":\"\"}"), 10, 10, 1.0);
    assert_eq!(skipped.inked(), 0);
}

#[test]
fn opacity_transforms_and_hit_regions_follow_the_element() {
    let turned = "{\"t\":\"div\",\"s\":{\"position\":\"absolute\",\"left\":\"50px\",\"top\":\"50px\",\"width\":\"40px\",\"height\":\"20px\",\"backgroundColor\":\"#0000ff\",\"transform\":\"rotate(90deg)\"},\"d\":{\"swInteraction\":\"{\\\"type\\\":\\\"link\\\"}\"}}";
    let painted = paint(&root(100, 100, &format!("{},{turned}", boxed("\"left\":\"0px\",\"top\":\"0px\",\"width\":\"40px\",\"height\":\"40px\",\"backgroundColor\":\"#ff0000\",\"opacity\":\"0.5\"", ""))), 100, 100, 1.0);
    let faded = painted.pixel(20, 20);
    assert!((126..=129).contains(&faded.3) && (126..=129).contains(&faded.0), "{faded:?}");
    // The 40x20 box turned a quarter about its centre (70, 60) covers x 60..80, y 40..80.
    assert_eq!(painted.pixel(70, 45), BLUE);
    assert_eq!(painted.pixel(54, 60).3, 0);
    assert_eq!(painted.hit_regions.len(), 1);
    let hit = &painted.hit_regions[0];
    assert_eq!(hit.interaction.opt_string("type"), "link");
    for (actual, expected) in [(hit.bounds.left, 60.0), (hit.bounds.top, 40.0), (hit.bounds.right, 80.0), (hit.bounds.bottom, 80.0)] {
        assert!((actual - expected).abs() < 0.01, "{:?}", hit.bounds);
    }
    // Tap regions are in points whatever the scale, and a malformed interaction is not a tap region.
    let button = "{\"t\":\"div\",\"s\":{\"position\":\"absolute\",\"left\":\"10px\",\"top\":\"20px\",\"width\":\"30px\",\"height\":\"40px\"},\"d\":{\"swInteraction\":\"{\\\"type\\\":\\\"button\\\",\\\"action\\\":\\\"go\\\"}\"}}";
    let broken = "{\"t\":\"div\",\"s\":{\"position\":\"absolute\",\"left\":\"0px\",\"top\":\"0px\",\"width\":\"5px\",\"height\":\"5px\"},\"d\":{\"swInteraction\":\"{not json\"}}";
    let scaled = paint(&root(100, 100, &format!("{button},{broken}")), 300, 300, 3.0);
    assert_eq!(scaled.hit_regions.len(), 1);
    assert_eq!(scaled.hit_regions[0].bounds, crate::Bounds { left: 10.0, top: 20.0, right: 40.0, bottom: 60.0 });
    assert_eq!(scaled.hit_regions[0].interaction.opt_string("action"), "go");
}

#[test]
fn gradients_and_shadows_are_painted() {
    let full = "\"left\":\"0px\",\"top\":\"0px\",\"width\":\"100px\",\"height\":\"100px\"";
    let linear = paint(&root(100, 100, &boxed(&format!("{full},\"backgroundImage\":\"linear-gradient(90deg, rgb(255, 0, 0) 0px, rgb(0, 0, 255) 100px)\""), "")), 100, 100, 1.0);
    let (start, end) = (linear.pixel(2, 50), linear.pixel(97, 50));
    assert!(start.0 > 240 && start.2 < 15 && end.2 > 240 && end.0 < 15, "{start:?} {end:?}");
    let radial = paint(&root(100, 100, &boxed(&format!("{full},\"backgroundImage\":\"radial-gradient(circle at 50px 50px, rgb(255, 255, 255) 0px, rgb(0, 0, 0) 50px)\""), "")), 100, 100, 1.0);
    assert!(radial.pixel(50, 50).0 > 240 && radial.pixel(2, 50).0 < 15);
    // A conic gradient starts at 12 o'clock and runs clockwise.
    let conic = paint(&root(100, 100, &boxed(&format!("{full},\"backgroundImage\":\"conic-gradient(from 0deg at 50px 50px, rgb(255, 0, 0) 0deg, rgb(0, 0, 255) 360deg)\""), "")), 100, 100, 1.0);
    let (just_after_twelve, just_before_twelve, six) = (conic.pixel(53, 10), conic.pixel(46, 10), conic.pixel(50, 90));
    assert!(just_after_twelve.0 > 235 && just_before_twelve.2 > 235, "{just_after_twelve:?} {just_before_twelve:?}");
    assert!((i32::from(six.0) - i32::from(six.2)).abs() < 12, "{six:?}");
    // `from` turns the start: at 90 degrees it is at 3 o'clock.
    let turned = paint(&root(100, 100, &boxed(&format!("{full},\"backgroundImage\":\"conic-gradient(from 90deg at 50px 50px, rgb(255, 0, 0) 0deg, rgb(0, 0, 255) 360deg)\""), "")), 100, 100, 1.0);
    assert!(turned.pixel(90, 53).0 > 235 && turned.pixel(90, 46).2 > 235, "{:?} {:?}", turned.pixel(90, 53), turned.pixel(90, 46));
    // A gradient sized for a larger view is moved behind a smaller outline.
    let moved = paint(&root(100, 100, &boxed("\"left\":\"0px\",\"top\":\"0px\",\"width\":\"50px\",\"height\":\"50px\",\"backgroundImage\":\"linear-gradient(90deg, rgb(255, 0, 0) 0px, rgb(0, 0, 255) 200px)\",\"backgroundSize\":\"200px 50px\",\"backgroundPosition\":\"-150px 0px\"", "")), 100, 100, 1.0);
    assert!(moved.pixel(45, 25).2 > 230 && moved.pixel(45, 25).0 < 25, "{:?}", moved.pixel(45, 25));
    // A stop that fades out keeps its color: no gray fringe half way.
    let fading = paint(&root(100, 100, &boxed(&format!("{full},\"backgroundImage\":\"linear-gradient(90deg, rgba(255, 0, 0, 1) 0px, rgba(0, 0, 255, 0) 100px)\""), "")), 100, 100, 1.0);
    let middle = fading.pixel(50, 50);
    assert!((120..=135).contains(&middle.3) && middle.0 > 115 && middle.2 < 12, "{middle:?}");

    // A drop shadow lies under and beside the element, softly.
    let shadow = paint(&root(100, 100, &boxed("\"left\":\"30px\",\"top\":\"30px\",\"width\":\"30px\",\"height\":\"30px\",\"backgroundColor\":\"#ffffff\",\"filter\":\"drop-shadow(8px 8px 3px rgba(0, 0, 0, 1))\"", "")), 100, 100, 1.0);
    assert_eq!(shadow.pixel(45, 45), (255, 255, 255, 255));
    let cast = shadow.pixel(64, 64);
    assert!(cast.3 > 200 && cast.0 < 30, "{cast:?}");
    assert_eq!(shadow.pixel(10, 10).3, 0);
    assert!((1..=254).contains(&shadow.pixel(70, 50).3), "{:?}", shadow.pixel(70, 50));
    // At twice the scale the shadow is as far away and as soft, in points.
    let doubled = paint(&root(100, 100, &boxed("\"left\":\"30px\",\"top\":\"30px\",\"width\":\"30px\",\"height\":\"30px\",\"backgroundColor\":\"#ffffff\",\"filter\":\"drop-shadow(8px 8px 3px rgba(0, 0, 0, 1))\"", "")), 200, 200, 2.0);
    assert!(doubled.pixel(128, 128).3 > 200 && doubled.pixel(20, 20).3 == 0);
    assert!((i32::from(doubled.pixel(140, 100).3) - i32::from(shadow.pixel(70, 50).3)).abs() < 40, "{:?} {:?}", doubled.pixel(140, 100), shadow.pixel(70, 50));
    // A box shadow is drawn under the box, an inset one as an inner border.
    let outer = paint(&root(100, 100, &boxed("\"left\":\"30px\",\"top\":\"30px\",\"width\":\"30px\",\"height\":\"30px\",\"backgroundColor\":\"#ffffff\",\"boxShadow\":\"0px 10px 6px rgba(0, 0, 0, 0.5)\"", "")), 100, 100, 1.0);
    assert!((60..=140).contains(&outer.pixel(45, 66).3), "{:?}", outer.pixel(45, 66));
    let inset = paint(&root(100, 100, &boxed("\"left\":\"30px\",\"top\":\"30px\",\"width\":\"30px\",\"height\":\"30px\",\"boxShadow\":\"inset 0 0 0 2px rgb(255, 0, 0)\"", "")), 100, 100, 1.0);
    assert_eq!(inset.pixel(31, 45), RED);
    assert_eq!(inset.pixel(45, 45).3, 0);
}

/// A view turned in 3D with perspective is still drawn, narrower than flat.
#[test]
fn perspective_rotation_is_drawn() {
    let flat = paint(&root(100, 100, &boxed("\"left\":\"20px\",\"top\":\"20px\",\"width\":\"60px\",\"height\":\"60px\",\"backgroundColor\":\"#ff0000\"", "")), 200, 200, 2.0);
    let turned = paint(&root(100, 100, &boxed("\"left\":\"20px\",\"top\":\"20px\",\"width\":\"60px\",\"height\":\"60px\",\"backgroundColor\":\"#ff0000\",\"transform\":\"perspective(300px) rotate3d(0, 1, 0, 50deg)\"", "")), 200, 200, 2.0);
    let (flat_bounds, turned_bounds) = (flat.ink_bounds(), turned.ink_bounds());
    assert!(turned.inked() > 2000, "{}", turned.inked());
    assert!(turned_bounds.2 - turned_bounds.0 < flat_bounds.2 - flat_bounds.0 - 20, "{flat_bounds:?} {turned_bounds:?}");
    // One side is nearer than the other: the two vertical edges have different heights.
    let column_height = |x: usize| (0..200).filter(|y| turned.pixel(x, *y).3 > 128).count();
    let (left, right) = (column_height(turned_bounds.0 as usize + 3), column_height(turned_bounds.2 as usize - 3));
    assert!(left.abs_diff(right) > 6, "{left} {right}");
    assert_eq!(turned.pixel(100, 100), RED);
}

// MARK: - SVG

#[test]
fn svg_shapes_strokes_and_dashes_are_drawn() {
    let children = [
        shape("rect", "\"x\":\"0\",\"y\":\"0\",\"width\":\"10\",\"height\":\"10\",\"fill\":\"#ff0000\""),
        shape("path", "\"d\":\"M30 0h10v10h-10z M32 2v6h6v-6z\",\"fill\":\"currentColor\",\"fill-rule\":\"evenodd\""),
        shape("circle", "\"cx\":\"25\",\"cy\":\"30\",\"r\":\"10\",\"fill\":\"none\",\"stroke\":\"#0000ff\",\"stroke-width\":\"4\",\"pathLength\":\"100\",\"stroke-dasharray\":\"25 75\""),
        shape("line", "\"x1\":\"0\",\"y1\":\"48\",\"x2\":\"50\",\"y2\":\"48\",\"stroke\":\"#00ff00\",\"stroke-width\":\"2\""),
    ]
    .join(",");
    let painted = paint(&root(100, 100, &svg("\"width\":\"100\",\"height\":\"100\",\"viewBox\":\"0 0 50 50\"", &children, ",\"color\":\"rgb(0, 128, 0)\"")), 100, 100, 1.0);
    // The view box doubles everything.
    assert_eq!(painted.pixel(10, 10), RED);
    assert_eq!(painted.pixel(30, 10).3, 0);
    // currentColor is the CSS color; the even-odd hole stays empty.
    assert_eq!(painted.pixel(62, 10), (0, 128, 0, 255));
    assert_eq!(painted.pixel(70, 10).3, 0);
    // A quarter of the circle is stroked: from 3 o'clock clockwise to 6 o'clock.
    assert_eq!(painted.pixel(64, 74), BLUE);
    assert_eq!(painted.pixel(36, 46).3, 0);
    assert_eq!(painted.pixel(64, 46).3, 0);
    assert_eq!(painted.pixel(36, 74).3, 0);
    assert_eq!(painted.pixel(50, 96), GREEN);
}

/// A ring drawn as one dash as long as its outline closes, and a dash offset moves the start.
#[test]
fn a_full_ring_closes_and_a_dash_offset_turns_it() {
    let ring = |dashes: &str, extra: &str| {
        let circle = shape("circle", &format!("\"cx\":\"50\",\"cy\":\"50\",\"r\":\"40\",\"fill\":\"none\",\"stroke\":\"#ff0000\",\"stroke-width\":\"8\",\"pathLength\":\"100\",\"stroke-dasharray\":\"{dashes}\"{extra}"));
        paint(&root(100, 100, &svg("\"width\":\"100\",\"height\":\"100\"", &circle, "")), 300, 300, 3.0)
    };
    let full = ring("100 100", "");
    // Every point of the ring's centre line is red, also just before the start at 3 o'clock.
    for degrees in (0..360).step_by(3) {
        let angle = (degrees as f32).to_radians();
        let (x, y) = ((150.0 + 120.0 * angle.cos()) as usize, (150.0 + 120.0 * angle.sin()) as usize);
        assert_eq!(full.pixel(x, y), RED, "{degrees} degrees");
    }
    // The root turned back a quarter starts at 12 o'clock, as the progress rings do.
    let circle = shape("circle", "\"cx\":\"50\",\"cy\":\"50\",\"r\":\"40\",\"fill\":\"none\",\"stroke\":\"#ff0000\",\"stroke-width\":\"8\",\"pathLength\":\"100\",\"stroke-dasharray\":\"25 100\",\"stroke-linecap\":\"butt\"");
    let quarter = paint(&root(100, 100, &svg("\"width\":\"100\",\"height\":\"100\"", &circle, ",\"transform\":\"rotate(-90deg)\"")), 100, 100, 1.0);
    // From 12 to 3 o'clock: the upper right is stroked, the other three quarters are not.
    assert_eq!(quarter.pixel(78, 22), RED);
    for (x, y) in [(78, 78), (22, 78), (22, 22)] {
        assert_eq!(quarter.pixel(x, y).3, 0, "{x},{y}");
    }
    // A negative offset of a quarter moves the dash on by a quarter of the outline: from 6 to 9 o'clock.
    let offset = ring("25 100", ",\"stroke-dashoffset\":\"-25\"");
    assert_eq!(offset.pixel(66, 234), RED, "the lower left quarter");
    assert_eq!(offset.pixel(234, 234).3, 0);
    assert_eq!(offset.pixel(234, 66).3, 0);
    // A positive one moves it back, off the start of the outline; what follows is the gap.
    assert_eq!(ring("25 200", ",\"stroke-dashoffset\":\"25\"").inked(), 0);
    // The pattern repeats: past the gap the next dash shows at the end of the outline, before 3 o'clock.
    let wrapped = ring("25 100", ",\"stroke-dashoffset\":\"40\"");
    assert_eq!(wrapped.pixel(264, 105), RED);
    assert_eq!(wrapped.pixel(264, 195).3, 0);
    // A dash of no length draws nothing, not even a round dot.
    assert_eq!(ring("0 100", ",\"stroke-linecap\":\"round\"").inked(), 0);
}

#[test]
fn svg_arcs_masks_and_transforms_are_drawn() {
    // A half disc on the right of x = 50, drawn with an arc.
    let arc = paint(&root(100, 100, &svg("\"width\":\"100\",\"height\":\"100\"", &shape("path", "\"d\":\"M50 10 A40 40 0 0 1 50 90 Z\",\"fill\":\"#ff0000\""), "")), 100, 100, 1.0);
    assert_eq!(arc.pixel(70, 50), RED);
    assert_eq!(arc.pixel(30, 50).3, 0);
    // A mask keeps the drawing where the mask is white.
    let mask = format!("{{\"t\":\"mask\",\"g\":1,\"a\":{{\"id\":\"m\"}},\"c\":[{}]}}", shape("rect", "\"x\":\"0\",\"y\":\"0\",\"width\":\"50\",\"height\":\"100\",\"fill\":\"white\""));
    let masked = paint(&root(100, 100, &svg("\"width\":\"100\",\"height\":\"100\"", &format!("{mask},{}", shape("rect", "\"x\":\"10\",\"y\":\"10\",\"width\":\"80\",\"height\":\"80\",\"fill\":\"#0000ff\",\"mask\":\"url(#m)\"")), "")), 100, 100, 1.0);
    assert_eq!(masked.pixel(30, 50), BLUE);
    assert_eq!(masked.pixel(70, 50).3, 0);
    // A black part of the mask hides the drawing, and a gray part lets half of it through.
    let shaded = format!(
        "{{\"t\":\"mask\",\"g\":1,\"a\":{{\"id\":\"m\"}},\"c\":[{},{}]}}",
        shape("rect", "\"x\":\"0\",\"y\":\"0\",\"width\":\"100\",\"height\":\"100\",\"fill\":\"white\""),
        shape("rect", "\"x\":\"0\",\"y\":\"0\",\"width\":\"50\",\"height\":\"50\",\"fill\":\"black\"") + "," + &shape("rect", "\"x\":\"50\",\"y\":\"0\",\"width\":\"50\",\"height\":\"50\",\"fill\":\"#808080\"")
    );
    let partly = paint(&root(100, 100, &svg("\"width\":\"100\",\"height\":\"100\"", &format!("{shaded},{}", shape("rect", "\"x\":\"0\",\"y\":\"0\",\"width\":\"100\",\"height\":\"100\",\"fill\":\"#0000ff\",\"mask\":\"url(#m)\"")), "")), 100, 100, 1.0);
    assert_eq!(partly.pixel(25, 25).3, 0);
    assert!((120..=136).contains(&partly.pixel(75, 25).3), "{:?}", partly.pixel(75, 25));
    assert_eq!(partly.pixel(50, 75), BLUE);
    // What is drawn before the masked element is not touched by its mask.
    let behind = shape("rect", "\"x\":\"60\",\"y\":\"40\",\"width\":\"30\",\"height\":\"20\",\"fill\":\"#00ff00\"");
    let kept = paint(&root(100, 100, &svg("\"width\":\"100\",\"height\":\"100\"", &format!("{mask},{behind},{}", shape("rect", "\"x\":\"10\",\"y\":\"10\",\"width\":\"80\",\"height\":\"80\",\"fill\":\"#0000ff\",\"mask\":\"url(#m)\"")), "")), 100, 100, 1.0);
    assert_eq!(kept.pixel(70, 50), GREEN);
    assert_eq!(kept.pixel(30, 50), BLUE);
    // A group transform moves and turns its children.
    let group = format!("{{\"t\":\"g\",\"g\":1,\"a\":{{\"transform\":\"translate(50 50) rotate(90)\",\"opacity\":\"0.5\"}},\"c\":[{}]}}", shape("rect", "\"x\":\"0\",\"y\":\"0\",\"width\":\"40\",\"height\":\"10\",\"fill\":\"#ff0000\""));
    let moved = paint(&root(100, 100, &svg("\"width\":\"100\",\"height\":\"100\"", &group, "")), 100, 100, 1.0);
    assert!((126..=129).contains(&moved.pixel(45, 70).3), "{:?}", moved.pixel(45, 70));
    assert_eq!(moved.pixel(70, 55).3, 0);
    // Text in an SVG is anchored at its x.
    let label = "{\"t\":\"text\",\"g\":1,\"a\":{\"x\":\"50\",\"y\":\"30\",\"text-anchor\":\"middle\",\"font-size\":\"16\",\"fill\":\"#ff0000\"},\"x\":\"HHHH\"}";
    let anchored = paint(&root(100, 100, &svg("\"width\":\"100\",\"height\":\"100\"", label, "")), 100, 100, 1.0).ink_bounds();
    assert!(((anchored.0 + anchored.2) as f32 / 2.0 - 50.0).abs() < 2.0 && anchored.3 <= 31 && anchored.3 >= 28, "{anchored:?}");
}

// MARK: - Images

/// A `width` x `height` PNG: red on the left half, blue on the right.
fn two_color_png(width: i32, height: i32) -> Vec<u8> {
    let mut pixels = Vec::with_capacity((width * height * 4) as usize);
    for _ in 0..height {
        for x in 0..width {
            pixels.extend_from_slice(if x < width / 2 { &[255, 0, 0, 255] } else { &[0, 0, 255, 255] });
        }
    }
    crate::encode_png(&pixels, width as u32, height as u32).expect("PNG")
}

fn image_source(files: &[(&str, Vec<u8>)], gif_time: Option<u64>) -> PackageImageSource {
    let files = MemoryPackageFiles::new([], files.iter().map(|(path, data)| ((*path).to_owned(), data.clone())));
    PackageImageSource::new(Some(Arc::new(files)), HashMap::new(), gif_time)
}

fn image_element(source: &str, fit: &str) -> String {
    format!("{{\"t\":\"img\",\"s\":{{\"position\":\"absolute\",\"left\":\"10px\",\"top\":\"10px\",\"width\":\"80px\",\"height\":\"40px\",\"objectFit\":\"{fit}\"}},\"a\":{{\"src\":{}}}}}", quote(source))
}

#[test]
fn images_are_fitted_into_their_box() {
    let mut text = engine();
    let mut images = image_source(&[("art/square.png", two_color_png(40, 40))], None);
    assert_eq!(images.size("res:art/square.png"), Some((40, 40)));
    // contain: the square is 40 points wide in the middle of the 80-point box.
    let contain = paint_with(&root(100, 60, &image_element("res:art/square.png", "contain")), 100, 60, 1.0, &mut text, &mut images);
    assert_eq!(contain.pixel(15, 30).3, 0);
    assert_eq!(contain.pixel(40, 30), RED);
    assert_eq!(contain.pixel(60, 30), BLUE);
    assert_eq!(contain.pixel(85, 30).3, 0);
    // cover: the square fills the width and is cut above and below; nothing leaves the box.
    let cover = paint_with(&root(100, 60, &image_element("res:art/square.png", "cover")), 100, 60, 1.0, &mut text, &mut images);
    assert_eq!(cover.pixel(15, 30), RED);
    assert_eq!(cover.pixel(85, 30), BLUE);
    assert_eq!(cover.pixel(50, 5).3, 0);
    assert_eq!(cover.pixel(50, 55).3, 0);
    // fill stretches.
    let fill = paint_with(&root(100, 60, &image_element("res:art/square.png", "fill")), 100, 60, 1.0, &mut text, &mut images);
    assert_eq!(fill.pixel(12, 12), RED);
    assert_eq!(fill.pixel(88, 48), BLUE);
    // An inline image is decoded from its data URL.
    let inline = format!("data:image/png;base64,{}", base64(&two_color_png(8, 8)));
    assert_eq!(images.size(&inline), Some((8, 8)));
    assert_eq!(paint_with(&root(100, 60, &image_element(&inline, "fill")), 100, 60, 1.0, &mut text, &mut images).pixel(12, 12), RED);
}

#[test]
fn images_that_cannot_be_shown_are_left_out() {
    let mut text = engine();
    let mut images = image_source(&[("broken.png", b"\x89PNG\r\n\x1a\nnot really".to_vec()), ("empty.png", Vec::new()), ("text.png", b"hello".to_vec())], None);
    for source in ["res:broken.png", "res:empty.png", "res:text.png", "res:missing.png", "res:../outside.png", "https://example.com/not-fetched.png", "data:image/png;base64,@@@", "file:///etc/passwd", ""] {
        assert_eq!(images.size(source), None, "{source}");
        let painted = paint_with(&root(100, 60, &image_element(source, "contain")), 100, 60, 1.0, &mut text, &mut images);
        assert_eq!(painted.inked(), 0, "{source}");
    }
    // A header that announces more pixels than the limit is refused before anything is allocated.
    let mut huge = two_color_png(4, 4);
    huge[16..20].copy_from_slice(&60_000u32.to_be_bytes());
    huge[20..24].copy_from_slice(&60_000u32.to_be_bytes());
    let mut images = image_source(&[("huge.png", huge)], None);
    assert_eq!(images.size("res:huge.png"), None);
}

#[test]
fn a_large_image_is_reduced_for_a_small_box() {
    let mut images = image_source(&[("photo.png", two_color_png(512, 512))], None);
    let small = images.image("res:photo.png", 32 * 32).expect("image");
    assert!(small.width() <= 64 && small.width() >= 32, "{}", small.width());
    let large = images.image("res:photo.png", 512 * 512).expect("image");
    assert_eq!(large.width(), 512);
    // The natural size is still the file's.
    assert_eq!(images.size("res:photo.png"), Some((512, 512)));
}

#[test]
fn a_gif_shows_the_frame_of_the_requested_moment_and_reports_its_timing() {
    let data = crate::gif::tests::gif(8, 8, &[(1, 20), (2, 30), (3, 50)]);
    let element = root(100, 60, &image_element("res:cat.gif", "fill"));
    let mut text = engine();
    for (time, color) in [(None, RED), (Some(0), RED), (Some(250), GREEN), (Some(600), BLUE), (Some(1000), RED), (Some(1000 + 499), GREEN)] {
        let mut images = image_source(&[("cat.gif", data.clone())], time);
        let painted = paint_with(&element, 100, 60, 1.0, &mut text, &mut images);
        assert_eq!(painted.pixel(50, 30), color, "{time:?}");
        assert_eq!(painted.gif_slots.len(), 1);
        let slot = &painted.gif_slots[0];
        assert_eq!((slot.source.as_str(), slot.delays.as_slice()), ("res:cat.gif", &[200, 300, 500][..]));
        assert_eq!(slot.bounds, crate::Bounds { left: 10.0, top: 10.0, right: 90.0, bottom: 50.0 });
    }
    // A GIF of one frame is a picture, not an animation.
    let mut images = image_source(&[("still.gif", crate::gif::tests::gif(8, 8, &[(2, 0)]))], Some(500));
    let still = paint_with(&root(100, 60, &image_element("res:still.gif", "fill")), 100, 60, 1.0, &mut text, &mut images);
    assert_eq!(still.pixel(50, 30), GREEN);
    assert!(still.gif_slots.is_empty());
}

fn base64(data: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut text = String::new();
    for chunk in data.chunks(3) {
        let value = u32::from(chunk[0]) << 16 | u32::from(*chunk.get(1).unwrap_or(&0)) << 8 | u32::from(*chunk.get(2).unwrap_or(&0));
        for index in 0..4 {
            text.push(if index <= chunk.len() { ALPHABET[(value >> (18 - 6 * index) & 63) as usize] as char } else { '=' });
        }
    }
    text
}

// MARK: - Lists

#[test]
fn a_list_drawn_in_place_keeps_only_the_visible_tap_targets() {
    let row = |index: usize| format!("{{\"t\":\"div\",\"s\":{{\"position\":\"absolute\",\"left\":\"0px\",\"top\":\"{}px\",\"width\":\"100px\",\"height\":\"20px\",\"backgroundColor\":\"#ff0000\"}},\"d\":{{\"swListRow\":\"1\",\"swInteraction\":\"{{\\\"type\\\":\\\"toggle\\\",\\\"stateKey\\\":\\\"row.{index}\\\"}}\"}}}}", index * 25);
    let rows: Vec<String> = (0..10).map(row).collect();
    let list = format!("{{\"t\":\"div\",\"s\":{{\"position\":\"absolute\",\"left\":\"10px\",\"top\":\"30px\",\"width\":\"100px\",\"height\":\"60px\"}},\"d\":{{\"swList\":\"{{\\\"contentHeight\\\":245}}\"}},\"c\":[{}]}}", rows.join(","));
    let painted = paint(&root(120, 120, &list), 120, 120, 1.0);
    // Rows 0 to 2 reach into the 60 points that show; the third is cut off at the list's lower edge.
    assert_eq!(painted.hit_regions.iter().map(|hit| hit.interaction.opt_string("stateKey")).collect::<Vec<_>>(), ["row.0", "row.1", "row.2"]);
    assert_eq!(painted.hit_regions[2].bounds, crate::Bounds { left: 10.0, top: 80.0, right: 110.0, bottom: 90.0 });
    assert_eq!(painted.pixel(50, 85), RED);
    assert_eq!(painted.pixel(50, 95).3, 0);
    assert_eq!(painted.pixel(50, 110).3, 0);
}
