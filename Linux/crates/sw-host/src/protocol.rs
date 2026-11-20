//! The words of the display protocol (`docs/linux/protocol.md`): the
//! requests a client may send over the socket, the replies, and the events
//! `scriptwidget watch` prints.
//!
//! A request is one line of JSON that names only package names, widget
//! identifiers, integers and fixed words. Everything is validated here, on
//! both sides: the command line refuses a bad argument before it connects,
//! and the service refuses it again, because any program of the user can
//! write to the socket.

use serde_json::{Map, Value, json};
use sw_core::packages::names;

/// The version in `hello`. A display that does not know it shows "update ScriptWidget" and parses nothing else.
pub const PROTOCOL: u32 = 1;
/// A request line, without its line feed, is at most this long.
pub const MAXIMUM_LINE_BYTES: usize = 4096;
/// The words `menu` accepts. Nothing else is ever looked up.
pub const MENU_WORDS: [&str; 7] = ["resize-small", "resize-medium", "resize-large", "resize-extraLarge", "edit", "remove", "refresh"];
pub const FAMILIES: [&str; 4] = sw_core::library::FAMILIES;
/// Offsets are kept inside this range, as on Windows.
pub const MAXIMUM_OFFSET: i64 = 100_000;
/// A display reports its scale in thousandths: 1000 is 1, 1500 is 1.5.
pub const MINIMUM_SCALE: i64 = 500;
pub const MAXIMUM_SCALE: i64 = 8000;
pub const MAXIMUM_SCREEN_LENGTH: i64 = 32_768;
const IDENTIFIER_LENGTH: usize = 16;
const MAXIMUM_SCREEN_NAME: usize = 64;

/// Why a request was refused: a fixed code and a sentence for a person.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Refusal {
    pub code: &'static str,
    pub message: String,
}

impl Refusal {
    pub fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self { code, message: message.into() }
    }

    pub fn invalid(message: impl Into<String>) -> Self {
        Self::new("request.invalid", message)
    }

    pub fn reply(&self) -> Value {
        json!({ "ok": false, "error": { "code": self.code, "message": self.message } })
    }
}

/// A new widget identifier: 16 lower-case hexadecimal digits from the system's random source.
pub fn new_identifier() -> std::io::Result<String> {
    let mut bytes = [0u8; IDENTIFIER_LENGTH / 2];
    getrandom::fill(&mut bytes).map_err(|error| std::io::Error::other(error.to_string()))?;
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

/// True for the form [`new_identifier`] produces; nothing else is ever looked up or used in a file name.
pub fn is_identifier(text: &str) -> bool {
    text.len() == IDENTIFIER_LENGTH && text.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

/// A display's own name for an output, such as `eDP-1`: letters, digits, `.`, `_`, `:` and `-`.
pub fn is_screen_name(text: &str) -> bool {
    !text.is_empty() && text.len() <= MAXIMUM_SCREEN_NAME && text.bytes().all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b':' | b'-'))
}

pub fn is_family(text: &str) -> bool {
    FAMILIES.contains(&text)
}

/// `on`, `off` or `toggle`, for `arrange` and `peek`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Switch {
    On,
    Off,
    Toggle,
}

impl Switch {
    pub fn parse(word: &str) -> Option<Self> {
        match word {
            "on" => Some(Self::On),
            "off" => Some(Self::Off),
            "toggle" => Some(Self::Toggle),
            _ => None,
        }
    }

    pub fn word(self) -> &'static str {
        match self {
            Self::On => "on",
            Self::Off => "off",
            Self::Toggle => "toggle",
        }
    }

    pub fn apply(self, current: bool) -> bool {
        match self {
            Self::On => true,
            Self::Off => false,
            Self::Toggle => !current,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Request {
    /// Turns the connection into the event stream.
    Watch,
    Status,
    /// `package` is the name of an installed package.
    Add { package: String, family: Option<String> },
    Remove { id: String },
    Widgets,
    /// One widget, the widgets of one package, or all of them.
    Refresh { id: Option<String>, package: Option<String> },
    Peek(Switch),
    Arrange(Switch),
    /// `version` is the picture the region number belongs to; without it, the current one.
    Tap { id: String, n: u32, version: Option<u64> },
    Move { id: String, screen: String, x: i64, y: i64 },
    /// `scale` in thousandths; `width` and `height` in logical pixels.
    Screen { name: String, scale: i64, width: i64, height: i64 },
    Theme { dark: bool },
    Menu { id: String, word: String },
    /// The display says that the session was locked or unlocked.
    Session { locked: bool },
    /// `settings.json` was changed: read it again and plan the next runs by it.
    Reload,
}

fn text<'a>(object: &'a Map<String, Value>, name: &str) -> Result<&'a str, Refusal> {
    object.get(name).and_then(Value::as_str).ok_or_else(|| Refusal::invalid(format!("\"{name}\" must be a string")))
}

