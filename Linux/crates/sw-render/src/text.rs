//! Text measurement and line breaking. The shared layout asks for sizes
//! through this module and the painter draws with it, so what was measured
//! is what gets drawn: both build the same Skia paragraph, with unhinted
//! glyphs at subpixel positions. All values are in points; the painter
//! scales the canvas. Ported from
//! `Windows/src/ScriptWidget.Core/Render/TextEngine.cs`.

use std::collections::HashMap;

use skia_safe::font::Edging;
use skia_safe::font_style::{Slant, Width};
use skia_safe::textlayout::{Paragraph, ParagraphBuilder, ParagraphStyle, TextDirection, TextStyle as ParagraphTextStyle};
use skia_safe::{Canvas, FontHinting, FontStyle, Paint};

use crate::fonts::FontRegistry;

/// Font description shared by measurement and drawing. Sizes are in points.
#[derive(Debug, Clone, PartialEq)]
pub struct TextStyle {
    pub family: String,
    pub size: f32,
    pub weight: i32,
    pub leading: f32,
}

#[derive(Debug, Clone, PartialEq)]
pub struct TextLine {
    pub text: String,
    pub width: f32,
}

pub struct TextEngine {
    fonts: FontRegistry,
    /// Widths of single lines; the layout asks for the same texts again and again.
    widths: HashMap<(String, i32, u32, String), f32>,
}

impl TextEngine {
    pub fn new(fonts: FontRegistry) -> Self {
        Self { fonts, widths: HashMap::new() }
    }

    pub fn fonts(&self) -> &FontRegistry {
        &self.fonts
    }

    /// For changing the locale or the default face; measured widths are forgotten.
    pub fn fonts_mut(&mut self) -> &mut FontRegistry {
        self.widths.clear();
        &mut self.fonts
    }

    /// The real family name of the face a CSS font-family resolves to; empty when the machine has none for it.
    pub fn primary_family(&mut self, family: &str, weight: i32) -> String {
        self.fonts.face(family, weight).primary.clone()
    }

    /// One paragraph of `text` in `style`, not laid out yet. `paint` colors the glyphs.
    fn paragraph(&mut self, text: &str, style: &TextStyle, paint: Option<&Paint>) -> Paragraph {
        let face = self.fonts.face(&style.family, style.weight);
        let mut text_style = ParagraphTextStyle::new();
        text_style
            .set_font_size(if style.size > 0.0 && style.size.is_finite() { style.size } else { 0.01 })
            .set_font_style(FontStyle::new(face.weight.into(), Width::NORMAL, Slant::Upright))
            .set_font_families(&face.families)
            // Fallback for what the listed families lack takes the locale into account too.
            .set_locale(self.fonts.locale())
            // Glyphs keep their measured shapes and positions at every scale: no fitting to the pixel grid.
            .set_subpixel(true)
            .set_font_hinting(FontHinting::None)
            // Grayscale: subpixel color fringes need an opaque background, and a widget bitmap is transparent.
            .set_font_edging(Edging::AntiAlias);
        if let Some(paint) = paint {
            text_style.set_foreground_paint(paint);
        }
        let mut paragraph_style = ParagraphStyle::new();
        paragraph_style
            .set_text_direction(TextDirection::LTR)
            .turn_hinting_off()
            // Skia otherwise lays out in the width rounded down to a whole number: a line measured
            // at 107.2 would not fit a box of 107.5, and the layout sizes boxes to measured widths.
            .set_apply_rounding_hack(false)
            .set_text_style(&text_style);
        // A character followed by the emoji variation selector is an emoji even when the text
        // face has a plain glyph for it, as Inter has for the heart and the sun.
        let emoji = if text.contains(EMOJI_SELECTOR) { self.fonts.emoji_family() } else { None };
        let mut builder = ParagraphBuilder::new(&paragraph_style, self.fonts.collection());
        builder.push_style(&text_style);
        match emoji {
            Some(emoji) => {
                let mut emoji_style = text_style.clone();
                emoji_style.set_font_families(&std::iter::once(&emoji).chain(&face.families).collect::<Vec<_>>());
                let mut plain = 0usize;
                for (start, end) in emoji_presentation_runs(text) {
                    builder.add_text(&text[plain..start]);
                    builder.push_style(&emoji_style).add_text(&text[start..end]).pop();
                    plain = end;
                }
                builder.add_text(&text[plain..]);
            }
            None => {
                builder.add_text(text);
            }
        }
        builder.build()
    }

