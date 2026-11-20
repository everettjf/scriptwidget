//! Where an element with the `animation` property is at a given moment.
//!
//! The shared renderer records what moves and how in `data-sw-animation`
//! (see `applyDecoration` in `Web/preview-engine/src/render/renderer.js`): a
//! clock hand that turns with the time of day, a turn at a custom rate, or a
//! swing from side to side. This module turns that record and a moment into a
//! pose, with the arithmetic of the Apple runtime
//! (`ScriptWidgetAnimationPhase` in `ScriptWidgetAttributeAnimationModifier.swift`)
//! and of the browser (`Web/preview-engine/src/render/animation.js`).
//!
//! The pose functions take the local time as numbers and are pure. Finding
//! the local time of a moment in a zone asks ICU, as the shared renderer does.

use serde_json::{Value, json};
use sw_core::intl;
use sw_core::json::{parse_object, stringify};

/// Moments outside the years 1 to 9999 have no pose: the hands rest, as in the Apple runtime.
pub const EARLIEST_MILLISECONDS: i64 = -62_135_596_800_000;
pub const LATEST_MILLISECONDS: i64 = 253_402_300_799_000;
/// 2001-01-01T00:00:00Z, the reference date of the Apple runtime, in seconds since 1970.
const REFERENCE_SECONDS: f64 = 978_307_200.0;

/// One of the three hands of a clock.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Hand {
    Second,
    Minute,
    Hour,
}

impl Hand {
    /// How long one turn takes, in seconds.
    pub fn cycle_seconds(self) -> f64 {
        match self {
            Hand::Second => 60.0,
            Hand::Minute => 3600.0,
            Hand::Hour => 43_200.0,
        }
    }
}

/// What the `animation` property of an element asks for.
#[derive(Debug, Clone, PartialEq)]
pub enum Motion {
    /// `clockSecond`, `clockMinute` or `clockHour`: the angle of that hand at the time of day in `zone`.
    Hand { hand: Hand, zone: String },
    /// `clockCustom,<interval>` or `type: "clock"`: half a turn every `interval` seconds, backwards when negative.
    Spin { interval: f64, zone: String },
    /// `swing`: `distance` points to one side and to the other; there and back takes twice `duration` seconds.
    Swing { horizontal: bool, distance: f64, duration: f64 },
}

/// Where a moving element is: turned about its anchor, or moved from its place.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Pose {
    /// Degrees, clockwise.
    Turn(f64),
    /// Points to the right and down.
    Shift(f64, f64),
}

/// The custom clock interval the runtime uses for `value`: never faster than half a turn in a quarter of a second.
pub fn clock_period(value: f64) -> f64 {
    if !value.is_finite() {
        10.0
    } else if value.abs() < 0.25 {
        if value < 0.0 { -0.25 } else { 0.25 }
    } else {
        value
    }
}

pub fn swing_duration(value: f64) -> f64 {
    if value.is_finite() && value > 0.0 { value.clamp(0.1, 86_400.0) } else { 1.0 }
}

pub fn swing_distance(value: f64) -> f64 {
    if value.is_finite() { value.clamp(-10_000.0, 10_000.0) } else { 10.0 }
}

/// The offset of a swing `elapsed` seconds after it began.
pub fn swing_offset(elapsed: f64, duration: f64, distance: f64) -> f64 {
    if !elapsed.is_finite() {
        return 0.0;
    }
    let duration = swing_duration(duration);
    (elapsed % (2.0 * duration) / duration * std::f64::consts::PI).sin() * swing_distance(distance)
}

/// The angle of a clock hand at a time of day, in degrees from twelve o'clock.
pub fn hand_angle(hand: Hand, local: &LocalTime) -> f64 {
    let cycle = hand.cycle_seconds();
    local.seconds_of_day() % cycle / cycle * 360.0
}

/// The angle of a turn at a custom rate. It is counted from 2001 in local
/// time, so that it does not jump at midnight; the sign follows the interval.
pub fn spin_angle(interval: f64, local: &LocalTime) -> f64 {
    (local.reference_seconds() / clock_period(interval)) % 2.0 * 180.0
}

