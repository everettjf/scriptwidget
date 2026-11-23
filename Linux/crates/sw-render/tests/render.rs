//! The renderer as a host uses it: layout in the shared web renderer, then
//! paint. Ported from `Windows/tests/ScriptWidget.Core.Tests/Render/RenderTests.cs`;
//! pixels are premultiplied RGBA here. The corpus run is in `corpus.rs`.
//!
//!   node Linux/scripts/build-shared-js.mjs
//!   cargo test -p sw-render --test render

use std::path::PathBuf;
use std::sync::{Arc, OnceLock};

use serde_json::{Value, json};
use sw_core::{MemoryPackageFiles, PackageFiles, SharedScripts};
use sw_render::{RenderOutput, RenderRequest, WidgetRenderer, cjk_region_order, family_size};

const FIXED_NOW: i64 = 1_767_268_800_000;

fn linux_directory() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn scripts() -> Arc<SharedScripts> {
    static SCRIPTS: OnceLock<Arc<SharedScripts>> = OnceLock::new();
    SCRIPTS.get_or_init(|| Arc::new(SharedScripts::new(linux_directory().join("assets/scriptwidget")).expect("shared scripts: run node Linux/scripts/build-shared-js.mjs"))).clone()
}

/// One renderer (and its layout context) for the whole file; calls from the test threads are queued to its thread.
fn renderer() -> &'static WidgetRenderer {
    static RENDERER: OnceLock<WidgetRenderer> = OnceLock::new();
    RENDERER.get_or_init(|| WidgetRenderer::with_locale(scripts(), "en-US").expect("render thread"))
}

fn render(tree: &str, width: f32, height: f32, scale: f32) -> RenderOutput {
    renderer().render(RenderRequest::new(tree, width, height, scale)).expect("render")
}

/// Red, green, blue, alpha of one pixel.
fn pixel(output: &RenderOutput, x: u32, y: u32) -> (u8, u8, u8, u8) {
    let at = ((y * output.pixel_width + x) * 4) as usize;
    (output.pixels[at], output.pixels[at + 1], output.pixels[at + 2], output.pixels[at + 3])
}

fn count(pixels: &[u8], matches: impl Fn(&[u8]) -> bool) -> usize {
    pixels.chunks_exact(4).filter(|pixel| matches(pixel)).count()
}

fn is_red(pixel: &[u8]) -> bool {
    pixel == [255, 0, 0, 255]
}

fn corpus_tree(name: &str) -> String {
    static CORPUS: OnceLock<Value> = OnceLock::new();
    let corpus = CORPUS.get_or_init(|| serde_json::from_str(&std::fs::read_to_string(linux_directory().join("tests/assets/parity-corpus.json")).expect("parity corpus")).expect("corpus JSON"));
    corpus["corpus"].as_array().into_iter().flatten().find(|item| item["name"] == name).and_then(|item| item["expected"]["tree"].as_str()).unwrap_or_else(|| panic!("{name} is not in the corpus")).to_owned()
}

const RED_CARD: &str = r##"{"$element":"vstack","props":{"frame":"max","background":"#ff0000"},"children":[{"$element":"text","props":{"color":"white"},"children":["Hello"]}]}"##;

// MARK: - Output

#[test]
fn the_widget_families_have_the_desktop_sizes() {
    assert_eq!(family_size("small"), Some((170.0, 170.0)));
    assert_eq!(family_size("medium"), Some((329.0, 170.0)));
    assert_eq!(family_size("large"), Some((329.0, 345.0)));
    assert_eq!(family_size("extraLarge"), Some((639.0, 345.0)));
    assert_eq!(family_size("accessoryCircular"), None);
    // The bitmap is the size in points times the scale, for every family.
    for (family, width, height) in sw_render::FAMILY_SIZES {
        for scale in [1.0f32, 1.5, 2.0] {
            let rendered = renderer().render(RenderRequest::for_family(RED_CARD, family, scale).expect("family")).expect("render");
            assert_eq!((rendered.pixel_width, rendered.pixel_height), ((width * scale).ceil() as u32, (height * scale).ceil() as u32), "{family} at {scale}");
            assert_eq!(rendered.scale, scale);
            assert_eq!(pixel(&rendered, 0, 0), (255, 0, 0, 255));
            // The last column and row are partly covered when the size is not a whole number of pixels.
            assert_eq!(pixel(&rendered, rendered.pixel_width - 2, rendered.pixel_height - 2), (255, 0, 0, 255));
            assert_eq!(pixel(&rendered, rendered.pixel_width - 1, rendered.pixel_height - 1).3 == 255, (width * scale).fract() == 0.0 && (height * scale).fract() == 0.0);
        }
    }
    assert!(RenderRequest::for_family(RED_CARD, "huge", 1.0).is_none());
}