fn optional_text<'a>(object: &'a Map<String, Value>, name: &str) -> Result<Option<&'a str>, Refusal> {
    match object.get(name) {
        None => Ok(None),
        Some(value) => value.as_str().map(Some).ok_or_else(|| Refusal::invalid(format!("\"{name}\" must be a string"))),
    }
}

fn integer(object: &Map<String, Value>, name: &str) -> Result<i64, Refusal> {
    // Only what JSON writes as an integer: 1.0 and 1e3 are refused.
    object.get(name).and_then(Value::as_i64).ok_or_else(|| Refusal::invalid(format!("\"{name}\" must be an integer")))
}

fn word<'a>(object: &'a Map<String, Value>, name: &str, allowed: &[&str]) -> Result<&'a str, Refusal> {
    let value = text(object, name)?;
    if allowed.contains(&value) { Ok(value) } else { Err(Refusal::invalid(format!("\"{name}\" must be one of: {}", allowed.join(", ")))) }
}

fn identifier(object: &Map<String, Value>) -> Result<String, Refusal> {
    let value = text(object, "id")?;
    if is_identifier(value) { Ok(value.to_owned()) } else { Err(Refusal::invalid("\"id\" is not a widget identifier")) }
}

fn package(value: &str) -> Result<String, Refusal> {
    if names::is_valid(value) { Ok(value.to_owned()) } else { Err(Refusal::invalid("\"package\" is not a package name")) }
}

fn family(value: &str) -> Result<String, Refusal> {
    if is_family(value) { Ok(value.to_owned()) } else { Err(Refusal::invalid("\"family\" must be small, medium, large or extraLarge")) }
}

fn in_range(name: &str, value: i64, minimum: i64, maximum: i64) -> Result<i64, Refusal> {
    if (minimum..=maximum).contains(&value) { Ok(value) } else { Err(Refusal::invalid(format!("\"{name}\" must be between {minimum} and {maximum}"))) }
}

impl Request {
    /// Checks the values of a request built from command-line arguments, by the rules a received line is read with.
    pub fn checked(self) -> Result<Self, Refusal> {
        Self::parse(&self.line())
    }

