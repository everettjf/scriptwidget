//! Replies that change part of the code. Port of `AiSourceEdits.kt`.

use super::{is_blank, trim};

/// One change to a widget's source: `search` is replaced by `replace`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AiSourceEdit {
    pub search: String,
    pub replace: String,
}

impl AiSourceEdit {
    pub fn new(search: impl Into<String>, replace: impl Into<String>) -> Self {
        Self { search: search.into(), replace: replace.into() }
    }
}

/// Why a reply written as edit blocks was refused.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Failure {
    pub reason: String,
}

impl Failure {
    pub fn new(reason: impl Into<String>) -> Self {
        Self { reason: reason.into() }
    }
}

impl std::fmt::Display for Failure {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.reason)
    }
}

impl std::error::Error for Failure {}

/// A reply that changes part of the current code instead of sending all of it.
/// Port of `AISourceEdits`; the ports must read and apply the same replies in
/// the same way.
///
/// The model writes one block per place:
///
/// ```text
/// <<<<<<< SEARCH
/// lines copied from the current code
/// =======
/// the lines that replace them
/// >>>>>>> REPLACE
/// ```
///
/// Nothing is guessed. The searched text has to be in the code exactly once;
/// otherwise the whole reply is refused and the model is asked again. What comes
/// out is run and checked like any other candidate.
pub struct AiSourceEdits;

impl AiSourceEdits {
    pub const SEARCH_MARKER: &'static str = "<<<<<<< SEARCH";
    pub const DIVIDER_MARKER: &'static str = "=======";
    pub const REPLACE_MARKER: &'static str = ">>>>>>> REPLACE";
    pub const MAX_EDITS: usize = 20;

    /// Whether `reply` is written as edit blocks.
    pub fn is_edit_reply(reply: &str) -> bool {
        normalized(reply).split('\n').any(|line| trim(line) == Self::SEARCH_MARKER)
    }

    /// The edits of `reply`, in order; `None` when it has no edit block. A block that is not
    /// complete, has nothing to search for, or too many blocks is a [`Failure`].
    pub fn parse(reply: &str) -> Result<Option<Vec<AiSourceEdit>>, Failure> {
        if !Self::is_edit_reply(reply) {
            return Ok(None);
        }
        let mut edits: Vec<AiSourceEdit> = Vec::new();
        let mut search: Option<Vec<&str>> = None;
        let mut replace: Option<Vec<&str>> = None;
        let text = normalized(reply);
        for line in text.split('\n') {
            let marker = trim(line);
            if marker == Self::SEARCH_MARKER {
                if search.is_some() {
                    return Err(Failure::new("an edit block starts before the one before it ends"));
                }
                search = Some(Vec::new());
            } else if marker == Self::DIVIDER_MARKER && search.is_some() && replace.is_none() {
                replace = Some(Vec::new());
            } else if marker == Self::REPLACE_MARKER {
                let (Some(from), Some(to)) = (search.take(), replace.take()) else { return Err(Failure::new("an edit block ends without its SEARCH part and its ======= line")) };
                let text = from.join("\n");
                if is_blank(&text) {
                    return Err(Failure::new(format!("edit {} has nothing in its SEARCH part", edits.len() + 1)));
                }
                edits.push(AiSourceEdit { search: text, replace: to.join("\n") });
                if edits.len() > Self::MAX_EDITS {
                    return Err(Failure::new(format!("there are more than {} edit blocks", Self::MAX_EDITS)));
                }
            } else if let Some(replace) = replace.as_mut() {
                replace.push(line);
            } else if let Some(search) = search.as_mut() {
                search.push(line);
            }
        }
        if search.is_some() {
            return Err(Failure::new("the last edit block has no >>>>>>> REPLACE line"));
        }
        Ok(Some(edits))
    }

    /// `source` with `edits` applied one after the other. The result ends with a line break.
    /// A searched text that is not in the code, or is there more than once, is a [`Failure`].
    pub fn apply(edits: &[AiSourceEdit], source: &str) -> Result<String, Failure> {
        let mut text = normalized(source);
        for (index, edit) in edits.iter().enumerate() {
            let count = occurrences(&text, &edit.search);
            if count == 0 {
                return Err(Failure::new(format!("the SEARCH text of edit {} is not in the current code; it has to be copied exactly, with its indentation", index + 1)));
            }
            if count > 1 {
                return Err(Failure::new(format!("the SEARCH text of edit {} is in the current code {count} times; add neighbouring lines so that it is there once", index + 1)));
            }
            text = text.replacen(&edit.search, &edit.replace, 1);
        }
        Ok(format!("{}\n", text.trim_end_matches(['\n', ' ', '\t'])))
    }
}

fn normalized(text: &str) -> String {
    text.replace("\r\n", "\n").replace('\r', "\n")
}

fn occurrences(text: &str, part: &str) -> usize {
    if part.is_empty() { 0 } else { text.matches(part).count() }
}