/// The bitmap budget lowers the scale instead of failing, and the PNG keeps the pixels.
#[test]
fn the_bitmap_budget_scales_the_output_and_png_keeps_the_pixels() {
    let full = render(RED_CARD, 200.0, 100.0, 2.0);
    assert_eq!((full.pixel_width, full.pixel_height, full.scale), (400, 200, 2.0));
    let mut request = RenderRequest::new(RED_CARD, 200.0, 100.0, 2.0);
    request.maximum_bitmap_bytes = 80_000;
    let limited = renderer().render(request).expect("render");
    assert!(limited.scale < 2.0 && limited.scale > 0.9, "scale {}", limited.scale);
    assert!(u64::from(limited.pixel_width) * u64::from(limited.pixel_height) * 4 <= 82_000, "{}x{}", limited.pixel_width, limited.pixel_height);
    assert!(count(&limited.pixels, is_red) > (limited.pixel_width * limited.pixel_height / 2) as usize);

    let png = full.encode_png().expect("PNG");
    assert_eq!(&png[..8], b"\x89PNG\r\n\x1a\n");
    let image = skia_safe::Image::from_encoded(skia_safe::Data::new_copy(&png)).expect("decoded PNG");
    assert_eq!((image.width() as u32, image.height() as u32), (full.pixel_width, full.pixel_height));
    let info = skia_safe::ImageInfo::new((image.width(), image.height()), skia_safe::ColorType::RGBA8888, skia_safe::AlphaType::Premul, None);
    let mut decoded = vec![0u8; full.pixels.len()];
    assert!(image.read_pixels(&info, decoded.as_mut_slice(), info.min_row_bytes(), (0, 0), skia_safe::image::CachingHint::Disallow));
    // Straight alpha and back may move a translucent channel by a step or two.
    for (at, (left, right)) in decoded.iter().zip(&full.pixels).enumerate() {
        assert!(left.abs_diff(*right) <= 2, "byte {at}: {left} vs {right}");
    }
    // The straight pixels are what the PNG stores.
    let straight = full.straight_pixels();
    assert_eq!(straight.len(), full.pixels.len());
    for (straight, premultiplied) in straight.chunks_exact(4).zip(full.pixels.chunks_exact(4)) {
        assert_eq!(straight[3], premultiplied[3]);
        assert!(straight[0] >= premultiplied[0]);
    }
    assert!(sw_render::encode_png(&[0; 7], 2, 1).is_err());
    assert!(sw_render::encode_png(&[], 0, 0).is_err());
}

/// Outside the rounded widget background nothing is drawn: those pixels stay fully transparent.
#[test]
fn pixels_outside_the_rounded_background_are_transparent() {
    // A 120-point red square with 30-point corners, centred in a 170-point widget with a clear background.
    let tree = r##"{"$element":"zstack","props":{"frame":"max","background":"clear"},"children":[{"$element":"roundedrect","props":{"color":"#ff0000","frame":"120,120","radius":"30"},"children":[]}]}"##;
    let rendered = renderer().render(RenderRequest::for_family(tree, "small", 2.0).expect("family")).expect("render");
    assert_eq!((rendered.pixel_width, rendered.pixel_height), (340, 340));
    // The widget's own corners and edges.
    for (x, y) in [(0, 0), (339, 0), (0, 339), (339, 339), (170, 20), (20, 170), (170, 320), (320, 170)] {
        assert_eq!(pixel(&rendered, x, y), (0, 0, 0, 0), "{x},{y}");
    }
    // Inside the square's bounding box (50..290) but outside its rounded corners.
    for (x, y) in [(54, 54), (285, 54), (54, 285), (285, 285), (62, 58)] {
        assert_eq!(pixel(&rendered, x, y).3, 0, "{x},{y}");
    }
    // The square itself, up to the middle of each edge and well inside each corner arc.
    for (x, y) in [(170, 170), (170, 53), (53, 170), (286, 170), (170, 286), (75, 75), (265, 265)] {
        assert_eq!(pixel(&rendered, x, y), (255, 0, 0, 255), "{x},{y}");
    }
    // Only the anti-aliased edge is translucent, and premultiplied: no channel exceeds alpha.
    let red = count(&rendered.pixels, is_red);
    let clear = count(&rendered.pixels, |pixel| pixel[3] == 0);
    assert!((240 * 240 - 4 * 900 - 1500..=240 * 240).contains(&red), "{red} red pixels");
    assert!(340 * 340 - red - clear < 1500, "{} translucent pixels", 340 * 340 - red - clear);
    assert_eq!(count(&rendered.pixels, |pixel| pixel[0] > pixel[3] || pixel[1] > pixel[3] || pixel[2] > pixel[3]), 0);

    // A widget with its own background fills the bitmap; the host rounds its corners.
    let mut card = renderer().render(RenderRequest::for_family(RED_CARD, "small", 2.0).expect("family")).expect("render");
    assert_eq!(pixel(&card, 0, 0), (255, 0, 0, 255));
    // Its text is drawn in white on the red card.
    assert!(count(&card.pixels, |pixel| pixel == [255, 255, 255, 255]) > 50);
    sw_render::rounded_corners::apply(&mut card.pixels, 340, 340, sw_render::rounded_corners::DEFAULT_RADIUS * card.scale);
    assert_eq!(pixel(&card, 0, 0).3, 0);
    assert_eq!(pixel(&card, 170, 0), (255, 0, 0, 255));
}

