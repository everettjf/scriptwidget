//! Decodes package, inline and fetched images for one render. Ported from
//! `PackageImageSource` in `Windows/src/ScriptWidget.Core/Render/WidgetRenderer.cs`.
//! Image data comes from packages and the network: sizes are checked before
//! anything is decoded.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;

use skia_safe::codec::Codec;
use skia_safe::{AlphaType, ColorType, Data, FilterMode, Image, ImageInfo, MipmapMode, Paint, Rect, SamplingOptions, images, surfaces};
use sw_core::{PackageFiles, normalize_package_path};

use crate::gif::{self, GifTimeline};

/// A larger file is not decoded.
pub const MAXIMUM_IMAGE_BYTES: usize = 16 * 1024 * 1024;
/// A picture with more pixels is not decoded: 40 million pixels (larger than an 8K frame) are 160 MB.
pub const MAXIMUM_IMAGE_PIXELS: i64 = 40 * 1000 * 1000;

pub struct PackageImageSource {
    files: Option<Arc<dyn PackageFiles>>,
    remote: HashMap<String, PathBuf>,
    /// The moment of every GIF's animation to show; `None` shows the first frame.
    gif_time: Option<u64>,
    decoded: HashMap<String, Option<Image>>,
    reduced: HashMap<(String, i64), Option<Image>>,
    timelines: HashMap<String, Option<GifTimeline>>,
}

impl PackageImageSource {
    pub fn new(files: Option<Arc<dyn PackageFiles>>, remote: HashMap<String, PathBuf>, gif_time: Option<u64>) -> Self {
        Self { files, remote, gif_time, decoded: HashMap::new(), reduced: HashMap::new(), timelines: HashMap::new() }
    }

    fn bytes(&self, source: &str) -> Option<Vec<u8>> {
        let data = if let Some(path) = source.strip_prefix("res:") {
            // The layout only writes paths of the package's own files; a path that could leave the package is not read.
            self.files.as_ref()?.read_bytes(&normalize_package_path(Some(path))?)?
        } else if source.starts_with("data:") {
            let encoded = source.split_once("base64,").map_or(source, |(_, encoded)| encoded);
            if encoded.len() / 4 * 3 > MAXIMUM_IMAGE_BYTES + 3 {
                return None;
            }
            base64(encoded)?
        } else {
            let path = self.remote.get(source)?;
            // The size is checked before the file is read.
            let length = std::fs::metadata(path).ok().filter(|metadata| metadata.is_file())?.len();
            if length > MAXIMUM_IMAGE_BYTES as u64 {
                return None;
            }
            std::fs::read(path).ok()?
        };
        (!data.is_empty() && data.len() <= MAXIMUM_IMAGE_BYTES).then_some(data)
    }

    /// The whole image, decoded once per render; `None` when the source cannot be decoded.
    fn decode(&mut self, source: &str) -> Option<Image> {
        if let Some(existing) = self.decoded.get(source) {
            return existing.clone();
        }
        let image = self.bytes(source).and_then(|data| {
            if gif::is_gif(&data) {
                let timeline = gif::inspect(&data);
                self.timelines.insert(source.to_owned(), timeline.clone());
                let timeline = timeline?;
                let frame = self.gif_time.map_or(0, |time| timeline.frame_at(time));
                let (_, pixels) = crate::gif_cache::frame(&data, frame)?;
                let info = ImageInfo::new((timeline.width as i32, timeline.height as i32), ColorType::RGBA8888, AlphaType::Premul, None);
                return images::raster_from_data(&info, Data::new_copy(&pixels), info.min_row_bytes());
            }
            decode_still(&data)
        });
        self.decoded.insert(source.to_owned(), image.clone());
        image
    }

    /// Natural size in pixels, or `None` when the source cannot be decoded.
    pub fn size(&mut self, source: &str) -> Option<(i32, i32)> {
        self.decode(source).map(|image| (image.width(), image.height()))
    }

    /// The timing of `source` when it is an animated GIF that was decoded in this render.
    pub fn animation(&mut self, source: &str) -> Option<GifTimeline> {
        self.decode(source)?;
        self.timelines.get(source).cloned().flatten().filter(GifTimeline::is_animated)
    }

    /// The image, with no more than about four times `maximum_pixels` pixels.
    pub fn image(&mut self, source: &str, maximum_pixels: i64) -> Option<Image> {
        let key = (source.to_owned(), maximum_pixels);
        if let Some(existing) = self.reduced.get(&key) {
            return existing.clone();
        }
        let result = self.decode(source).map(|image| reduce(&image, maximum_pixels).unwrap_or(image));
        self.reduced.insert(key, result.clone());
        result
    }
}

/// Decodes PNG, JPEG, WebP, BMP and the other formats Skia reads into pixels.
pub(crate) fn decode_still(data: &[u8]) -> Option<Image> {
    let mut codec = Codec::from_data(Data::new_copy(data))?;
    // The header says how large the picture is, before any of it is decoded.
    let size = codec.dimensions();
    if size.width <= 0 || size.height <= 0 || i64::from(size.width) * i64::from(size.height) > MAXIMUM_IMAGE_PIXELS {
        return None;
    }
    // Decoded now, once: a damaged file is found here, not while painting. A photo is turned as its orientation says.
    codec.get_image(None, None).ok()
}

pub fn sampling() -> SamplingOptions {
    SamplingOptions::new(FilterMode::Linear, MipmapMode::Linear)
}

/// Halves the image until it has fewer than `maximum_pixels` pixels after one more halving.
fn reduce(image: &Image, maximum_pixels: i64) -> Option<Image> {
    let (width, height) = (i64::from(image.width()), i64::from(image.height()));
    let mut sample = 1i64;
    while (width / (sample * 2)) * (height / (sample * 2)) >= maximum_pixels.max(1) {
        sample *= 2;
    }
    if sample == 1 {
        return None;
    }
    let (target_width, target_height) = ((width / sample).max(1) as i32, (height / sample).max(1) as i32);
    let mut surface = surfaces::raster(&ImageInfo::new((target_width, target_height), ColorType::RGBA8888, AlphaType::Premul, None), None, None)?;
    surface.canvas().draw_image_rect_with_sampling_options(image, None, Rect::from_wh(target_width as f32, target_height as f32), sampling(), &Paint::default());
    Some(surface.image_snapshot())
}

/// Standard base64 with optional padding; whitespace is skipped. `None` for anything else.
fn base64(text: &str) -> Option<Vec<u8>> {
    let mut output = Vec::with_capacity(text.len() / 4 * 3);
    let (mut buffer, mut bits) = (0u32, 0u32);
    let mut padding = false;
    for byte in text.bytes() {
        let value = match byte {
            b'A'..=b'Z' => byte - b'A',
            b'a'..=b'z' => byte - b'a' + 26,
            b'0'..=b'9' => byte - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            b'=' => {
                padding = true;
                continue;
            }
            b' ' | b'\n' | b'\r' | b'\t' => continue,
            _ => return None,
        };
        if padding {
            return None;
        }
        buffer = buffer << 6 | u32::from(value);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            output.push((buffer >> bits) as u8);
        }
    }
    Some(output)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_base64() {
        assert_eq!(base64("aGVsbG8=").as_deref(), Some(&b"hello"[..]));
        assert_eq!(base64("aGVs\nbG8").as_deref(), Some(&b"hello"[..]));
        assert_eq!(base64("").as_deref(), Some(&b""[..]));
        assert_eq!(base64("a*b"), None);
        assert_eq!(base64("aGVsbG8=x"), None);
    }
}
