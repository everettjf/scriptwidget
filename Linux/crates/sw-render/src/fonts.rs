//! Resolves the CSS font-family strings the shared renderer emits to Skia
//! font families. Ported from `Windows/src/ScriptWidget.Core/Render/FontRegistry.cs`.
//!
//! The default face is the bundled Inter, so layout is the same on every
//! machine. Chinese, Japanese and Korean text and emoji come from the system
//! fonts through fontconfig. Which CJK face is tried first is decided here,
//! from the locale: left to fontconfig, a machine without a configured
//! preference shows Chinese text with Korean glyph shapes.

use std::collections::HashMap;
use std::rc::Rc;

use skia_safe::font_arguments::variation_position::Coordinate;
use skia_safe::font_arguments::VariationPosition;
use skia_safe::font_style::{Slant, Width};
use skia_safe::textlayout::{FontCollection, TypefaceFontProvider};
use skia_safe::{Font, FontArguments, FontMgr, FontStyle, FourByteTag, Typeface};

/// The font that ships inside the program: Inter, the file the Android app
/// ships, embedded at build time from its asset folder. It is under the SIL
/// Open Font License (OFL-Inter.txt in that folder).
const INTER: &[u8] = include_bytes!("../../../../Android/core/src/main/assets/fonts/Inter.ttf");

/// Display fonts selectable with `font="custom,<name>,<size>"`: the names a
/// script may use, the alias the face is registered under, and the file name.
///
/// Unlike on Android and Windows these six are NOT inside the program: the
/// repository records no licence for them, so a Linux release does not
/// redistribute them. A file with one of these names in the optional font
/// folder (see [`display_font_folder`]) is used; without it the text is drawn
/// with Inter.
const DISPLAY_FONTS: &[(&[&str], &str, &str)] = &[
    (&["apple ][", "apple"], "sw-display-apple", "Apple ][.ttf"),
    (&["larabiefont free", "larabiefontfree"], "sw-display-larabiefont", "Larabiefont Free.ttf"),
    (&["monofonto"], "sw-display-monofonto", "Monofonto.ttf"),
    (&["white rabbit", "whiterabbit", "new"], "sw-display-whiterabbit", "New.ttf"),
    (&["oneslot"], "sw-display-oneslot", "OneSlot.ttf"),
    (&["unispace"], "sw-display-unispace", "Unispace.ttf"),
];

/// A display font file larger than this is ignored.
const MAXIMUM_DISPLAY_FONT_BYTES: u64 = 16 * 1024 * 1024;

/// Where optional display fonts are looked for: the folder `SCRIPTWIDGET_FONTS`
/// names, else `fonts` next to the `runtime` folder of the installed
/// resources (`share/scriptwidget/fonts`). `None` when neither exists. Unit
/// tests of this crate read the Android asset folder of the repository.
pub fn display_font_folder() -> Option<std::path::PathBuf> {
    static FOLDER: std::sync::OnceLock<Option<std::path::PathBuf>> = std::sync::OnceLock::new();
    FOLDER
        .get_or_init(|| {
            if let Some(value) = std::env::var_os("SCRIPTWIDGET_FONTS").filter(|value| !value.is_empty()) {
                let folder = std::path::PathBuf::from(value);
                return folder.is_absolute().then_some(folder);
            }
            if cfg!(test) {
                return Some(std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../Android/core/src/main/assets/fonts"));
            }
            let resources = sw_core::Resources::locate().ok()?;
            let folder = resources.runtime.parent()?.join("fonts");
            folder.is_dir().then_some(folder)
        })
        .clone()
}

/// The bytes of an optional display font, or `None` when it is not installed.
fn display_font_bytes(file: &str) -> Option<Vec<u8>> {
    let path = display_font_folder()?.join(file);
    let metadata = std::fs::symlink_metadata(&path).ok()?;
    if !metadata.is_file() || metadata.len() > MAXIMUM_DISPLAY_FONT_BYTES {
        return None;
    }
    std::fs::read(path).ok()
}

/// System families tried for the generic names: the one the user configured
/// for the generic name in fontconfig first, then common ones by name.
const MONOSPACE: &[&str] = &["monospace", "DejaVu Sans Mono", "Liberation Mono", "Noto Sans Mono", "Menlo", "Courier New"];
const SERIF: &[&str] = &["serif", "Noto Serif", "DejaVu Serif", "Liberation Serif", "Georgia", "Times New Roman"];
const SANS_SERIF: &[&str] = &["sans-serif", "Noto Sans", "DejaVu Sans", "Liberation Sans", "Helvetica Neue", "Arial"];
/// Color emoji families, the usual Linux one first.
const EMOJI: &[&str] = &["Noto Color Emoji", "Twemoji", "JoyPixels", "Apple Color Emoji", "Segoe UI Emoji"];
/// Names that fontconfig maps to whatever the user configured; other font managers do not know them.
const GENERIC_FAMILIES: &[&str] = &["monospace", "serif", "sans-serif"];

/// The script a locale reads Han characters in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CjkRegion {
    SimplifiedChinese,
    TraditionalChinese,
    HongKong,
    Japanese,
    Korean,
}

