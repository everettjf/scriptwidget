// Phase 0 spike: can skia-safe draw a medium widget (329x170 pt at scale 2) on aarch64 Linux?
// Throwaway code. Usage: skia-spike <out-dir> [latin-font-family]

use std::{collections::BTreeSet, env, fs, path::PathBuf, time::Instant};

use skia_safe::{
    gradient_shader, surfaces,
    textlayout::{FontCollection, Paragraph, ParagraphBuilder, ParagraphStyle, TextStyle},
    Color, Data, EncodedImageFormat, FontMgr, Image, Paint, PaintStyle, PathBuilder, Point, RRect,
    Rect, SamplingOptions, TileMode,
};

const W: i32 = 658;
const H: i32 = 340;

fn paragraph(
    fonts: &FontCollection,
    text: &str,
    families: &[&str],
    size: f32,
    color: Color,
    max_lines: Option<usize>,
    width: f32,
) -> Paragraph {
    let mut style = ParagraphStyle::new();
    if let Some(n) = max_lines {
        style.set_max_lines(n);
        style.set_ellipsis("\u{2026}");
    }
    let mut ts = TextStyle::new();
    ts.set_font_size(size);
    ts.set_color(color);
    if !families.is_empty() {
        ts.set_font_families(families);
    }
    // Without a locale the CJK fallback is whichever Noto Sans CJK face fontconfig lists first.
    if let Ok(locale) = env::var("SPIKE_LOCALE") {
        ts.set_locale(locale);
    }
    let mut b = ParagraphBuilder::new(&style, fonts);
    b.push_style(&ts);
    b.add_text(text);
    let mut p = b.build();
    p.layout(width);
    p
}

fn report(label: &str, text: &str, p: &Paragraph) {
    let mut used = BTreeSet::new();
    for info in p.get_fonts() {
        let slice: String = text.get(info.text_range.clone()).unwrap_or("?").to_string();
        used.insert(format!(
            "{} <- {:?}",
            info.font.typeface().family_name(),
            slice
        ));
    }
    println!(
        "[{label}] lines={} height={:.1} longest_line={:.1} exceeded_max_lines={}",
        p.line_number(),
        p.height(),
        p.longest_line(),
        p.did_exceed_max_lines()
    );
    for u in used {
        println!("    font: {u}");
    }
}

fn make_test_png() -> Vec<u8> {
    // A 64x64 PNG made here, written to disk, then decoded again below from its bytes.
    let mut s = surfaces::raster_n32_premul((64, 64)).unwrap();
    let c = s.canvas();
    c.clear(Color::from_argb(255, 255, 200, 0));
    let mut p = Paint::default();
    p.set_anti_alias(true);
    p.set_color(Color::from_argb(255, 220, 40, 60));
    c.draw_circle((32, 32), 22.0, &p);
    p.set_color(Color::WHITE);
    c.draw_rect(Rect::from_xywh(26.0, 14.0, 12.0, 36.0), &p);
    let img = s.image_snapshot();
    img.encode(None, EncodedImageFormat::PNG, None)
        .unwrap()
        .as_bytes()
        .to_vec()
}

