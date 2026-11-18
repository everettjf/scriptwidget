//! ICU-backed implementation of the Intl subset installed by the QuickJS host
//! file. QuickJS has no Intl; JavaScriptCore on iPhone and the Android and
//! Windows hosts format with ICU as well, so the same skeletons produce
//! matching text for the same locale data. This calls the system ICU through
//! the shim in `native/icu_shim.c`.
//!
//! Ported from `Windows/src/ScriptWidget.Core/Runtime/IntlBridge.cs`.

use std::collections::{HashMap, VecDeque};
use std::ffi::{CStr, CString, c_char, c_void};
use std::ptr;
use std::sync::{Mutex, RwLock};

use serde_json::{Value, json};

use crate::json::{Object, ObjectExt, as_text, parse_object, stringify, stringify_object};

static LOCALE_OVERRIDE: RwLock<Option<String>> = RwLock::new(None);
static TIME_ZONE_OVERRIDE: RwLock<Option<String>> = RwLock::new(None);

/// Overrides the system locale; used by deterministic tests.
pub fn set_locale_override(tag: Option<&str>) {
    *LOCALE_OVERRIDE.write().unwrap_or_else(|poisoned| poisoned.into_inner()) = tag.map(str::to_owned);
}

/// Overrides the zone Intl formats in and the zone of JavaScript's local
/// time, for the whole process; used by deterministic tests.
///
/// # Safety
/// Same contract as [`sw_quickjs::set_process_time_zone`], which this calls:
/// no other thread may use the environment or local time meanwhile.
pub unsafe fn set_time_zone_override(iana_name: Option<&str>) {
    *TIME_ZONE_OVERRIDE.write().unwrap_or_else(|poisoned| poisoned.into_inner()) = iana_name.map(str::to_owned);
    // SAFETY: guaranteed by the caller.
    unsafe { sw_quickjs::set_process_time_zone(iana_name) };
}

/// BCP 47 tag of the user's locale: the override, or the POSIX locale of the
/// process ("en_US.UTF-8" is "en-US"), or "en-US".
pub fn default_locale_tag() -> String {
    if let Some(tag) = LOCALE_OVERRIDE.read().unwrap_or_else(|poisoned| poisoned.into_inner()).clone() {
        return tag;
    }
    ["LC_ALL", "LC_TIME", "LANG"]
        .iter()
        .filter_map(|name| std::env::var(name).ok())
        .find(|value| !value.is_empty())
        .and_then(|value| posix_locale_tag(&value))
        .unwrap_or_else(|| "en-US".into())
}

fn posix_locale_tag(value: &str) -> Option<String> {
    let name = value.split(['.', '@']).next().unwrap_or("");
    if name.is_empty() || name == "C" || name == "POSIX" || !name.chars().all(|character| character.is_ascii_alphanumeric() || character == '_') {
        return None;
    }
    Some(name.replace('_', "-"))
}

/// IANA name of the zone local time is shown in.
pub fn default_time_zone() -> String {
    if let Some(zone) = TIME_ZONE_OVERRIDE.read().unwrap_or_else(|poisoned| poisoned.into_inner()).clone() {
        return zone;
    }
    // SAFETY: the buffer and capacity describe the same memory.
    text("Time zone", |buffer, capacity, status| unsafe { icu::sw_ucal_getDefaultTimeZone(buffer, capacity, status) })
        .ok()
        .map(|zone| String::from_utf16_lossy(&zone))
        .filter(|zone| !zone.is_empty() && zone != "Etc/Unknown")
        .unwrap_or_else(|| "UTC".into())
}

/// Version of the ICU library in use, such as "78.3".
pub fn icu_version() -> String {
    let mut version = [0u8; 4];
    // SAFETY: the function writes four bytes.
    unsafe { icu::sw_u_getVersion(version.as_mut_ptr()) };
    format!("{}.{}", version[0], version[1])
}

pub fn handles(operation: &str) -> bool {
    operation.starts_with("intl.")
}

/// Formatters are cached and ICU objects are not shared between threads at
/// the same time: every operation runs under this lock.
static STATE: Mutex<State> = Mutex::new(State { formats: None, order: VecDeque::new() });