impl CjkRegion {
    /// Families that carry this region's glyph shapes, the usual Linux ones first.
    fn families(self) -> &'static [&'static str] {
        match self {
            Self::SimplifiedChinese => &["Noto Sans CJK SC", "Noto Sans SC", "Source Han Sans SC", "Source Han Sans CN", "WenQuanYi Micro Hei", "WenQuanYi Zen Hei", "PingFang SC", "Microsoft YaHei"],
            Self::TraditionalChinese => &["Noto Sans CJK TC", "Noto Sans TC", "Source Han Sans TC", "Source Han Sans TW", "PingFang TC", "Microsoft JhengHei"],
            Self::HongKong => &["Noto Sans CJK HK", "Noto Sans HK", "Source Han Sans HC", "Source Han Sans HK", "PingFang HK"],
            Self::Japanese => &["Noto Sans CJK JP", "Noto Sans JP", "Source Han Sans JP", "Source Han Sans", "IPAGothic", "Hiragino Sans"],
            Self::Korean => &["Noto Sans CJK KR", "Noto Sans KR", "Source Han Sans KR", "Source Han Sans K", "NanumGothic", "Apple SD Gothic Neo"],
        }
    }
}

/// The order in which CJK faces are tried for a BCP 47 locale tag. A Han
/// character exists in every one of them, so the first decides its shape:
/// the reader's own region comes first, and Simplified Chinese is the
/// default for every locale that is not Chinese, Japanese or Korean, as on
/// Android, where the bundled fallback is Noto Sans SC.
pub fn cjk_region_order(locale: &str) -> [CjkRegion; 5] {
    use CjkRegion::{HongKong, Japanese, Korean, SimplifiedChinese, TraditionalChinese};
    let lower = locale.to_ascii_lowercase().replace('_', "-");
    let mut parts = lower.split('-');
    let language = parts.next().unwrap_or("");
    let rest: Vec<&str> = parts.collect();
    let has = |subtag: &str| rest.contains(&subtag);
    match language {
        "ja" => [Japanese, SimplifiedChinese, TraditionalChinese, HongKong, Korean],
        "ko" => [Korean, SimplifiedChinese, TraditionalChinese, HongKong, Japanese],
        "zh" | "yue" | "cmn" => {
            // The script subtag decides; without one, the region does.
            let traditional = has("hant") || (!has("hans") && (has("tw") || has("hk") || has("mo") || language == "yue"));
            if traditional && (has("hk") || has("mo") || language == "yue") {
                [HongKong, TraditionalChinese, SimplifiedChinese, Japanese, Korean]
            } else if traditional {
                [TraditionalChinese, HongKong, SimplifiedChinese, Japanese, Korean]
            } else {
                [SimplifiedChinese, TraditionalChinese, HongKong, Japanese, Korean]
            }
        }
        _ => [SimplifiedChinese, TraditionalChinese, HongKong, Japanese, Korean],
    }
}

