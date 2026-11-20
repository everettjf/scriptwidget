//! Finds tags and attributes in generated code that ScriptWidget does not have.
//! Port of `AiJsxCheck.kt` (`AIJSXCheck` in Swift); the three must report the
//! same problems for the same code.
//!
//! The runtime ignores an unknown attribute, and a value outside a closed list,
//! without an error: the widget runs and shows something else. The repair loop
//! can only fix what it is told, so this check tells it before the widget runs.
//!
//! It reads the code loosely, not as a parser would, and is built to stay
//! silent when unsure: a tag whose name starts with a capital letter is taken
//! for the script's own component, and anything that is not plainly a tag is
//! skipped. It grants nothing and blocks nothing at run time; the runtime's
//! own switch stays the authority.

use std::sync::OnceLock;

use super::is_whitespace;
use super::jsx_surface_data::TEXT;

/// A closed list of values, or `None` when any value goes.
pub type Values = Option<Vec<String>>;
/// Attribute names in the order of the generated list, each with its values.
pub type Attributes = Vec<(String, Values)>;

fn find<'a>(attributes: &'a Attributes, name: &str) -> Option<&'a Values> {
    attributes.iter().find(|(known, _)| known == name).map(|(_, values)| values)
}

/// Sets `name`, keeping its place when it is already there, as a `LinkedHashMap` does.
fn put(attributes: &mut Attributes, name: String, values: Values) {
    match attributes.iter_mut().find(|(known, _)| *known == name) {
        Some(entry) => entry.1 = values,
        None => attributes.push((name, values)),
    }
}

/// What a system has: the general attributes, the tags with their own attributes, and the tags that draw no tag written inside them.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Surface {
    pub globals: Attributes,
    pub tags: Vec<(String, Attributes)>,
    pub leaves: Vec<String>,
}

impl Surface {
    fn tag(&self, name: &str) -> Option<&Attributes> {
        self.tags.iter().find(|(known, _)| known == name).map(|(_, attributes)| attributes)
    }
}

pub struct AiJsxCheck;

struct Attribute {
    name: String,
    /// The value when it is written as a plain string.
    literal: Option<String>,
}

struct Tag {
    name: String,
    attributes: Vec<Attribute>,
    /// The index after the tag's `>`.
    end: usize,
    self_closing: bool,
}

const FRAME_ALIGNMENTS: [&str; 9] = ["center", "leading", "trailing", "top", "bottom", "topLeading", "topTrailing", "bottomLeading", "bottomTrailing"];
const TAG_BEFORE_KEYWORDS: [&str; 14] = ["return", "yield", "case", "default", "await", "else", "do", "in", "of", "typeof", "void", "delete", "new", "throw"];

impl AiJsxCheck {
    pub const MAX_PROBLEMS: usize = 5;

    pub const FRAME_HELP: &'static str = "Write it without spaces as one of: \"max\", \"max,leading\", \"60\", \"60,40\", \"60,40,leading\", \
\"max,40\", \"max,40,leading\", \"60,max\", \"60,max,leading\". The alignments are: center, leading, trailing, top, bottom, \
topLeading, topTrailing, bottomLeading, bottomTrailing. There is no \"auto\": for a row as wide as the widget \
and as tall as its content, put a <spacer/> inside an <hstack>.";