/// A moment as the calendar and the clock of some zone show it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LocalTime {
    pub year: i64,
    /// 1 to 12.
    pub month: u32,
    pub day: u32,
    pub hour: u32,
    pub minute: u32,
    pub second: u32,
    pub millisecond: u32,
}

impl LocalTime {
    /// `milliseconds` since 1970 in UTC, by arithmetic alone.
    pub fn utc(milliseconds: i64) -> Self {
        let days = milliseconds.div_euclid(86_400_000);
        let of_day = milliseconds.rem_euclid(86_400_000);
        // Days to a date of the Gregorian calendar (Howard Hinnant's civil_from_days).
        let shifted = days + 719_468;
        let era = shifted.div_euclid(146_097);
        let day_of_era = shifted.rem_euclid(146_097);
        let year_of_era = (day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
        let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
        let month_index = (5 * day_of_year + 2) / 153;
        let day = day_of_year - (153 * month_index + 2) / 5 + 1;
        let month = if month_index < 10 { month_index + 3 } else { month_index - 9 };
        let year = year_of_era + era * 400 + i64::from(month <= 2);
        Self {
            year,
            month: month as u32,
            day: day as u32,
            hour: (of_day / 3_600_000) as u32,
            minute: (of_day / 60_000 % 60) as u32,
            second: (of_day / 1000 % 60) as u32,
            millisecond: (of_day % 1000) as u32,
        }
    }

    /// `milliseconds` since 1970 in `zone`, an IANA name. `"current"`, an
    /// empty name and a name ICU does not know all mean the zone of the
    /// system, as in the Apple runtime and the browser.
    pub fn in_zone(milliseconds: i64, zone: &str) -> Self {
        let named = if zone.is_empty() || zone == "current" { None } else { Some(zone) };
        named.and_then(|zone| parts(milliseconds, Some(zone))).or_else(|| parts(milliseconds, None)).unwrap_or_else(|| Self::utc(milliseconds))
    }

    /// Seconds since midnight, with the fraction.
    pub fn seconds_of_day(&self) -> f64 {
        f64::from(self.hour * 3600 + self.minute * 60 + self.second) + f64::from(self.millisecond) / 1000.0
    }

    /// Seconds since the start of 2001 on this calendar and clock, as if they were UTC.
    pub fn reference_seconds(&self) -> f64 {
        // Date to days (days_from_civil).
        let year = self.year - i64::from(self.month <= 2);
        let era = year.div_euclid(400);
        let year_of_era = year.rem_euclid(400);
        let month = i64::from(self.month);
        let day_of_year = (153 * (if month > 2 { month - 3 } else { month + 9 }) + 2) / 5 + i64::from(self.day) - 1;
        let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
        let days = era * 146_097 + day_of_era - 719_468;
        days as f64 * 86_400.0 + self.seconds_of_day() - REFERENCE_SECONDS
    }
}

/// The fields ICU gives for a moment: the request `clockPhase` of the shared renderer makes.
fn parts(milliseconds: i64, zone: Option<&str>) -> Option<LocalTime> {
    let mut options = json!({
        "year": "numeric", "month": "numeric", "day": "numeric", "hour": "numeric", "minute": "numeric", "second": "numeric",
        "hourCycle": "h23", "calendar": "gregory", "numberingSystem": "latn",
    });
    if let Some(zone) = zone {
        if intl::call("intl.validZone", Some(zone)).ok().flatten().as_deref() != Some("1") {
            return None;
        }
        options["timeZone"] = json!(zone);
    }
    let request = stringify(&json!({ "locale": "en-US", "options": options, "time": milliseconds as f64 }));
    let answer = intl::call("intl.dateParts", Some(&request)).ok().flatten()?;
    let Value::Array(items) = serde_json::from_str::<Value>(&answer).ok()? else { return None };
    let field = |name: &str| items.iter().find(|item| item.get("type").and_then(Value::as_str) == Some(name)).and_then(|item| item.get("value")).and_then(Value::as_str).and_then(|text| text.trim().parse::<i64>().ok());
    let small = |name: &str, most: i64| field(name).filter(|value| (0..=most).contains(value)).map(|value| value as u32);
    Some(LocalTime {
        year: field("year")?,
        month: small("month", 12).filter(|month| *month >= 1)?,
        day: small("day", 31).filter(|day| *day >= 1)?,
        // "24" is what some ICU data writes for midnight.
        hour: small("hour", 24)? % 24,
        minute: small("minute", 59)?,
        second: small("second", 59)?,
        millisecond: milliseconds.rem_euclid(1000) as u32,
    })
}

impl Motion {
    /// Reads what the shared renderer recorded; `None` for anything else.
    /// The numbers come from a package: they are bounded again here.
    pub fn parse(description: &str) -> Option<Self> {
        let json = parse_object(description).ok()?;
        let text = |name: &str| json.get(name).and_then(Value::as_str);
        let number = |name: &str| json.get(name).and_then(Value::as_f64);
        match text("kind")? {
            "swing" => Some(Motion::Swing { horizontal: text("axis") == Some("x"), distance: swing_distance(number("distance").unwrap_or(10.0)), duration: swing_duration(number("duration").unwrap_or(1.0)) }),
            "clock" => {
                let zone = text("timezone").unwrap_or("current").to_owned();
                match text("type")? {
                    "clockSecond" => Some(Motion::Hand { hand: Hand::Second, zone }),
                    "clockMinute" | "clockMiniute" => Some(Motion::Hand { hand: Hand::Minute, zone }),
                    "clockHour" => Some(Motion::Hand { hand: Hand::Hour, zone }),
                    "clock" => Some(Motion::Spin { interval: clock_period(number("interval").unwrap_or(10.0)), zone }),
                    _ => None,
                }
            }
            _ => None,
        }
    }