    /// Width of `text` on one line, trailing spaces included.
    pub fn measure(&mut self, text: &str, style: &TextStyle) -> f32 {
        if text.is_empty() {
            return 0.0;
        }
        let key = (style.family.clone(), style.weight, style.size.to_bits(), text.to_owned());
        if let Some(width) = self.widths.get(&key) {
            return *width;
        }
        let mut paragraph = self.paragraph(text, style, None);
        paragraph.layout(UNBOUNDED);
        let width = paragraph.max_intrinsic_width();
        if self.widths.len() >= MAXIMUM_WIDTHS {
            self.widths.clear();
        }
        self.widths.insert(key, width);
        width
    }

    /// Lines of `text` in a box `width` points wide. Explicit newlines always
    /// break. With a width, text wraps like CSS `white-space: pre-wrap` with
    /// `overflow-wrap: break-word`; without one it does not wrap.
    pub fn lines(&mut self, text: &str, style: &TextStyle, width: Option<f32>) -> Vec<TextLine> {
        let mut result = Vec::new();
        for paragraph_text in text.split('\n') {
            if paragraph_text.is_empty() {
                result.push(TextLine { text: String::new(), width: 0.0 });
                continue;
            }
            let whole = self.measure(paragraph_text, style);
            let limit = match width {
                Some(limit) if whole > limit + 0.01 => limit,
                _ => {
                    result.push(TextLine { text: paragraph_text.to_owned(), width: whole });
                    continue;
                }
            };
            let mut paragraph = self.paragraph(paragraph_text, style, None);
            paragraph.layout(limit.max(0.01));
            let ends: Vec<usize> = paragraph.get_line_metrics().iter().map(|metrics| byte_offset(paragraph_text, metrics.end_index)).collect();
            let mut start = 0usize;
            for end in ends {
                // The end takes the spaces the line ends with.
                if end <= start || end >= paragraph_text.len() {
                    continue;
                }
                if !self.is_between_words(&paragraph_text[start..], end - start, style) {
                    // A word wider than the box: Skia fills the line before it with its first letters.
                    break;
                }
                let line = paragraph_text[start..end].trim_end_matches(' ');
                result.push(TextLine { text: line.to_owned(), width: self.measure(line, style) });
                start = end;
            }
            self.break_long_words(&paragraph_text[start..], style, limit, &mut result);
        }
        result
    }

    /// The rest of a paragraph line by line, as CSS `overflow-wrap:
    /// break-word` breaks it: a line ends inside a word only when it has no
    /// other place to break, so a word wider than the box starts on a line of
    /// its own. Skia alone would start it on the line before.
    fn break_long_words(&mut self, text: &str, style: &TextStyle, limit: f32, result: &mut Vec<TextLine>) {
        let mut rest = text;
        for _ in 0..MAXIMUM_BROKEN_LINES {
            let trimmed = rest.trim_end_matches(' ');
            if self.measure(trimmed, style) <= limit + 0.01 {
                break;
            }
            let mut paragraph = self.paragraph(rest, style, None);
            paragraph.layout(limit.max(0.01));
            // At least one character a line.
            let mut end = paragraph.get_line_metrics().first().map_or(0, |metrics| byte_offset(rest, metrics.end_index)).max(rest.chars().next().map_or(0, char::len_utf8));
            if end >= rest.len() {
                break;
            }
            if !self.is_between_words(rest, end, style) {
                end = self.last_break(&rest[..end], style).unwrap_or(end);
            }
            let line = rest[..end].trim_end_matches(' ');
            result.push(TextLine { text: line.to_owned(), width: self.measure(line, style) });
            rest = &rest[end..];
        }
        if !rest.is_empty() {
            let line = rest.trim_end_matches(' ');
            result.push(TextLine { text: line.to_owned(), width: self.measure(line, style) });
        }
    }