fn main() {
    let out: PathBuf = env::args().nth(1).unwrap_or_else(|| "out".into()).into();
    let latin = env::args().nth(2).unwrap_or_else(|| "Liberation Sans".into());
    fs::create_dir_all(&out).unwrap();

    let png_in = out.join("input.png");
    fs::write(&png_in, make_test_png()).unwrap();

    let t_fonts = Instant::now();
    let mut fonts = FontCollection::new();
    // System font manager = fontconfig on Linux. Used for both named families and fallback.
    fonts.set_default_font_manager(FontMgr::new(), None);
    let fonts_ms = t_fonts.elapsed().as_secs_f64() * 1000.0;

    let latin_text = "ScriptWidget on Linux — Hello, 329×170 pt";
    let zh_text = "今天多云，气温 18°C，适合出门散步";
    let emoji_text = "Emoji: 😀 🌤️ 🚀 ❤️ 👨‍👩‍👧 🇨🇳 ✅";
    let wrap_text = "Measured multi-line text: 这一段中英文混排的文字需要自动换行并在第二行末尾截断，the layout must report its height before drawing.";

    let mut timings = Vec::new();
    let mut last = None;
    // Run 1 is cold (font lookup and fallback caches empty); later runs are warm.
    for run in 0..5 {
        let t = Instant::now();
        let mut surface = surfaces::raster_n32_premul((W, H)).expect("raster surface");
        let canvas = surface.canvas();
        canvas.clear(Color::TRANSPARENT);

        // Rounded background with a linear gradient.
        let mut bg = Paint::default();
        bg.set_anti_alias(true);
        bg.set_shader(gradient_shader::linear(
            (Point::new(0.0, 0.0), Point::new(W as f32, H as f32)),
            [
                Color::from_argb(255, 30, 60, 114),
                Color::from_argb(255, 42, 82, 152),
                Color::from_argb(255, 126, 87, 194),
            ]
            .as_ref(),
            None,
            TileMode::Clamp,
            None,
            None,
        ));
        let rr = RRect::new_rect_xy(Rect::from_wh(W as f32, H as f32), 44.0, 44.0);
        canvas.draw_rrect(rr, &bg);

        let text_w = W as f32 - 64.0 - 150.0;
        let p1 = paragraph(&fonts, latin_text, &[latin.as_str()], 28.0, Color::WHITE, Some(1), W as f32 - 64.0);
        p1.paint(canvas, (32.0, 24.0));
        let p2 = paragraph(&fonts, zh_text, &[], 26.0, Color::WHITE, Some(1), W as f32 - 64.0);
        p2.paint(canvas, (32.0, 24.0 + p1.height() + 6.0));
        let y3 = 24.0 + p1.height() + 6.0 + p2.height() + 6.0;
        let p3 = paragraph(&fonts, emoji_text, &[latin.as_str()], 26.0, Color::WHITE, Some(1), W as f32 - 64.0);
        p3.paint(canvas, (32.0, y3));
        let y4 = y3 + p3.height() + 8.0;
        let p4 = paragraph(
            &fonts,
            wrap_text,
            &[latin.as_str()],
            20.0,
            Color::from_argb(220, 255, 255, 255),
            Some(2),
            text_w,
        );
        p4.paint(canvas, (32.0, y4));

        // Line chart.
        let data = [0.30f32, 0.42, 0.35, 0.60, 0.52, 0.75, 0.68, 0.90, 0.80, 0.95];
        let chart = Rect::from_xywh(32.0, 232.0, text_w, 80.0);
        let mut pb = PathBuilder::new();
        for (i, v) in data.iter().enumerate() {
            let x = chart.left + chart.width() * i as f32 / (data.len() - 1) as f32;
            let y = chart.bottom - chart.height() * v;
            if i == 0 {
                pb.move_to((x, y));
            } else {
                pb.line_to((x, y));
            }
        }
        let path = pb.detach();
        let mut stroke = Paint::default();
        stroke.set_anti_alias(true);
        stroke.set_style(PaintStyle::Stroke);
        stroke.set_stroke_width(5.0);
        stroke.set_stroke_join(skia_safe::paint::Join::Round);
        stroke.set_stroke_cap(skia_safe::paint::Cap::Round);
        stroke.set_color(Color::from_argb(255, 120, 255, 190));
        canvas.draw_path(&path, &stroke);

        // Decode the PNG from bytes and draw it scaled 64 -> 120.
        let bytes = fs::read(&png_in).unwrap();
        let img = Image::from_encoded(Data::new_copy(&bytes)).expect("decode png");
        let dst = Rect::from_xywh(W as f32 - 32.0 - 120.0, H as f32 - 32.0 - 120.0, 120.0, 120.0);
        canvas.draw_image_rect_with_sampling_options(
            &img,
            None,
            dst,
            SamplingOptions::new(skia_safe::FilterMode::Linear, skia_safe::MipmapMode::None),
            &Paint::default(),
        );

        let draw_ms = t.elapsed().as_secs_f64() * 1000.0;
        let t = Instant::now();
        let png = surface
            .image_snapshot()
            .encode(None, EncodedImageFormat::PNG, None)
            .unwrap();
        let encode_ms = t.elapsed().as_secs_f64() * 1000.0;
        timings.push((draw_ms, encode_ms));

        if run == 0 {
            report("latin", latin_text, &p1);
            report("chinese", zh_text, &p2);
            report("emoji", emoji_text, &p3);
            report("wrapped", wrap_text, &p4);
            println!("decoded image: {}x{}", img.width(), img.height());
        }
        last = Some(png);
    }

    let png = last.unwrap();
    let file = out.join(env::var("SPIKE_OUT").unwrap_or_else(|_| "widget.png".into()));
    fs::write(&file, png.as_bytes()).unwrap();
    println!("font manager setup: {fonts_ms:.2} ms");
    for (i, (d, e)) in timings.iter().enumerate() {
        println!("run {}: draw {d:.2} ms, png encode {e:.2} ms", i + 1);
    }
    println!("wrote {} ({} bytes, {W}x{H})", file.display(), png.len());
}