struct State {
    /// Building an ICU formatter is far more expensive than using one; planners format thousands of dates.
    formats: Option<HashMap<String, DateFormat>>,
    order: VecDeque<String>,
}

struct DateFormat(*mut c_void);

// SAFETY: a UDateFormat may be used from any thread, one at a time; `STATE`'s lock guarantees that.
unsafe impl Send for DateFormat {}

impl Drop for DateFormat {
    fn drop(&mut self) {
        // SAFETY: opened by udat_open and closed once.
        unsafe { icu::sw_udat_close(self.0) }
    }
}

const FORMAT_CACHE_SIZE: usize = 32;

/// Answers an `intl.*` host operation. `Ok(None)` means the operation is not
/// one of this module's; an error is thrown in JavaScript.
pub fn call(operation: &str, payload: Option<&str>) -> Result<Option<String>, String> {
    match operation {
        "intl.locale" => return Ok(Some(default_locale_tag())),
        "intl.timeZone" => return Ok(Some(default_time_zone())),
        "intl.validZone" => return Ok(Some(if is_valid_zone(payload.unwrap_or("")) { "1" } else { "0" }.into())),
        _ => {}
    }
    if !handles(operation) {
        return Ok(None);
    }
    let request = parse_object(payload.ok_or("Missing Intl request")?)?;
    let mut state = STATE.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    match operation {
        "intl.date" => format_date(&mut state, &request).map(Some),
        "intl.dateParts" => date_parts(&mut state, &request).map(|parts| Some(stringify(&parts))),
        "intl.number" => format_number(&request).map(Some),
        "intl.plural" => plural(&request).map(Some),
        "intl.relative" => relative(&request).map(Some),
        "intl.compare" => compare(&request).map(Some),
        "intl.list" => list(&request).map(Some),
        _ => Ok(None),
    }
}

// MARK: - Locales and zones

/// ICU locale ID ("en_US") for a BCP 47 tag ("en-US").
fn locale(tag: &str) -> CString {
    let fallback = || CString::from(c"en_US");
    let Ok(input) = CString::new(tag.replace('_', "-")) else { return fallback() };
    let mut output = [0 as c_char; 160];
    let mut status = 0;
    // SAFETY: `input` is NUL-terminated and the capacity leaves room for the terminator.
    let length = unsafe { icu::sw_uloc_forLanguageTag(input.as_ptr(), output.as_mut_ptr(), output.len() as i32 - 1, ptr::null_mut(), &mut status) };
    if status > 0 || length <= 0 {
        return fallback();
    }
    // SAFETY: the last element is never written, so the buffer is NUL-terminated.
    unsafe { CStr::from_ptr(output.as_ptr()) }.to_owned()
}

fn required_locale(request: &Object) -> Result<String, String> {
    request.opt_string_or_none("locale").ok_or_else(|| "Missing locale".into())
}

fn is_valid_zone(id: &str) -> bool {
    if id.eq_ignore_ascii_case("UTC") || id.eq_ignore_ascii_case("GMT") {
        return true;
    }
    let units = utf16(id);
    if units.is_empty() || units.len() > 100 {
        return false;
    }
    let mut buffer = [0u16; 128];
    let mut status = 0;
    let mut system = 0i8;
    // SAFETY: lengths and capacities describe the buffers passed with them.
    unsafe { icu::sw_ucal_getCanonicalTimeZoneID(units.as_ptr(), units.len() as i32, buffer.as_mut_ptr(), buffer.len() as i32, &mut system, &mut status) };
    status <= 0 && system != 0
}

fn check(status: i32, what: &str) -> Result<(), String> {
    if status > 0 { Err(format!("{what} failed (ICU error {status})")) } else { Ok(()) }
}

fn utf16(text: &str) -> Vec<u16> {
    text.encode_utf16().collect()
}

/// Runs an ICU call that writes UTF-16 into a buffer, growing the buffer when it is too small.
fn text(what: &str, mut fill: impl FnMut(*mut u16, i32, *mut i32) -> i32) -> Result<Vec<u16>, String> {
    let mut capacity = 256usize;
    loop {
        let mut buffer = vec![0u16; capacity];
        let mut status = 0;
        let length = fill(buffer.as_mut_ptr(), capacity as i32, &mut status);
        if status == icu::BUFFER_OVERFLOW && capacity < 1 << 20 {
            capacity = (length.max(0) as usize + 1).max(capacity * 2);
            continue;
        }
        check(status, what)?;
        buffer.truncate((length.max(0) as usize).min(capacity));
        return Ok(buffer);
    }
}

