//! What the code editor offers while typing. The data is the metadata the
//! other editors complete from (`Editor/editorfe/src/scriptWidgetAPI.js`),
//! written as JSON by `Linux/scripts/build-shared-js.mjs` and built into the
//! program; the rules follow `Editor/editorfe/src/scriptWidgetCompletions.js`.
//!
//! Differences from the web editor: a component is found whatever the case
//! of its tag (the templates write `<vstack>`, the metadata says `VStack`);
//! `$` offers the script globals; globals Linux does not implement are not
//! offered; and what is inserted is plain text, because this editor has no
//! snippet placeholders.

use serde_json::Value;

/// The JSON of `Linux/assets/scriptwidget/api-reference.json`, or `{}` when it was not generated (see `build.rs`).
const EMBEDDED: &str = include_str!(concat!(env!("OUT_DIR"), "/api-reference.json"));

/// How far back from the cursor the text is looked at, as in the web editor.
const WINDOW_BYTES: usize = 1200;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Kind {
    Component,
    Property,
    Value,
    Function,
    Global,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Item {
    pub label: String,
    /// A short note beside the label: a type, or what a function returns.
    pub detail: String,
    pub documentation: String,
    /// The text that replaces what was typed.
    pub insert: String,
    pub kind: Kind,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Completions {
    /// Byte offset where the replaced text starts; it ends at the cursor.
    pub from: usize,
    pub items: Vec<Item>,
}

#[derive(Debug, Clone, Default)]
struct Property {
    name: String,
    kind: String,
    documentation: String,
    values: Vec<String>,
    required: bool,
}

#[derive(Debug, Clone, Default)]
struct Component {
    name: String,
    documentation: String,
    properties: Vec<Property>,
}

#[derive(Debug, Clone, Default)]
struct Function {
    /// "$storage.getString", or "fetch" for a function without an object.
    id: String,
    returns: String,
    documentation: String,
    arguments: Vec<String>,
}

#[derive(Debug, Clone, Default)]
pub struct ApiReference {
    components: Vec<Component>,
    global_properties: Vec<Property>,
    functions: Vec<Function>,
}

impl ApiReference {
    /// The reference built into the program.
    pub fn embedded() -> Self {
        Self::parse(EMBEDDED)
    }

    /// Reads the JSON leniently: what is missing or of another shape is left out.
    pub fn parse(json: &str) -> Self {
        let root: Value = serde_json::from_str(json).unwrap_or(Value::Null);
        let text = |value: &Value, key: &str| value.get(key).and_then(Value::as_str).unwrap_or_default().to_owned();
        let strings = |value: &Value, key: &str| value.get(key).and_then(Value::as_array).map(|items| items.iter().filter_map(|item| item.as_str().map(str::to_owned)).collect::<Vec<_>>()).unwrap_or_default();
        let properties = |value: Option<&Value>| {
            value
                .and_then(Value::as_object)
                .map(|entries| {
                    entries
                        .iter()
                        .map(|(name, property)| Property {
                            name: name.clone(),
                            kind: text(property, "type"),
                            documentation: match property.get("deprecated").and_then(Value::as_str) {
                                Some(deprecated) => format!("Deprecated: {deprecated}"),
                                None => text(property, "documentation"),
                            },
                            values: strings(property, "values"),
                            required: property.get("required").and_then(Value::as_bool).unwrap_or(false),
                        })
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default()
        };
        let components = root
            .get("components")
            .and_then(Value::as_object)
            .map(|entries| entries.iter().map(|(name, component)| Component { name: name.clone(), documentation: text(component, "documentation"), properties: properties(component.get("properties")) }).collect())
            .unwrap_or_default();
        let functions = root
            .get("functions")
            .and_then(Value::as_object)
            .map(|entries| entries.iter().map(|(id, function)| Function { id: id.clone(), returns: text(function, "returns"), documentation: text(function, "documentation"), arguments: strings(function, "arguments") }).collect())
            .unwrap_or_default();
        Self { components, global_properties: properties(root.get("globalProperties")), functions }
    }

    pub fn is_empty(&self) -> bool {
        self.components.is_empty() && self.functions.is_empty()
    }

    /// True when typing `text` should ask for completions: a name is being typed, or a tag, a member or a value was just opened.
    pub fn is_trigger(text: &str) -> bool {
        !text.is_empty() && text.chars().all(|character| is_word(character) || matches!(character, '$' | '<' | '.' | '"' | '\'' | ' '))
    }

    /// What to offer at byte `offset` of `text`, or `None` for nothing.
    pub fn complete(&self, text: &str, offset: usize) -> Option<Completions> {
        let offset = floor_boundary(text, offset.min(text.len()));
        let start = floor_boundary(text, offset.saturating_sub(WINDOW_BYTES));
        let before = &text[start..offset];

        if let Some(tag) = opening_tag(before) {
            // A value of a property that takes one of a fixed list.
            if let Some((property, typed)) = open_value(tag.attributes)
                && let Some(definition) = self.property(tag.name, property)
                && !definition.values.is_empty()
            {
                let items = definition.values.iter().filter(|value| starts_with(value, typed)).map(|value| Item { label: value.clone(), detail: definition.kind.clone(), documentation: String::new(), insert: value.clone(), kind: Kind::Value }).collect();
                return finish(offset - typed.len(), items);
            }
            // The name of the tag itself.
            if tag.attributes.is_empty() {
                return finish(offset - tag.name.len(), self.component_items(tag.name));
            }
            // A property name: a word that follows white space inside the tag, outside any quoted value.
            let word = trailing_word(tag.attributes);
            let preceded_by_space = tag.attributes[..tag.attributes.len() - word.len()].chars().next_back().is_some_and(char::is_whitespace);
            let quotes_closed = ['"', '\''].iter().all(|quote| tag.attributes.matches(*quote).count() % 2 == 0);
            if preceded_by_space && quotes_closed {
                let component = self.component(tag.name)?;
                let used = used_properties(tag.attributes);
                let items = component
                    .properties
                    .iter()
                    .chain(self.global_properties.iter().filter(|global| !component.properties.iter().any(|own| own.name == global.name)))
                    .filter(|property| !used.contains(&property.name.as_str()) && starts_with(&property.name, word))
                    .map(|property| Item {
                        label: property.name.clone(),
                        detail: if property.required { format!("{} · required", property.kind) } else { property.kind.clone() },
                        documentation: property.documentation.clone(),
                        insert: format!("{}=", property.name),
                        kind: Kind::Property,
                    })
                    .collect();
                return finish(offset - word.len(), items);
            }
            // Otherwise the cursor is in an expression of the tag: the rules for code apply.
        }

        // `$storage.` and what follows: the functions of one global.
        let word = trailing_name(before);
        if let Some((object, member)) = word.split_once('.')
            && object.starts_with('$')
            && !member.contains('.')
        {
            if unsupported(object) {
                return None;
            }
            let prefix = &word[..object.len() + 1];
            let items = self.functions.iter().filter(|function| function.id.starts_with(prefix) && starts_with(&function.id[prefix.len()..], member)).map(|function| self.function_item(function, &function.id[prefix.len()..])).collect();
            return finish(offset - member.len(), items);
        }
        // `$`: the globals, and the functions that have no object.
        if word.starts_with('$') && !word.contains('.') {
            let mut items: Vec<Item> = Vec::new();
            for function in &self.functions {
                match function.id.split_once('.') {
                    Some((object, _)) => {
                        if starts_with(object, word) && !unsupported(object) && !items.iter().any(|item| item.label == object) {
                            let count = self.functions.iter().filter(|other| other.id.split_once('.').is_some_and(|(owner, _)| owner == object)).count();
                            items.push(Item { label: object.to_owned(), detail: format!("{count} functions"), documentation: String::new(), insert: object.to_owned(), kind: Kind::Global });
                        }
                    }
                    None if starts_with(&function.id, word) => items.push(self.function_item(function, &function.id)),
                    None => {}
                }
            }
            return finish(offset - word.len(), items);
        }
        None
    }

    fn component(&self, name: &str) -> Option<&Component> {
        self.components.iter().find(|component| component.name.eq_ignore_ascii_case(name))
    }

    fn property(&self, component: &str, property: &str) -> Option<&Property> {
        self.component(component).and_then(|component| component.properties.iter().find(|own| own.name == property)).or_else(|| self.global_properties.iter().find(|global| global.name == property))
    }

    fn component_items(&self, typed: &str) -> Vec<Item> {
        // The case the user started in is kept: `<vs` completes to `vstack`, `<VS` to `VStack`.
        let lower = typed.chars().next().is_some_and(char::is_lowercase);
        self.components
            .iter()
            .filter(|component| starts_with(&component.name, typed))
            .map(|component| {
                let name = if lower { component.name.to_lowercase() } else { component.name.clone() };
                Item { label: name.clone(), detail: format!("{} properties", component.properties.len()), documentation: component.documentation.clone(), insert: name, kind: Kind::Component }
            })
            .collect()
    }

    fn function_item(&self, function: &Function, label: &str) -> Item {
        Item { label: label.to_owned(), detail: format!("({}) → {}", function.arguments.join(", "), function.returns), documentation: function.documentation.clone(), insert: label.to_owned(), kind: Kind::Function }
    }
}

fn finish(from: usize, items: Vec<Item>) -> Option<Completions> {
    (!items.is_empty()).then_some(Completions { from, items })
}

fn unsupported(global: &str) -> bool {
    sw_core::library::is_unsupported_api(global.trim_start_matches('$'))
}

fn is_word(character: char) -> bool {
    character.is_alphanumeric() || character == '_'
}

/// Without regard to ASCII case, as the web editor filters.
fn starts_with(name: &str, typed: &str) -> bool {
    name.len() >= typed.len() && name.is_char_boundary(typed.len()) && name[..typed.len()].eq_ignore_ascii_case(typed)
}

fn floor_boundary(text: &str, mut offset: usize) -> usize {
    while !text.is_char_boundary(offset) {
        offset -= 1;
    }
    offset
}

struct OpeningTag<'a> {
    name: &'a str,
    /// Everything after the name up to the cursor.
    attributes: &'a str,
}

/// The tag the cursor is inside: `<Name attributes` with no `<` or `>` after the `<`.
fn opening_tag(before: &str) -> Option<OpeningTag<'_>> {
    let open = before.rfind('<')?;
    let rest = &before[open + 1..];
    if rest.contains('>') {
        return None;
    }
    let name_length = rest.find(|character: char| !is_word(character)).unwrap_or(rest.len());
    let (name, attributes) = rest.split_at(name_length);
    // `a < b`, `</name` and a generic comparison are not tags; an empty name is a tag being started.
    let starts_like_a_tag = name.chars().next().is_none_or(|first| first.is_ascii_alphabetic());
    let follows_code = attributes.is_empty() || attributes.starts_with(char::is_whitespace);
    (starts_like_a_tag && follows_code && (!name.is_empty() || attributes.is_empty())).then_some(OpeningTag { name, attributes })
}

/// The property whose quoted value is being typed, and what was typed of it.
fn open_value(attributes: &str) -> Option<(&str, &str)> {
    let quote = attributes.rfind(['"', '\''])?;
    let typed = &attributes[quote + 1..];
    let assignment = attributes[..quote].trim_end().strip_suffix('=')?.trim_end();
    let property = trailing_word(assignment);
    (!property.is_empty() && !typed.contains(char::is_whitespace)).then_some((property, typed))
}

fn trailing_word(text: &str) -> &str {
    let start = text.char_indices().rev().take_while(|(_, character)| is_word(*character)).last().map_or(text.len(), |(index, _)| index);
    &text[start..]
}

/// The name before the cursor with its `$` and dots: `$storage.get`.
fn trailing_name(text: &str) -> &str {
    let start = text.char_indices().rev().take_while(|(_, character)| is_word(*character) || matches!(character, '$' | '.')).last().map_or(text.len(), |(index, _)| index);
    &text[start..]
}

/// The property names already written in a tag.
fn used_properties(attributes: &str) -> Vec<&str> {
    attributes.match_indices('=').map(|(at, _)| trailing_word(attributes[..at].trim_end())).filter(|name| !name.is_empty()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn reference() -> ApiReference {
        let reference = ApiReference::embedded();
        assert!(!reference.is_empty(), "the API reference is not built in: run node Linux/scripts/build-shared-js.mjs and build again");
        reference
    }

    /// Completes at the `|` in `text`.
    fn at(text: &str) -> Option<(String, Vec<Item>)> {
        let offset = text.find('|').expect("a | for the cursor");
        let source = text.replace('|', "");
        reference().complete(&source, offset).map(|completions| (source[completions.from..offset].to_owned(), completions.items))
    }

    fn labels(text: &str) -> Vec<String> {
        at(text).map(|(_, items)| items.into_iter().map(|item| item.label).collect()).unwrap_or_default()
    }

    #[test]
    fn the_metadata_of_the_other_editors_is_built_in() {
        let reference = reference();
        assert!(reference.components.len() >= 29 && reference.functions.len() >= 100 && reference.global_properties.len() > 10);
        assert!(reference.component("vstack").is_some() && reference.component("VStack").is_some());
    }

    #[test]
    fn a_tag_offers_components_in_the_case_it_was_started_in() {
        let (replaced, items) = at("$render(<vs|").unwrap();
        assert_eq!(replaced, "vs");
        assert_eq!(items.iter().map(|item| item.label.as_str()).collect::<Vec<_>>(), ["vstack"]);
        assert_eq!(items[0].kind, Kind::Component);
        assert!(!items[0].documentation.is_empty());
        assert_eq!(labels("<VS|"), ["VStack"]);
        assert!(labels("<|").len() >= 29, "every component right after <");
        assert_eq!(labels("<zzz|"), Vec::<String>::new());
    }

    #[test]
    fn inside_a_tag_the_properties_not_yet_written_are_offered() {
        let (replaced, items) = at("<text font=\"title\" co|").unwrap();
        assert_eq!(replaced, "co");
        assert!(items.iter().any(|item| item.label == "color" && item.insert == "color=" && item.kind == Kind::Property));
        assert!(items.iter().all(|item| item.label.to_lowercase().starts_with("co")));
        let all = labels("<vstack spacing={4} |");
        assert!(all.contains(&"background".to_owned()) && all.contains(&"padding".to_owned()));
        assert!(!all.contains(&"spacing".to_owned()), "already written");
        // Not after the tag is closed, not in the middle of a value, not for an unknown tag.
        assert_eq!(labels("<text>hello wor|"), Vec::<String>::new());
        assert_eq!(labels("<text font={siz|"), Vec::<String>::new());
        assert_eq!(labels("<nothing co|"), Vec::<String>::new());
        assert_eq!(labels("<text accessibilityLabel=\"two wo|"), Vec::<String>::new(), "inside a quoted value");
        assert!(labels("<text color={$storage.get|").contains(&"getString".to_owned()), "an expression in a tag is code");
    }

    #[test]
    fn a_value_from_a_fixed_list_is_offered_inside_its_quotes() {
        let (replaced, items) = at("<vstack backgroundMaterial=\"th|").unwrap();
        assert_eq!(replaced, "th");
        assert_eq!(items.iter().map(|item| item.label.as_str()).collect::<Vec<_>>(), ["thin", "thick"]);
        assert!(items.iter().all(|item| item.kind == Kind::Value));
        assert!(labels("<vstack backgroundMaterial='|").contains(&"regular".to_owned()));
        // A closed value is over.
        let after = labels("<vstack backgroundMaterial=\"thin\" |");
        assert!(after.contains(&"padding".to_owned()) && !after.contains(&"thin".to_owned()));
    }

    #[test]
    fn a_global_offers_its_functions_and_dollar_offers_the_globals() {
        let (replaced, items) = at("const name = $storage.get|").unwrap();
        assert_eq!(replaced, "get");
        assert!(items.iter().any(|item| item.label == "getString" && item.detail.contains("string") && item.kind == Kind::Function));
        assert!(items.iter().all(|item| item.label.starts_with("get")));
        assert!(labels("$storage.|").len() > 3);

        let globals = labels("await $|");
        assert!(globals.contains(&"$storage".to_owned()) && globals.contains(&"$device".to_owned()) && globals.contains(&"$weather".to_owned()));
        assert_eq!(globals.iter().filter(|label| *label == "$storage").count(), 1);
        assert_eq!(labels("$sto|"), ["$storage"]);
        assert_eq!(labels("$nothing.|"), Vec::<String>::new());
        assert_eq!(labels("const total = price * cou|"), Vec::<String>::new(), "ordinary code offers nothing");
        assert_eq!(labels("if (a < b|"), Vec::<String>::new());
        assert_eq!(labels("</vsta|"), Vec::<String>::new());
    }

    #[test]
    fn globals_linux_does_not_implement_are_not_offered() {
        let globals = labels("$|");
        for missing in ["$health", "$calendar", "$location", "$maps"] {
            assert!(!globals.contains(&missing.to_owned()), "{missing}");
        }
        assert_eq!(labels("$health.|"), Vec::<String>::new());
        // What Linux implements is completed like any other global.
        for present in ["$music", "$notifications", "$documents", "$photos", "$services"] {
            assert!(globals.contains(&present.to_owned()), "{present}");
        }
        assert!(labels("$music.|").contains(&"current".to_owned()), "{:?}", labels("$music.|"));
    }

    #[test]
    fn offsets_are_bytes_and_text_before_the_cursor_may_be_anything() {
        let (replaced, items) = at("// 你好，世界 🌍\n<text>中文</text>\n$render(<hst|").unwrap();
        assert_eq!((replaced.as_str(), items[0].label.as_str()), ("hst", "hstack"));
        let reference = reference();
        let text = "<text>你好</text>";
        for offset in 0..=text.len() + 3 {
            // An offset inside a character or past the end does not panic.
            let _ = reference.complete(text, offset);
        }
        let long = format!("{}<vst", "好".repeat(2000));
        assert_eq!(reference.complete(&long, long.len()).unwrap().items[0].label, "vstack");
        assert!(ApiReference::parse("not json").is_empty() && ApiReference::parse("{\"components\":7}").is_empty());
        assert!(ApiReference::parse("{}").complete("<v", 2).is_none());
    }

    #[test]
    fn typing_a_name_or_an_opening_character_asks_for_completions() {
        for text in ["a", "$", "<", ".", "\"", " ", "vs"] {
            assert!(ApiReference::is_trigger(text), "{text:?}");
        }
        for text in ["", "\n", ";", "(", "a;b"] {
            assert!(!ApiReference::is_trigger(text), "{text:?}");
        }
    }
}