    /// Whether a line of `text` may end at `end`, a place the layout chose: true between two
    /// words, and inside a word when the line holds nothing but a part of that word.
    fn is_between_words(&mut self, text: &str, end: usize, style: &TextStyle) -> bool {
        match text[end..].chars().next() {
            None | Some(' ') => true,
            Some(next) => self.last_break(&text[..end + next.len_utf8()], style) == Some(end),
        }
    }

    /// The last place in `text` where a line may end. Found by laying the
    /// text out in a box a little too narrow for it: its last word then moves
    /// to a second line, or, when it is one word, its last character does.
    fn last_break(&mut self, text: &str, style: &TextStyle) -> Option<usize> {
        let trimmed = text.trim_end_matches(' ');
        let whole = self.measure(trimmed, style);
        if trimmed.is_empty() || whole <= PROBE_MARGIN {
            return None;
        }
        let mut paragraph = self.paragraph(trimmed, style, None);
        paragraph.layout(whole - PROBE_MARGIN);
        let end = byte_offset(trimmed, paragraph.get_line_metrics().first()?.end_index);
        if end == 0 || end >= trimmed.len() {
            return None;
        }
        // Where a line may end the parts are as wide as the whole. Inside an emoji made of
        // several characters, or a ligature, they are not: the parts are other glyphs.
        let parts = self.measure(&trimmed[..end], style) + self.measure(&trimmed[end..], style);
        ((parts - whole).abs() <= style.size.abs() * 0.05 + 0.01).then_some(end)
    }

    /// First baseline below the top of a line box of the style's leading (CSS half-leading).
    pub fn baseline(&mut self, style: &TextStyle) -> f32 {
        let face = self.fonts.face(&style.family, style.weight);
        let ascent = face.ascent * style.size;
        let descent = face.descent * style.size;
        (style.leading - (ascent + descent)) / 2.0 + ascent
    }

    /// Draws one line with its left edge at `x` and its baseline at
    /// `baseline`, with the paragraph that [`TextEngine::measure`] measures.
    pub fn draw(&mut self, canvas: &Canvas, text: &str, style: &TextStyle, x: f32, baseline: f32, paint: &Paint) {
        if text.is_empty() {
            return;
        }
        let mut paragraph = self.paragraph(text, style, Some(paint));
        paragraph.layout(UNBOUNDED);
        // A fallback font may be taller than the style's font; the line's own baseline says where its top is.
        paragraph.paint(canvas, (x, baseline - paragraph.alphabetic_baseline()));
    }

    /// The font families that `text` would be drawn with, in order of first use; for diagnosis and tests.
    pub fn families_used(&mut self, text: &str, style: &TextStyle) -> Vec<String> {
        let mut paragraph = self.paragraph(text, style, None);
        paragraph.layout(UNBOUNDED);
        let mut families: Vec<String> = Vec::new();
        for info in paragraph.get_fonts() {
            let name = info.font.typeface().family_name();
            if !families.contains(&name) {
                families.push(name);
            }
        }
        families
    }
}

/// U+FE0F asks for the emoji form of the character before it.
const EMOJI_SELECTOR: char = '\u{fe0f}';
const ZERO_WIDTH_JOINER: char = '\u{200d}';
const KEYCAP: char = '\u{20e3}';