// MARK: - Dates

fn empty_options() -> Object {
    Object::new()
}

fn options_of(request: &Object) -> Object {
    request.opt_object("options").cloned().unwrap_or_else(empty_options)
}

/// The cached formatter for the request's locale and options.
fn date_format<'state>(state: &'state mut State, request: &Object) -> Result<&'state DateFormat, String> {
    let options = options_of(request);
    let key = format!("{}|{}|{}", required_locale(request)?, default_time_zone(), stringify_object(&options));
    let State { formats, order } = state;
    let formats = formats.get_or_insert_with(HashMap::new);
    if formats.contains_key(&key) {
        order.retain(|item| item != &key);
    } else {
        let created = create_date_format(request, &options)?;
        formats.insert(key.clone(), created);
        if formats.len() > FORMAT_CACHE_SIZE
            && let Some(eldest) = order.pop_front()
        {
            formats.remove(&eldest);
        }
    }
    order.push_back(key.clone());
    Ok(&formats[&key])
}

fn create_date_format(request: &Object, options: &Object) -> Result<DateFormat, String> {
    let locale = locale(&required_locale(request)?);
    let requested = options.opt_string("timeZone");
    let zone = utf16(&if requested.is_empty() { default_time_zone() } else { requested });
    let date_style = style(&options.opt_string("dateStyle"));
    let time_style = style(&options.opt_string("timeStyle"));
    let mut status = 0;
    let format = if date_style.is_some() || time_style.is_some() {
        // SAFETY: every pointer is valid for the length passed with it.
        unsafe {
            icu::sw_udat_open(time_style.unwrap_or(icu::STYLE_NONE), date_style.unwrap_or(icu::STYLE_NONE), locale.as_ptr(), zone.as_ptr(), zone.len() as i32, ptr::null(), 0, &mut status)
        }
    } else {
        let skeleton = utf16(&skeleton(options));
        // SAFETY: `locale` is NUL-terminated.
        let generator = unsafe { icu::sw_udatpg_open(locale.as_ptr(), &mut status) };
        check(status, "Date pattern generator")?;
        // SAFETY: the generator is open; lengths describe the buffers.
        let pattern = text("Date pattern", |buffer, capacity, error| unsafe {
            icu::sw_udatpg_getBestPattern(generator, skeleton.as_ptr(), skeleton.len() as i32, buffer, capacity, error)
        });
        // SAFETY: opened above, closed once.
        unsafe { icu::sw_udatpg_close(generator) };
        let pattern = apply_hour_width(&pattern?, &options.opt_string("hour"));
        // SAFETY: every pointer is valid for the length passed with it.
        unsafe {
            icu::sw_udat_open(icu::STYLE_PATTERN, icu::STYLE_PATTERN, locale.as_ptr(), zone.as_ptr(), zone.len() as i32, pattern.as_ptr(), pattern.len() as i32, &mut status)
        }
    };
    if status > 0 || format.is_null() {
        if !format.is_null() {
            drop(DateFormat(format));
        }
        return Err(format!("Date format failed (ICU error {status})"));
    }
    Ok(DateFormat(format))
}

/// ECMA-402 keeps the requested hour width even when the locale pattern for
/// the skeleton uses another one ("2-digit" gives "08:00 PM" in en-US).
fn apply_hour_width(pattern: &[u16], hour: &str) -> Vec<u16> {
    let width = match hour {
        "2-digit" => 2,
        "numeric" => 1,
        _ => return pattern.to_vec(),
    };
    let is_hour = |unit: u16| b"hHkK".iter().any(|letter| unit == u16::from(*letter));
    let mut result = Vec::with_capacity(pattern.len() + 2);
    let mut index = 0;
    let mut quoted = false;
    while index < pattern.len() {
        let unit = pattern[index];
        if unit == u16::from(b'\'') {
            quoted = !quoted;
        } else if !quoted && is_hour(unit) {
            while index < pattern.len() && pattern[index] == unit {
                index += 1;
            }
            result.extend(std::iter::repeat_n(unit, width));
            continue;
        }
        result.push(unit);
        index += 1;
    }
    result
}

