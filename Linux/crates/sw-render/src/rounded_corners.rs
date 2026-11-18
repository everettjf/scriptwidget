//! Rounds the corners of a rendered widget. The renderer draws the widget as
//! a full rectangle, as on Android, where the launcher clips it; the Linux
//! host owns the surface, so it cuts the corners itself. Ported from
//! `Windows/src/ScriptWidget.Core/Render/RoundedCorners.cs`.

/// Corner radius of a desktop widget, in points.
pub const DEFAULT_RADIUS: f32 = 20.0;

/// Makes the corners of a premultiplied bitmap of four bytes a pixel
/// transparent, with an antialiased edge. The bitmap is changed in place.
/// `radius` is in pixels.
pub fn apply(pixels: &mut [u8], width: usize, height: usize, radius: f32) {
    if !(radius > 0.0) || width == 0 || height == 0 || width.checked_mul(height).and_then(|count| count.checked_mul(4)).is_none_or(|bytes| pixels.len() < bytes) {
        return;
    }
    let radius = radius.min(width.min(height) as f32 / 2.0);
    let reach = (radius.ceil() as usize).min(width).min(height);
    for row in 0..reach {
        for column in 0..reach {
            // Distance of the pixel centre from the corner circle's centre.
            let dx = radius - (column as f32 + 0.5);
            let dy = radius - (row as f32 + 0.5);
            if dx <= 0.0 || dy <= 0.0 {
                continue;
            }
            let coverage = (radius - dx.hypot(dy) + 0.5).clamp(0.0, 1.0);
            if coverage >= 1.0 {
                continue;
            }
            let right = width - 1 - column;
            let bottom = height - 1 - row;
            scale(pixels, (row * width + column) * 4, coverage);
            if right != column {
                scale(pixels, (row * width + right) * 4, coverage);
            }
            if bottom == row {
                continue;
            }
            scale(pixels, (bottom * width + column) * 4, coverage);
            if right != column {
                scale(pixels, (bottom * width + right) * 4, coverage);
            }
        }
    }
}

fn scale(pixels: &mut [u8], index: usize, coverage: f32) {
    // Premultiplied color: every channel scales with the coverage.
    for channel in &mut pixels[index..index + 4] {
        *channel = (f32::from(*channel) * coverage + 0.5) as u8;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn corners_become_transparent_and_the_middle_stays() {
        let (width, height) = (40usize, 30usize);
        let mut pixels = vec![255u8; width * height * 4];
        apply(&mut pixels, width, height, 10.0);
        let alpha = |x: usize, y: usize| pixels[(y * width + x) * 4 + 3];
        for (x, y) in [(0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)] {
            assert_eq!(alpha(x, y), 0, "{x},{y}");
        }
        for (x, y) in [(20, 15), (20, 0), (0, 15), (width - 1, 15), (20, height - 1), (10, 10), (4, 4)] {
            assert_eq!(alpha(x, y), 255, "{x},{y}");
        }
        // The edge is antialiased, and the color stays premultiplied.
        let edge: Vec<&[u8]> = pixels.chunks(4).filter(|pixel| pixel[3] != 0 && pixel[3] != 255).collect();
        assert!(!edge.is_empty() && edge.iter().all(|pixel| pixel[0] == pixel[3]));
        // Symmetric in both directions.
        for (x, y) in [(1, 3), (2, 2), (5, 0)] {
            assert_eq!(alpha(x, y), alpha(width - 1 - x, y));
            assert_eq!(alpha(x, y), alpha(x, height - 1 - y));
        }
    }

    #[test]
    fn a_radius_larger_than_the_bitmap_and_bad_input_are_safe() {
        let mut small = vec![255u8; 3 * 3 * 4];
        apply(&mut small, 3, 3, 100.0);
        assert_eq!(small[4 * 4 + 3], 255);
        let mut short = vec![255u8; 8];
        apply(&mut short, 3, 3, 2.0);
        assert_eq!(short, vec![255u8; 8]);
        let mut untouched = vec![255u8; 16];
        apply(&mut untouched, 2, 2, 0.0);
        apply(&mut untouched, 2, 2, f32::NAN);
        apply(&mut untouched, usize::MAX, 2, 4.0);
        assert_eq!(untouched, vec![255u8; 16]);
    }
}
