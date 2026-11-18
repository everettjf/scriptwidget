//! Snapshots behind `$device` and `$system`: the Linux counterpart of
//! `Windows/src/ScriptWidget.Core/Api/DeviceInfo.cs`. Values are captured
//! once per execution, like the native iOS runtime. None of them needs a
//! permission or a privilege: everything is read from `/etc/os-release`,
//! `/proc`, `/sys` and the environment of the process.
//!
//! Choices where Linux has no single answer (see `docs/windows/README.md`,
//! "Data APIs", for the Windows values they follow):
//! - `model` is always `"PC"`; the hardware model is not exposed to scripts.
//! - `name` and `hostName` are the host name.
//! - `brightness` is always `1`, `thermalState` always `"nominal"` and
//!   `reduceMotionEnabled` always `false`: desktops disagree on where these
//!   live, and none is readable everywhere.
//! - a machine without a battery reports `level` 1 and state `"full"`.
//! - `lowPowerMode` is true when the kernel's platform profile is `low-power`.
//! - `screen` is whatever the host passes in: the runtime has no display
//!   connection of its own.

use std::ffi::CString;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

use crate::intl;
use crate::json::Object;

/// `$system.platform()` on this host.
pub const PLATFORM: &str = "linux";

/// The display a widget is shown on, in points.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Screen {
    pub width: f64,
    pub height: f64,
    pub scale: f64,
}

impl Default for Screen {
    /// What is reported when no display is known, as in a command-line render.
    fn default() -> Self {
        Self { width: 1920.0, height: 1080.0, scale: 1.0 }
    }
}

/// The `device` member of an execution request.
pub fn device_info(screen: Screen) -> Object {
    device_from(Path::new("/"), screen)
}

/// The `system` member of an execution request.
pub fn system_info() -> Object {
    system_from(Path::new("/"))
}

/// `device_info` with the system files read below `root`, for tests.
pub fn device_from(root: &Path, screen: Screen) -> Object {
    let release = os_release(root);
    let (level, state) = battery(root);
    let (total, free) = disk_space(&data_directory());
    object(json!({
        "screen": { "width": screen.width, "height": screen.height, "scale": screen.scale },
        "language": language(&intl::default_locale_tag()),
        "model": "PC",
        "name": host_name(root),
        "battery": { "level": level, "state": state },
        "systemVersion": release.get("VERSION_ID").cloned().filter(|version| !version.is_empty()).unwrap_or_else(|| kernel_release(root)),
        "totalDiskSpace": total,
        "freeDiskSpace": free,
    }))
}

/// `system_info` with the system files read below `root`, for tests.
pub fn system_from(root: &Path) -> Object {
    let locale = intl::default_locale_tag();
    let now = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |elapsed| elapsed.as_secs() as i64);
    let offset = utc_offset_seconds(now);
    let release = os_release(root);
    let pretty = release.get("PRETTY_NAME").or_else(|| release.get("NAME")).cloned().filter(|name| !name.is_empty()).unwrap_or_else(|| "Linux".into());
    let host = host_name(root);
    let active = std::thread::available_parallelism().map_or(1, |count| count.get());
    let (first_weekday, minimum_days) = week_rules(region(&locale));
    object(json!({
        "appInfo": { "name": "ScriptWidget", "bundleId": "com.atomsprout.scriptwidget", "version": env!("CARGO_PKG_VERSION"), "build": "0" },
        "locale": locale.replace('-', "_"),
        "preferredLanguages": preferred_languages(std::env::var("LANGUAGE").ok().as_deref(), &locale),
        "timeZone": { "identifier": intl::default_time_zone(), "abbreviation": abbreviation(offset), "offsetSeconds": offset },
        "is24HourClock": is_24_hour_clock(&locale),
        "calendarInfo": { "identifier": "gregorian", "firstWeekday": first_weekday, "minimumDaysInFirstWeek": minimum_days },
        "systemUptime": uptime(root),
        "memory": { "physical": physical_memory(root) },
        "thermalState": "nominal",
        "lowPowerMode": read(root, "sys/firmware/acpi/platform_profile").is_some_and(|profile| profile.trim() == "low-power"),
        "brightness": 1.0,
        "reduceMotionEnabled": false,
        "platform": PLATFORM,
        "hostName": host,
        "processName": "ScriptWidget",
        "osVersionString": format!("{pretty} (Linux {})", kernel_release(root)),
        "processorCount": configured_processors().max(active),
        "activeProcessorCount": active,
    }))
}

