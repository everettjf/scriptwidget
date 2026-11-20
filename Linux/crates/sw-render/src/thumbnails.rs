//! Thumbnails for `$photos`: the painter's side of
//! [`sw_core::api::photos::ThumbnailMaker`]. A picture file the user picked
//! is decoded within the limits every image has here (16 MB, 40 million
//! pixels), turned as its orientation says, scaled down and written again as
//! a JPEG. Writing it again drops every tag the file carried: the place it
//! was taken, the camera, the time.

use skia_safe::{AlphaType, Color, ColorType, EncodedImageFormat, ImageInfo, Paint, Rect, surfaces};
use sw_core::api::photos::{Thumbnail, ThumbnailMaker, thumbnail_plan};

use crate::images::{MAXIMUM_IMAGE_BYTES, decode_still, sampling};

/// Makes thumbnails with Skia.
#[derive(Debug, Clone, Copy, Default)]
pub struct SkiaThumbnails;

impl ThumbnailMaker for SkiaThumbnails {
    fn make(&self, source: &[u8], maximum_side: u32, maximum_bytes: usize) -> Option<Thumbnail> {
        if source.is_empty() || source.len() > MAXIMUM_IMAGE_BYTES {
            return None;
        }
        let image = decode_still(source)?;
        let (width, height) = (u32::try_from(image.width()).ok()?, u32::try_from(image.height()).ok()?);
        let bytes = thumbnail_plan::encode(width, height, maximum_side, maximum_bytes, |target_width, target_height, quality| {
            let info = ImageInfo::new((target_width as i32, target_height as i32), ColorType::RGBA8888, AlphaType::Opaque, None);
            let mut surface = surfaces::raster(&info, None, None)?;
            // A JPEG has no transparency: what is transparent in the picture becomes white.
            surface.canvas().clear(Color::WHITE);
            surface.canvas().draw_image_rect_with_sampling_options(&image, None, Rect::from_wh(target_width as f32, target_height as f32), sampling(), &Paint::default());
            Some(surface.image_snapshot().encode(None, EncodedImageFormat::JPEG, quality)?.as_bytes().to_vec())
        })?;
        Some(Thumbnail { bytes, original_width: width, original_height: height })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sw_core::api::photos::photo_limits::{MAXIMUM_SIDE, MAXIMUM_THUMBNAIL_BYTES};

    /// A PNG of noise: it does not compress, so the quality and size search has work to do.
    fn noise(width: u32, height: u32) -> Vec<u8> {
        let mut state = 0x2545_f491_4f6c_dd1du64;
        let pixels: Vec<u8> = (0..width * height * 4)
            .map(|index| {
                state ^= state << 13;
                state ^= state >> 7;
                state ^= state << 17;
                if index % 4 == 3 { 255 } else { state as u8 }
            })
            .collect();
        crate::encode_png(&pixels, width, height).unwrap()
    }

    #[test]
    fn a_picture_becomes_a_small_jpeg_without_its_metadata() {
        let source = noise(1600, 900);
        let thumbnail = SkiaThumbnails.make(&source, MAXIMUM_SIDE, MAXIMUM_THUMBNAIL_BYTES).expect("thumbnail");
        assert_eq!((thumbnail.original_width, thumbnail.original_height), (1600, 900));
        assert!(thumbnail_plan::is_jpeg(&thumbnail.bytes));
        assert!(thumbnail.bytes.len() <= MAXIMUM_THUMBNAIL_BYTES, "{} bytes", thumbnail.bytes.len());
        let decoded = decode_still(&thumbnail.bytes).expect("the thumbnail is a picture");
        assert!(decoded.width() <= MAXIMUM_SIDE as i32 && decoded.height() <= MAXIMUM_SIDE as i32, "{}x{}", decoded.width(), decoded.height());
        assert!(decoded.width() > decoded.height(), "the shape is kept");
        // No EXIF block: the marker of one is the text "Exif" after an APP1 segment.
        assert!(!thumbnail.bytes.windows(4).any(|window| window == b"Exif"));
    }

    #[test]
    fn a_small_picture_is_not_enlarged() {
        let thumbnail = SkiaThumbnails.make(&noise(40, 30), MAXIMUM_SIDE, MAXIMUM_THUMBNAIL_BYTES).expect("thumbnail");
        let decoded = decode_still(&thumbnail.bytes).unwrap();
        assert_eq!((decoded.width(), decoded.height()), (40, 30));
    }

    #[test]
    fn what_is_not_a_picture_is_refused() {
        for source in [&b""[..], b"{\"not\":\"a picture\"}", b"\x89PNG\r\n\x1a\n truncated", &[0xff, 0xd8, 0xff, 0xe0, 0, 16]] {
            assert!(SkiaThumbnails.make(source, MAXIMUM_SIDE, MAXIMUM_THUMBNAIL_BYTES).is_none());
        }
        // A byte limit nothing fits in ends the search instead of looping.
        assert!(SkiaThumbnails.make(&noise(400, 400), MAXIMUM_SIDE, 64).is_none());
    }
}