    /// The tags of this system: the shared ones and any marked `@linux`. There
    /// is none of the latter today; the scrolling `<list>` is marked `@android`
    /// and so is not a tag here, as it is not one on Windows or Apple systems.
    pub fn linux() -> &'static Surface {
        static SURFACE: OnceLock<Surface> = OnceLock::new();
        SURFACE.get_or_init(|| Self::parse_surface(TEXT, Some("linux")))
    }

    /// The generated list itself, for tests that read it as another system.
    pub fn surface_text() -> &'static str {
        TEXT
    }

    /// Reads the generated list; `system` chooses which system-only tags count.
    pub fn parse_surface(text: &str, system: Option<&str>) -> Surface {
        let mut surface = Surface::default();
        let attribute = |word: &str| -> (String, Values) {
            match word.split_once('=') {
                None => (word.to_owned(), None),
                Some((name, values)) => {
                    let mut list: Vec<String> = Vec::new();
                    for value in values.split('|') {
                        if !list.iter().any(|known| known == value) {
                            list.push(value.to_owned());
                        }
                    }
                    (name.to_owned(), Some(list))
                }
            }
        };
        let own = system.map(|system| format!("tag@{system}"));
        for line in text.lines() {
            let words: Vec<&str> = line.trim().split(' ').filter(|word| !word.is_empty()).collect();
            if words.len() < 2 {
                continue;
            }
            if words[0] == "leaf" {
                for word in &words[1..] {
                    if !surface.leaves.iter().any(|known| known == word) {
                        surface.leaves.push((*word).to_owned());
                    }
                }
            } else if words[0] == "global" {
                let (name, values) = attribute(words[1]);
                put(&mut surface.globals, name, values);
            } else if words[0] == "tag" || own.as_deref() == Some(words[0]) {
                let mut attributes = Attributes::new();
                for word in &words[2..] {
                    let (name, values) = attribute(word);
                    put(&mut attributes, name, values);
                }
                match surface.tags.iter_mut().find(|(known, _)| known == words[1]) {
                    Some(entry) => entry.1 = attributes,
                    None => surface.tags.push((words[1].to_owned(), attributes)),
                }
            }
        }
        surface
    }

    /// What is wrong with `source`, at most [`AiJsxCheck::MAX_PROBLEMS`] sentences; empty when nothing is.
    pub fn problems(source: &str, surface: &Surface) -> Vec<String> {
        let text: Vec<char> = source.chars().collect();
        let mut found: Vec<String> = Vec::new();
        let add = |found: &mut Vec<String>, problem: String| {
            if !found.contains(&problem) {
                found.push(problem);
            }
        };
        for tag in tags(&text) {
            if found.len() >= Self::MAX_PROBLEMS {
                break;
            }
            // A capital letter marks the script's own component, even one named like a tag; a dotted name is a member.
            if !tag.name.starts_with(|first: char| first.is_ascii_lowercase()) || tag.name.contains('.') {
                continue;
            }
            let name = &tag.name;
            let Some(own) = surface.tag(name) else {
                let all: Vec<&str> = surface.tags.iter().map(|(known, _)| known.as_str()).collect();
                add(&mut found, format!("<{name}> is not a ScriptWidget tag. The tags are: {}.", all.join(", ")));
                continue;
            };
            if surface.leaves.contains(name)
                && !tag.self_closing
                && let Some(inner) = first_tag_inside(&text, tag.end)
            {
                add(&mut found, format!("<{name}> takes no tags inside it, so the <{inner}> in it is not shown. Put it next to the <{name}>, not in it."));
            }
            for attribute in &tag.attributes {
                if found.len() >= Self::MAX_PROBLEMS {
                    break;
                }
                let own_values = find(own, &attribute.name);
                let global_values = find(&surface.globals, &attribute.name);
                if own_values.is_none() && global_values.is_none() {
                    let mut names: Vec<&str> = own.iter().map(|(known, _)| known.as_str()).collect();
                    for (known, _) in &surface.globals {
                        if !names.contains(&known.as_str()) {
                            names.push(known);
                        }
                    }
                    add(&mut found, format!("<{name}> has no attribute \"{}\"; it would be ignored. Its attributes are: {}.", attribute.name, names.join(", ")));
                    continue;
                }
                let Some(value) = &attribute.literal else { continue };
                if attribute.name == "frame" && !Self::frame_is_read(value) {
                    add(&mut found, format!("frame=\"{value}\" on <{name}> is not a frame ScriptWidget reads; it would be ignored or centered. {}", Self::FRAME_HELP));
                    continue;
                }
                // The tag's own list when it has one, else the general attribute's.
                let Some(allowed) = own_values.and_then(Option::as_ref).or_else(|| global_values.and_then(Option::as_ref)) else { continue };
                if !allowed.contains(value) {
                    add(&mut found, format!("{}=\"{value}\" on <{name}> is not one of its values; it would be ignored. Use one of: {}.", attribute.name, allowed.join(", ")));
                }
            }
        }
        found
    }

    /// Whether the runtime reads `value` as written. Follows `parseFrame` of the
    /// shared renderer: a value it drops, and an alignment it does not know and
    /// replaces with center, are both "not read".
    pub fn frame_is_read(value: &str) -> bool {
        let parts: Vec<&str> = value.split(',').filter(|part| !part.is_empty()).collect();
        let number = |text: &str| frame_number(text).is_some();
        let alignment = |text: &str| FRAME_ALIGNMENTS.contains(&text);
        match parts[..] {
            [only] => value == "max" || (only == value && frame_number(value).unwrap_or(-1.0) >= 0.0),
            [a, b] => {
                if number(a) {
                    number(b) || b == "max"
                } else {
                    a == "max" && (number(b) || b == "max" || alignment(b))
                }
            }
            [a, b, c] => alignment(c) && ((number(a) && (number(b) || b == "max")) || (a == "max" && number(b))),
            _ => false,
        }
    }

    /// One line for the model, or `None` when `source` has no problem.
    pub fn summary(source: &str, surface: &Surface) -> Option<String> {
        let problems = Self::problems(source, surface);
        if problems.is_empty() {
            return None;
        }
        let lines: Vec<String> = problems.iter().map(|problem| format!("- {problem}")).collect();
        Some(format!("The code uses tags or attributes that ScriptWidget does not have:\n{}", lines.join("\n")))
    }
}