fn object(value: Value) -> Object {
    match value {
        Value::Object(object) => object,
        _ => Object::new(),
    }
}

/// A small text file below `root`; `None` when it is missing, unreadable or implausibly large.
fn read(root: &Path, relative: &str) -> Option<String> {
    let path = root.join(relative);
    let metadata = std::fs::metadata(&path).ok()?;
    if !metadata.is_file() || metadata.len() > 64 * 1024 {
        return None;
    }
    let text = std::fs::read_to_string(path).ok()?;
    (text.len() <= 64 * 1024).then_some(text)
}

/// `KEY=value` lines of os-release(5), with shell quotes removed.
pub fn os_release(root: &Path) -> std::collections::HashMap<String, String> {
    let text = read(root, "etc/os-release").or_else(|| read(root, "usr/lib/os-release")).unwrap_or_default();
    let mut values = std::collections::HashMap::new();
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('#') {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else { continue };
        let value = value.trim();
        let unquoted = match value.as_bytes() {
            [b'"', .., b'"'] | [b'\'', .., b'\''] if value.len() >= 2 => &value[1..value.len() - 1],
            _ => value,
        };
        let mut plain = String::with_capacity(unquoted.len());
        let mut characters = unquoted.chars();
        while let Some(character) = characters.next() {
            // Inside double quotes a backslash protects the next character.
            plain.push(if character == '\\' && value.starts_with('"') { characters.next().unwrap_or('\\') } else { character });
        }
        values.insert(key.trim().to_owned(), plain);
    }
    values
}

fn host_name(root: &Path) -> String {
    ["proc/sys/kernel/hostname", "etc/hostname"]
        .iter()
        .filter_map(|file| read(root, file))
        .map(|text| text.trim().to_owned())
        .find(|name| !name.is_empty())
        .or_else(|| std::env::var("HOSTNAME").ok().filter(|name| !name.is_empty()))
        .unwrap_or_else(|| "localhost".into())
}

fn kernel_release(root: &Path) -> String {
    read(root, "proc/sys/kernel/osrelease").map(|text| text.trim().to_owned()).unwrap_or_default()
}

/// Level 0…1 and `charging`, `unplugged`, `full` or `unknown`, from the first
/// system battery in `/sys/class/power_supply`. Batteries of mice, keyboards
/// and headsets (`scope` `Device`) do not count.
fn battery(root: &Path) -> (f64, &'static str) {
    let directory = root.join("sys/class/power_supply");
    let mut names: Vec<String> = std::fs::read_dir(&directory).into_iter().flatten().filter_map(|entry| entry.ok()?.file_name().into_string().ok()).collect();
    names.sort_unstable();
    let supply = |name: &str, file: &str| read(&directory, &format!("{name}/{file}")).map(|text| text.trim().to_owned());
    let Some(name) = names.iter().find(|name| supply(name, "type").as_deref() == Some("Battery") && supply(name, "scope").as_deref() != Some("Device")) else {
        // A desktop without a battery, as on Windows.
        return (1.0, "full");
    };
    let percent = supply(name, "capacity").and_then(|text| text.parse::<f64>().ok()).filter(|percent| (0.0..=100.0).contains(percent));
    let state = match supply(name, "status").as_deref() {
        Some("Charging") => "charging",
        Some("Discharging") => "unplugged",
        Some("Full") => "full",
        // On external power without charging, for example at a charge limit.
        Some("Not charging") => {
            if percent.is_some_and(|percent| percent >= 100.0) {
                "full"
            } else {
                "charging"
            }
        }
        _ => "unknown",
    };
    (percent.map_or(-1.0, |percent| percent / 100.0), state)
}

fn uptime(root: &Path) -> f64 {
    read(root, "proc/uptime").and_then(|text| text.split_whitespace().next()?.parse::<f64>().ok()).unwrap_or(0.0)
}

fn physical_memory(root: &Path) -> u64 {
    read(root, "proc/meminfo")
        .and_then(|text| {
            let line = text.lines().find(|line| line.starts_with("MemTotal:"))?;
            line.split_whitespace().nth(1)?.parse::<u64>().ok()
        })
        .map_or(0, |kilobytes| kilobytes.saturating_mul(1024))
}

