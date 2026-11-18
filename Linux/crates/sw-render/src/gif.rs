//! Decodes a GIF into whole frames with their delays, for a display layer
//! that cycles through them. The data comes from a package and is not
//! trusted: its size, the canvas, the number of frames and the memory all
//! frames take together are bounded here, as
//! `Windows/src/ScriptWidget.Core/Render/GifFrames.cs` bounds them. Unlike
//! that sampler, every frame is kept with its own delay.

use skia_safe::codec::codec_animation::DisposalMethod;
use skia_safe::codec::{self, Codec, Options, ZeroInitialized, gif_decoder};
use skia_safe::{AlphaType, ColorType, Data, ImageInfo};

/// A larger file is not opened.
pub const MAXIMUM_INPUT_BYTES: usize = 8 * 1024 * 1024;
/// Frames after this many are dropped.
pub const MAXIMUM_FRAMES: usize = 60;
/// The canvas of the GIF: a larger one is refused.
pub const MAXIMUM_CANVAS_PIXELS: i64 = 16 * 1024 * 1024;
/// All kept frames together; a GIF that needs more shows its first frame only.
pub const MAXIMUM_TOTAL_PIXELS: i64 = 16 * 1024 * 1024;
/// Browsers show a frame with no delay, or one too short to see, for this long.
const DEFAULT_DELAY_MILLISECONDS: u32 = 100;
const MINIMUM_DELAY_MILLISECONDS: u32 = 20;

/// Size and timing of a GIF, read without decoding pixels.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GifTimeline {
    pub width: u32,
    pub height: u32,
    /// How long each kept frame is shown, in milliseconds. One entry for a still image.
    pub delays: Vec<u32>,
}

impl GifTimeline {
    pub fn is_animated(&self) -> bool {
        self.delays.len() > 1
    }

    /// The length of one pass through the frames.
    pub fn duration(&self) -> u64 {
        self.delays.iter().map(|delay| u64::from(*delay)).sum()
    }

    /// The frame on screen `milliseconds` after the start; the animation repeats.
    pub fn frame_at(&self, milliseconds: u64) -> usize {
        let duration = self.duration();
        if duration == 0 || self.delays.len() < 2 {
            return 0;
        }
        let mut time = milliseconds % duration;
        for (index, delay) in self.delays.iter().enumerate() {
            if time < u64::from(*delay) {
                return index;
            }
            time -= u64::from(*delay);
        }
        self.delays.len() - 1
    }
}

/// One whole frame: `width * height * 4` bytes of premultiplied RGBA, rows from the top.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GifFrame {
    pub pixels: Vec<u8>,
    pub delay: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GifAnimation {
    pub width: u32,
    pub height: u32,
    pub frames: Vec<GifFrame>,
}

impl GifAnimation {
    pub fn timeline(&self) -> GifTimeline {
        GifTimeline { width: self.width, height: self.height, delays: self.frames.iter().map(|frame| frame.delay).collect() }
    }
}

pub fn is_gif(data: &[u8]) -> bool {
    data.starts_with(b"GIF87a") || data.starts_with(b"GIF89a")
}

fn open(data: &[u8]) -> Option<(Codec<'static>, GifTimeline)> {
    if data.len() > MAXIMUM_INPUT_BYTES || !is_gif(data) {
        return None;
    }
    let mut codec = Codec::from_data_with_decoders(Data::new_copy(data), &[gif_decoder::decoder()])?;
    let size = codec.dimensions();
    if size.width <= 0 || size.height <= 0 || i64::from(size.width) * i64::from(size.height) > MAXIMUM_CANVAS_PIXELS {
        return None;
    }
    let frame_pixels = i64::from(size.width) * i64::from(size.height);
    let mut count = codec.get_frame_count().clamp(1, MAXIMUM_FRAMES);
    if frame_pixels * count as i64 > MAXIMUM_TOTAL_PIXELS {
        count = 1;
    }
    let mut delays = Vec::with_capacity(count);
    for index in 0..count {
        let delay = codec.get_frame_info(index).map_or(0, |info| info.duration.max(0) as u32);
        delays.push(if delay < MINIMUM_DELAY_MILLISECONDS { DEFAULT_DELAY_MILLISECONDS } else { delay });
    }
    Some((codec, GifTimeline { width: size.width as u32, height: size.height as u32, delays }))
}

