//! What the user allows and picks for the data APIs of one widget, and the
//! GitHub account of `$services`: the window's side of
//! `sw_core::api::SystemStores`. The command line does the same with
//! `scriptwidget services`, `notifications`, `documents` and `photos`.
//!
//! A manifest says what a widget would like to use. This is where the user
//! answers, one widget at a time. A file or a picture is picked by its path;
//! the widget gets its content and never the path. The GitHub token goes
//! from the field to GitHub once, to be verified, and then into the system
//! keyring; nothing here returns it or writes it anywhere else.

use std::path::Path;
use std::sync::Arc;

use sw_core::InstalledPackage;
use sw_core::api::SystemStores;
use sw_core::api::documents::{PickError, document_rules};
use sw_core::api::photos::photo_limits;
use sw_core::api::support::{SystemReject, system_log};

use crate::model::{Studio, StudioError};
use crate::strings::{t, tf};

/// The permissions of the data APIs this page answers, in the order it shows them.
pub const PERMISSIONS: [&str; 5] = ["notifications", "services", "documents", "photos", "music"];

/// One picked file as the user sees it: with its path, which a widget never gets.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PickedItem {
    pub id: String,
    pub name: String,
    pub path: String,
    /// False when the file is gone or is no longer a regular file.
    pub readable: bool,
}

/// What is granted to and picked for one widget.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct AccessState {
    /// Which of [`PERMISSIONS`] the widget's manifest declares.
    pub declared: Vec<String>,
    pub notifications: bool,
    /// The login of the connected GitHub account, if one is connected.
    pub github: Option<String>,
    pub github_allowed: bool,
    pub documents: Vec<PickedItem>,
    pub photos: Vec<PickedItem>,
    /// A list that cannot be read, as a sentence.
    pub problem: Option<String>,
}

impl AccessState {
    pub fn declares(&self, permission: &str) -> bool {
        self.declared.iter().any(|known| known == permission)
    }
}

pub struct DataAccess {
    studio: Arc<Studio>,
    stores: SystemStores,
}

impl DataAccess {
    pub fn new(studio: Arc<Studio>) -> Self {
        let stores = SystemStores::for_user(studio.paths());
        Self::with_stores(studio, stores)
    }

    /// Over other stores: another keyring and another way to GitHub. For tests.
    pub fn with_stores(studio: Arc<Studio>, stores: SystemStores) -> Self {
        // The painter makes the thumbnails of picked pictures, here and in the previews.
        stores.photos.set_maker(Arc::new(sw_render::SkiaThumbnails));
        studio.system().photos.set_maker(Arc::new(sw_render::SkiaThumbnails));
        Self { studio, stores }
    }

    fn package(&self, name: &str) -> Result<InstalledPackage, StudioError> {
        self.studio.library().find(name).ok_or_else(|| StudioError(tf("editor.missing", &[name])))
    }

    pub fn state(&self, name: &str) -> Result<AccessState, StudioError> {
        let package = self.package(name)?;
        let permissions = package.permissions();
        let mut state = AccessState { declared: PERMISSIONS.iter().filter(|permission| permissions.iter().any(|known| known == *permission)).map(|permission| (*permission).to_owned()).collect(), ..AccessState::default() };
        state.notifications = self.stores.grants.capabilities(&package.installation).iter().any(|capability| capability == "notifications");
        match self.stores.services.summary() {
            Ok(Some(summary)) => {
                state.github_allowed = summary.grants.contains(&package.installation);
                state.github = Some(summary.username);
            }
            Ok(None) => {}
            Err(_) => state.problem = Some(t("access.github.unreadable")),
        }
        let readable = |path: &Path| std::fs::symlink_metadata(path).is_ok_and(|metadata| metadata.is_file());
        match self.stores.documents.list(&package.installation) {
            Ok(entries) => state.documents = entries.iter().map(|entry| PickedItem { id: entry.id.clone(), name: entry.name.clone(), path: entry.path.display().to_string(), readable: readable(&entry.path) }).collect(),
            Err(_) => state.problem = Some(t("access.list.unreadable")),
        }
        match self.stores.photos.list(&package.installation) {
            Ok(entries) => {
                state.photos = entries.iter().map(|entry| PickedItem { id: entry.id.clone(), name: entry.path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default(), path: entry.path.display().to_string(), readable: readable(&entry.path) }).collect();
            }
            Err(_) => state.problem = Some(t("access.list.unreadable")),
        }
        Ok(state)
    }

    pub fn set_notifications(&self, name: &str, allowed: bool) -> Result<(), StudioError> {
        let package = self.package(name)?;
        if !self.stores.grants.set(&package.installation, "notifications", allowed) {
            return Err(StudioError(t("access.failed")));
        }
        if !allowed {
            // What it scheduled while it was allowed is not shown after the user said no.
            for entry in self.stores.notifications.all().unwrap_or_default().iter().filter(|entry| entry.owner == package.installation) {
                self.stores.notifications.remove(&entry.owner, &entry.key);
            }
        }
        Ok(())
    }