    /// The zone whose local time the pose depends on; `None` for a swing.
    pub fn zone(&self) -> Option<&str> {
        match self {
            Motion::Hand { zone, .. } | Motion::Spin { zone, .. } => Some(zone),
            Motion::Swing { .. } => None,
        }
    }

    /// The pose at `milliseconds` since 1970, given what the clock of the
    /// motion's zone shows then. A swing counts its time from 1970, so that a
    /// moment always gives the same pose.
    pub fn pose_at(&self, milliseconds: i64, local: &LocalTime) -> Pose {
        let in_range = (EARLIEST_MILLISECONDS..=LATEST_MILLISECONDS).contains(&milliseconds);
        match self {
            Motion::Hand { hand, .. } => Pose::Turn(if in_range { hand_angle(*hand, local) } else { 0.0 }),
            Motion::Spin { interval, .. } => Pose::Turn(if in_range { spin_angle(*interval, local) } else { 0.0 }),
            Motion::Swing { horizontal, distance, duration } => {
                let offset = swing_offset(milliseconds as f64 / 1000.0, *duration, *distance);
                if *horizontal { Pose::Shift(offset, 0.0) } else { Pose::Shift(0.0, offset) }
            }
        }
    }

    /// [`Motion::pose_at`], with the local time looked up.
    pub fn pose(&self, milliseconds: i64) -> Pose {
        let local = self.zone().map_or_else(|| LocalTime::utc(milliseconds), |zone| LocalTime::in_zone(milliseconds, zone));
        self.pose_at(milliseconds, &local)
    }