/// Size and timing, or `None` when the data is not a GIF this module accepts.
pub fn inspect(data: &[u8]) -> Option<GifTimeline> {
    open(data).map(|(_, timeline)| timeline)
}

/// Every kept frame, composed onto the frames before it, or `None` when the
/// data is not a GIF this module accepts or cannot be decoded.
pub fn decode(data: &[u8]) -> Option<GifAnimation> {
    decode_frames(data, usize::MAX, true)
}

/// Frame `index` alone (the last frame when there are fewer), with the timing of the whole GIF.
/// The frames before it are decoded too, because it is drawn over them, but not kept.
pub fn decode_frame(data: &[u8], index: usize) -> Option<(GifTimeline, Vec<u8>)> {
    let mut animation = decode_frames(data, index.saturating_add(1), false)?;
    let frame = animation.frames.pop()?;
    Some((inspect(data)?, frame.pixels))
}

/// The first `limit` frames; with `keep_all` false only the last of them is returned.
fn decode_frames(data: &[u8], limit: usize, keep_all: bool) -> Option<GifAnimation> {
    let (mut codec, timeline) = open(data)?;
    let info = ImageInfo::new((timeline.width as i32, timeline.height as i32), ColorType::RGBA8888, AlphaType::Premul, None);
    let row_bytes = info.min_row_bytes();
    let byte_count = info.compute_byte_size(row_bytes);
    let mut frames: Vec<GifFrame> = Vec::new();
    // What the previous frame left on the canvas, when the next frame may be drawn over it.
    let mut prior: Option<usize> = None;
    let mut canvas = vec![0u8; byte_count];
    for (index, delay) in timeline.delays.iter().enumerate().take(limit) {
        let frame_info = codec.get_frame_info(index);
        // The canvas can be reused when the frame that is in it is one the new frame may be blended with.
        let reusable = match (prior, frame_info.as_ref()) {
            (Some(prior), Some(frame)) => frame.required_frame != codec::NO_FRAME && frame.required_frame as usize <= prior,
            _ => false,
        };
        if !reusable {
            canvas.fill(0);
            prior = None;
        }
        let options = Options { zero_initialized: if reusable { ZeroInitialized::No } else { ZeroInitialized::Yes }, subset: None, frame_index: index, prior_frame: prior, max_decode_memory: Some(MAXIMUM_DECODE_BYTES) };
        match codec.get_pixels_with_options(&info, &mut canvas, row_bytes, Some(&options)) {
            codec::Result::Success => {}
            // A damaged later frame ends the animation; what was decoded before is kept.
            _ if index > 0 => break,
            // The first frame of a cut-off file is shown as far as it goes.
            codec::Result::IncompleteInput => {}
            _ => return None,
        }
        if !keep_all {
            frames.clear();
        }
        frames.push(GifFrame { pixels: canvas.clone(), delay: *delay });
        let keeps = frame_info.is_some_and(|frame| frame.disposal_method != DisposalMethod::RestorePrevious);
        prior = if keeps { Some(index) } else { None };
    }
    if frames.is_empty() {
        return None;
    }
    Some(GifAnimation { width: timeline.width, height: timeline.height, frames })
}