    /// Reads one received line. Unknown operations, unknown members, wrong types and values out of range are refused.
    pub fn parse(line: &str) -> Result<Self, Refusal> {
        if line.len() > MAXIMUM_LINE_BYTES {
            return Err(Refusal::new("request.too_long", "The request is too long."));
        }
        let Ok(Value::Object(object)) = serde_json::from_str::<Value>(line) else {
            return Err(Refusal::invalid("A request is one JSON object on one line."));
        };
        let operation = text(&object, "op")?;
        let members: &[&str] = match operation {
            "watch" | "status" | "widgets" | "reload" => &[],
            "add" => &["package", "family"],
            "remove" => &["id"],
            "refresh" => &["id", "package"],
            "peek" | "arrange" => &["state"],
            "tap" => &["id", "n", "version"],
            "move" => &["id", "screen", "x", "y"],
            "screen" => &["name", "scale", "width", "height"],
            "theme" => &["mode"],
            "menu" => &["id", "word"],
            "session" => &["state"],
            _ => return Err(Refusal::invalid("Unknown operation.")),
        };
        if let Some(unknown) = object.keys().find(|key| *key != "op" && !members.contains(&key.as_str())) {
            // The name is the sender's own text: say which one without repeating more than a word of it.
            let shown: String = unknown.chars().filter(|character| character.is_ascii_alphanumeric()).take(24).collect();
            return Err(Refusal::invalid(format!("Unknown member \"{shown}\".")));
        }
        Ok(match operation {
            "watch" => Self::Watch,
            "status" => Self::Status,
            "widgets" => Self::Widgets,
            "reload" => Self::Reload,
            "add" => Self::Add { package: package(text(&object, "package")?)?, family: optional_text(&object, "family")?.map(family).transpose()? },
            "remove" => Self::Remove { id: identifier(&object)? },
            "refresh" => {
                let id = if object.contains_key("id") { Some(identifier(&object)?) } else { None };
                let package = optional_text(&object, "package")?.map(package).transpose()?;
                if id.is_some() && package.is_some() {
                    return Err(Refusal::invalid("Name a widget or a package, not both."));
                }
                Self::Refresh { id, package }
            }
            "peek" | "arrange" => {
                let switch = Switch::parse(word(&object, "state", &["on", "off", "toggle"])?).unwrap_or(Switch::Toggle);
                if operation == "peek" { Self::Peek(switch) } else { Self::Arrange(switch) }
            }
            "tap" => Self::Tap {
                id: identifier(&object)?,
                n: in_range("n", integer(&object, "n")?, 0, 4095)? as u32,
                version: if object.contains_key("version") { Some(in_range("version", integer(&object, "version")?, 1, i64::MAX)? as u64) } else { None },
            },
            "move" => {
                let screen = text(&object, "screen")?;
                if !is_screen_name(screen) {
                    return Err(Refusal::invalid("\"screen\" is not a screen name"));
                }
                // Clamped, as on Windows: a widget dragged far away comes back to the edge of the range.
                let offset = |name: &str| integer(&object, name).map(|value| value.clamp(-MAXIMUM_OFFSET, MAXIMUM_OFFSET));
                Self::Move { id: identifier(&object)?, screen: screen.to_owned(), x: offset("x")?, y: offset("y")? }
            }
            "screen" => {
                let name = text(&object, "name")?;
                if !is_screen_name(name) {
                    return Err(Refusal::invalid("\"name\" is not a screen name"));
                }
                Self::Screen {
                    name: name.to_owned(),
                    scale: in_range("scale", integer(&object, "scale")?, MINIMUM_SCALE, MAXIMUM_SCALE)?,
                    width: in_range("width", integer(&object, "width")?, 1, MAXIMUM_SCREEN_LENGTH)?,
                    height: in_range("height", integer(&object, "height")?, 1, MAXIMUM_SCREEN_LENGTH)?,
                }
            }
            "theme" => Self::Theme { dark: word(&object, "mode", &["dark", "light"])? == "dark" },
            "menu" => Self::Menu { id: identifier(&object)?, word: word(&object, "word", &MENU_WORDS)?.to_owned() },
            _ => Self::Session { locked: word(&object, "state", &["locked", "unlocked"])? == "locked" },
        })
    }

    /// The request as the one line that is sent, without the line feed.
    pub fn line(&self) -> String {
        let value = match self {
            Self::Watch => json!({ "op": "watch" }),
            Self::Status => json!({ "op": "status" }),
            Self::Widgets => json!({ "op": "widgets" }),
            Self::Reload => json!({ "op": "reload" }),
            Self::Add { package, family } => {
                let mut value = json!({ "op": "add", "package": package });
                if let Some(family) = family {
                    value["family"] = json!(family);
                }
                value
            }
            Self::Remove { id } => json!({ "op": "remove", "id": id }),
            Self::Refresh { id, package } => {
                let mut value = json!({ "op": "refresh" });
                if let Some(id) = id {
                    value["id"] = json!(id);
                }
                if let Some(package) = package {
                    value["package"] = json!(package);
                }
                value
            }
            Self::Peek(switch) => json!({ "op": "peek", "state": switch.word() }),
            Self::Arrange(switch) => json!({ "op": "arrange", "state": switch.word() }),
            Self::Tap { id, n, version } => {
                let mut value = json!({ "op": "tap", "id": id, "n": n });
                if let Some(version) = version {
                    value["version"] = json!(version);
                }
                value
            }
            Self::Move { id, screen, x, y } => json!({ "op": "move", "id": id, "screen": screen, "x": x, "y": y }),
            Self::Screen { name, scale, width, height } => json!({ "op": "screen", "name": name, "scale": scale, "width": width, "height": height }),
            Self::Theme { dark } => json!({ "op": "theme", "mode": if *dark { "dark" } else { "light" } }),
            Self::Menu { id, word } => json!({ "op": "menu", "id": id, "word": word }),
            Self::Session { locked } => json!({ "op": "session", "state": if *locked { "locked" } else { "unlocked" } }),
        };
        value.to_string()
    }
}

