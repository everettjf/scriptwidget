//! Everything the data APIs keep between runs, in one place: what the user
//! granted and picked for each widget, the pending notifications and the
//! connected service. The runtime builds its modules over these; the command
//! line and the management window change them on the user's behalf.
//!
//! All of it is below `System/` in the data folder, in files only the user
//! can read. A service token is not among them: it is in the system keyring.

use std::sync::Arc;
use std::time::Duration;

use crate::ai::credentials::{CredentialStore, SecretToolStore};
use crate::api::bus::SessionBus;
use crate::api::documents::DocumentStore;
use crate::api::fetch::FetchModule;
use crate::api::notifications::{DesktopNotifications, NotificationPlatform, NotificationStore};
use crate::api::photos::PhotoLibrary;
use crate::api::services::{FetchServiceTransport, KEYRING_KIND, KEYRING_LABEL, ServiceConnections, ServiceTransport};
use crate::api::support::{SystemAccessGrants, is_owner};
use crate::data_paths::DataPaths;

/// A widget run cannot wait for the user to unlock a keyring.
const KEYRING_LIMIT_IN_A_RUN: Duration = Duration::from_millis(1500);

#[derive(Clone)]
pub struct SystemStores {
    pub grants: Arc<SystemAccessGrants>,
    pub notifications: Arc<NotificationStore>,
    pub notification_platform: Arc<dyn NotificationPlatform>,
    pub documents: Arc<DocumentStore>,
    pub photos: Arc<PhotoLibrary>,
    pub services: Arc<ServiceConnections>,
    pub bus: SessionBus,
}

impl SystemStores {
    /// The stores of a runtime: the keyring is asked with a short limit.
    pub fn for_runs(paths: &DataPaths, fetch: Arc<FetchModule>) -> Self {
        let tokens = SecretToolStore::new().for_kind(KEYRING_KIND, KEYRING_LABEL).with_limit(KEYRING_LIMIT_IN_A_RUN);
        Self::with_parts(paths, Arc::new(tokens), Arc::new(FetchServiceTransport::new(fetch)), SessionBus::new())
    }

    /// The stores for what the user does at the command line or in the
    /// management window: the keyring may take as long as unlocking it takes.
    pub fn for_user(paths: &DataPaths) -> Self {
        let tokens = SecretToolStore::new().for_kind(KEYRING_KIND, KEYRING_LABEL);
        Self::with_parts(paths, Arc::new(tokens), Arc::new(FetchServiceTransport::new(Arc::new(FetchModule::new()))), SessionBus::new())
    }

    /// The stores over another keyring, another way to GitHub and another `busctl`; for tests.
    pub fn with_parts(paths: &DataPaths, tokens: Arc<dyn CredentialStore>, transport: Arc<dyn ServiceTransport>, bus: SessionBus) -> Self {
        let system = paths.system();
        Self {
            grants: Arc::new(SystemAccessGrants::new(system.join("grants.json"))),
            notifications: Arc::new(NotificationStore::new(system.join("notifications.json"))),
            notification_platform: Arc::new(DesktopNotifications::new(bus.clone())),
            documents: Arc::new(DocumentStore::new(system.join("Documents"))),
            photos: Arc::new(PhotoLibrary::new(system.join("Photos"), paths.cache().join("photos"))),
            services: Arc::new(ServiceConnections::new(system.join("services.json"), tokens, transport)),
            bus,
        }
    }

    /// Forgets everything kept for a deleted installation: its grants, its
    /// pending notifications, its picked documents and pictures, and its
    /// permission to read the connected service.
    pub fn retire(&self, installation: &str) {
        if !is_owner(installation) {
            return;
        }
        for entry in self.notifications.all().unwrap_or_default().iter().filter(|entry| entry.owner == installation) {
            self.notifications.remove(&entry.owner, &entry.key);
        }
        self.grants.retire(installation);
        self.documents.clear(installation);
        self.photos.clear(installation);
        self.services.set_grant(installation, false);
    }
}