/// A plain decimal such as 60, -4 or 12.5; nothing else, and no spaces.
fn frame_number(text: &str) -> Option<f64> {
    let mut digits = 0;
    let mut dots = 0;
    for (index, character) in text.chars().enumerate() {
        if character.is_ascii_digit() {
            digits += 1;
        } else if character == '.' {
            dots += 1;
        } else if !(index == 0 && (character == '-' || character == '+')) {
            return None;
        }
    }
    if digits > 0 && dots <= 1 { text.parse().ok() } else { None }
}

fn is_word_character(character: char) -> bool {
    character.is_ascii_alphanumeric() || character == '_' || character == '$'
}

fn is_name_character(character: char) -> bool {
    character.is_ascii_alphanumeric() || character == '.' || character == '_'
}

fn index_of(text: &[char], wanted: char, from: usize) -> Option<usize> {
    text.get(from..)?.iter().position(|character| *character == wanted).map(|at| from + at)
}

fn text_of(text: &[char], from: usize, to: usize) -> String {
    text[from..to].iter().collect()
}

/// The opening tags of `text`, read loosely.
fn tags(text: &[char]) -> Vec<Tag> {
    let length = text.len();
    let mut result = Vec::new();
    let mut index = 0;
    while index < length {
        let character = text[index];
        let next = text.get(index + 1).copied();
        if character == '/' && next == Some('/') {
            index = index_of(text, '\n', index).unwrap_or(length);
        } else if character == '/' && next == Some('*') {
            let mut end = None;
            let mut at = index + 2;
            while at + 1 < length {
                if text[at] == '*' && text[at + 1] == '/' {
                    end = Some(at + 2);
                    break;
                }
                at += 1;
            }
            index = end.unwrap_or(length);
        } else if character == '"' || character == '\'' {
            index = skip_quoted(text, index, true);
        } else if character == '`' {
            index = skip_quoted(text, index, false);
        } else if character == '<' && next.is_some_and(|next| next.is_ascii_alphabetic()) && starts_tag(text, index) {
            match read_tag(text, index + 1) {
                None => index += 1,
                Some((tag, after)) => {
                    result.push(tag);
                    index = after;
                }
            }
        } else {
            index += 1;
        }
    }
    result
}

/// Whether the `<` at `at` can open a tag: after an operator or a keyword, not after a value.
fn starts_tag(text: &[char], at: usize) -> bool {
    let Some(before) = text[..at].iter().rposition(|character| !is_whitespace(*character)) else { return true };
    let character = text[before];
    if character == ')' || character == ']' {
        return false;
    }
    if !is_word_character(character) {
        return true;
    }
    let start = text[..before].iter().rposition(|character| !is_word_character(*character)).map_or(0, |index| index + 1);
    TAG_BEFORE_KEYWORDS.contains(&text_of(text, start, before + 1).as_str())
}