fn style(name: &str) -> Option<i32> {
    match name {
        "full" => Some(0),
        "long" => Some(1),
        "medium" => Some(2),
        "short" => Some(3),
        _ => None,
    }
}

/// Maps ECMA-402 date options to an ICU skeleton.
fn skeleton(options: &Object) -> String {
    let mut text = String::new();
    let repeat = |text: &mut String, letter: char, count: usize| text.extend(std::iter::repeat_n(letter, count));
    let width = |text: &mut String, name: &str, letter: char| match options.opt_string(name).as_str() {
        "narrow" => repeat(text, letter, 5),
        "short" => repeat(text, letter, 3),
        "long" => repeat(text, letter, 4),
        "numeric" => repeat(text, letter, 1),
        "2-digit" => repeat(text, letter, 2),
        _ => {}
    };
    let named = |text: &mut String, name: &str, narrow: &str, short: &str, long: &str| match options.opt_string(name).as_str() {
        "narrow" => text.push_str(narrow),
        "short" => text.push_str(short),
        "long" => text.push_str(long),
        _ => {}
    };
    named(&mut text, "era", "GGGGG", "G", "GGGG");
    width(&mut text, "year", 'y');
    width(&mut text, "month", 'M');
    named(&mut text, "weekday", "EEEEE", "EEE", "EEEE");
    width(&mut text, "day", 'd');
    let hour = options.opt_string("hour");
    if !hour.is_empty() {
        let letter = if options.has("hourCycle") {
            match options.opt_string("hourCycle").as_str() {
                "h11" => 'K',
                "h12" => 'h',
                "h23" => 'H',
                "h24" => 'k',
                _ => 'j',
            }
        } else if options.has("hour12") {
            if options.opt_bool("hour12", false) { 'h' } else { 'H' }
        } else {
            'j'
        };
        repeat(&mut text, letter, if hour == "2-digit" { 2 } else { 1 });
    }
    named(&mut text, "dayPeriod", "BBBBB", "B", "BBBB");
    let minute = options.opt_string("minute");
    if !minute.is_empty() {
        text.push_str(if minute == "2-digit" { "mm" } else { "m" });
    }
    let second = options.opt_string("second");
    if !second.is_empty() {
        text.push_str(if second == "2-digit" { "ss" } else { "s" });
    }
    let fraction = options.opt_i32("fractionalSecondDigits", 0);
    if (1..=3).contains(&fraction) {
        repeat(&mut text, 'S', fraction as usize);
    }
    text.push_str(match options.opt_string("timeZoneName").as_str() {
        "short" => "z",
        "long" => "zzzz",
        "shortOffset" => "O",
        "longOffset" => "OOOO",
        "shortGeneric" => "v",
        "longGeneric" => "vvvv",
        _ => "",
    });
    text
}

fn time(request: &Object) -> Result<f64, String> {
    let time = request.opt_f64("time");
    if time.is_nan() { Err("Invalid time value".into()) } else { Ok(time.trunc()) }
}

fn format_date(state: &mut State, request: &Object) -> Result<String, String> {
    let time = time(request)?;
    let format = date_format(state, request)?;
    // SAFETY: the formatter is open and used under the state lock.
    let formatted = text("Date format", |buffer, capacity, status| unsafe { icu::sw_udat_format(format.0, time, buffer, capacity, status) })?;
    Ok(normalize_spaces(&formatted))
}

/// ICU 72+ separates the day period with U+202F; JavaScriptCore emits a plain space for compatibility.
fn normalize_spaces(text: &[u16]) -> String {
    String::from_utf16_lossy(text).replace('\u{202f}', " ")
}

/// ECMA-402 part type of a UDateFormatField.
fn part_name(field: i32) -> &'static str {
    match field {
        0 => "era",
        1 | 18 | 20 | 30 | 34 => "year",
        2 | 26 => "month",
        3 => "day",
        9 | 19 | 25 => "weekday",
        4 | 5 | 15 | 16 => "hour",
        6 => "minute",
        7 => "second",
        8 => "fractionalSecond",
        14 | 35 | 36 => "dayPeriod",
        17 | 23 | 24 | 29 | 31 | 32 | 33 => "timeZoneName",
        _ => "literal",
    }
}

