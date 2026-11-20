//! When a widget is next due: the pure arithmetic of the refresh schedule,
//! with every time passed in, so that it is tested without waiting.
//!
//! The rules are those of the Windows host (`AppHost.cs`): a script runs
//! again after the refresh interval or at its next timeline transition,
//! whichever is first; a tree with a running timer is drawn again every
//! second and one with a clock time every minute, without running the script.

use serde_json::Value;

/// How often a tree must be drawn again because a `<date>` in it changes by itself.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Tick {
    /// `style` is `timer`, `relative` or `offset`: the text changes every second.
    Second,
    /// `style` is `time`: the text changes every minute.
    Minute,
}

/// The fastest tick any `<date>` of a tree needs, or `None` when the picture only changes when the script runs.
pub fn tick_of(tree: &str) -> Option<Tick> {
    if !tree.contains("\"date\"") {
        return None;
    }
    // The tree nests deeper than serde_json reads by default; its depth is bounded by the runtime contract.
    let mut deserializer = serde_json::Deserializer::from_str(tree);
    deserializer.disable_recursion_limit();
    let parsed: Value = serde::Deserialize::deserialize(&mut deserializer).ok()?;
    let mut found = None;
    let mut pending = vec![&parsed];
    while let Some(node) = pending.pop() {
        match node {
            Value::Object(item) => {
                if item.get("$element").and_then(Value::as_str) == Some("date") {
                    let tick = match item.get("props").and_then(|props| props.get("style")).and_then(Value::as_str).unwrap_or("date") {
                        "timer" | "relative" | "offset" => Some(Tick::Second),
                        "time" => Some(Tick::Minute),
                        _ => None,
                    };
                    found = match (found, tick) {
                        (Some(a), Some(b)) => Some(std::cmp::min::<Tick>(a, b)),
                        (a, b) => a.or(b),
                    };
                }
                pending.extend(item.get("children"));
            }
            Value::Array(items) => pending.extend(items),
            _ => {}
        }
    }
    found
}

/// Milliseconds until the picture changes: just after the next full second or minute of the wall clock.
pub fn tick_delay(tick: Tick, wall_milliseconds: i64) -> u64 {
    let (period, margin) = match tick {
        Tick::Second => (1000, 15),
        Tick::Minute => (60_000, 50),
    };
    (period - wall_milliseconds.rem_euclid(period) + margin) as u64
}

/// Milliseconds until the script runs again: the refresh interval, or the
/// next timeline transition when that comes first (but not sooner than a second).
pub fn run_delay(refresh_minutes: u64, next_transition_wall: Option<i64>, wall_milliseconds: i64) -> u64 {
    let interval = refresh_minutes * 60_000;
    match next_transition_wall {
        Some(transition) => interval.min((transition - wall_milliseconds).max(1000) as u64),
        None => interval,
    }
}

/// The frames of a widget with animated GIFs: `(start, duration)` in
/// milliseconds for each picture, in order. One GIF gives its own frames.
/// Several GIFs give a picture for every moment one of them changes, over the
/// length of the longest; the shorter ones repeat within it. When that would
/// be more than `maximum` pictures, only the longest GIF moves.
///
/// `delays` has one list per GIF: how long each of its frames is shown.
pub fn gif_frames(delays: &[Vec<u32>], maximum: usize) -> Vec<(u64, u32)> {
    let duration = |slot: &Vec<u32>| slot.iter().map(|delay| u64::from(*delay)).sum::<u64>();
    let animated: Vec<&Vec<u32>> = delays.iter().filter(|slot| slot.len() > 1 && duration(slot) > 0).collect();
    let Some(longest) = animated.iter().copied().max_by_key(|slot| duration(slot)) else { return Vec::new() };
    let total = duration(longest);
    let boundaries_of = |slot: &Vec<u32>| {
        let mut boundaries = Vec::new();
        let mut time = 0u64;
        'outer: loop {
            for delay in slot {
                if time >= total || boundaries.len() > maximum {
                    break 'outer;
                }
                boundaries.push(time);
                time += u64::from((*delay).max(1));
            }
        }
        boundaries
    };
    let mut boundaries: Vec<u64> = animated.iter().flat_map(|slot| boundaries_of(slot)).collect();
    boundaries.sort_unstable();
    boundaries.dedup();
    if boundaries.len() > maximum {
        boundaries = boundaries_of(longest);
        boundaries.truncate(maximum);
    }
    let ends = boundaries.iter().skip(1).copied().chain([total]);
    boundaries.iter().copied().zip(ends).map(|(start, end)| (start, (end - start).min(u64::from(u32::MAX)) as u32)).collect()
}