    /// After how many milliseconds the motion is where it began, for a
    /// motion that repeats by itself; `None` for a clock hand, which follows
    /// the time of day.
    pub fn period_milliseconds(&self) -> Option<u64> {
        let seconds = match self {
            Motion::Hand { .. } => return None,
            Motion::Spin { interval, .. } => 2.0 * clock_period(*interval).abs(),
            Motion::Swing { duration, .. } => 2.0 * swing_duration(*duration),
        };
        Some((seconds * 1000.0).round().clamp(1.0, 1e15) as u64)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 2026-01-01T12:00:00Z.
    const NOON: i64 = 1_767_268_800_000;

    fn close(left: f64, right: f64) -> bool {
        (left - right).abs() < 1e-6
    }

    fn at(hour: u32, minute: u32, second: u32, millisecond: u32) -> LocalTime {
        LocalTime { year: 2026, month: 1, day: 1, hour, minute, second, millisecond }
    }

    #[test]
    fn the_calendar_of_utc_is_computed() {
        assert_eq!(LocalTime::utc(0), LocalTime { year: 1970, month: 1, day: 1, hour: 0, minute: 0, second: 0, millisecond: 0 });
        assert_eq!(LocalTime::utc(NOON + 3_723_456), LocalTime { year: 2026, month: 1, day: 1, hour: 13, minute: 2, second: 3, millisecond: 456 });
        // A leap day, the last millisecond of a year, and a moment before 1970.
        assert_eq!(LocalTime::utc(1_709_164_800_000), LocalTime { year: 2024, month: 2, day: 29, hour: 0, minute: 0, second: 0, millisecond: 0 });
        assert_eq!(LocalTime::utc(946_684_799_999), LocalTime { year: 1999, month: 12, day: 31, hour: 23, minute: 59, second: 59, millisecond: 999 });
        assert_eq!(LocalTime::utc(-1), LocalTime { year: 1969, month: 12, day: 31, hour: 23, minute: 59, second: 59, millisecond: 999 });
        assert_eq!(LocalTime::utc(EARLIEST_MILLISECONDS), LocalTime { year: 1, month: 1, day: 1, hour: 0, minute: 0, second: 0, millisecond: 0 });
        // The reference date of the custom clock.
        assert!(close(LocalTime::utc(978_307_200_000).reference_seconds(), 0.0));
        assert!(close(LocalTime::utc(NOON + 250).reference_seconds(), (NOON as f64 + 250.0) / 1000.0 - 978_307_200.0));
        assert!(close(LocalTime::utc(-86_400_000).reference_seconds(), -86_400.0 - 978_307_200.0));
    }

    #[test]
    fn clock_hands_point_at_the_time_of_day() {
        // Three o'clock: the hour hand a quarter turn on, the others at twelve.
        let three = at(3, 0, 0, 0);
        assert!(close(hand_angle(Hand::Hour, &three), 90.0));
        assert!(close(hand_angle(Hand::Minute, &three), 0.0));
        assert!(close(hand_angle(Hand::Second, &three), 0.0));
        // 15:00 is the same place on a twelve-hour face.
        assert!(close(hand_angle(Hand::Hour, &at(15, 0, 0, 0)), 90.0));
        // 09:30:15.500: every hand moves with the smaller units, as on iPhone.
        let later = at(9, 30, 15, 500);
        assert!(close(hand_angle(Hand::Second, &later), 15.5 / 60.0 * 360.0));
        assert!(close(hand_angle(Hand::Minute, &later), (30.0 * 60.0 + 15.5) / 3600.0 * 360.0));
        assert!(close(hand_angle(Hand::Hour, &later), (9.0 * 3600.0 + 30.0 * 60.0 + 15.5) / 43_200.0 * 360.0));
        // The last moment of the day is just short of a full turn.
        let end = at(23, 59, 59, 999);
        assert!(hand_angle(Hand::Hour, &end) > 359.99 && hand_angle(Hand::Hour, &end) < 360.0);
        assert!(hand_angle(Hand::Second, &end) > 359.9 && hand_angle(Hand::Second, &end) < 360.0);
    }

    #[test]
    fn a_clock_hand_follows_its_time_zone() {
        // Noon in UTC is 21:00 in Tokyo and 07:00 in New York (winter).
        let pose = |zone: &str, hand: Hand| Motion::Hand { hand, zone: zone.into() }.pose(NOON);
        assert_eq!(LocalTime::in_zone(NOON, "UTC"), LocalTime::utc(NOON));
        assert_eq!(LocalTime::in_zone(NOON + 1234, "Asia/Tokyo"), LocalTime { year: 2026, month: 1, day: 1, hour: 21, minute: 0, second: 1, millisecond: 234 });
        let turn = |pose: Pose| match pose {
            Pose::Turn(degrees) => degrees,
            Pose::Shift(..) => panic!("a turn"),
        };
        assert!(close(turn(pose("UTC", Hand::Hour)), 0.0));
        assert!(close(turn(pose("Asia/Tokyo", Hand::Hour)), 270.0));
        assert!(close(turn(pose("America/New_York", Hand::Hour)), 210.0));
        // A zone with a half-hour offset moves the minute hand too.
        assert!(close(turn(pose("Asia/Kolkata", Hand::Minute)), 180.0));
        // Past midnight there: the date is the next day, the hand is where 00:30 puts it.
        assert_eq!(LocalTime::in_zone(NOON + 3 * 3_600_000 + 30 * 60_000, "Asia/Tokyo").day, 2);
        assert!(close(turn(Motion::Hand { hand: Hand::Hour, zone: "Asia/Tokyo".into() }.pose(NOON + 3 * 3_600_000 + 30 * 60_000)), 15.0));
        // An unknown zone and "current" are the zone of the system.
        let current = LocalTime::in_zone(NOON, "current");
        assert_eq!(LocalTime::in_zone(NOON, "Nowhere/Nothing"), current);
        assert_eq!(LocalTime::in_zone(NOON, ""), current);
        assert_eq!(pose("Nowhere/Nothing", Hand::Minute), pose("current", Hand::Minute));
    }

    #[test]
    fn a_custom_clock_turns_half_a_circle_each_interval() {
        // Counted from 2001: at the reference date the angle is zero.
        let reference = LocalTime { year: 2001, month: 1, day: 1, hour: 0, minute: 0, second: 0, millisecond: 0 };
        assert!(close(spin_angle(10.0, &reference), 0.0));
        let after = |seconds: u32, millisecond: u32| LocalTime { second: seconds, millisecond, ..reference };
        assert!(close(spin_angle(10.0, &after(5, 0)), 90.0));
        assert!(close(spin_angle(10.0, &after(10, 0)), 180.0));
        assert!(close(spin_angle(10.0, &after(15, 0)), 270.0));
        assert!(close(spin_angle(10.0, &after(20, 0)), 0.0), "a full turn takes twice the interval");
        assert!(close(spin_angle(10.0, &after(2, 500)), 45.0));
        // A negative interval turns the other way.
        assert!(close(spin_angle(-10.0, &after(5, 0)), -90.0));
        // An interval too short to see, and one that is not a number, are replaced.
        assert!(close(spin_angle(0.01, &after(0, 125)), 90.0));
        assert!(close(spin_angle(f64::NAN, &after(5, 0)), 90.0));
        assert_eq!((clock_period(0.0), clock_period(-0.1), clock_period(f64::INFINITY), clock_period(3.0)), (0.25, -0.25, 10.0, 3.0));
        // Midnight is not a jump: one second across it is one second of turning.
        let before = LocalTime { year: 2026, month: 1, day: 1, hour: 23, minute: 59, second: 59, millisecond: 500 };
        let next = LocalTime { year: 2026, month: 1, day: 2, hour: 0, minute: 0, second: 0, millisecond: 500 };
        let step = (spin_angle(7.0, &next) - spin_angle(7.0, &before)).rem_euclid(360.0);
        // Twenty-five years of seconds leave a double about seven digits after the point.
        assert!((step - 180.0 / 7.0).abs() < 1e-4, "{step}");
        // The zone shifts the phase: the angle is counted in local time.
        let spin = Motion::Spin { interval: 3600.0, zone: "UTC".into() };
        let Pose::Turn(utc) = spin.pose(NOON) else { panic!("a turn") };
        let Pose::Turn(tokyo) = (Motion::Spin { interval: 3600.0, zone: "Asia/Tokyo".into() }).pose(NOON) else { panic!("a turn") };
        assert!(((tokyo - utc).rem_euclid(360.0) - 180.0).abs() < 1e-4, "{utc} {tokyo}: nine hours are four and a half turns");
        assert_eq!(spin.period_milliseconds(), Some(7_200_000));
    }

    #[test]
    fn a_swing_goes_there_and_back_in_twice_its_duration() {
        for (elapsed, offset) in [(0.0, 0.0), (0.5, 10.0), (1.0, 0.0), (1.5, -10.0), (2.0, 0.0), (2.5, 10.0), (0.25, 10.0 * std::f64::consts::FRAC_1_SQRT_2)] {
            assert!(close(swing_offset(elapsed, 1.0, 10.0), offset), "{elapsed}: {}", swing_offset(elapsed, 1.0, 10.0));
        }
        // A longer swing is slower; a negative distance starts the other way.
        assert!(close(swing_offset(10.0, 20.0, 6.0), 6.0));
        assert!(close(swing_offset(0.5, 1.0, -4.0), -4.0));
        // What is not a usable number is replaced, as in the Apple runtime.
        assert_eq!((swing_duration(0.0), swing_duration(-3.0), swing_duration(f64::NAN), swing_duration(0.01), swing_duration(1e9)), (1.0, 1.0, 1.0, 0.1, 86_400.0));
        assert_eq!((swing_distance(f64::NAN), swing_distance(1e9), swing_distance(-1e9)), (10.0, 10_000.0, -10_000.0));
        assert_eq!(swing_offset(f64::INFINITY, 1.0, 10.0), 0.0);
        // The pose of a moment: time is counted from 1970.
        let swing = Motion::Swing { horizontal: true, distance: 10.0, duration: 1.0 };
        assert_eq!(swing.pose(0), Pose::Shift(0.0, 0.0));
        let Pose::Shift(x, y) = swing.pose(NOON + 500) else { panic!("a shift") };
        assert!(close(x, 10.0) && y == 0.0, "{x} {y}");
        let Pose::Shift(x, y) = (Motion::Swing { horizontal: false, distance: 10.0, duration: 1.0 }).pose(NOON + 1500) else { panic!("a shift") };
        assert!(x == 0.0 && close(y, -10.0), "{x} {y}");
        // One period later the pose is the same.
        assert_eq!(swing.period_milliseconds(), Some(2000));
        let Pose::Shift(first, _) = swing.pose(NOON + 300) else { panic!("a shift") };
        let Pose::Shift(again, _) = swing.pose(NOON + 2300) else { panic!("a shift") };
        assert!(close(first, again));
    }

    #[test]
    fn the_record_of_the_shared_renderer_is_read() {
        assert_eq!(Motion::parse(r#"{"kind":"clock","type":"clockSecond","timezone":"current","anchor":"center"}"#), Some(Motion::Hand { hand: Hand::Second, zone: "current".into() }));
        assert_eq!(Motion::parse(r#"{"kind":"clock","type":"clockMiniute","timezone":"Asia/Tokyo","anchor":"bottom"}"#), Some(Motion::Hand { hand: Hand::Minute, zone: "Asia/Tokyo".into() }));
        assert_eq!(Motion::parse(r#"{"kind":"clock","type":"clockHour"}"#), Some(Motion::Hand { hand: Hand::Hour, zone: "current".into() }));
        assert_eq!(Motion::parse(r#"{"kind":"clock","type":"clock","timezone":"current","anchor":"center","interval":-20}"#), Some(Motion::Spin { interval: -20.0, zone: "current".into() }));
        assert_eq!(Motion::parse(r#"{"kind":"clock","type":"clock","interval":0.001}"#), Some(Motion::Spin { interval: 0.25, zone: "current".into() }));
        assert_eq!(Motion::parse(r#"{"kind":"swing","axis":"y","distance":6,"duration":15}"#), Some(Motion::Swing { horizontal: false, distance: 6.0, duration: 15.0 }));
        assert_eq!(Motion::parse(r#"{"kind":"swing","axis":"x","distance":1e9,"duration":-1}"#), Some(Motion::Swing { horizontal: true, distance: 10_000.0, duration: 1.0 }));
        for other in ["", "null", "[]", r#"{"kind":"clock","type":"sundial"}"#, r#"{"kind":"fade"}"#, r#"{"type":"clockHour"}"#] {
            assert_eq!(Motion::parse(other), None, "{other}");
        }
        assert_eq!(Motion::Hand { hand: Hand::Second, zone: String::new() }.period_milliseconds(), None);
        assert_eq!(Motion::Spin { interval: -0.25, zone: String::new() }.period_milliseconds(), Some(500));
        assert_eq!(Motion::Swing { horizontal: true, distance: 1.0, duration: 0.1 }.period_milliseconds(), Some(200));
    }

    #[test]
    fn a_moment_outside_the_calendar_rests() {
        let hand = Motion::Hand { hand: Hand::Minute, zone: "UTC".into() };
        assert_eq!(hand.pose(LATEST_MILLISECONDS + 1), Pose::Turn(0.0));
        assert_eq!(hand.pose(EARLIEST_MILLISECONDS - 1), Pose::Turn(0.0));
        assert_eq!(Motion::Spin { interval: 10.0, zone: "UTC".into() }.pose(i64::MAX), Pose::Turn(0.0));
        assert_ne!(hand.pose(LATEST_MILLISECONDS), Pose::Turn(0.0));
    }
}
