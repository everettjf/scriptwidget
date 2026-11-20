//! AI widget generation: the multi-turn conversation with a model the user
//! chose. A port of `Android/core/src/main/java/com/everettjf/scriptwidget/core/ai`
//! (itself a port of `Shared/ScriptWidgetRuntime/AI`); each module names the
//! Kotlin file it ports and keeps its names where Rust naming allows.
//!
//! What is trusted and what is not:
//! - The endpoint, the model and the API key are the user's own choice. The
//!   key lives in the system keyring ([`credentials`]) and is handed to
//!   [`AiClient`] per call; it is never part of a profile, a prompt, a
//!   conversation, a package, a log line or an error message.
//! - Everything a model answers is untrusted text. It becomes a widget only
//!   after it compiled and ran in the engine with the limits every run has,
//!   and the only part of a manifest it can influence is the network
//!   declaration ([`AiManifestDeclaration`]), which accepts public host names
//!   and the `network` permission and nothing else.
//! - Skills only add text to a request; they grant nothing.

pub mod agent_loop;
pub mod candidates;
pub mod client;
pub mod conversation;
pub mod conversation_store;
pub mod conversation_turns;
pub mod credentials;
pub mod jsx_check;
mod jsx_surface_data;
pub mod output;
pub mod profile;
pub mod profile_store;
pub mod prompt_builder;
pub mod source_diff;
pub mod source_edits;
pub mod transport;

pub use agent_loop::{AgentLoop, AgentLoopEvent, AgentLoopOutcome, AgentLoopRequest, Mode};
pub use client::{AiChat, AiChatResult, AiClient, AiMessage, AiStreamReader, AiTokenUsage, BoundChat, Role};
pub use conversation::{AiConversation, AiConversationLimits, AiConversationTurn, AiConversationUsageAdvice, AiConversationVersion, Reason, Status};
pub use conversation_store::{AiConversationStore, AiConversationSummary};
pub use conversation_turns::{AiConversationTurns, Started};
pub use credentials::{ApiKey, CredentialError, CredentialStore, MemoryCredentialStore, SecretToolStore};
pub use output::{AiCandidate, AiManifestDeclaration, AiManifests, AiOutput, ValidationResult};
pub use profile::{AiProfile, AiProviderKind, AiSettings};
pub use profile_store::AiProfileStore;
pub use prompt_builder::{AiExamplePrompt, AiExamplePrompts, AiReference, AiTurnContext, AiTurnReply, AiWidgetSize, Exchange, LinuxPromptNotes, PromptBuilder};
pub use source_diff::AiSourceDiff;
pub use source_edits::{AiSourceEdit, AiSourceEdits};
pub use transport::{AiCancellation, AiClientError, AiErrorKind, AiHttpRequest, AiHttpResponse, AiTransport, HttpsAiTransport};

/// Milliseconds since 1970, as the conversation files store times.
pub fn now_milliseconds() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |elapsed| elapsed.as_millis() as i64)
}

/// A random identifier in the form of a version 4 UUID, as `UUID.randomUUID()` gives on Android.
pub(crate) fn new_id() -> String {
    let mut bytes = [0u8; 16];
    // Without a random source the identifier is still unique within this process and this millisecond.
    if getrandom::fill(&mut bytes).is_err() {
        static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        bytes[..8].copy_from_slice(&(now_milliseconds() as u64).to_be_bytes());
        bytes[8..].copy_from_slice(&COUNTER.fetch_add(1, std::sync::atomic::Ordering::SeqCst).to_be_bytes());
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    format!("{}-{}-{}-{}-{}", &hex[0..8], &hex[8..12], &hex[12..16], &hex[16..20], &hex[20..32])
}

/// The first `limit` characters of `text`. Kotlin counts UTF-16 units and
/// Swift counts characters; this counts Unicode scalar values, which differs
/// from Kotlin only for text outside the Basic Multilingual Plane.
pub(crate) fn take(text: &str, limit: usize) -> &str {
    match text.char_indices().nth(limit) {
        Some((at, _)) => &text[..at],
        None => text,
    }
}

pub(crate) fn length(text: &str) -> usize {
    text.chars().count()
}

/// `Char.isWhitespace()` of Kotlin.
pub(crate) fn is_whitespace(character: char) -> bool {
    character.is_whitespace() || ('\u{1c}'..='\u{1f}').contains(&character)
}

/// `String.isBlank()` of Kotlin.
pub(crate) fn is_blank(text: &str) -> bool {
    text.chars().all(is_whitespace)
}

/// `String.trim()` of Kotlin.
pub(crate) fn trim(text: &str) -> &str {
    text.trim_matches(is_whitespace)
}

/// Writes `bytes` under a private temporary name beside `target` and renames
/// the result over it. The file is created new, never through a link, and is
/// readable by the user only; the folder is made for the user only when it
/// does not exist.
pub(crate) fn write_private(target: &std::path::Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write as _;
    use std::os::unix::fs::{DirBuilderExt as _, OpenOptionsExt as _};
    let invalid = || std::io::Error::new(std::io::ErrorKind::InvalidInput, "not a file path");
    let folder = target.parent().ok_or_else(invalid)?;
    let name = target.file_name().ok_or_else(invalid)?;
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(folder)?;
    let mut random = [0u8; 8];
    getrandom::fill(&mut random).map_err(|error| std::io::Error::other(error.to_string()))?;
    let suffix: String = random.iter().map(|byte| format!("{byte:02x}")).collect();
    let temporary = folder.join(format!(".{}.{suffix}.tmp", name.to_string_lossy()));
    let written = (|| {
        let mut file = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC).open(&temporary)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        std::fs::rename(&temporary, target)
    })();
    if written.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    written
}