/// The byte ranges of `text` that ask for emoji presentation: a character
/// with the emoji variation selector, and what is joined to it (a keycap, or
/// more emoji through zero-width joiners). A sequence that starts with an
/// emoji that needs no selector is left to the font fallback, which keeps it
/// in one piece.
fn emoji_presentation_runs(text: &str) -> Vec<(usize, usize)> {
    let characters: Vec<(usize, char)> = text.char_indices().collect();
    let is = |index: usize, character: char| characters.get(index).is_some_and(|(_, found)| *found == character);
    let mut runs = Vec::new();
    let mut index = 0usize;
    while index < characters.len() {
        let joined_to_previous = index > 0 && is(index - 1, ZERO_WIDTH_JOINER);
        if !is(index + 1, EMOJI_SELECTOR) || joined_to_previous || characters[index].1 == ZERO_WIDTH_JOINER {
            index += 1;
            continue;
        }
        let mut end = index + 2;
        loop {
            if is(end, KEYCAP) {
                end += 1;
            } else if is(end, ZERO_WIDTH_JOINER) && end + 1 < characters.len() {
                end += if is(end + 2, EMOJI_SELECTOR) { 3 } else { 2 };
            } else {
                break;
            }
        }
        runs.push((characters[index].0, characters.get(end).map_or(text.len(), |(offset, _)| *offset)));
        index = end;
    }
    runs
}

/// The byte offset in `text` of an offset in UTF-16 code units, which is how
/// Skia's line metrics count; an offset past the end is the end.
fn byte_offset(text: &str, utf16_offset: usize) -> usize {
    let mut units = 0usize;
    for (index, character) in text.char_indices() {
        if units >= utf16_offset {
            return index;
        }
        units += character.len_utf16();
    }
    text.len()
}

/// A width no line reaches: the paragraph does not wrap.
const UNBOUNDED: f32 = 1.0e9;
const MAXIMUM_WIDTHS: usize = 8192;
/// How much narrower than a text the box is that moves its last word to a second line.
const PROBE_MARGIN: f32 = 0.5;
/// A paragraph with an overlong word is broken into no more lines than this; the rest stays on the last one.
const MAXIMUM_BROKEN_LINES: usize = 200;

#[cfg(test)]
mod tests {
    use super::{byte_offset, emoji_presentation_runs};

    #[test]
    fn characters_with_the_emoji_selector_are_emoji_runs() {
        fn run(text: &str) -> Vec<&str> {
            emoji_presentation_runs(text).into_iter().map(|(start, end)| &text[start..end]).collect()
        }
        assert_eq!(run("I \u{2764}\u{fe0f} widgets"), ["\u{2764}\u{fe0f}"]);
        assert_eq!(run("\u{2600}\u{fe0f}\u{2764}\u{fe0f}"), ["\u{2600}\u{fe0f}", "\u{2764}\u{fe0f}"]);
        // A keycap and a joined sequence stay in one run.
        assert_eq!(run("1\u{fe0f}\u{20e3} first"), ["1\u{fe0f}\u{20e3}"]);
        assert_eq!(run("\u{1f3f3}\u{fe0f}\u{200d}\u{1f308}!"), ["\u{1f3f3}\u{fe0f}\u{200d}\u{1f308}"]);
        assert_eq!(run("\u{1f441}\u{fe0f}\u{200d}\u{1f5e8}\u{fe0f}"), ["\u{1f441}\u{fe0f}\u{200d}\u{1f5e8}\u{fe0f}"]);
        // A sequence that starts with an emoji of its own is not cut where a later part has the selector.
        assert!(run("\u{1f9d1}\u{200d}\u{2695}\u{fe0f}").is_empty());
        // Plain text, a bare heart, and a selector with nothing before it.
        assert!(run("hello \u{2764} \u{1f600}").is_empty());
        assert!(run("\u{fe0f}").is_empty());
        assert!(run("").is_empty());
        assert_eq!(run("\u{2764}\u{fe0f}\u{200d}"), ["\u{2764}\u{fe0f}"]);
    }

    #[test]
    fn line_ends_counted_in_utf16_units_become_byte_offsets() {
        assert_eq!(byte_offset("hello", 2), 2);
        // A Han character is one unit and three bytes; an emoji is two units and four bytes.
        assert_eq!(byte_offset("今天多云", 2), 6);
        assert_eq!(byte_offset("a😀b", 3), 5);
        // An offset inside a surrogate pair moves to the end of the character.
        assert_eq!(byte_offset("a😀b", 2), 5);
        assert_eq!(byte_offset("abc", 0), 0);
        assert_eq!(byte_offset("abc", 99), 3);
        assert_eq!(byte_offset("", 4), 0);
    }
}