/// One resolved face: the families a paragraph asks for, in order, the
/// weight, and the ascent and descent of the first family as fractions of
/// the font size.
#[derive(Debug)]
pub struct Face {
    /// Names registered with the paragraph's own font provider, the face of the style first, then the CJK faces.
    pub families: Vec<String>,
    /// The real family name of the first face; empty when the style has no face of its own on this machine.
    pub primary: String,
    pub weight: i32,
    pub ascent: f32,
    pub descent: f32,
}

/// The name and the face of a system family at `weight`, or `None` when it
/// is not installed. Asking for a family that is missing does not fail:
/// fontconfig answers with its nearest substitute, so the answer only counts
/// when it is the family that was asked for. A generic name is answered with
/// the family the user configured for it.
fn installed(system: &FontMgr, family: &str, weight: i32) -> Option<(String, Typeface)> {
    let generic = GENERIC_FAMILIES.contains(&family);
    if generic && !cfg!(all(unix, not(target_os = "macos"))) {
        return None;
    }
    let typeface = system.match_family_style(family, FontStyle::new(weight.into(), Width::NORMAL, Slant::Upright))?;
    let name = typeface.family_name();
    (generic || name.eq_ignore_ascii_case(family)).then_some((name, typeface))
}

/// Every face a paragraph may name is registered here under a name of its
/// own, the system's faces included. A paragraph that named a system family
/// directly would have Skia look it up in fontconfig's list for that name,
/// which on a machine with substitution rules also holds other families, and
/// the face it picks from that list is not always the one that was asked for
/// (on the test machine it picked none, and text fell to the last-resort
/// fallback). The faces registered here are the ones fontconfig's own match
/// returns.
pub struct FontRegistry {
    collection: FontCollection,
    provider: TypefaceFontProvider,
    system: FontMgr,
    /// Makes typefaces from the bundled files.
    loader: FontMgr,
    inter: Option<Typeface>,
    /// Names already registered with `provider`, with their faces; `None` for a face that could not be made.
    registered: HashMap<String, Option<Typeface>>,
    cache: HashMap<String, Rc<Face>>,
    use_system_font: bool,
    locale: String,
    cjk: Vec<String>,
}

impl FontRegistry {
    /// `locale` is a BCP 47 tag; it orders the CJK faces (see [`cjk_region_order`]).
    pub fn new(locale: &str) -> Self {
        let system = FontMgr::new();
        // FreeType reads the bundled files on every platform that has it, so their metrics do not depend on the system.
        let loader = FontMgr::custom_empty().unwrap_or_else(|| system.clone());
        let provider = TypefaceFontProvider::new();
        let mut collection = FontCollection::new();
        collection.set_asset_font_manager(Some(provider.clone().into()));
        // Only for what the registered faces lack: emoji and other scripts.
        collection.set_default_font_manager(system.clone(), None);
        let inter = loader.new_from_bytes(INTER, None);
        let mut registry = Self { collection, provider, system, loader, inter, registered: HashMap::new(), cache: HashMap::new(), use_system_font: false, locale: String::new(), cjk: Vec::new() };
        registry.set_locale(locale);
        registry
    }

    pub fn collection(&self) -> &FontCollection {
        &self.collection
    }

    pub fn locale(&self) -> &str {
        &self.locale
    }

    /// The installed CJK families, in the order they are tried.
    pub fn cjk_families(&self) -> &[String] {
        &self.cjk
    }

    /// True when the bundled Inter could be loaded.
    pub fn has_bundled_font(&self) -> bool {
        self.inter.is_some()
    }

    pub fn set_locale(&mut self, locale: &str) {
        if locale == self.locale && !self.locale.is_empty() {
            return;
        }
        self.locale = if locale.is_empty() { "en-US".into() } else { locale.to_owned() };
        let mut cjk = Vec::new();
        for region in cjk_region_order(&self.locale) {
            for family in region.families() {
                if let Some((name, _)) = installed(&self.system, family, 400) {
                    cjk.push(name);
                }
            }
        }
        self.cjk = cjk;
        self.cache.clear();
    }

    /// When true, default-design text uses the machine's own sans-serif face.
    pub fn set_use_system_font(&mut self, value: bool) {
        if value != self.use_system_font {
            self.use_system_font = value;
            self.cache.clear();
        }
    }