    pub fn set_github(&self, name: &str, allowed: bool) -> Result<(), StudioError> {
        let package = self.package(name)?;
        if self.stores.services.set_grant(&package.installation, allowed) { Ok(()) } else { Err(StudioError(t("access.failed"))) }
    }

    /// Picks a JSON or CSV file for the widget. Returns the name it is listed under.
    pub fn add_document(&self, name: &str, file: &Path) -> Result<String, StudioError> {
        let package = self.package(name)?;
        self.stores.documents.add(&package.installation, file).map(|entry| entry.name).map_err(|error| StudioError(pick_message(error, false)))
    }

    pub fn remove_document(&self, name: &str, id: &str) -> Result<(), StudioError> {
        let package = self.package(name)?;
        self.stores.documents.remove(&package.installation, id).map(|_| ()).ok_or_else(|| StudioError(t("access.failed")))
    }

    /// Picks a picture for the widget; its thumbnail is made now. Blocks while the picture is decoded: call it off the window's thread.
    pub fn add_photo(&self, name: &str, file: &Path) -> Result<(), StudioError> {
        let package = self.package(name)?;
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |elapsed| elapsed.as_millis() as i64);
        self.stores.photos.add(&package.installation, file, now).map(|_| ()).map_err(|error| StudioError(pick_message(error, true)))
    }

    pub fn remove_photo(&self, name: &str, id: &str) -> Result<(), StudioError> {
        let package = self.package(name)?;
        if self.stores.photos.remove(&package.installation, id) { Ok(()) } else { Err(StudioError(t("access.failed"))) }
    }

    /// Forgets everything kept for a widget that is being removed.
    pub fn retire(&self, name: &str) {
        if let Ok(package) = self.package(name) {
            self.stores.retire(&package.installation);
        }
    }

    // The GitHub account, on the settings page

    /// The login of the connected account, `None` when none is connected, or why that cannot be told.
    pub fn github(&self) -> Result<Option<String>, StudioError> {
        self.stores.services.summary().map(|summary| summary.map(|summary| summary.username)).map_err(service_message)
    }

    /// Verifies the token with GitHub and keeps it in the keyring. Returns the login. Blocks for the request: call it off the window's thread.
    pub fn connect_github(&self, token: &str) -> Result<String, StudioError> {
        self.stores.services.connect(token).map_err(service_message)
    }

    pub fn disconnect_github(&self) -> Result<(), StudioError> {
        self.stores.services.disconnect().map_err(service_message)
    }
}

/// A sentence for the user. The rejection's own text is for scripts; its code decides what is said here.
fn service_message(error: SystemReject) -> StudioError {
    StudioError(match system_log::code(&error.0) {
        "service_credential" => t("access.github.notAToken"),
        "service_expired" | "service_permission" => t("access.github.refused"),
        "service_rate_limit" => t("access.github.rateLimit"),
        "service_storage" | "service_locked" => t("access.github.keyring"),
        _ => t("access.github.unavailable"),
    })
}

