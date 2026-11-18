//! Bounded XML parser behind `$xml.parse`, with the limits and output shape
//! of ScriptWidgetXMLParser: `{name, attributes, text, children}`. The Linux
//! counterpart of `Windows/src/ScriptWidget.Core/Runtime/XmlBridge.cs`.
//!
//! The document is untrusted. Document type and entity declarations are
//! rejected, so there are no entities to expand and nothing external to
//! resolve: only the five predefined entities and character references are
//! understood. Comments and processing instructions are skipped.
//!
//! The limit messages are the ones of the other platforms. The messages for
//! malformed documents are this parser's own: Windows reports the wording of
//! the .NET reader there, which is not part of the contract.

use serde_json::{Value, json};

use crate::json::{Object, stringify};

pub const MAXIMUM_BYTES: usize = 256 * 1024;
pub const MAXIMUM_ELEMENTS: usize = 2048;
pub const MAXIMUM_DEPTH: usize = 32;

/// JSON text: `{"ok":true,"value":…}` or `{"ok":false,"error":"…"}`.
pub fn parse(source: &str) -> String {
    stringify(&match parse_document(source) {
        Ok(value) => json!({ "ok": true, "value": value }),
        Err(error) => json!({ "ok": false, "error": if error.is_empty() { "Invalid XML".to_owned() } else { error } }),
    })
}

struct Node {
    name: String,
    attributes: Object,
    text: String,
    children: Vec<Value>,
}

impl Node {
    fn into_json(self) -> Value {
        json!({ "name": self.name, "attributes": self.attributes, "text": self.text, "children": self.children })
    }
}

struct Parser<'a> {
    rest: &'a str,
}

fn name_start(character: char) -> bool {
    character.is_ascii_alphabetic() || character == '_' || character == ':' || character as u32 >= 0x80
}

fn name_part(character: char) -> bool {
    name_start(character) || character.is_ascii_digit() || character == '-' || character == '.'
}

/// Characters XML 1.0 allows in a document.
fn allowed(character: char) -> bool {
    matches!(character, '\t' | '\n' | '\r' | '\u{20}'..='\u{d7ff}' | '\u{e000}'..='\u{fffd}' | '\u{10000}'..='\u{10ffff}')
}

impl<'a> Parser<'a> {
    fn starts_with(&self, prefix: &str) -> bool {
        self.rest.starts_with(prefix)
    }

    fn advance(&mut self, bytes: usize) {
        self.rest = &self.rest[bytes..];
    }

    fn skip_spaces(&mut self) -> bool {
        let trimmed = self.rest.trim_start_matches([' ', '\t', '\n', '\r']);
        let skipped = trimmed.len() != self.rest.len();
        self.rest = trimmed;
        skipped
    }

    /// Skips to just after `end`; `what` names the construct in the error.
    fn skip_past(&mut self, end: &str, what: &str) -> Result<&'a str, String> {
        let at = self.rest.find(end).ok_or_else(|| format!("XML {what} is not closed"))?;
        let inside = &self.rest[..at];
        self.advance(at + end.len());
        Ok(inside)
    }

    fn name(&mut self) -> Result<&'a str, String> {
        let length = self.rest.char_indices().find(|(index, character)| if *index == 0 { !name_start(*character) } else { !name_part(*character) }).map_or(self.rest.len(), |(index, _)| index);
        if length == 0 {
            return Err("XML name is missing".into());
        }
        let name = &self.rest[..length];
        self.advance(length);
        Ok(name)
    }

    /// Appends text up to `stop`, decoding references. Returns the bytes appended.
    fn text(&mut self, stop: &[char], attribute: bool, output: &mut String) -> Result<usize, String> {
        let start = output.len();
        while let Some(character) = self.rest.chars().next() {
            if stop.contains(&character) {
                break;
            }
            if character == '<' {
                // Only reachable in an attribute value.
                return Err("XML attribute values cannot contain '<'".into());
            }
            if character != '&' {
                // Line breaks and tabs in an attribute value are spaces (XML 1.0, 3.3.3).
                output.push(if attribute && matches!(character, '\t' | '\n') { ' ' } else { character });
                self.advance(character.len_utf8());
                continue;
            }
            let end = self.rest.find(';').filter(|end| *end <= 12).ok_or("XML reference is not closed")?;
            let reference = &self.rest[1..end];
            let decoded = match reference {
                "amp" => '&',
                "lt" => '<',
                "gt" => '>',
                "quot" => '"',
                "apos" => '\'',
                _ => {
                    let Some(number) = reference.strip_prefix('#') else { return Err("XML entity references are not allowed".into()) };
                    let code = match number.strip_prefix('x') {
                        Some(hexadecimal) if !hexadecimal.is_empty() && hexadecimal.bytes().all(|byte| byte.is_ascii_hexdigit()) => u32::from_str_radix(hexadecimal, 16).ok(),
                        None if !number.is_empty() && number.bytes().all(|byte| byte.is_ascii_digit()) => number.parse::<u32>().ok(),
                        _ => None,
                    };
                    code.and_then(char::from_u32).filter(|character| allowed(*character)).ok_or("XML character reference is not valid")?
                }
            };
            output.push(decoded);
            self.advance(end + 1);
        }
        Ok(output.len() - start)
    }
}