/// A display scale as text ("2", "1.5", "1.25") in thousandths, or `None` when it is not a plain decimal number.
pub fn scale_thousandths(text: &str) -> Option<i64> {
    let (whole, fraction) = text.split_once('.').unwrap_or((text, ""));
    if whole.is_empty() || whole.len() > 2 || fraction.len() > 6 || !whole.bytes().chain(fraction.bytes()).all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    let mut thousandths = whole.parse::<i64>().ok()? * 1000;
    let digits: Vec<i64> = fraction.bytes().map(|byte| i64::from(byte - b'0')).collect();
    for (index, weight) in [100, 10, 1].into_iter().enumerate() {
        thousandths += digits.get(index).copied().unwrap_or(0) * weight;
    }
    // 1.3333 is a third more than 1.333: round on the fourth digit.
    if digits.get(3).copied().unwrap_or(0) >= 5 {
        thousandths += 1;
    }
    Some(thousandths)
}

// Events

pub fn hello(dark: bool, arrange: bool, peek: bool) -> Value {
    json!({ "event": "hello", "protocol": PROTOCOL, "dark": dark, "arrange": arrange, "peek": peek, "service": env!("CARGO_PKG_VERSION") })
}

pub fn mode(arrange: bool, peek: bool) -> Value {
    json!({ "event": "mode", "arrange": arrange, "peek": peek })
}

pub fn removed(id: &str) -> Value {
    json!({ "event": "remove", "id": id })
}

pub fn bye(reason: &str) -> Value {
    json!({ "event": "bye", "reason": reason })
}

#[cfg(test)]
mod tests {
    use super::*;

    const ID: &str = "0123456789abcdef";

    #[test]
    fn identifiers_are_sixteen_lower_case_hexadecimal_digits() {
        let id = new_identifier().unwrap();
        assert!(is_identifier(&id), "{id}");
        assert_ne!(id, new_identifier().unwrap());
        for bad in ["", "0123456789abcde", "0123456789abcdef0", "0123456789ABCDEF", "0123456789abcdeg", "../../etc/passwd0", "0123456789abcde/", "0123456789abcde\n"] {
            assert!(!is_identifier(bad), "{bad:?}");
        }
    }

    #[test]
    fn every_request_survives_its_own_line() {
        let requests = [
            Request::Watch,
            Request::Status,
            Request::Reload,
            Request::Widgets,
            Request::Add { package: "Daily Quote".into(), family: None },
            Request::Add { package: "时钟".into(), family: Some("extraLarge".into()) },
            Request::Remove { id: ID.into() },
            Request::Refresh { id: None, package: None },
            Request::Refresh { id: Some(ID.into()), package: None },
            Request::Refresh { id: None, package: Some("Clock".into()) },
            Request::Peek(Switch::Toggle),
            Request::Arrange(Switch::On),
            Request::Tap { id: ID.into(), n: 3, version: None },
            Request::Tap { id: ID.into(), n: 0, version: Some(7) },
            Request::Move { id: ID.into(), screen: "eDP-1".into(), x: -20, y: 400 },
            Request::Screen { name: "HDMI-A-1".into(), scale: 1500, width: 2560, height: 1440 },
            Request::Theme { dark: true },
            Request::Menu { id: ID.into(), word: "resize-extraLarge".into() },
            Request::Session { locked: true },
        ];
        for request in requests {
            let line = request.line();
            assert!(!line.contains('\n'));
            assert_eq!(Request::parse(&line), Ok(request.clone()), "{line}");
            assert_eq!(request.clone().checked(), Ok(request));
        }
    }

