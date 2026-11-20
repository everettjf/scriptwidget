//! Conversations as files. Port of `AiConversationStore.kt`.

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use super::conversation::{AiConversation, AiConversationLimits};

/// What a list of conversations shows, without the sources.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AiConversationSummary {
    pub id: String,
    pub title: String,
    pub package_id: Option<String>,
    pub version_count: usize,
    pub updated_at: i64,
}

/// Conversations as files, one JSON file each, in a directory that belongs to
/// the application (`AiConversations` in the data folder, see
/// [`crate::DataPaths::ai_conversations`]). Port of `AIConversationStore`.
///
/// They hold the user's requests and the widget sources and stay on this
/// computer, readable by the user only. They never hold a key and name no
/// provider.
///
/// Files that cannot be read, are too large or are not conversations are
/// ignored, never deleted and never partly used. Only the newest
/// [`AiConversationLimits::MAX_CONVERSATIONS`] are kept.
///
/// All methods block; call them off the window's thread.
pub struct AiConversationStore {
    directory: PathBuf,
    lock: Mutex<()>,
}

impl AiConversationStore {
    pub fn new(directory: impl Into<PathBuf>) -> Self {
        Self { directory: directory.into(), lock: Mutex::new(()) }
    }

    pub fn directory(&self) -> &Path {
        &self.directory
    }

    pub fn save(&self, conversation: &AiConversation) -> bool {
        let _guard = self.lock.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if !AiConversation::is_safe_id(&conversation.id) {
            return false;
        }
        let bytes = crate::json::stringify(&conversation.to_json()).into_bytes();
        if bytes.len() as u64 > AiConversationLimits::MAX_FILE_BYTES {
            return false;
        }
        if super::write_private(&self.file(&conversation.id), &bytes).is_err() {
            return false;
        }
        self.prune();
        true
    }

    pub fn load(&self, id: &str) -> Option<AiConversation> {
        let _guard = self.lock.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if !AiConversation::is_safe_id(id) {
            return None;
        }
        read(&self.file(id))
    }

    pub fn delete(&self, id: &str) {
        let _guard = self.lock.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if AiConversation::is_safe_id(id) {
            let _ = std::fs::remove_file(self.file(id));
        }
    }

    /// Newest first. With `drafts_only`, conversations that belong to an installed widget are left out.
    pub fn summaries(&self, drafts_only: bool) -> Vec<AiConversationSummary> {
        let _guard = self.lock.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let mut all: Vec<AiConversation> = self.all().into_iter().filter(|conversation| (!drafts_only || conversation.is_draft()) && !conversation.turns.is_empty()).collect();
        all.sort_by_key(|conversation| std::cmp::Reverse(conversation.updated_at));
        all.into_iter().map(|conversation| AiConversationSummary { version_count: conversation.versions.len(), id: conversation.id, title: conversation.title, package_id: conversation.package_id, updated_at: conversation.updated_at }).collect()
    }

    /// The newest conversation of an installed widget.
    pub fn latest(&self, package_id: &str) -> Option<AiConversation> {
        let _guard = self.lock.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        self.all().into_iter().filter(|conversation| conversation.package_id.as_deref() == Some(package_id)).max_by_key(|conversation| conversation.updated_at)
    }

    /// A widget was deleted: its conversations go with it.
    pub fn delete_for_package(&self, package_id: &str) {
        let _guard = self.lock.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        for conversation in self.all() {
            if conversation.package_id.as_deref() == Some(package_id) {
                let _ = std::fs::remove_file(self.file(&conversation.id));
            }
        }
    }

    fn file(&self, id: &str) -> PathBuf {
        self.directory.join(format!("{id}.json"))
    }

    fn files(&self) -> Vec<PathBuf> {
        let Ok(entries) = std::fs::read_dir(&self.directory) else { return Vec::new() };
        let mut files: Vec<PathBuf> = entries.flatten().map(|entry| entry.path()).filter(|path| path.extension().is_some_and(|extension| extension == "json")).collect();
        files.sort();
        files
    }

    fn all(&self) -> Vec<AiConversation> {
        self.files().iter().filter_map(|file| read(file)).collect()
    }

    fn prune(&self) {
        let mut known: Vec<(i64, PathBuf)> = self.files().into_iter().filter_map(|file| read(&file).map(|conversation| (conversation.updated_at, file))).collect();
        if known.len() <= AiConversationLimits::MAX_CONVERSATIONS {
            return;
        }
        known.sort_by_key(|(updated_at, _)| std::cmp::Reverse(*updated_at));
        for (_, file) in known.into_iter().skip(AiConversationLimits::MAX_CONVERSATIONS) {
            let _ = std::fs::remove_file(file);
        }
    }
}

fn read(file: &Path) -> Option<AiConversation> {
    // A regular file itself, not a link to one, and not larger than a conversation may be.
    let metadata = std::fs::symlink_metadata(file).ok()?;
    if !metadata.is_file() || metadata.len() > AiConversationLimits::MAX_FILE_BYTES {
        return None;
    }
    let text = std::fs::read_to_string(file).ok()?;
    let conversation = AiConversation::from_json(&serde_json::from_str(&text).ok()?)?;
    // The name is the id: a file copied under another name is not trusted.
    (file.file_name()?.to_str()? == format!("{}.json", conversation.id)).then_some(conversation)
}