fn date_parts(state: &mut State, request: &Object) -> Result<Value, String> {
    let time = time(request)?;
    let format = date_format(state, request)?;
    let mut status = 0;
    // SAFETY: closed below on every path.
    let iterator = unsafe { icu::sw_ufieldpositer_open(&mut status) };
    check(status, "Date parts")?;
    // SAFETY: formatter and iterator are open.
    let formatted = text("Date parts", |buffer, capacity, error| unsafe { icu::sw_udat_formatForFields(format.0, time, buffer, capacity, iterator, error) });
    // The iterator holds the fields of the last successful call.
    let mut fields: Vec<(i32, i32, i32)> = Vec::new();
    if formatted.is_ok() {
        loop {
            let (mut start, mut end) = (0, 0);
            // SAFETY: the iterator is open.
            let field = unsafe { icu::sw_ufieldpositer_next(iterator, &mut start, &mut end) };
            if field < 0 {
                break;
            }
            fields.push((start, end, field));
        }
    }
    // SAFETY: opened above, closed once.
    unsafe { icu::sw_ufieldpositer_close(iterator) };
    let formatted = formatted?;
    fields.sort_by(|left, right| left.0.cmp(&right.0).then(right.1.cmp(&left.1)));

    let mut parts = Vec::new();
    let mut add = |kind: &str, start: usize, end: usize| {
        if end > start {
            parts.push(json!({ "type": kind, "value": normalize_spaces(&formatted[start..end]) }));
        }
    };
    let mut index = 0usize;
    for (start, end, field) in fields {
        if start < 0 || (start as usize) < index || end as usize > formatted.len() || end < start {
            continue;
        }
        let (start, end) = (start as usize, end as usize);
        add("literal", index, start);
        add(part_name(field), start, end);
        index = end;
    }
    add("literal", index, formatted.len());
    Ok(Value::Array(parts))
}

// MARK: - Numbers