    #[test]
    fn what_is_not_a_known_request_is_refused() {
        let id = format!("\"id\":\"{ID}\"");
        let lines = [
            String::new(),
            "watch".into(),
            "[]".into(),
            "\"watch\"".into(),
            "{}".into(),
            "{\"op\":7}".into(),
            "{\"op\":\"run\"}".into(),
            "{\"op\":\"exec\",\"command\":\"rm -rf ~\"}".into(),
            "{\"op\":\"watch\",\"extra\":1}".into(),
            "{\"op\":\"add\"}".into(),
            "{\"op\":\"add\",\"package\":\"../x\"}".into(),
            "{\"op\":\"add\",\"package\":\"/etc\"}".into(),
            "{\"op\":\"add\",\"package\":\".hidden\"}".into(),
            "{\"op\":\"add\",\"package\":\"A\",\"family\":\"huge\"}".into(),
            "{\"op\":\"add\",\"package\":\"A\",\"path\":\"/tmp/x\"}".into(),
            "{\"op\":\"remove\",\"id\":\"../../../etc/passwd\"}".into(),
            "{\"op\":\"remove\",\"id\":7}".into(),
            format!("{{\"op\":\"refresh\",{id},\"package\":\"A\"}}"),
            format!("{{\"op\":\"tap\",{id}}}"),
            format!("{{\"op\":\"tap\",{id},\"n\":-1}}"),
            format!("{{\"op\":\"tap\",{id},\"n\":1.5}}"),
            format!("{{\"op\":\"tap\",{id},\"n\":\"1\"}}"),
            format!("{{\"op\":\"tap\",{id},\"n\":99999}}"),
            format!("{{\"op\":\"tap\",{id},\"n\":1,\"version\":0}}"),
            format!("{{\"op\":\"move\",{id},\"screen\":\"a b\",\"x\":1,\"y\":1}}"),
            format!("{{\"op\":\"move\",{id},\"screen\":\"../x\",\"x\":1,\"y\":1}}"),
            format!("{{\"op\":\"move\",{id},\"screen\":\"eDP-1\",\"x\":\"1\",\"y\":1}}"),
            "{\"op\":\"screen\",\"name\":\"eDP-1\",\"scale\":100,\"width\":10,\"height\":10}".into(),
            "{\"op\":\"screen\",\"name\":\"eDP-1\",\"scale\":1000,\"width\":0,\"height\":10}".into(),
            "{\"op\":\"screen\",\"name\":\"\",\"scale\":1000,\"width\":10,\"height\":10}".into(),
            "{\"op\":\"theme\",\"mode\":\"blue\"}".into(),
            format!("{{\"op\":\"menu\",{id},\"word\":\"delete-everything\"}}"),
            format!("{{\"op\":\"menu\",{id},\"word\":\"resize-huge\"}}"),
            "{\"op\":\"peek\",\"state\":\"maybe\"}".into(),
            "{\"op\":\"session\",\"state\":\"asleep\"}".into(),
        ];
        for line in lines {
            let refusal = Request::parse(&line).expect_err(&line);
            assert_eq!(refusal.code, "request.invalid", "{line}");
        }
        let long = format!("{{\"op\":\"add\",\"package\":\"{}\"}}", "a".repeat(MAXIMUM_LINE_BYTES));
        assert_eq!(Request::parse(&long).unwrap_err().code, "request.too_long");
    }

    #[test]
    fn offsets_are_clamped_and_scales_are_read_as_thousandths() {
        let line = format!("{{\"op\":\"move\",\"id\":\"{ID}\",\"screen\":\"DP-1\",\"x\":-99999999,\"y\":99999999}}");
        assert_eq!(Request::parse(&line), Ok(Request::Move { id: ID.into(), screen: "DP-1".into(), x: -MAXIMUM_OFFSET, y: MAXIMUM_OFFSET }));
        for (text, thousandths) in [("1", 1000), ("2", 2000), ("1.5", 1500), ("1.25", 1250), ("1.3333", 1333), ("1.6667", 1667), ("0.5", 500), ("1.", 1000)] {
            assert_eq!(scale_thousandths(text), Some(thousandths), "{text}");
        }
        for text in ["", ".5", "-1", "1e3", "1,5", "abc", "1.5x", "100", "1.2345678"] {
            assert_eq!(scale_thousandths(text), None, "{text}");
        }
    }

    #[test]
    fn an_unknown_member_is_named_without_repeating_what_was_sent() {
        let refusal = Request::parse("{\"op\":\"watch\",\"<script>alert(1)</script>\":1}").unwrap_err();
        assert_eq!(refusal.message, "Unknown member \"scriptalert1script\".");
    }
}