/// Where ScriptWidget keeps its data: `$XDG_DATA_HOME`, or `~/.local/share`.
fn data_directory() -> std::path::PathBuf {
    std::env::var_os("XDG_DATA_HOME")
        .filter(|value| Path::new(value).is_absolute())
        .map(std::path::PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| Path::new(&home).join(".local/share")))
        .unwrap_or_else(|| "/".into())
}

/// Total and available bytes of the file system that holds `path` or its nearest existing parent.
// The field types differ between C libraries.
#[allow(clippy::unnecessary_cast)]
fn disk_space(path: &Path) -> (u64, u64) {
    let mut current = Some(path);
    while let Some(candidate) = current {
        if let Ok(name) = CString::new(candidate.as_os_str().as_encoded_bytes()) {
            // SAFETY: `name` is NUL-terminated and `stats` is a valid place to write the result.
            let stats = unsafe {
                let mut stats = std::mem::MaybeUninit::<libc::statvfs>::zeroed();
                if libc::statvfs(name.as_ptr(), stats.as_mut_ptr()) == 0 { Some(stats.assume_init()) } else { None }
            };
            if let Some(stats) = stats {
                let block = stats.f_frsize as u64;
                return ((stats.f_blocks as u64).saturating_mul(block), (stats.f_bavail as u64).saturating_mul(block));
            }
        }
        current = candidate.parent();
    }
    (0, 0)
}

/// Offset of local time from UTC at `seconds`, in the zone of the process.
#[allow(clippy::unnecessary_cast)]
fn utc_offset_seconds(seconds: i64) -> i64 {
    // SAFETY: `localtime_r` writes into `local` and reads `time`; both live on this stack.
    unsafe {
        let time = seconds as libc::time_t;
        let mut local = std::mem::MaybeUninit::<libc::tm>::zeroed();
        if libc::localtime_r(&time, local.as_mut_ptr()).is_null() { 0 } else { local.assume_init().tm_gmtoff as i64 }
    }
}

/// `GMT+8`, `GMT-3:30`: the form the Windows runtime reports.
fn abbreviation(offset_seconds: i64) -> String {
    let minutes = offset_seconds.abs() / 60;
    let sign = if offset_seconds < 0 { '-' } else { '+' };
    if minutes % 60 == 0 { format!("GMT{sign}{}", minutes / 60) } else { format!("GMT{sign}{}:{:02}", minutes / 60, minutes % 60) }
}

fn configured_processors() -> usize {
    // SAFETY: `sysconf` only reads its argument.
    let count = unsafe { libc::sysconf(libc::_SC_NPROCESSORS_CONF) };
    usize::try_from(count).unwrap_or(1).max(1)
}

/// The language subtag of a BCP 47 tag.
fn language(tag: &str) -> String {
    tag.split(['-', '_']).next().filter(|language| !language.is_empty()).unwrap_or("en").to_ascii_lowercase()
}

/// The two-letter region of a BCP 47 tag, or "".
fn region(tag: &str) -> &str {
    tag.split(['-', '_']).skip(1).find(|part| part.len() == 2 && part.bytes().all(|byte| byte.is_ascii_alphabetic())).unwrap_or("")
}

/// The gettext priority list in `LANGUAGE` ("zh_CN:en_US") as BCP 47 tags, or the locale alone.
fn preferred_languages(variable: Option<&str>, locale: &str) -> Vec<String> {
    let mut languages: Vec<String> = Vec::new();
    for item in variable.unwrap_or("").split(':') {
        let name = item.split(['.', '@']).next().unwrap_or("");
        if name.is_empty() || name == "C" || name == "POSIX" || !name.chars().all(|character| character.is_ascii_alphanumeric() || character == '_' || character == '-') {
            continue;
        }
        let tag = name.replace('_', "-");
        if !languages.contains(&tag) {
            languages.push(tag);
        }
    }
    if languages.is_empty() {
        languages.push(locale.to_owned());
    }
    languages
}