/// A cycle shows no picture for less than this: at most twenty pictures a second.
pub const MINIMUM_MOTION_FRAME: u64 = 50;
/// A cycle whose pictures would each stay longer than this is not built: the widget is drawn every second instead.
pub const MAXIMUM_MOTION_FRAME: u64 = 1000;

/// How a widget with moving parts is shown.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MotionPlan {
    /// The pictures of one cycle, as [`gif_frames`] gives them; empty when one picture is enough.
    pub frames: Vec<(u64, u32)>,
    /// How often the tree is drawn again without running the script.
    pub tick: Option<Tick>,
}

/// The pictures of a widget whose elements move by themselves, and how often
/// it is drawn again.
///
/// A GIF plays as before. A swing and a custom clock repeat, so together they
/// are one more track of the cycle, as if they were a GIF with evenly spaced
/// frames: as long as the time after which all of them are where they began,
/// with a picture every [`MINIMUM_MOTION_FRAME`] milliseconds, or as many
/// pictures as `maximum` and `affordable` allow. When that would leave a
/// picture on screen for more than [`MAXIMUM_MOTION_FRAME`], or the widget is
/// drawn every second anyway, no cycle is built for them: they are drawn where
/// they are at each second. Clock hands follow the time of day and never
/// repeat within a cycle: they are drawn again every second or minute.
///
/// `gifs` has the frame delays of each GIF, `periods` the milliseconds after
/// which each repeating motion is where it began, `hands` the tick the clock
/// hands need (a second hand every second, the others every minute), `dates`
/// the tick of the tree's dates. `maximum` is the most pictures a cycle may
/// have, `affordable` the most the pixel budget allows at this widget's size;
/// a cycle of GIFs alone that needs more shows its first frame only.
pub fn motion_plan(gifs: &[Vec<u32>], periods: &[u64], hands: Option<Tick>, dates: Option<Tick>, maximum: usize, affordable: usize) -> MotionPlan {
    let fastest = |left: Option<Tick>, right: Option<Tick>| match (left, right) {
        (Some(left), Some(right)) => Some(left.min(right)),
        (left, right) => left.or(right),
    };
    let tick = fastest(dates, hands);
    let within = |frames: Vec<(u64, u32)>| if frames.len() > affordable { Vec::new() } else { frames };
    if periods.is_empty() {
        return MotionPlan { frames: within(gif_frames(gifs, maximum)), tick };
    }
    let track = if tick == Some(Tick::Second) { None } else { motion_track(periods, maximum.min(affordable)) };
    let frames = track.map(|track| {
        let mut tracks = gifs.to_vec();
        tracks.push(track);
        gif_frames(&tracks, maximum)
    });
    match frames {
        Some(frames) if frames.len() <= affordable => MotionPlan { frames, tick },
        _ => MotionPlan { frames: within(gif_frames(gifs, maximum)), tick: Some(Tick::Second) },
    }
}