fn format_number(request: &Object) -> Result<String, String> {
    let locale = locale(&required_locale(request)?);
    let options = options_of(request);
    let value = match request.opt_string("value").as_str() {
        "Infinity" => f64::INFINITY,
        "-Infinity" => f64::NEG_INFINITY,
        // Rust would also read "inf" and "nan"; JavaScript's String(Number) never produces them.
        raw if raw.bytes().all(|byte| byte.is_ascii_digit() || matches!(byte, b'+' | b'-' | b'.' | b'e' | b'E')) => raw.parse().unwrap_or(f64::NAN),
        _ => f64::NAN,
    };
    if value.is_nan() {
        return Ok("NaN".into());
    }
    if value.is_infinite() {
        return Ok(if value > 0.0 { "∞" } else { "-∞" }.into());
    }

    let requested = options.opt_string("style");
    let style = if requested.is_empty() { "decimal" } else { requested.as_str() };
    let mut skeleton = String::new();
    let mut default_minimum = 0;
    let mut default_maximum = 3;
    match style {
        "percent" => {
            skeleton.push_str("percent scale/100 ");
            default_maximum = 0;
        }
        "currency" => {
            let code = options.opt_string("currency");
            let currency = if code.is_empty() { "USD".to_owned() } else { code.to_uppercase() };
            if currency.len() != 3 || !currency.bytes().all(|byte| byte.is_ascii_alphabetic()) {
                return Err(format!("Invalid currency code {currency}"));
            }
            skeleton.push_str(&format!("currency/{currency} "));
            let mut code_units = utf16(&currency);
            code_units.push(0);
            let mut status = 0;
            // SAFETY: the code is NUL-terminated.
            let digits = unsafe { icu::sw_ucurr_getDefaultFractionDigits(code_units.as_ptr(), &mut status) };
            let digits = if status > 0 { 2 } else { digits };
            default_minimum = digits;
            default_maximum = digits;
            skeleton.push_str(match options.opt_string("currencyDisplay").as_str() {
                "code" => "unit-width-iso-code ",
                "name" => "unit-width-full-name ",
                "narrowSymbol" => "unit-width-narrow ",
                _ => "",
            });
        }
        _ => {}
    }
    let notation = options.opt_string("notation");
    match notation.as_str() {
        "compact" => skeleton.push_str(if options.opt_string("compactDisplay") == "long" { "compact-long " } else { "compact-short " }),
        "scientific" => skeleton.push_str("scientific "),
        "engineering" => skeleton.push_str("engineering "),
        _ => {}
    }
    let compact = notation == "compact";
    let repeat = |letter: char, count: i32| letter.to_string().repeat(count.max(0) as usize);
    if options.has("minimumSignificantDigits") || options.has("maximumSignificantDigits") {
        let minimum = options.opt_i32("minimumSignificantDigits", 1).clamp(1, 21);
        let maximum = options.opt_i32("maximumSignificantDigits", 21).clamp(minimum, 21);
        skeleton.push_str(&format!("{}{} ", repeat('@', minimum), repeat('#', maximum - minimum)));
    } else if options.has("minimumFractionDigits") || options.has("maximumFractionDigits") || !compact {
        let minimum = options.opt_i32("minimumFractionDigits", default_minimum.min(options.opt_i32("maximumFractionDigits", default_minimum))).clamp(0, 100);
        let maximum = options.opt_i32("maximumFractionDigits", default_maximum.max(minimum)).clamp(minimum, 100);
        if maximum == 0 {
            skeleton.push_str("precision-integer ");
        } else {
            skeleton.push_str(&format!(".{}{} ", repeat('0', minimum), repeat('#', maximum - minimum)));
        }
    }
    if options.has("minimumIntegerDigits") {
        skeleton.push_str(&format!("integer-width/*{} ", repeat('0', options.opt_i32("minimumIntegerDigits", 1).clamp(1, 21))));
    }
    if options.has("useGrouping") && !options.opt_bool("useGrouping", true) {
        skeleton.push_str("group-off ");
    }
    skeleton.push_str(match options.opt_string("signDisplay").as_str() {
        "always" => "sign-always ",
        "never" => "sign-never ",
        "exceptZero" => "sign-except-zero ",
        _ => "",
    });

    let skeleton = utf16(skeleton.trim_end());
    let mut error = 0;
    // SAFETY: lengths describe the buffers; `locale` is NUL-terminated.
    let formatter = unsafe { icu::sw_unumf_openForSkeletonAndLocale(skeleton.as_ptr(), skeleton.len() as i32, locale.as_ptr(), &mut error) };
    if error > 0 || formatter.is_null() {
        if !formatter.is_null() {
            // SAFETY: opened above.
            unsafe { icu::sw_unumf_close(formatter) };
        }
        return Err(format!("Number format failed (ICU error {error})"));
    }
    // SAFETY: closed below.
    let result = unsafe { icu::sw_unumf_openResult(&mut error) };
    let formatted = (|| {
        check(error, "Number format")?;
        // The decimal expansion of the double, like BigDecimal(value) on Android.
        let digits = format!("{value:.60e}");
        let mut error = 0;
        // SAFETY: formatter and result are open; the length describes `digits`.
        unsafe { icu::sw_unumf_formatDecimal(formatter, digits.as_ptr().cast(), digits.len() as i32, result, &mut error) };
        check(error, "Number format")?;
        // SAFETY: the result is open.
        text("Number format", |buffer, capacity, status| unsafe { icu::sw_unumf_resultToString(result, buffer, capacity, status) })
    })();
    // SAFETY: both were opened above and are closed once.
    unsafe {
        if !result.is_null() {
            icu::sw_unumf_closeResult(result);
        }
        icu::sw_unumf_close(formatter);
    }
    Ok(String::from_utf16_lossy(&formatted?))
}

fn plural(request: &Object) -> Result<String, String> {
    let locale = locale(&required_locale(request)?);
    let mut status = 0;
    // SAFETY: `locale` is NUL-terminated.
    let rules = unsafe { icu::sw_uplrules_openForType(locale.as_ptr(), if request.opt_string("type") == "ordinal" { 1 } else { 0 }, &mut status) };
    check(status, "Plural rules")?;
    let value = request.opt_f64("value");
    // SAFETY: the rules are open.
    let keyword = text("Plural rules", |buffer, capacity, error| unsafe { icu::sw_uplrules_select(rules, value, buffer, capacity, error) });
    // SAFETY: opened above, closed once.
    unsafe { icu::sw_uplrules_close(rules) };
    Ok(String::from_utf16_lossy(&keyword?))
}