/// A tree that is not one fails, and the renderer works again afterwards.
#[test]
fn a_malformed_tree_fails_and_the_next_render_works() {
    assert!(renderer().render(RenderRequest::new("{not json", 100.0, 100.0, 1.0)).is_err());
    assert!(count(&render(RED_CARD, 100.0, 100.0, 1.0).pixels, is_red) > 1000);
    // Sizes that cannot be a bitmap are refused rather than allocated.
    for (width, height, scale) in [(0.0, 100.0, 1.0), (100.0, -1.0, 1.0), (100.0, 100.0, 0.0), (f32::NAN, 100.0, 1.0), (100.0, f32::INFINITY, 1.0)] {
        assert!(renderer().render(RenderRequest::new(RED_CARD, width, height, scale)).is_err(), "{width} x {height} at {scale}");
    }
    // A request for an enormous bitmap is cut down to the largest side instead of exhausting memory.
    let mut request = RenderRequest::new(RED_CARD, 100.0, 10.0, 1000.0);
    request.maximum_bitmap_bytes = 4 * 1024 * 1024;
    let limited = renderer().render(request).expect("render");
    assert!(u64::from(limited.pixel_width) * u64::from(limited.pixel_height) * 4 <= 4 * 1024 * 1024 + 65536, "{}x{}", limited.pixel_width, limited.pixel_height);
    // A tree nested far deeper than any widget either renders or fails; it does not take the renderer down.
    for depth in [60usize, 400, 5000] {
        let tree = format!("{}{}{}", r##"{"$element":"zstack","props":{"background":"#ff0000"},"children":["##.repeat(depth), r##"{"$element":"text","props":null,"children":["deep"]}"##, "]}".repeat(depth));
        match renderer().render(RenderRequest::new(tree, 100.0, 100.0, 1.0)) {
            Ok(rendered) => assert_eq!(rendered.pixels.len(), 100 * 100 * 4, "{depth} levels"),
            Err(error) => assert!(depth > 60 && !error.message.is_empty(), "{depth} levels: {error}"),
        }
        assert!(count(&render(RED_CARD, 100.0, 100.0, 1.0).pixels, is_red) > 1000, "after {depth} levels");
    }
    // Releasing the layout context only costs the time to make it again.
    renderer().release();
    assert!(count(&render(RED_CARD, 100.0, 100.0, 1.0).pixels, is_red) > 1000);
}

/// The layout records what the painter draws; a host can read it for diagnosis.
#[test]
fn the_layout_is_a_tree_of_recorded_elements() {
    let layout: Value = serde_json::from_str(&renderer().layout(RenderRequest::new(RED_CARD, 100.0, 100.0, 1.0)).expect("layout")).expect("layout JSON");
    assert_eq!(layout["width"], json!(100));
    assert_eq!(layout["root"]["s"]["width"], json!("100px"));
    assert!(layout["root"]["c"].as_array().is_some_and(|children| !children.is_empty()));
    assert!(layout["diagnostics"].is_array());
}

// MARK: - Tap regions

fn types(output: &RenderOutput) -> Vec<&str> {
    output.hit_regions.iter().map(|hit| hit.interaction.get("type").and_then(Value::as_str).unwrap_or("?")).collect()
}

fn text<'a>(output: &'a RenderOutput, index: usize, name: &str) -> Option<&'a str> {
    output.hit_regions[index].interaction.get(name).and_then(Value::as_str)
}

