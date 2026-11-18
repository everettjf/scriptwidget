//! Decoded GIF frames kept between renders, for a caller that draws every
//! frame of an animation one after the other (the background service).
//!
//! Showing frame N of a GIF means decoding frames 0 to N, because a frame is
//! drawn over the ones before it. Drawing all N frames of a widget, one
//! render each, would decode N²/2 frames. While a [`FrameCacheScope`] is
//! alive, the first render of a GIF decodes it once and the following renders
//! take their frame from here. Outside a scope nothing is kept and every
//! render decodes for itself, as before.
//!
//! The cache is bounded by [`gif::MAXIMUM_TOTAL_PIXELS`] over all the GIFs in
//! it, the same bound one GIF has, and is emptied when the last scope ends.
//! A GIF is recognised by a keyed hash of its bytes; the key is random per
//! process, so package data cannot be made to collide with another GIF.

use std::collections::VecDeque;
use std::hash::{BuildHasher, RandomState};
use std::sync::{Arc, Mutex, OnceLock};

use crate::gif::{self, GifAnimation, GifTimeline};

struct Entry {
    length: usize,
    hash: u64,
    animation: Arc<GifAnimation>,
}

#[derive(Default)]
struct Cache {
    scopes: usize,
    entries: VecDeque<Entry>,
}

fn cache() -> &'static Mutex<Cache> {
    static CACHE: OnceLock<Mutex<Cache>> = OnceLock::new();
    CACHE.get_or_init(Mutex::default)
}

fn hasher() -> &'static RandomState {
    static HASHER: OnceLock<RandomState> = OnceLock::new();
    HASHER.get_or_init(RandomState::new)
}

fn pixels(animation: &GifAnimation) -> i64 {
    i64::from(animation.width) * i64::from(animation.height) * animation.frames.len() as i64
}

/// Keeps decoded GIF frames while it is alive. Scopes nest; the frames are dropped when the last one ends.
pub struct FrameCacheScope(());

impl FrameCacheScope {
    pub fn new() -> Self {
        cache().lock().unwrap_or_else(|poisoned| poisoned.into_inner()).scopes += 1;
        Self(())
    }
}

impl Default for FrameCacheScope {
    fn default() -> Self {
        Self::new()
    }
}

impl Drop for FrameCacheScope {
    fn drop(&mut self) {
        let mut cache = cache().lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        cache.scopes = cache.scopes.saturating_sub(1);
        if cache.scopes == 0 {
            cache.entries.clear();
        }
    }
}

/// [`gif::decode_frame`], answered from the cache while a [`FrameCacheScope`] is alive.
pub fn frame(data: &[u8], index: usize) -> Option<(GifTimeline, Vec<u8>)> {
    if cache().lock().unwrap_or_else(|poisoned| poisoned.into_inner()).scopes == 0 {
        return gif::decode_frame(data, index);
    }
    let hash = hasher().hash_one(data);
    let cached = {
        let cache = cache().lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        cache.entries.iter().find(|entry| entry.length == data.len() && entry.hash == hash).map(|entry| entry.animation.clone())
    };
    let animation = match cached {
        Some(animation) => animation,
        None => {
            // Decoded outside the lock: another thread's render is not held up by this one's GIF.
            let animation = Arc::new(gif::decode(data)?);
            let mut cache = cache().lock().unwrap_or_else(|poisoned| poisoned.into_inner());
            if cache.scopes > 0 {
                cache.entries.push_back(Entry { length: data.len(), hash, animation: animation.clone() });
                while cache.entries.len() > 1 && cache.entries.iter().map(|entry| pixels(&entry.animation)).sum::<i64>() > gif::MAXIMUM_TOTAL_PIXELS {
                    cache.entries.pop_front();
                }
            }
            animation
        }
    };
    let frame = animation.frames.get(index.min(animation.frames.len().checked_sub(1)?))?;
    // The timing of the whole GIF, as `decode_frame` reports it, also when a damaged later frame cut the decoding short.
    Some((gif::inspect(data)?, frame.pixels.clone()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_scope_answers_like_the_decoder_and_forgets_when_it_ends() {
        let data = gif::tests::gif(4, 4, &[(1, 10), (2, 20), (3, 30)]);
        for index in [0, 1, 2, 9] {
            assert_eq!(frame(&data, index), gif::decode_frame(&data, index), "no scope, frame {index}");
        }
        {
            let _scope = FrameCacheScope::new();
            for index in [2, 0, 1, 9] {
                assert_eq!(frame(&data, index), gif::decode_frame(&data, index), "in a scope, frame {index}");
            }
            let held = cache().lock().unwrap().entries.iter().filter(|entry| entry.length == data.len()).count();
            assert_eq!(held, 1, "decoded once, kept once");
            assert_eq!(frame(b"not a gif", 0), None);
        }
        // Other tests may hold scopes of their own; this GIF's scope has ended.
        if cache().lock().unwrap().scopes == 0 {
            assert!(cache().lock().unwrap().entries.is_empty());
        }
    }
}
