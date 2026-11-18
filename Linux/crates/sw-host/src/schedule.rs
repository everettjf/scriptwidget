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
}