/// Reads a tag whose name starts at `from`; the tag and the index after its `>`, or `None` when it is not one.
fn read_tag(text: &[char], from: usize) -> Option<(Tag, usize)> {
    let length = text.len();
    let mut index = from;
    while index < length && is_name_character(text[index]) {
        index += 1;
    }
    let name = text_of(text, from, index);
    let mut attributes = Vec::new();
    loop {
        while index < length && is_whitespace(text[index]) {
            index += 1;
        }
        if index >= length {
            return None;
        }
        let character = text[index];
        if character == '>' {
            return Some((Tag { name, attributes, end: index + 1, self_closing: false }, index + 1));
        }
        if character == '/' {
            return if text.get(index + 1) == Some(&'>') { Some((Tag { name, attributes, end: index + 2, self_closing: true }, index + 2)) } else { None };
        }
        if character == '{' {
            // {...spread}
            index = skip_braces(text, index)?;
            continue;
        }
        if !(character.is_ascii_alphabetic() || character == '_') {
            return None;
        }
        let start = index;
        while index < length && (text[index].is_ascii_alphanumeric() || matches!(text[index], '_' | '-' | ':')) {
            index += 1;
        }
        let attribute_name = text_of(text, start, index);
        while index < length && is_whitespace(text[index]) {
            index += 1;
        }
        if index >= length || text[index] != '=' {
            attributes.push(Attribute { name: attribute_name, literal: None });
            continue;
        }
        index += 1;
        while index < length && is_whitespace(text[index]) {
            index += 1;
        }
        if index >= length {
            return None;
        }
        match text[index] {
            quote @ ('"' | '\'') => {
                let end = index_of(text, quote, index + 1)?;
                attributes.push(Attribute { name: attribute_name, literal: Some(text_of(text, index + 1, end)) });
                index = end + 1;
            }
            '{' => {
                let end = skip_braces(text, index)?;
                let inner: Vec<char> = text_of(text, index + 1, end - 1).trim_matches(is_whitespace).chars().collect();
                // {"value"} is as plain as "value".
                let plain = inner.len() >= 2
                    && (inner[0] == '"' || inner[0] == '\'')
                    && inner[inner.len() - 1] == inner[0]
                    && index_of(&inner, inner[0], 1) == Some(inner.len() - 1)
                    && !inner.contains(&'\\');
                attributes.push(Attribute { name: attribute_name, literal: plain.then(|| inner[1..inner.len() - 1].iter().collect()) });
                index = end;
            }
            _ => return None,
        }
    }
}

/// The name of a tag written directly inside the tag whose `>` ends at `from`, before that tag closes;
/// `None` when there is none. What stands in `{...}` is passed over: it is computed, and not judged.
fn first_tag_inside(text: &[char], from: usize) -> Option<String> {
    let mut index = from;
    while index < text.len() {
        match text[index] {
            '{' => index = skip_braces(text, index)?,
            '<' => {
                if !text.get(index + 1).is_some_and(|next| next.is_ascii_alphabetic()) {
                    return None;
                }
                let mut end = index + 1;
                while end < text.len() && is_name_character(text[end]) {
                    end += 1;
                }
                return Some(text_of(text, index + 1, end));
            }
            _ => index += 1,
        }
    }
    None
}

/// The index after the `}` that closes the `{` at `from`, or `None` when it is not closed.
fn skip_braces(text: &[char], from: usize) -> Option<usize> {
    let mut depth = 0;
    let mut index = from;
    while index < text.len() {
        match text[index] {
            '{' => {
                depth += 1;
                index += 1;
            }
            '}' => {
                depth -= 1;
                index += 1;
                if depth == 0 {
                    return Some(index);
                }
            }
            '"' | '\'' => index = skip_quoted(text, index, true),
            '`' => index = skip_quoted(text, index, false),
            _ => index += 1,
        }
    }
    None
}

/// The index after the quoted text that starts at `from`. A quote that is not closed on its line,
/// an apostrophe in a sentence for one, is passed over as a single character.
fn skip_quoted(text: &[char], from: usize, same_line_only: bool) -> usize {
    let quote = text[from];
    let mut index = from + 1;
    while index < text.len() {
        let character = text[index];
        if character == '\\' {
            index += 2;
            continue;
        }
        if character == quote {
            return index + 1;
        }
        if same_line_only && character == '\n' {
            return from + 1;
        }
        index += 1;
    }
    from + 1
}