fn relative(request: &Object) -> Result<String, String> {
    let options = options_of(request);
    let style = match options.opt_string("style").as_str() {
        "short" => 1,
        "narrow" => 2,
        _ => 0,
    };
    let name = request.opt_string("unit");
    let unit = match name.strip_suffix('s').unwrap_or(&name) {
        "year" => 0,
        "quarter" => 1,
        "month" => 2,
        "week" => 3,
        "day" => 4,
        "hour" => 5,
        "minute" => 6,
        "second" => 7,
        _ => return Err("Invalid unit argument for format()".into()),
    };
    let locale = locale(&required_locale(request)?);
    let mut status = 0;
    // SAFETY: `locale` is NUL-terminated.
    let formatter = unsafe { icu::sw_ureldatefmt_open(locale.as_ptr(), style, &mut status) };
    check(status, "Relative time format")?;
    let value = request.opt_f64("value");
    let automatic = options.opt_string("numeric") == "auto";
    // SAFETY: the formatter is open.
    let formatted = text("Relative time format", |buffer, capacity, error| unsafe {
        if automatic { icu::sw_ureldatefmt_format(formatter, value, unit, buffer, capacity, error) } else { icu::sw_ureldatefmt_formatNumeric(formatter, value, unit, buffer, capacity, error) }
    });
    // SAFETY: opened above, closed once.
    unsafe { icu::sw_ureldatefmt_close(formatter) };
    Ok(String::from_utf16_lossy(&formatted?))
}

fn compare(request: &Object) -> Result<String, String> {
    let locale = locale(&required_locale(request)?);
    let left = utf16(&request.opt_string("left"));
    let right = utf16(&request.opt_string("right"));
    let mut status = 0;
    // SAFETY: `locale` is NUL-terminated.
    let collator = unsafe { icu::sw_ucol_open(locale.as_ptr(), &mut status) };
    check(status, "Collator")?;
    // SAFETY: the collator is open; lengths describe the buffers. Closed once.
    let result = unsafe {
        let result = icu::sw_ucol_strcoll(collator, left.as_ptr(), left.len() as i32, right.as_ptr(), right.len() as i32);
        icu::sw_ucol_close(collator);
        result
    };
    Ok(result.clamp(-1, 1).to_string())
}

fn list(request: &Object) -> Result<String, String> {
    let items: Vec<Vec<u16>> = request.opt_array("items").map(|items| items.iter().map(|item| utf16(&as_text(item).unwrap_or_default())).collect()).unwrap_or_default();
    let options = options_of(request);
    let kind = match options.opt_string("type").as_str() {
        "disjunction" => 1,
        "unit" => 2,
        _ => 0,
    };
    let width = match options.opt_string("style").as_str() {
        "short" => 1,
        "narrow" => 2,
        _ => 0,
    };
    if items.is_empty() {
        return Ok(String::new());
    }
    let locale = locale(&required_locale(request)?);
    let mut status = 0;
    // SAFETY: `locale` is NUL-terminated.
    let formatter = unsafe { icu::sw_ulistfmt_openForType(locale.as_ptr(), kind, width, &mut status) };
    check(status, "List format")?;
    let pointers: Vec<*const u16> = items.iter().map(|item| item.as_ptr()).collect();
    let lengths: Vec<i32> = items.iter().map(|item| item.len() as i32).collect();
    // SAFETY: the formatter is open; both arrays have `items.len()` entries.
    let formatted = text("List format", |buffer, capacity, error| unsafe {
        icu::sw_ulistfmt_format(formatter, pointers.as_ptr(), lengths.as_ptr(), items.len() as i32, buffer, capacity, error)
    });
    // SAFETY: opened above, closed once.
    unsafe { icu::sw_ulistfmt_close(formatter) };
    Ok(String::from_utf16_lossy(&formatted?))
}

/// The functions of `native/icu_shim.c`.
mod icu {
    use std::ffi::{c_char, c_void};

    pub const BUFFER_OVERFLOW: i32 = 15;
    pub const STYLE_NONE: i32 = -1;
    pub const STYLE_PATTERN: i32 = -2;