    pub fn face(&mut self, family: &str, weight: i32) -> Rc<Face> {
        let clamped = weight.clamp(100, 900);
        let key = format!("{family}|{clamped}");
        if let Some(face) = self.cache.get(&key) {
            return face.clone();
        }
        if self.cache.len() > MAXIMUM_FACES {
            self.cache.clear();
        }
        let face = Rc::new(self.resolve(family, clamped));
        self.cache.insert(key, face.clone());
        face
    }

    fn resolve(&mut self, family: &str, weight: i32) -> Face {
        let first = family.split(',').next().unwrap_or("").trim().trim_matches('"');
        let lower = first.to_lowercase();
        if let Some((_, alias, file)) = DISPLAY_FONTS.iter().find(|(names, _, _)| names.contains(&lower.as_str())) {
            // A display font has one face; its weight is not synthesized, as on Android.
            // It is optional on Linux: without the file the text is drawn with Inter.
            let loader = self.loader.clone();
            if let Some(typeface) = self.register(alias, || display_font_bytes(file).and_then(|data| loader.new_from_bytes(&data, None))) {
                return self.finish(Some(((*alias).to_owned(), typeface)), 400);
            }
            return self.bundled(weight);
        }
        if lower == "ui-monospace" || lower.contains("mono") || lower == "consolas" {
            return self.system_face(MONOSPACE, weight);
        }
        if lower == "new york" || lower == "ui-serif" {
            return self.system_face(SERIF, weight);
        }
        if self.use_system_font {
            return self.system_face(SANS_SERIF, weight);
        }
        self.bundled(weight)
    }

    /// Inter is a variable font: each weight is its own instance, registered under its own name.
    fn bundled(&mut self, weight: i32) -> Face {
        let alias = format!("sw-inter-{weight}");
        let inter = self.inter.clone();
        let instance = self.register(&alias, || {
            let inter = inter?;
            let coordinates = [Coordinate { axis: FourByteTag::from_chars('w', 'g', 'h', 't'), value: weight as f32 }];
            let arguments = FontArguments::new().set_variation_design_position(VariationPosition { coordinates: &coordinates });
            inter.clone_with_arguments(&arguments).or(Some(inter))
        });
        match instance {
            Some(typeface) => self.finish(Some((alias, typeface)), weight),
            None => self.system_face(SANS_SERIF, weight),
        }
    }

    fn register(&mut self, alias: &str, make: impl FnOnce() -> Option<Typeface>) -> Option<Typeface> {
        if let Some(existing) = self.registered.get(alias) {
            return existing.clone();
        }
        let typeface = make();
        if let Some(typeface) = &typeface {
            self.provider.register_typeface(typeface.clone(), Some(alias));
        }
        self.registered.insert(alias.to_owned(), typeface.clone());
        typeface
    }

    /// The system family at `weight`, registered under a name of its own.
    fn system_family(&mut self, family: &str, weight: i32) -> Option<(String, Typeface)> {
        let alias = format!("sw-system-{weight}-{}", family.to_lowercase());
        let system = self.system.clone();
        let typeface = self.register(&alias, || installed(&system, family, weight).map(|(_, typeface)| typeface))?;
        Some((alias, typeface))
    }

    /// The registered name of the color emoji face, or `None` when the machine has none of the known ones.
    pub fn emoji_family(&mut self) -> Option<String> {
        EMOJI.iter().find_map(|family| self.system_family(family, 400)).map(|(alias, _)| alias)
    }

    fn system_face(&mut self, candidates: &[&str], weight: i32) -> Face {
        let first = candidates.iter().find_map(|family| self.system_family(family, weight));
        // With no candidate installed the text falls to the CJK faces and the system's fallback.
        self.finish(first, weight)
    }