/// Whether the locale writes 13:00 rather than 1 PM, asked of ICU like every other locale question.
fn is_24_hour_clock(locale: &str) -> bool {
    // 13:00 UTC on 2 January 2000, written with Latin digits whatever the locale's own are.
    let locale = if locale.contains("-u-") { locale.to_owned() } else { format!("{locale}-u-nu-latn") };
    let request = json!({ "locale": locale, "time": 946_818_000_000.0, "options": { "hour": "numeric", "timeZone": "UTC" } });
    match intl::call("intl.date", Some(&crate::json::stringify(&request))) {
        Ok(Some(text)) => text.contains("13"),
        _ => true,
    }
}

/// First day of the week (Sunday is 1, as `Calendar.firstWeekday` on iOS) and
/// the minimal days in the first week, by region. CLDR 48's week data, as
/// ICU 78 reports it for every ISO country; other regions use Monday and 1.
fn week_rules(region: &str) -> (u8, u8) {
    const SUNDAY: &[&str] = &[
        "AG", "AS", "BD", "BR", "BS", "BT", "BW", "BZ", "CA", "CO", "DM", "DO", "ET", "GT", "GU", "HK", "HN", "ID", "IL", "IN", "IS", "JM", "JP", "KE", "KH", "KR", "LA", "MH", "MM", "MO", "MT", "MX", "MZ", "NI", "NP",
        "PA", "PE", "PH", "PK", "PR", "PT", "PY", "SA", "SG", "SV", "TH", "TT", "TW", "UM", "US", "VE", "VI", "WS", "YE", "ZA", "ZW",
    ];
    const SATURDAY: &[&str] = &["AF", "BH", "DJ", "DZ", "EG", "IQ", "IR", "JO", "KW", "LY", "OM", "QA", "SD", "SY"];
    const FOUR_DAYS: &[&str] = &[
        "AD", "AT", "AX", "BE", "BG", "CH", "CZ", "DE", "DK", "EE", "ES", "FI", "FJ", "FO", "FR", "GB", "GF", "GG", "GI", "GP", "GR", "HU", "IE", "IM", "IS", "IT", "JE", "LI", "LT", "LU", "MC", "MQ", "NL", "NO", "PL",
        "PT", "RE", "RU", "SE", "SJ", "SK", "SM", "VA",
    ];
    let region = region.to_ascii_uppercase();
    let first = if SUNDAY.contains(&region.as_str()) {
        1
    } else if region == "MV" {
        6
    } else if SATURDAY.contains(&region.as_str()) {
        7
    } else {
        2
    };
    (first, if FOUR_DAYS.contains(&region.as_str()) { 4 } else { 1 })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn offsets_are_written_like_the_other_platforms() {
        assert_eq!(abbreviation(0), "GMT+0");
        assert_eq!(abbreviation(8 * 3600), "GMT+8");
        assert_eq!(abbreviation(-5 * 3600), "GMT-5");
        assert_eq!(abbreviation(-(3 * 3600 + 1800)), "GMT-3:30");
        assert_eq!(abbreviation(5 * 3600 + 45 * 60), "GMT+5:45");
    }

    #[test]
    fn languages_and_regions_come_from_the_locale() {
        assert_eq!(language("zh-Hans-CN"), "zh");
        assert_eq!(language("en_US"), "en");
        assert_eq!(language(""), "en");
        assert_eq!(region("zh-Hans-CN"), "CN");
        assert_eq!(region("en-US"), "US");
        assert_eq!(region("eo"), "");
        assert_eq!(preferred_languages(Some("zh_CN.UTF-8:en_US:zh_CN:C:../x"), "de-DE"), ["zh-CN", "en-US"]);
        assert_eq!(preferred_languages(Some(""), "de-DE"), ["de-DE"]);
        assert_eq!(preferred_languages(None, "de-DE"), ["de-DE"]);
    }

    #[test]
    fn weeks_follow_the_region() {
        assert_eq!(week_rules("US"), (1, 1));
        assert_eq!(week_rules("de"), (2, 4));
        assert_eq!(week_rules("GB"), (2, 4));
        assert_eq!(week_rules("CN"), (2, 1));
        assert_eq!(week_rules("EG"), (7, 1));
        assert_eq!(week_rules(""), (2, 1));
        assert_eq!(week_rules("MV"), (6, 1));
        assert_eq!(week_rules("PT"), (1, 4));
    }
}