/// True when the text holds `<!DOCTYPE` or `<!ENTITY`, in any case and with spaces after `<!`.
fn has_declaration(source: &str) -> bool {
    let bytes = source.as_bytes();
    let mut at = 0;
    while let Some(found) = source[at..].find("<!") {
        let mut next = at + found + 2;
        while bytes.get(next).is_some_and(u8::is_ascii_whitespace) {
            next += 1;
        }
        let word = &bytes[next..bytes.len().min(next + 7)];
        if word.len() >= 6 && (word[..6].eq_ignore_ascii_case(b"ENTITY") || word.eq_ignore_ascii_case(b"DOCTYPE")) {
            return true;
        }
        at += found + 2;
    }
    false
}

fn parse_document(source: &str) -> Result<Value, String> {
    if source.len() > MAXIMUM_BYTES {
        return Err(format!("XML exceeds the {MAXIMUM_BYTES}-byte limit"));
    }
    if has_declaration(source) {
        return Err("XML document type and entity declarations are not allowed".into());
    }
    if !source.chars().all(allowed) {
        return Err("XML contains a character that is not allowed".into());
    }
    // A line break is one line feed, however the document wrote it (XML 1.0, 2.11).
    let normalized = source.replace("\r\n", "\n").replace('\r', "\n");
    let mut parser = Parser { rest: normalized.strip_prefix('\u{feff}').unwrap_or(&normalized) };
    let mut stack: Vec<Node> = Vec::new();
    let mut root: Option<Value> = None;
    let mut elements = 0usize;
    let mut text_bytes = 0usize;
    let too_much_text = || format!("XML text exceeds the {MAXIMUM_BYTES}-byte limit");

    if parser.starts_with("<?xml") && parser.rest[5..].starts_with([' ', '\t', '\n', '?']) {
        parser.skip_past("?>", "declaration")?;
    }
    while !parser.rest.is_empty() {
        if parser.starts_with("<!--") {
            parser.advance(4);
            parser.skip_past("-->", "comment")?;
        } else if parser.starts_with("<![CDATA[") {
            parser.advance(9);
            let text = parser.skip_past("]]>", "CDATA section")?;
            let Some(current) = stack.last_mut() else { return Err("XML has text outside the root element".into()) };
            text_bytes += text.len();
            if text_bytes > MAXIMUM_BYTES {
                return Err(too_much_text());
            }
            current.text.push_str(text);
        } else if parser.starts_with("<!") {
            return Err("XML document type declarations are not allowed".into());
        } else if parser.starts_with("<?") {
            parser.advance(2);
            let target = parser.name()?;
            if target.eq_ignore_ascii_case("xml") {
                return Err("XML declaration must be at the start of the document".into());
            }
            parser.skip_past("?>", "processing instruction")?;
        } else if parser.starts_with("</") {
            parser.advance(2);
            let name = parser.name()?;
            parser.skip_spaces();
            if !parser.starts_with(">") {
                return Err(format!("XML end tag {name} is not closed"));
            }
            parser.advance(1);
            let node = stack.pop().ok_or_else(|| format!("XML end tag {name} has no start tag"))?;
            if node.name != name {
                return Err(format!("XML end tag {name} does not match start tag {}", node.name));
            }
            close(node, &mut stack, &mut root);
        } else if parser.starts_with("<") {
            parser.advance(1);
            elements += 1;
            if elements > MAXIMUM_ELEMENTS {
                return Err(format!("XML exceeds the {MAXIMUM_ELEMENTS}-element limit"));
            }
            if stack.len() >= MAXIMUM_DEPTH {
                return Err(format!("XML exceeds the {MAXIMUM_DEPTH}-level depth limit"));
            }
            if stack.is_empty() && root.is_some() {
                return Err("XML has more than one root element".into());
            }
            let name = parser.name()?;
            let mut node = Node { name: name.to_owned(), attributes: Object::new(), text: String::new(), children: Vec::new() };
            let empty = loop {
                let spaced = parser.skip_spaces();
                if parser.starts_with("/>") {
                    parser.advance(2);
                    break true;
                }
                if parser.starts_with(">") {
                    parser.advance(1);
                    break false;
                }
                if parser.rest.is_empty() {
                    return Err(format!("XML start tag {name} is not closed"));
                }
                if !spaced {
                    return Err(format!("XML start tag {name} is malformed"));
                }
                let attribute = parser.name()?;
                parser.skip_spaces();
                if !parser.starts_with("=") {
                    return Err(format!("XML attribute {attribute} has no value"));
                }
                parser.advance(1);
                parser.skip_spaces();
                let quote = match parser.rest.chars().next() {
                    Some(quote @ ('"' | '\'')) => quote,
                    _ => return Err(format!("XML attribute {attribute} is not quoted")),
                };
                parser.advance(1);
                let mut value = String::new();
                parser.text(&[quote], true, &mut value)?;
                if !parser.starts_with(quote.encode_utf8(&mut [0; 4])) {
                    return Err(format!("XML attribute {attribute} is not closed"));
                }
                parser.advance(1);
                if node.attributes.insert(attribute.to_owned(), Value::String(value)).is_some() {
                    return Err(format!("XML attribute {attribute} is repeated"));
                }
            };
            if empty {
                close(node, &mut stack, &mut root);
            } else {
                stack.push(node);
            }
        } else {
            let mut text = String::new();
            text_bytes += parser.text(&['<'], false, &mut text)?;
            if text_bytes > MAXIMUM_BYTES {
                return Err(too_much_text());
            }
            match stack.last_mut() {
                Some(current) => current.text.push_str(&text),
                None if text.trim_matches([' ', '\t', '\n']).is_empty() => {}
                None => return Err("XML has text outside the root element".into()),
            }
        }
    }
    if let Some(open) = stack.last() {
        return Err(format!("XML element {} is not closed", open.name));
    }
    root.ok_or_else(|| "XML has no root element".into())
}