/// What the decoder may allocate besides the frames it writes into.
const MAXIMUM_DECODE_BYTES: usize = 64 * 1024 * 1024;

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// A GIF of `frames` frames, each one solid color from a four-entry
    /// palette (black, red, green, blue), `width` x `height`, uncompressed LZW.
    pub(crate) fn gif(width: u16, height: u16, frames: &[(u8, u16)]) -> Vec<u8> {
        let mut data = Vec::new();
        data.extend_from_slice(b"GIF89a");
        data.extend_from_slice(&width.to_le_bytes());
        data.extend_from_slice(&height.to_le_bytes());
        // A global color table of four entries, color resolution 2 bits.
        data.extend_from_slice(&[0x91, 0, 0]);
        data.extend_from_slice(&[0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255]);
        // Loop forever.
        data.extend_from_slice(&[0x21, 0xFF, 0x0B]);
        data.extend_from_slice(b"NETSCAPE2.0");
        data.extend_from_slice(&[3, 1, 0, 0, 0]);
        for (color, delay) in frames {
            data.extend_from_slice(&[0x21, 0xF9, 4, 0]);
            data.extend_from_slice(&delay.to_le_bytes());
            data.extend_from_slice(&[0, 0]);
            data.push(0x2C);
            data.extend_from_slice(&[0, 0, 0, 0]);
            data.extend_from_slice(&width.to_le_bytes());
            data.extend_from_slice(&height.to_le_bytes());
            data.push(0);
            // Codes of 3 bits (minimum code size 2): a clear code before every pixel keeps them 3 bits wide.
            data.push(2);
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
    fn decodes_every_frame_with_its_delay() {
        let data = gif(4, 3, &[(1, 10), (2, 25), (3, 0)]);
        let timeline = inspect(&data).expect("timeline");
        assert_eq!((timeline.width, timeline.height), (4, 3));
        // Hundredths of a second become milliseconds; no delay becomes the browsers' 100 ms.
        assert_eq!(timeline.delays, [100, 250, 100]);
        assert!(timeline.is_animated());
        let animation = decode(&data).expect("frames");
        assert_eq!(animation.timeline(), timeline);
        for (frame, color) in animation.frames.iter().zip([[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255]]) {
            assert_eq!(frame.pixels.len(), 4 * 3 * 4);
            assert!(frame.pixels.chunks(4).all(|pixel| pixel == color), "{:?}", &frame.pixels[..8]);
        }
        let (_, second) = decode_frame(&data, 1).expect("second frame");
        assert_eq!(second, animation.frames[1].pixels);
    }

    #[test]
    fn the_frame_on_screen_follows_the_delays_and_repeats() {
        let timeline = GifTimeline { width: 1, height: 1, delays: vec![100, 250, 100] };
        assert_eq!(timeline.duration(), 450);
        for (time, frame) in [(0, 0), (99, 0), (100, 1), (349, 1), (350, 2), (449, 2), (450, 0), (450 * 7 + 120, 1)] {
            assert_eq!(timeline.frame_at(time), frame, "{time}");
        }
        assert_eq!(GifTimeline { width: 1, height: 1, delays: vec![40] }.frame_at(1000), 0);
    }

    #[test]
    fn keeps_no_more_frames_than_the_limit() {
        let frames: Vec<(u8, u16)> = (0..75).map(|index| (1 + index % 3, 5)).collect();
        let data = gif(2, 2, &frames);
        assert_eq!(inspect(&data).expect("timeline").delays.len(), MAXIMUM_FRAMES);
        assert_eq!(decode(&data).expect("frames").frames.len(), MAXIMUM_FRAMES);
    }

    #[test]
    fn refuses_what_is_not_a_bounded_gif() {
        assert_eq!(inspect(b"not a gif"), None);
        assert_eq!(decode(&[]), None);
        // A PNG signature.
        assert_eq!(decode(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]), None);
        // A header that claims a 60000 x 60000 canvas is refused before any pixel is allocated.
        let mut huge = gif(2, 2, &[(1, 10), (2, 10)]);
        huge[6..8].copy_from_slice(&60000u16.to_le_bytes());
        huge[8..10].copy_from_slice(&60000u16.to_le_bytes());
        assert_eq!(inspect(&huge), None);
        assert_eq!(decode(&huge), None);
        // A file over the size limit is not opened.
        let mut long = gif(2, 2, &[(1, 10)]);
        long.resize(MAXIMUM_INPUT_BYTES + 1, 0);
        assert_eq!(inspect(&long), None);
        // Cut off in the middle of the first frame's header: nothing to show, and no panic.
        let whole = gif(2, 2, &[(1, 10), (2, 10)]);
        let _ = decode(&whole[..40]);
        let _ = decode(&whole[..whole.len() - 12]);
    }

    #[test]
    fn a_gif_whose_frames_exceed_the_memory_budget_shows_its_first_frame() {
        // 3000 x 3000 is 9 million pixels a frame: two frames are over the budget of 16 million.
        let mut data = gif(2, 2, &[(1, 10), (2, 10)]);
        data[6..8].copy_from_slice(&3000u16.to_le_bytes());
        data[8..10].copy_from_slice(&3000u16.to_le_bytes());
        let timeline = inspect(&data).expect("timeline");
        assert_eq!((timeline.width, timeline.height, timeline.delays.len()), (3000, 3000, 1));
        assert!(!timeline.is_animated());
    }
}