/// The repeating motions of a widget as one track of evenly spaced frames,
/// or `None` when no cycle of at most `maximum` pictures shows them well.
fn motion_track(periods: &[u64], maximum: usize) -> Option<Vec<u32>> {
    fn divisor(mut left: u64, mut right: u64) -> u64 {
        while right != 0 {
            (left, right) = (right, left % right);
        }
        left
    }
    let longest = (maximum as u64).checked_mul(MAXIMUM_MOTION_FRAME)?;
    // The first moment every motion is back where it began.
    let mut total = 1u64;
    for period in periods {
        let period = (*period).max(1);
        total = (total / divisor(total, period)).checked_mul(period).filter(|total| *total <= longest)?;
    }
    let count = (total / MINIMUM_MOTION_FRAME).min(maximum as u64);
    if count < 2 {
        return None;
    }
    // Whole milliseconds that add up to exactly the cycle.
    Some((0..count).map(|index| ((index + 1) * total / count - index * total / count) as u32).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tree(styles: &[Option<&str>]) -> String {
        let dates: Vec<String> = styles
            .iter()
            .map(|style| match style {
                Some(style) => format!(r#"{{"$element":"date","props":{{"style":"{style}","date":"2026-01-01T00:00:00Z"}},"children":[]}}"#),
                None => r#"{"$element":"date","props":{"date":"2026-01-01T00:00:00Z"},"children":[]}"#.to_owned(),
            })
            .collect();
        format!(r#"{{"$element":"vstack","props":null,"children":[{{"$element":"hstack","props":null,"children":[{}]}}]}}"#, dates.join(","))
    }

    #[test]
    fn a_timer_ticks_each_second_and_a_clock_each_minute() {
        assert_eq!(tick_of(&tree(&[])), None);
        assert_eq!(tick_of(&tree(&[None])), None, "a plain date changes when the script runs");
        assert_eq!(tick_of(&tree(&[Some("date")])), None);
        assert_eq!(tick_of(&tree(&[Some("time")])), Some(Tick::Minute));
        for style in ["timer", "relative", "offset"] {
            assert_eq!(tick_of(&tree(&[Some(style)])), Some(Tick::Second), "{style}");
        }
        assert_eq!(tick_of(&tree(&[Some("time"), Some("timer"), None])), Some(Tick::Second), "the fastest wins");
        assert_eq!(tick_of(&tree(&[Some("timer"), Some("time")])), Some(Tick::Second));
        // Text that only mentions a date is not a date element.
        assert_eq!(tick_of(r#"{"$element":"text","props":{"style":"timer"},"children":["\"date\""]}"#), None);
        assert_eq!(tick_of("{\"date\" not json"), None);
    }

    #[test]
    fn a_deeply_nested_tree_is_read() {
        let depth = 400;
        let deep = format!("{}{}{}", r#"{"$element":"vstack","props":null,"children":["#.repeat(depth), tree(&[Some("timer")]), "]}".repeat(depth));
        assert_eq!(tick_of(&deep), Some(Tick::Second));
    }

    #[test]
    fn ticks_follow_the_wall_clock() {
        assert_eq!(tick_delay(Tick::Second, 1_700_000_000_000), 1015);
        assert_eq!(tick_delay(Tick::Second, 1_700_000_000_400), 615);
        assert_eq!(tick_delay(Tick::Second, 1_700_000_000_999), 16);
        // 1_700_000_040_000 is a full minute.
        assert_eq!(tick_delay(Tick::Minute, 1_700_000_040_000), 60_050);
        assert_eq!(tick_delay(Tick::Minute, 1_700_000_040_000 + 20_000), 40_050);
        assert_eq!(tick_delay(Tick::Minute, 1_700_000_040_000 + 59_999), 51);
        assert_eq!(tick_delay(Tick::Second, -1), 16, "before 1970 the arithmetic still holds");
    }

    #[test]
    fn the_script_runs_at_the_interval_or_the_next_transition() {
        let now = 1_700_000_000_000;
        assert_eq!(run_delay(15, None, now), 900_000);
        assert_eq!(run_delay(5, None, now), 300_000);
        assert_eq!(run_delay(15, Some(now + 60_000), now), 60_000);
        assert_eq!(run_delay(15, Some(now + 3_600_000), now), 900_000, "a far transition does not delay the refresh");
        assert_eq!(run_delay(15, Some(now + 10), now), 1000, "never a busy loop");
        assert_eq!(run_delay(15, Some(now - 5000), now), 1000, "a transition that has passed runs soon, once");
    }

    #[test]
    fn one_gif_gives_its_own_frames() {
        assert_eq!(gif_frames(&[vec![100, 250, 100]], 60), [(0, 100), (100, 250), (350, 100)]);
        assert_eq!(gif_frames(&[], 60), []);
        assert_eq!(gif_frames(&[vec![100]], 60), [], "a still image has no frames");
        assert_eq!(gif_frames(&[vec![100], vec![50, 50]], 60), [(0, 50), (50, 50)]);
    }

    #[test]
    fn several_gifs_share_one_cycle() {
        // 300 ms in three frames, and 200 ms in two: the short one starts again at 200.
        assert_eq!(gif_frames(&[vec![100, 100, 100], vec![150, 50]], 60), [(0, 100), (100, 50), (150, 50), (200, 100)]);
        // The same GIF twice changes nothing.
        assert_eq!(gif_frames(&[vec![100, 100], vec![100, 100]], 60), [(0, 100), (100, 100)]);
        let frames = gif_frames(&[vec![100, 100, 100], vec![150, 50]], 60);
        assert_eq!(frames.iter().map(|(_, duration)| u64::from(*duration)).sum::<u64>(), 300, "the cycle is as long as the longest GIF");
    }

    #[test]
    fn no_more_pictures_than_the_limit() {
        // Two GIFs that never change together: 60 + 59 moments, over the limit, so only the longest moves.
        let long: Vec<u32> = vec![100; 60];
        let odd: Vec<u32> = vec![101; 59];
        let frames = gif_frames(&[long.clone(), odd], 60);
        assert_eq!(frames.len(), 60);
        assert!(frames.iter().all(|(_, duration)| *duration == 100));
        assert_eq!(gif_frames(&[vec![20; 200]], 60).len(), 60);
        // A zero delay cannot stall the loop.
        assert_eq!(gif_frames(&[vec![0, 100]], 60), [(0, 1), (1, 99)]);
    }

    fn plan(gifs: &[Vec<u32>], periods: &[u64], hands: Option<Tick>, dates: Option<Tick>) -> MotionPlan {
        motion_plan(gifs, periods, hands, dates, 60, 60)
    }

    #[test]
    fn a_widget_with_nothing_that_moves_has_one_picture_and_no_tick() {
        assert_eq!(plan(&[], &[], None, None), MotionPlan { frames: vec![], tick: None });
        // Dates and GIFs alone are scheduled as before.
        assert_eq!(plan(&[], &[], None, Some(Tick::Minute)), MotionPlan { frames: vec![], tick: Some(Tick::Minute) });
        assert_eq!(plan(&[vec![100, 250, 100]], &[], None, Some(Tick::Second)), MotionPlan { frames: vec![(0, 100), (100, 250), (350, 100)], tick: Some(Tick::Second) });
        // A GIF cycle that the pixel budget cannot hold shows its first frame.
        assert_eq!(motion_plan(&[vec![100, 250, 100]], &[], None, None, 60, 2), MotionPlan { frames: vec![], tick: None });
    }

    #[test]
    fn clock_hands_are_drawn_again_each_second_or_minute() {
        assert_eq!(plan(&[], &[], Some(Tick::Second), None), MotionPlan { frames: vec![], tick: Some(Tick::Second) });
        assert_eq!(plan(&[], &[], Some(Tick::Minute), None), MotionPlan { frames: vec![], tick: Some(Tick::Minute) });
        // The fastest of the hands and the dates wins.
        assert_eq!(plan(&[], &[], Some(Tick::Minute), Some(Tick::Second)).tick, Some(Tick::Second));
        assert_eq!(plan(&[], &[], Some(Tick::Second), Some(Tick::Minute)).tick, Some(Tick::Second));
    }

    #[test]
    fn a_swing_becomes_a_cycle_of_evenly_spaced_pictures() {
        // There and back in two seconds: forty pictures of 50 ms, twenty a second.
        let swing = plan(&[], &[2000], None, None);
        assert_eq!(swing.tick, None);
        assert_eq!(swing.frames.len(), 40);
        assert!(swing.frames.iter().enumerate().all(|(index, frame)| *frame == (index as u64 * 50, 50)));
        // The fastest swing there is: 200 ms in four pictures.
        assert_eq!(plan(&[], &[200], None, None).frames, [(0, 50), (50, 50), (100, 50), (150, 50)]);
        // A slower motion gets the sixty pictures the cycle may have: 40 seconds, two thirds of a second each.
        let slow = plan(&[], &[40_000], None, None);
        assert_eq!(slow.frames.len(), 60);
        assert_eq!(slow.frames.iter().map(|(_, duration)| u64::from(*duration)).sum::<u64>(), 40_000, "the durations add up to the cycle");
        assert!(slow.frames.iter().all(|(_, duration)| (666..=667).contains(duration)));
        assert_eq!(slow.frames[59].0 + u64::from(slow.frames[59].1), 40_000);
        // A minute is the longest cycle: one picture a second.
        assert_eq!(plan(&[], &[60_000], None, None).frames.len(), 60);
        assert_eq!(plan(&[], &[60_000], None, None).tick, None);
    }

    #[test]
    fn a_motion_too_slow_for_a_cycle_is_drawn_each_second() {
        assert_eq!(plan(&[], &[60_001], None, None), MotionPlan { frames: vec![], tick: Some(Tick::Second) });
        assert_eq!(plan(&[], &[172_800_000], None, None), MotionPlan { frames: vec![], tick: Some(Tick::Second) });
        // The aquarium: 30, 40 and 60 seconds are together again after 120.
        assert_eq!(plan(&[], &[40_000, 60_000, 30_000], None, None), MotionPlan { frames: vec![], tick: Some(Tick::Second) });
        // Periods that never meet, and ones whose product does not fit a number.
        assert_eq!(plan(&[], &[24_000, 24_340, 24_680], None, None).tick, Some(Tick::Second));
        assert_eq!(plan(&[], &[u64::MAX, u64::MAX - 1], None, None), MotionPlan { frames: vec![], tick: Some(Tick::Second) });
        assert_eq!(plan(&[], &[0], None, None).tick, Some(Tick::Second), "no period is not a cycle");
        // A widget that is drawn every second anyway moves then, and builds no cycle on top.
        assert_eq!(plan(&[], &[2000], Some(Tick::Second), None), MotionPlan { frames: vec![], tick: Some(Tick::Second) });
        assert_eq!(plan(&[], &[2000], None, Some(Tick::Second)), MotionPlan { frames: vec![], tick: Some(Tick::Second) });
        // With a tick of a minute the cycle is kept, and published again each minute.
        let minute = plan(&[], &[2000], Some(Tick::Minute), None);
        assert_eq!((minute.frames.len(), minute.tick), (40, Some(Tick::Minute)));
    }

    #[test]
    fn motions_that_meet_share_a_cycle() {
        // Two and three seconds are together again after six: sixty pictures of 100 ms.
        let both = plan(&[], &[2000, 3000, 2000], None, None);
        assert_eq!(both.frames.len(), 60);
        assert!(both.frames.iter().all(|(_, duration)| *duration == 100));
        assert_eq!(both.tick, None);
    }

    #[test]
    fn the_pixel_budget_lowers_the_number_of_pictures() {
        // Room for ten pictures: a two-second swing gets ten of 200 ms.
        let few = motion_plan(&[], &[2000], None, None, 60, 10);
        assert_eq!(few.frames.len(), 10);
        assert!(few.frames.iter().all(|(_, duration)| *duration == 200));
        // Room for ten pictures and a 40 second turn: four seconds a picture is too slow, so each second is drawn.
        assert_eq!(motion_plan(&[], &[40_000], None, None, 60, 10), MotionPlan { frames: vec![], tick: Some(Tick::Second) });
        // Room for one picture: nothing cycles.
        assert_eq!(motion_plan(&[], &[2000], None, None, 60, 1), MotionPlan { frames: vec![], tick: Some(Tick::Second) });
        assert_eq!(motion_plan(&[], &[2000], None, None, 60, 0), MotionPlan { frames: vec![], tick: Some(Tick::Second) });
    }

    #[test]
    fn a_gif_and_a_motion_share_the_cycle_like_two_gifs() {
        // A GIF of 400 ms and a swing of 200 ms: the swing's four pictures repeat inside the GIF's cycle.
        let both = plan(&[vec![200, 200]], &[200], None, None);
        assert_eq!(both.frames, [(0, 50), (50, 50), (100, 50), (150, 50), (200, 50), (250, 50), (300, 50), (350, 50)]);
        // More moments than a cycle may have: only the longest track sets the moments, as for two GIFs.
        let crowded = plan(&[vec![70; 30]], &[3000], None, None);
        assert_eq!(crowded.frames.len(), 60);
        assert!(crowded.frames.iter().all(|(_, duration)| *duration == 50));
        // A motion too slow for a cycle leaves the GIF playing and is drawn each second.
        assert_eq!(plan(&[vec![100, 100]], &[90_000], None, None), MotionPlan { frames: vec![(0, 100), (100, 100)], tick: Some(Tick::Second) });
    }
}