    fn finish(&mut self, first: Option<(String, Typeface)>, weight: i32) -> Face {
        let (primary, ascent, descent) = match &first {
            Some((_, typeface)) => {
                let mut font = Font::from_typeface(typeface, METRICS_SIZE);
                font.set_linear_metrics(true).set_hinting(skia_safe::FontHinting::None).set_subpixel(true);
                let (_, metrics) = font.metrics();
                (typeface.family_name(), -metrics.ascent / METRICS_SIZE, metrics.descent / METRICS_SIZE)
            }
            // Typical metrics stand in for the unknown face.
            None => (String::new(), 1.079, 0.251),
        };
        let mut families: Vec<String> = first.into_iter().map(|(alias, _)| alias).collect();
        for family in self.cjk.clone() {
            if let Some((alias, _)) = self.system_family(&family, weight) {
                families.push(alias);
            }
        }
        Face { families, primary, weight, ascent, descent }
    }
}

const MAXIMUM_FACES: usize = 512;
/// Font metrics scale with the size; they are read once at this size.
const METRICS_SIZE: f32 = 100.0;

#[cfg(test)]
mod tests {
    use super::CjkRegion::{HongKong, Japanese, Korean, SimplifiedChinese, TraditionalChinese};
    use super::*;

    #[test]
    fn the_readers_region_comes_first() {
        for locale in ["zh-Hans", "zh-CN", "zh", "zh-Hans-HK", "zh_CN", "zh-SG", "cmn-Hans"] {
            assert_eq!(cjk_region_order(locale)[0], SimplifiedChinese, "{locale}");
        }
        for locale in ["zh-Hant", "zh-TW", "zh-Hant-TW", "zh_TW"] {
            assert_eq!(cjk_region_order(locale)[..2], [TraditionalChinese, HongKong], "{locale}");
        }
        for locale in ["zh-HK", "zh-Hant-HK", "zh-MO", "yue", "yue-Hant-HK"] {
            assert_eq!(cjk_region_order(locale)[..2], [HongKong, TraditionalChinese], "{locale}");
        }
        assert_eq!(cjk_region_order("ja-JP")[0], Japanese);
        assert_eq!(cjk_region_order("ko")[0], Korean);
    }

    #[test]
    fn other_locales_read_han_characters_as_simplified_chinese() {
        for locale in ["en-US", "de-DE", "", "C", "fr"] {
            assert_eq!(cjk_region_order(locale), [SimplifiedChinese, TraditionalChinese, HongKong, Japanese, Korean], "{locale}");
        }
        // Korean is never ahead of a Chinese face unless the locale is Korean.
        for locale in ["en-US", "zh-CN", "zh-TW", "zh-HK", "ja-JP"] {
            assert_eq!(cjk_region_order(locale)[4], Korean, "{locale}");
        }
    }

    #[test]
    fn every_region_is_tried() {
        for locale in ["en", "zh-TW", "zh-HK", "ja", "ko"] {
            let order = cjk_region_order(locale);
            for region in [SimplifiedChinese, TraditionalChinese, HongKong, Japanese, Korean] {
                assert!(order.contains(&region), "{locale}: {region:?}");
            }
        }
    }

    #[test]
    fn bundled_fonts_load_and_weights_are_separate_instances() {
        let mut fonts = FontRegistry::new("en-US");
        assert!(fonts.has_bundled_font());
        let regular = fonts.face("-apple-system, sans-serif", 400);
        let bold = fonts.face("-apple-system, sans-serif", 700);
        assert_eq!(regular.families[0], "sw-inter-400");
        assert_eq!(bold.families[0], "sw-inter-700");
        assert!(regular.ascent > 0.7 && regular.ascent < 1.3 && regular.descent > 0.1 && regular.descent < 0.5, "{regular:?}");
        // Out-of-range weights are clamped, and a face is resolved once.
        assert!(Rc::ptr_eq(&fonts.face("x", 1200), &fonts.face("x", 900)));
        for (name, alias) in [("Monofonto, sans-serif", "sw-display-monofonto"), ("\"Apple ][\"", "sw-display-apple"), ("New", "sw-display-whiterabbit"), ("OneSlot", "sw-display-oneslot"), ("unispace", "sw-display-unispace"), ("Larabiefont Free", "sw-display-larabiefont")] {
            let face = fonts.face(name, 700);
            assert_eq!((face.families[0].as_str(), face.weight), (alias, 400), "{name}");
        }
    }
}