fn close(node: Node, stack: &mut [Node], root: &mut Option<Value>) {
    match stack.last_mut() {
        Some(parent) => parent.children.push(node.into_json()),
        None => *root = Some(node.into_json()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn value(source: &str) -> Value {
        let result: Value = serde_json::from_str(&parse(source)).unwrap();
        assert_eq!(result["ok"], true, "{source}: {result}");
        result["value"].clone()
    }

    fn error(source: &str) -> String {
        let result: Value = serde_json::from_str(&parse(source)).unwrap();
        assert_eq!(result["ok"], false, "{source}: {result}");
        result["error"].as_str().unwrap().to_owned()
    }

    #[test]
    fn elements_attributes_text_and_children_keep_their_shape() {
        let source = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!-- feed -->\n<rss version='2.0' xmlns:dc=\"http://purl.org/dc/\">\r\n  <channel>\n    <title>News &amp; <![CDATA[<b>more</b>]]> &#x4f60;&#22909;</title>\n    <dc:date when=\"a\tb\nc &quot;d&quot; &lt;\"/>\n    <?pi data?>\n  </channel>\n</rss>\n";
        assert_eq!(
            stringify(&value(source)),
            r#"{"name":"rss","attributes":{"version":"2.0","xmlns:dc":"http://purl.org/dc/"},"text":"\n  \n","children":[{"name":"channel","attributes":{},"text":"\n    \n    \n    \n  ","children":[{"name":"title","attributes":{},"text":"News & <b>more</b> 你好","children":[]},{"name":"dc:date","attributes":{"when":"a b c \"d\" <"},"text":"","children":[]}]}]}"#
        );
        assert_eq!(stringify(&value("\u{feff}<a/>")), r#"{"name":"a","attributes":{},"text":"","children":[]}"#);
        assert_eq!(value("<a>x<b>y</b>z</a>")["text"], "xz");
        assert_eq!(value("<a>1 &gt; 0 &apos;&#65;&apos;</a>")["text"], "1 > 0 'A'");
    }

    #[test]
    fn declarations_and_entities_are_refused() {
        let declaration = "XML document type and entity declarations are not allowed";
        assert_eq!(error("<!DOCTYPE a [<!ENTITY x \"y\">]><a>&x;</a>"), declaration);
        assert_eq!(error("<!doctype html><a/>"), declaration);
        assert_eq!(error("<a><! ENTITY x SYSTEM \"file:///etc/passwd\"></a>"), declaration);
        assert_eq!(error("<!DOCTYPE a SYSTEM \"http://example.com/a.dtd\"><a/>"), declaration);
        // A billion laughs needs entity declarations; without them a reference is refused.
        assert_eq!(error("<a>&lol9;</a>"), "XML entity references are not allowed");
        assert_eq!(error("<a b=\"&xxe;\"/>"), "XML entity references are not allowed");
        assert_eq!(error("<a><!ELEMENT a ANY></a>"), "XML document type declarations are not allowed");
        assert_eq!(error("<a>&#0;</a>"), "XML character reference is not valid");
        assert_eq!(error("<a>&#xD800;</a>"), "XML character reference is not valid");
        assert_eq!(error("<a>&amp</a>"), "XML reference is not closed");
    }

    #[test]
    fn the_limits_are_those_of_the_other_platforms() {
        assert_eq!(error(&format!("<a>{}</a>", "x".repeat(MAXIMUM_BYTES))), "XML exceeds the 262144-byte limit");
        assert_eq!(value(&format!("<a>{}</a>", "x".repeat(MAXIMUM_BYTES - 7)))["text"].as_str().unwrap().len(), MAXIMUM_BYTES - 7);
        assert_eq!(error(&format!("<a>{}</a>", "<b/>".repeat(MAXIMUM_ELEMENTS))), "XML exceeds the 2048-element limit");
        assert_eq!(value(&format!("<a>{}</a>", "<b/>".repeat(MAXIMUM_ELEMENTS - 1)))["children"].as_array().unwrap().len(), MAXIMUM_ELEMENTS - 1);
        let nested = |depth: usize| format!("{}{}", "<a>".repeat(depth), "</a>".repeat(depth));
        assert_eq!(error(&nested(MAXIMUM_DEPTH + 1)), "XML exceeds the 32-level depth limit");
        assert_eq!(value(&nested(MAXIMUM_DEPTH))["name"], "a");
    }

    #[test]
    fn malformed_documents_are_errors() {
        for source in [
            "", "   ", "plain", "<a>", "<a></b>", "</a>", "<a/><b/>", "<a/>text", "text<a/>", "<a b></a>", "<a b=c/>", "<a b='1' b='2'/>", "<a b='1'c='2'/>", "<a b='<'/>", "<a b='1/>", "<1a/>", "< a/>", "<a><!-- open</a>",
            "<a><![CDATA[open</a>", "<a>\u{1}</a>", "<a/><?xml version='1.0'?>", "<a></a >x",
        ] {
            assert!(!error(source).is_empty(), "{source:?}");
        }
        assert_eq!(error("<a/><b/>"), "XML has more than one root element");
        assert_eq!(error(""), "XML has no root element");
        assert_eq!(error("<a><b></a></b>"), "XML end tag a does not match start tag b");
    }
}