#[test]
fn buttons_toggles_and_links_are_tap_regions() {
    let mut request = RenderRequest::for_family(corpus_tree("component/button"), "medium", 2.0).expect("family");
    request.now_milliseconds = Some(FIXED_NOW);
    let buttons = renderer().render(request).expect("render");
    assert_eq!(buttons.hit_regions.len(), 2, "{:?}", buttons.hit_regions);
    for hit in &buttons.hit_regions {
        // In points, inside the widget, whatever the scale of the bitmap.
        assert!(hit.bounds.left >= 0.0 && hit.bounds.top >= 0.0 && hit.bounds.right <= 329.5 && hit.bounds.bottom <= 170.5, "{:?}", hit.bounds);
        assert!(hit.bounds.width() > 20.0 && hit.bounds.height() > 10.0, "{:?}", hit.bounds);
    }
    // The first button calls a function of the script, the second reloads the widget.
    assert_eq!(types(&buttons), ["button", "button"]);
    assert_eq!((text(&buttons, 0, "handler"), text(&buttons, 0, "action")), (Some("onButtonClick"), None));
    assert_eq!((text(&buttons, 1, "handler"), text(&buttons, 1, "action")), (None, Some("reload")));
    assert!(buttons.hit_regions[0].bounds.bottom <= buttons.hit_regions[1].bounds.top + 0.5, "the buttons are stacked");
    // The same regions at another scale.
    let mut request = RenderRequest::for_family(corpus_tree("component/button"), "medium", 1.0).expect("family");
    request.now_milliseconds = Some(FIXED_NOW);
    assert_eq!(renderer().render(request).expect("render").hit_regions, buttons.hit_regions);

    let toggle = renderer().render(RenderRequest::for_family(corpus_tree("component/toggle"), "medium", 2.0).expect("family")).expect("render");
    assert_eq!(types(&toggle), ["toggle"]);
    assert_eq!(text(&toggle, 0, "handler"), Some("onToggleClick"));
    assert_eq!(toggle.hit_regions[0].interaction.get("on"), Some(&json!(true)));

    // Three links, and the whole widget is a link too: it is painted first, so it lies under them.
    let links = renderer().render(RenderRequest::for_family(corpus_tree("component/link"), "medium", 2.0).expect("family")).expect("render");
    assert_eq!(types(&links), ["link", "link", "link", "link"]);
    assert_eq!((0..4).map(|index| text(&links, index, "url").unwrap_or("")).collect::<Vec<_>>(), ["https://atomsprout.com/scriptwidget", "https://www.baidu.com", "https://www.google.com", "https://www.bing.com"]);
    assert!(links.hit_regions[0].bounds.width() > 300.0 && links.hit_regions[0].bounds.height() > 150.0, "{:?}", links.hit_regions[0].bounds);
    for hit in &links.hit_regions[1..] {
        assert!(hit.bounds.intersect(&links.hit_regions[0].bounds) == Some(hit.bounds), "{:?}", hit.bounds);
    }

    // A widget without controls has no tap regions.
    assert!(render(RED_CARD, 100.0, 100.0, 1.0).hit_regions.is_empty());
}

// MARK: - Lists and theme colors (Android inputs that the shared layout still understands)