fn pick_message(error: PickError, photo: bool) -> String {
    match (error, photo) {
        (PickError::UnsupportedType, _) => t("access.pick.type"),
        (PickError::TooLarge, false) => tf("access.pick.documentTooLarge", &[&(document_rules::MAXIMUM_BYTES / 1024).to_string()]),
        (PickError::TooLarge, true) => tf("access.pick.photoTooLarge", &[&(photo_limits::MAXIMUM_SOURCE_BYTES / (1024 * 1024)).to_string()]),
        (PickError::InvalidContent, false) => t("access.pick.documentInvalid"),
        (PickError::InvalidContent, true) => t("access.pick.photoInvalid"),
        (PickError::Full, false) => tf("access.pick.full", &[&document_rules::MAXIMUM_FILES.to_string()]),
        (PickError::Full, true) => tf("access.pick.full", &[&photo_limits::MAXIMUM_SELECTED.to_string()]),
        (PickError::Duplicate, _) => t("access.pick.duplicate"),
        (PickError::Unreadable, _) => t("access.pick.unreadable"),
        (PickError::NotInstalled | PickError::Storage, _) => t("access.failed"),
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use sw_core::ai::credentials::{CredentialStore, MemoryCredentialStore};
    use sw_core::api::bus::SessionBus;
    use sw_core::api::services::{KEYRING_ACCOUNT, ServiceHttpResponse, ServiceTransport};

    use super::*;
    use crate::testing::{Scratch, studio};

    /// Not a token of anyone.
    const TOKEN: &str = "github_pat_FAKEFAKEFAKEFAKEFAKE_notARealToken00000001";

    struct FakeGitHub(Mutex<u16>);

    impl ServiceTransport for FakeGitHub {
        fn get(&self, _: &str, _: &[(String, String)]) -> Result<ServiceHttpResponse, ()> {
            Ok(ServiceHttpResponse { status: *self.0.lock().unwrap(), content_type: Some("application/json".into()), rate_limited: false, body: br#"{"login":"octocat","id":583231,"public_repos":2}"#.to_vec() })
        }
    }

    fn access(scratch: &Scratch) -> (DataAccess, Arc<MemoryCredentialStore>, Arc<FakeGitHub>, Arc<Studio>) {
        let studio = Arc::new(studio(scratch));
        let (keyring, github) = (Arc::new(MemoryCredentialStore::new()), Arc::new(FakeGitHub(Mutex::new(200))));
        let stores = SystemStores::with_parts(studio.paths(), keyring.clone(), github.clone(), SessionBus::with_program("/nonexistent/busctl"));
        (DataAccess::with_stores(studio.clone(), stores), keyring, github, studio)
    }

    #[test]
    fn grants_and_picked_files_are_one_widgets() {
        let scratch = Scratch::new("access");
        let (access, _, _, studio) = access(&scratch);
        let first = studio.new_widget("First").unwrap();
        let second = studio.new_widget("Second").unwrap();
        assert_eq!(access.state(&first).unwrap(), AccessState::default(), "a new widget declares nothing and has nothing");

        access.set_notifications(&first, true).unwrap();
        let json = scratch.write("home/data.json", b"{\"a\": 1}");
        assert_eq!(access.add_document(&first, &json).unwrap(), "data.json");
        // A real picture, made by the painter.
        let pixels = vec![200u8; 64 * 48 * 4];
        let picture = scratch.write("home/picture.png", &sw_render::encode_png(&pixels, 64, 48).unwrap());
        access.add_photo(&first, &picture).unwrap();
        let state = access.state(&first).unwrap();
        assert!(state.notifications);
        assert_eq!(state.documents.iter().map(|item| (item.name.as_str(), item.readable)).collect::<Vec<_>>(), [("data.json", true)]);
        assert_eq!(state.photos.iter().map(|item| (item.name.as_str(), item.readable)).collect::<Vec<_>>(), [("picture.png", true)]);
        assert_eq!(access.state(&second).unwrap(), AccessState::default(), "the other widget has none of it");

        // What cannot be picked says why, in a sentence of the window.
        assert_eq!(access.add_document(&first, &json).unwrap_err().0, t("access.pick.duplicate"));
        assert_eq!(access.add_document(&first, &scratch.write("home/notes.txt", b"x")).unwrap_err().0, t("access.pick.type"));
        assert_eq!(access.add_document(&first, &scratch.write("home/bad.json", b"{")).unwrap_err().0, t("access.pick.documentInvalid"));
        assert_eq!(access.add_photo(&first, &scratch.write("home/fake.png", b"not a picture")).unwrap_err().0, t("access.pick.photoInvalid"));
        assert!(access.add_document("No Such Widget", &json).is_err());

        // A picked file that is gone is still listed, marked, so the user can take it off the list.
        std::fs::remove_file(&json).unwrap();
        let state = access.state(&first).unwrap();
        assert!(!state.documents[0].readable);
        access.remove_document(&first, &state.documents[0].id).unwrap();
        access.remove_photo(&first, &state.photos[0].id).unwrap();
        access.set_notifications(&first, false).unwrap();
        assert_eq!(access.state(&first).unwrap(), AccessState::default());
        assert!(picture.is_file(), "removing from the list leaves the file");
    }

    #[test]
    fn the_github_account_is_connected_with_a_token_that_stays_in_the_keyring() {
        let scratch = Scratch::new("access-github");
        let (access, keyring, github, studio) = access(&scratch);
        let widget = studio.new_widget("Profile").unwrap();
        assert_eq!(access.github().unwrap(), None);
        assert!(access.set_github(&widget, true).is_err(), "nothing to allow before an account is connected");
        assert_eq!(access.connect_github("hunter2").unwrap_err().0, t("access.github.notAToken"));
        *github.0.lock().unwrap() = 401;
        assert_eq!(access.connect_github(TOKEN).unwrap_err().0, t("access.github.refused"));
        assert_eq!(keyring.load(KEYRING_ACCOUNT), Ok(None));
        *github.0.lock().unwrap() = 200;
        assert_eq!(access.connect_github(TOKEN).unwrap(), "octocat");
        assert_eq!(keyring.load(KEYRING_ACCOUNT).unwrap().unwrap().expose(), TOKEN);
        assert_eq!(access.github().unwrap().as_deref(), Some("octocat"));
        // Nothing in the data folder holds the token.
        fn scan(directory: &Path) {
            for entry in std::fs::read_dir(directory).into_iter().flatten().flatten() {
                if entry.path().is_dir() {
                    scan(&entry.path());
                } else {
                    assert!(!String::from_utf8_lossy(&std::fs::read(entry.path()).unwrap()).contains("notARealToken"), "{}", entry.path().display());
                }
            }
        }
        scan(scratch.root());

        access.set_github(&widget, true).unwrap();
        let state = access.state(&widget).unwrap();
        assert_eq!((state.github.as_deref(), state.github_allowed), (Some("octocat"), true));
        // Removing the widget takes its grant with it.
        access.retire(&widget);
        studio.remove(&widget).unwrap();
        access.disconnect_github().unwrap();
        assert_eq!((access.github().unwrap(), keyring.load(KEYRING_ACCOUNT)), (None, Ok(None)));
    }
}