    unsafe extern "C" {
        pub fn sw_u_getVersion(version: *mut u8);
        pub fn sw_uloc_forLanguageTag(tag: *const c_char, locale_id: *mut c_char, capacity: i32, parsed_length: *mut i32, status: *mut i32) -> i32;
        pub fn sw_ucal_getCanonicalTimeZoneID(id: *const u16, length: i32, result: *mut u16, capacity: i32, is_system_id: *mut i8, status: *mut i32) -> i32;
        pub fn sw_ucal_getDefaultTimeZone(result: *mut u16, capacity: i32, status: *mut i32) -> i32;

        pub fn sw_udat_open(time_style: i32, date_style: i32, locale: *const c_char, zone: *const u16, zone_length: i32, pattern: *const u16, pattern_length: i32, status: *mut i32) -> *mut c_void;
        pub fn sw_udat_close(format: *mut c_void);
        pub fn sw_udat_format(format: *const c_void, date: f64, result: *mut u16, capacity: i32, status: *mut i32) -> i32;
        pub fn sw_udat_formatForFields(format: *const c_void, date: f64, result: *mut u16, capacity: i32, iterator: *mut c_void, status: *mut i32) -> i32;
        pub fn sw_ufieldpositer_open(status: *mut i32) -> *mut c_void;
        pub fn sw_ufieldpositer_close(iterator: *mut c_void);
        pub fn sw_ufieldpositer_next(iterator: *mut c_void, begin: *mut i32, end: *mut i32) -> i32;
        pub fn sw_udatpg_open(locale: *const c_char, status: *mut i32) -> *mut c_void;
        pub fn sw_udatpg_close(generator: *mut c_void);
        pub fn sw_udatpg_getBestPattern(generator: *mut c_void, skeleton: *const u16, length: i32, pattern: *mut u16, capacity: i32, status: *mut i32) -> i32;

        pub fn sw_unumf_openForSkeletonAndLocale(skeleton: *const u16, length: i32, locale: *const c_char, status: *mut i32) -> *mut c_void;
        pub fn sw_unumf_close(formatter: *mut c_void);
        pub fn sw_unumf_openResult(status: *mut i32) -> *mut c_void;
        pub fn sw_unumf_closeResult(result: *mut c_void);
        pub fn sw_unumf_formatDecimal(formatter: *const c_void, value: *const c_char, length: i32, result: *mut c_void, status: *mut i32);
        pub fn sw_unumf_resultToString(result: *const c_void, buffer: *mut u16, capacity: i32, status: *mut i32) -> i32;
        pub fn sw_ucurr_getDefaultFractionDigits(currency: *const u16, status: *mut i32) -> i32;

        pub fn sw_uplrules_openForType(locale: *const c_char, kind: i32, status: *mut i32) -> *mut c_void;
        pub fn sw_uplrules_close(rules: *mut c_void);
        pub fn sw_uplrules_select(rules: *const c_void, number: f64, keyword: *mut u16, capacity: i32, status: *mut i32) -> i32;

        pub fn sw_ureldatefmt_open(locale: *const c_char, width: i32, status: *mut i32) -> *mut c_void;
        pub fn sw_ureldatefmt_close(formatter: *mut c_void);
        pub fn sw_ureldatefmt_format(formatter: *const c_void, offset: f64, unit: i32, result: *mut u16, capacity: i32, status: *mut i32) -> i32;
        pub fn sw_ureldatefmt_formatNumeric(formatter: *const c_void, offset: f64, unit: i32, result: *mut u16, capacity: i32, status: *mut i32) -> i32;

        pub fn sw_ucol_open(locale: *const c_char, status: *mut i32) -> *mut c_void;
        pub fn sw_ucol_close(collator: *mut c_void);
        pub fn sw_ucol_strcoll(collator: *const c_void, source: *const u16, source_length: i32, target: *const u16, target_length: i32) -> i32;

        pub fn sw_ulistfmt_openForType(locale: *const c_char, kind: i32, width: i32, status: *mut i32) -> *mut c_void;
        pub fn sw_ulistfmt_close(formatter: *mut c_void);
        pub fn sw_ulistfmt_format(formatter: *const c_void, strings: *const *const u16, lengths: *const i32, count: i32, result: *mut u16, capacity: i32, status: *mut i32) -> i32;
    }
}