fn list_tree(rows: usize) -> String {
    let items: Vec<String> = (1..=rows).map(|row| format!(r##"{{"$element":"toggle","props":{{"stateKey":"check.{row}","on":false}},"children":[{{"$element":"text","props":{{"color":"material.primary"}},"children":["Row {row}"]}}]}}"##)).collect();
    format!(
        r##"{{"$element":"vstack","props":{{"frame":"max","alignment":"leading","background":"material.surface"}},"children":[{{"$element":"text","props":null,"children":["Header"]}},{{"$element":"list","props":{{"spacing":"2"}},"children":[{}]}}]}}"##,
        items.join(",")
    )
}

fn test_colors() -> Value {
    json!({ "light": { "primary": [255, 0, 0, 1], "surface": [0, 0, 255, 1] }, "dark": { "primary": [0, 255, 0, 1], "surface": [10, 20, 30, 1] } })
}

/// A desktop does not scroll: the list is drawn in place and only the visible rows can be tapped.
#[test]
fn a_list_is_drawn_in_place_with_its_visible_tap_targets() {
    let mut request = RenderRequest::new(list_tree(40), 338.0, 300.0, 2.0);
    request.family = "large".into();
    request.colors = Some(test_colors());
    let rendered = renderer().render(request).expect("render");
    assert!((3..=15).contains(&rendered.hit_regions.len()), "{} tap regions", rendered.hit_regions.len());
    for hit in &rendered.hit_regions {
        assert!(hit.bounds.top >= 0.0 && hit.bounds.bottom <= 300.5, "{:?}", hit.bounds);
    }
    let keys: Vec<&str> = rendered.hit_regions.iter().filter_map(|hit| hit.interaction.get("stateKey").and_then(Value::as_str)).collect();
    assert_eq!(keys[..3], ["check.1", "check.2", "check.3"]);
    // The rows are part of the bitmap, in the theme color, on the theme surface.
    assert!(count(&rendered.pixels, is_red) > 500);
    assert_eq!(pixel(&rendered, 4, rendered.pixel_height - 4), (0, 0, 255, 255));
}

/// The dark bitmap takes the dark palette. Linux has no wallpaper palette: without one, and for a role
/// a palette leaves out, the names are the fixed colors that iPhone, iPad and Mac draw.
#[test]
fn theme_colors_follow_the_appearance_and_are_fixed_without_a_palette() {
    let mut request = RenderRequest::new(list_tree(3), 200.0, 200.0, 1.0);
    request.dark_mode = true;
    request.colors = Some(test_colors());
    assert_eq!(pixel(&renderer().render(request).expect("render"), 2, 198), (10, 20, 30, 255));
    // No palette: `material.surface` of the baseline Material 3 scheme, #FEF7FF in light mode and #141218 in dark mode.
    assert_eq!(pixel(&render(&list_tree(3), 200.0, 200.0, 1.0), 2, 198), (0xFE, 0xF7, 0xFF, 255));
    let mut dark = RenderRequest::new(list_tree(3), 200.0, 200.0, 1.0);
    dark.dark_mode = true;
    assert_eq!(pixel(&renderer().render(dark).expect("render"), 2, 198), (0x14, 0x12, 0x18, 255));
    // A malformed palette does not fail the render: its roles are the fixed colors too.
    let mut request = RenderRequest::new(list_tree(3), 200.0, 200.0, 1.0);
    request.colors = Some(json!({ "light": { "surface": "red", "primary": [1, 2] } }));
    assert_eq!(pixel(&renderer().render(request).expect("render"), 2, 198), (0xFE, 0xF7, 0xFF, 255));
    // A role that does not exist is still ignored: the widget keeps the system background, white in light mode.
    let unknown = r##"{"$element":"vstack","props":{"frame":"max","background":"material.nothing"},"children":[]}"##;
    assert_eq!(pixel(&render(unknown, 200.0, 200.0, 1.0), 2, 198), (255, 255, 255, 255));
}

// MARK: - Dates and animation

/// A date is drawn into the bitmap; the host renders again when it changes.
#[test]
fn a_timer_is_drawn_as_text_and_follows_the_clock_of_the_request() {
    let tree = r##"{"$element":"vstack","props":{"frame":"max"},"children":[{"$element":"date","props":{"date":"now","style":"timer","color":"#ff0000"},"children":[]}]}"##;
    let at = |now: i64| {
        let mut request = RenderRequest::new(tree, 200.0, 100.0, 2.0);
        request.now_milliseconds = Some(now);
        renderer().render(request).expect("render")
    };
    let first = at(FIXED_NOW);
    assert!(count(&first.pixels, is_red) > 20, "the date text is drawn in red");
    // The same moment gives the same bitmap, byte for byte.
    assert!(first.pixels == at(FIXED_NOW).pixels);
}

/// Clock hands are drawn where the time of the request puts them.
#[test]
fn an_animated_clock_shows_the_time_of_the_request() {
    let tree = corpus_tree("template/Animation Clock");
    let at = |now: i64| {
        let mut request = RenderRequest::for_family(tree.clone(), "small", 2.0).expect("family");
        request.now_milliseconds = Some(now);
        renderer().render(request).expect("render")
    };
    let noon = at(FIXED_NOW);
    assert!(count(&noon.pixels, |pixel| pixel[3] != 0) > 1000);
    assert!(noon.pixels == at(FIXED_NOW).pixels, "the same moment draws the same clock");
    // A quarter of an hour later the minute hand has moved.
    assert!(noon.pixels != at(FIXED_NOW + 15 * 60 * 1000).pixels);
}

/// The clock template: three hands, each painted at the moment that is asked for.
#[test]
fn the_hands_of_the_animation_clock_are_posed_at_a_moment() {
    use sw_render::motion::{Hand, Motion};
    let tree = corpus_tree("template/Animation Clock");
    let request = |motion: Option<i64>| {
        let mut request = RenderRequest::for_family(tree.clone(), "small", 2.0).expect("family");
        // The text of the time is that of one fixed moment; only the hands follow `motion`.
        request.now_milliseconds = Some(FIXED_NOW);
        request.motion_milliseconds = motion;
        request
    };
    let at = |motion: Option<i64>| renderer().render(request(motion)).expect("render");
    let noon = at(Some(FIXED_NOW));
    let hands: Vec<Hand> = noon.motion_slots.iter().filter_map(|slot| if let Motion::Hand { hand, .. } = &slot.motion { Some(*hand) } else { None }).collect();
    assert_eq!(hands, [Hand::Second, Hand::Minute, Hand::Hour]);
    assert!(noon.motion_slots.iter().all(|slot| slot.motion.zone() == Some("current")));
    assert!(!noon.layout_reused);
    // The pose computed here is the one the shared renderer computes for the same moment.
    assert!(noon.pixels == at(None).pixels, "the moment of the layout");
    assert!(noon.pixels == at(Some(FIXED_NOW)).pixels, "the same moment draws the same clock");
    // One second moves the second hand; a quarter of an hour moves the minute hand too.
    let second = at(Some(FIXED_NOW + 1000));
    let quarter = at(Some(FIXED_NOW + 15 * 60_000));
    assert!(noon.pixels != second.pixels && noon.pixels != quarter.pixels && second.pixels != quarter.pixels);
    // Twelve hours later every hand is where it was.
    assert!(noon.pixels == at(Some(FIXED_NOW + 12 * 3_600_000)).pixels);

    // With a layout key the layout runs once; every later picture is painted from it, and is the same picture.
    let keyed = |motion: Option<i64>, key: u64| {
        let mut request = request(motion);
        request.layout_key = Some(key);
        renderer_of_its_own().render(request).expect("render")
    };
    let first = keyed(Some(FIXED_NOW), 7);
    assert!(!first.layout_reused && first.pixels == noon.pixels);
    let again = keyed(Some(FIXED_NOW + 1000), 7);
    assert!(again.layout_reused, "painted from the kept layout");
    assert!(again.pixels == second.pixels);
    assert_eq!(again.motion_slots, second.motion_slots);
    // At another scale too: the layout is in points.
    let mut small = request(Some(FIXED_NOW + 1000));
    small.layout_key = Some(7);
    small.scale = 1.0;
    let small = renderer_of_its_own().render(small).expect("render");
    assert!(small.layout_reused && small.pixel_width == 170);
    // Without a moment, a keyed render shows the time of the request, never the hands of an older layout.
    assert!(keyed(None, 7).pixels == noon.pixels);
    // Another key, another tree or another theme is laid out again.
    assert!(!keyed(Some(FIXED_NOW), 8).layout_reused);
    assert!(keyed(Some(FIXED_NOW), 8).layout_reused);
    let mut dark = request(Some(FIXED_NOW));
    dark.layout_key = Some(8);
    dark.dark_mode = true;
    assert!(!renderer_of_its_own().render(dark).expect("render").layout_reused);
    let mut other = RenderRequest::new(RED_CARD, 170.0, 170.0, 2.0);
    other.layout_key = Some(8);
    assert!(!renderer_of_its_own().render(other.clone()).expect("render").layout_reused);
    assert!(renderer_of_its_own().render(other.clone()).expect("render").layout_reused);
    // Releasing the layout context forgets the kept layout.
    renderer_of_its_own().release();
    assert!(!renderer_of_its_own().render(other).expect("render").layout_reused);
}

/// A renderer no other test draws with: what it keeps between two renders is this test's alone.
fn renderer_of_its_own() -> &'static WidgetRenderer {
    static RENDERER: OnceLock<WidgetRenderer> = OnceLock::new();
    RENDERER.get_or_init(|| WidgetRenderer::with_locale(scripts(), "en-US").expect("render thread"))
}

/// The aquarium template: three swings of 30, 40 and 60 seconds there and back.
#[test]
fn the_creatures_of_the_animation_aquarium_swing() {
    use sw_render::motion::Motion;
    let tree = corpus_tree("template/Animation Aquarium");
    let at = |motion: Option<i64>| {
        let mut request = RenderRequest::for_family(tree.clone(), "medium", 2.0).expect("family");
        request.now_milliseconds = Some(FIXED_NOW);
        request.motion_milliseconds = motion;
        renderer().render(request).expect("render")
    };
    let rest = at(None);
    assert!(!rest.motion_slots.is_empty());
    let mut periods: Vec<u64> = rest.motion_slots.iter().map(|slot| slot.motion.period_milliseconds().expect("a swing repeats")).collect();
    assert!(rest.motion_slots.iter().all(|slot| matches!(slot.motion, Motion::Swing { .. })));
    periods.sort_unstable();
    periods.dedup();
    assert_eq!(periods, [30_000, 40_000, 60_000]);
    // FIXED_NOW is a whole number of every cycle after 1970: every creature is at rest.
    assert!(rest.pixels == at(Some(FIXED_NOW)).pixels);
    let later = at(Some(FIXED_NOW + 5000));
    assert!(rest.pixels != later.pixels, "five seconds on, they have moved");
    assert!(later.pixels != at(Some(FIXED_NOW + 6000)).pixels);
    assert!(later.pixels == at(Some(FIXED_NOW + 5000)).pixels, "a moment has one picture");
    // After 120 seconds, the first moment all three cycles end together, the picture repeats.
    assert!(later.pixels == at(Some(FIXED_NOW + 125_000)).pixels);
    // A creature moves along one axis, by no more than its swing distance: 100 points for
    // the fish that swim across, 70 for those that rise and sink, 50 for the bubbles.
    for (still, moved) in rest.motion_slots.iter().zip(&later.motion_slots) {
        let (dx, dy) = (moved.bounds.left - still.bounds.left, moved.bounds.top - still.bounds.top);
        assert!(dx.abs() <= 100.0 && dy.abs() <= 70.0 && (dx != 0.0) != (dy != 0.0), "{dx} {dy}");
    }
}

/// A widget with no `animation` is the same picture at every moment.
#[test]
fn a_widget_that_does_not_move_ignores_the_moment() {
    let at = |motion: Option<i64>| {
        let mut request = RenderRequest::new(RED_CARD, 200.0, 100.0, 2.0);
        request.motion_milliseconds = motion;
        renderer().render(request).expect("render")
    };
    let still = at(None);
    assert!(still.motion_slots.is_empty());
    assert!(still.pixels == at(Some(FIXED_NOW)).pixels && still.pixels == at(Some(FIXED_NOW + 777)).pixels);
}

// MARK: - GIFs

/// A GIF of `frames` solid frames (1 red, 2 green, 3 blue) with delays in hundredths of a second.
fn gif(width: u16, height: u16, frames: &[(u8, u16)]) -> Vec<u8> {
    let mut data = Vec::new();
    data.extend_from_slice(b"GIF89a");
    data.extend_from_slice(&width.to_le_bytes());
    data.extend_from_slice(&height.to_le_bytes());
    data.extend_from_slice(&[0x91, 0, 0]);
    data.extend_from_slice(&[0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255]);
    for (color, delay) in frames {
        data.extend_from_slice(&[0x21, 0xF9, 4, 0]);
        data.extend_from_slice(&delay.to_le_bytes());
        data.extend_from_slice(&[0, 0, 0x2C, 0, 0, 0, 0]);
        data.extend_from_slice(&width.to_le_bytes());
        data.extend_from_slice(&height.to_le_bytes());
        data.extend_from_slice(&[0, 2]);
        // Three-bit codes; a clear code before every pixel keeps them three bits wide.
        let mut bits: Vec<bool> = Vec::new();
        let mut push = |code: u8| (0..3).for_each(|bit| bits.push(code >> bit & 1 == 1));
        for _ in 0..usize::from(width) * usize::from(height) {
            push(4);
            push(*color);
        }
        push(5);
        let bytes: Vec<u8> = bits.chunks(8).map(|chunk| chunk.iter().enumerate().fold(0u8, |byte, (bit, set)| byte | (u8::from(*set) << bit))).collect();
        for block in bytes.chunks(255) {
            data.push(block.len() as u8);
            data.extend_from_slice(block);
        }
        data.push(0);
    }
    data.push(0x3B);
    data
}

#[test]
fn a_gif_is_reported_with_its_delays_and_drawn_at_the_requested_moment() {
    let tree = r##"{"$element":"vstack","props":{"frame":"max","background":"clear"},"children":[{"$element":"gif","props":{"file":"spin","frame":"80,80"},"children":[]}]}"##;
    let files: Arc<dyn PackageFiles> = Arc::new(MemoryPackageFiles::new([], [("image/spin.gif".to_owned(), gif(16, 16, &[(1, 20), (2, 30), (3, 50)]))]));
    let at = |time: Option<u64>| {
        let mut request = RenderRequest::for_family(tree, "small", 2.0).expect("family");
        request.files = Some(files.clone());
        request.gif_time_milliseconds = time;
        renderer().render(request).expect("render")
    };
    let first = at(None);
    assert_eq!(first.gif_slots.len(), 1, "{:?}", first.diagnostics);
    let slot = &first.gif_slots[0];
    assert_eq!((slot.source.as_str(), slot.delays.as_slice()), ("res:image/spin.gif", &[200, 300, 500][..]));
    assert!(slot.bounds.width() > 40.0 && slot.bounds.height() > 40.0 && slot.bounds.left >= 0.0 && slot.bounds.right <= 170.5, "{:?}", slot.bounds);
    // A single render shows the first frame; a display layer asks for the later ones by time.
    let middle = |output: &RenderOutput| pixel(output, ((slot.bounds.left + slot.bounds.right) * output.scale / 2.0) as u32, ((slot.bounds.top + slot.bounds.bottom) * output.scale / 2.0) as u32);
    assert_eq!(middle(&first), (255, 0, 0, 255));
    assert_eq!(middle(&at(Some(0))), (255, 0, 0, 255));
    assert_eq!(middle(&at(Some(200))), (0, 255, 0, 255));
    assert_eq!(middle(&at(Some(999))), (0, 0, 255, 255));
    assert_eq!(middle(&at(Some(1000))), (255, 0, 0, 255));
    // The frames are also available on their own, bounded, for a host that composes them itself.
    let animation = sw_render::gif::decode(&gif(16, 16, &[(1, 20), (2, 30), (3, 50)])).expect("frames");
    assert_eq!((animation.width, animation.height, animation.frames.len()), (16, 16, 3));
    assert_eq!(animation.frames[2].pixels[..4], [0, 0, 255, 255]);

    // A file that is not an image leaves the widget drawn without it.
    let broken: Arc<dyn PackageFiles> = Arc::new(MemoryPackageFiles::new([], [("image/spin.gif".to_owned(), b"GIF89a broken".to_vec())]));
    let mut request = RenderRequest::for_family(tree, "small", 2.0).expect("family");
    request.files = Some(broken);
    let without = renderer().render(request).expect("render");
    assert!(without.gif_slots.is_empty());
}

// MARK: - Fonts

/// Which CJK face Chinese text is drawn with is decided by the locale, not left to the system's fallback order.
#[test]
fn chinese_text_uses_the_face_of_the_locale() {
    let own = WidgetRenderer::with_locale(scripts(), "zh-Hans").expect("render thread");
    let report = own.fonts().expect("fonts");
    assert!(report.bundled, "the bundled Inter was not loaded");
    assert_eq!(report.locale, "zh-Hans");
    // Latin text is the bundled Inter everywhere.
    assert_eq!(own.families_used("Widget 123", 400).expect("families"), ["Inter"]);
    println!("CJK families installed, in the order of zh-Hans: {:?}", report.cjk_families);
    if report.cjk_families.is_empty() {
        println!("no CJK font is installed on this machine; the face of Chinese text was not checked");
        return;
    }
    let chinese = "今天多云，适合出门散步";
    let simplified = own.families_used(chinese, 400).expect("families");
    assert_eq!(simplified, [report.cjk_families[0].clone()], "Chinese text is drawn with the first installed face of the locale");
    // The pan-CJK families carry the region in their name; when they are installed the choice is checked by name.
    let noto = |region: &str| format!("Noto Sans CJK {region}");
    if report.cjk_families.contains(&noto("SC")) && report.cjk_families.contains(&noto("KR")) && report.cjk_families.contains(&noto("JP")) && report.cjk_families.contains(&noto("TC")) {
        assert_eq!(simplified, [noto("SC")]);
        // Latin, Chinese and Korean in one line: Inter, then the Chinese face, which also has the Korean letters.
        assert_eq!(own.families_used("Hi 今天 한국어", 400).expect("families"), ["Inter".to_owned(), noto("SC")]);
        for (locale, region) in [("en-US", "SC"), ("zh-CN", "SC"), ("zh-TW", "TC"), ("zh-Hant-HK", "HK"), ("ja-JP", "JP"), ("ko-KR", "KR"), ("de-DE", "SC")] {
            own.set_locale(locale);
            let report = own.fonts().expect("fonts");
            assert_eq!(report.locale, locale);
            if !report.cjk_families.contains(&noto(region)) {
                println!("{} is not installed; {locale} was not checked", noto(region));
                continue;
            }
            assert_eq!(own.families_used(chinese, 400).expect("families"), [noto(region)], "{locale}");
            assert_eq!(own.families_used(chinese, 700).expect("families"), [noto(region)], "{locale}, bold");
        }
    } else {
        println!("the Noto Sans CJK families are not all installed; the per-locale choice was not checked by name");
    }
    // The order itself does not depend on what is installed.
    assert_eq!(cjk_region_order("zh-Hans")[0], sw_render::CjkRegion::SimplifiedChinese);
    assert_eq!(cjk_region_order("ko-KR")[0], sw_render::CjkRegion::Korean);
}

/// The renderer is used from several threads at once; every call is queued to its one thread.
#[test]
fn renders_from_several_threads_are_queued() {
    let expected = render(RED_CARD, 120.0, 60.0, 1.0).pixels;
    std::thread::scope(|scope| {
        for _ in 0..4 {
            scope.spawn(|| {
                for _ in 0..5 {
                    assert!(render(RED_CARD, 120.0, 60.0, 1.0).pixels == expected);
                }
            });
        }
    });
}
