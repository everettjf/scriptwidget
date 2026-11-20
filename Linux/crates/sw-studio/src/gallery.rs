//! The Gallery page without the window: the verified catalog, what is
//! installed from it, and installing. `Android/app/.../ui/GalleryScreen.kt`
//! is what it follows; the work is [`sw_core::gallery`].
//!
//! The catalog comes from one fixed address and is refused as a whole unless
//! it passes every check. An item is installed from the catalog this service
//! loaded, never from what a view hands back, and only after each of its
//! files matched the size and SHA-256 the catalog states. That detects a
//! corrupted or substituted download; it does not review the code, so the
//! page shows what a widget may do before it is installed.

use std::sync::{Arc, Mutex};

use sw_core::PackageFiles;
use sw_core::gallery::{FetchGalleryTransport, GalleryError, GalleryIndex, GalleryIndexCache, GalleryInstallState, GalleryInstallationRegistry, GalleryInstaller, GalleryItem, GalleryItemKind, GalleryRepository, GalleryTransport};
use sw_core::json::ObjectExt;
use sw_core::library::{INSTALLATION_FILE, unsupported_api};
use sw_core::packages::manifests;

use crate::model::{Studio, StudioError};

impl From<GalleryError> for StudioError {
    fn from(error: GalleryError) -> Self {
        Self(error.message)
    }
}

/// One item of the catalog, as a row and its detail show it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GalleryCard {
    pub id: String,
    pub kind: GalleryItemKind,
    pub name: String,
    pub version: String,
    pub summary: String,
    pub author: String,
    pub license: String,
    pub tags: Vec<String>,
    pub files: usize,
    pub bytes: u64,
    /// A link to the source on github.com; the catalog was refused if it is anything else.
    pub source_url: String,
    pub state: GalleryInstallState,
}

/// The catalog as the page shows it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GalleryView {
    pub cards: Vec<GalleryCard>,
    /// GitHub was not reached: this is the last catalog that passed the checks.
    pub offline: bool,
    pub offline_reason: Option<String>,
    /// When the catalog was fetched, in milliseconds since 1970.
    pub fetched_at: i64,
}

impl GalleryView {
    /// The cards a search and a kind leave: the text is looked for, without regard to case, in the name, the summary, the author and the tags.
    pub fn matching(&self, query: &str, kind: Option<GalleryItemKind>) -> Vec<&GalleryCard> {
        let needle = query.trim().to_lowercase();
        self.cards.iter().filter(|card| kind.is_none_or(|kind| card.kind == kind)).filter(|card| needle.is_empty() || [&card.name, &card.summary, &card.author].into_iter().chain(&card.tags).any(|text| text.to_lowercase().contains(&needle))).collect()
    }

    pub fn card(&self, id: &str) -> Option<&GalleryCard> {
        self.cards.iter().find(|card| card.id == id)
    }
}

/// What the verified `widget.json` of an item says the widget may do.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ManifestPreview {
    /// The lowest runtime API the widget needs.
    pub api_version: Option<String>,
    pub permissions: Vec<String>,
    /// The Internet hosts the widget may ask.
    pub hosts: Vec<String>,
    /// A script global the widget uses that ScriptWidget for Linux does not implement, with its dollar sign.
    pub unsupported: Option<String>,
}

/// What an install made.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Installed {
    pub kind: GalleryItemKind,
    /// The name of the widget among the user's widgets, or the id of the Skill.
    pub local: String,
    /// The name the catalog gives the item.
    pub name: String,
}

pub struct Gallery {
    studio: Arc<Studio>,
    transport: Arc<dyn GalleryTransport>,
    registry: GalleryInstallationRegistry,
    /// The catalog of the last load: the only source of what is installed.
    index: Mutex<Option<GalleryIndex>>,
}

impl Gallery {
    /// The Gallery of the program: GitHub's raw host over the checked HTTPS client.
    pub fn new(studio: Arc<Studio>) -> Self {
        Self::with_transport(studio, Arc::new(FetchGalleryTransport::new()))
    }

    pub fn with_transport(studio: Arc<Studio>, transport: Arc<dyn GalleryTransport>) -> Self {
        Self { registry: GalleryInstallationRegistry::new(studio.paths().gallery_installations()), studio, transport, index: Mutex::new(None) }
    }

    fn installer(&self) -> GalleryInstaller<'_> {
        GalleryInstaller::new(self.transport.as_ref(), &self.registry, self.studio.library().store(), self.studio.skill_store(), self.studio.paths().gallery_downloads()).carried_files(&[INSTALLATION_FILE])
    }

    fn item(&self, id: &str) -> Result<GalleryItem, StudioError> {
        let index = self.index.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        index.as_ref().and_then(|index| index.items.iter().find(|item| item.id == id)).cloned().ok_or_else(|| StudioError(format!("The Gallery has no item {id}.")))
    }

    fn cards(&self, index: &GalleryIndex) -> Vec<GalleryCard> {
        let installer = self.installer();
        index
            .items
            .iter()
            .map(|item| GalleryCard {
                id: item.id.clone(),
                kind: item.kind,
                name: item.name.clone(),
                version: item.version.clone(),
                summary: item.summary.clone(),
                author: item.author.clone(),
                license: item.license.clone(),
                tags: item.tags.clone(),
                files: item.files.len(),
                bytes: u64::try_from(item.total_bytes()).unwrap_or(0),
                source_url: item.source_url.clone(),
                state: installer.state(item),
            })
            .collect()
    }

    /// Loads the catalog: a verified copy younger than 15 minutes, or a fetch
    /// (always, with `refresh`). When GitHub is not reached the last verified
    /// copy is shown as offline; without one the failure is the result.
    /// Blocks on the network: call it off the window's thread.
    pub fn load(&self, refresh: bool) -> Result<GalleryView, StudioError> {
        let snapshot = GalleryRepository::new(self.transport.clone(), GalleryIndexCache::new(self.studio.paths().gallery_cache())).load(refresh)?;
        let view = GalleryView { cards: self.cards(&snapshot.index), offline: snapshot.is_offline, offline_reason: snapshot.offline_reason, fetched_at: snapshot.fetched_at };
        *self.index.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(snapshot.index);
        Ok(view)
    }

    /// The install states of the loaded catalog, read again from disk: after
    /// an install, or after a widget was removed on another page. No network.
    pub fn states(&self) -> Vec<(String, GalleryInstallState)> {
        let index = self.index.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).clone();
        index.map(|index| self.cards(&index).into_iter().map(|card| (card.id, card.state)).collect()).unwrap_or_default()
    }

    /// Downloads, checks and installs the item `id` of the loaded catalog, or
    /// updates it in place. A widget is compiled before it is published; a
    /// Skill is installed and not turned on. Blocks on the network: call it
    /// off the window's thread.
    pub fn install(&self, id: &str) -> Result<Installed, StudioError> {
        let item = self.item(id)?;
        let api_version = self.studio.api_version();
        let compile = |files: &dyn PackageFiles| self.studio.compile(files);
        let record = self.installer().runtime_api_version(api_version.as_deref()).widget_validator(&compile).install(&item)?;
        if item.kind == GalleryItemKind::Widget {
            // What was drawn for the widget this one replaces is not this one.
            self.studio.library().clear_build(&record.local_identifier);
        }
        Ok(Installed { kind: item.kind, local: record.local_identifier, name: item.name })
    }

    /// What a widget of the catalog may do, read from its `widget.json` and
    /// its scripts after each matched the catalog's size and SHA-256. Nothing
    /// is installed or run. Blocks on the network.
    pub fn preview(&self, id: &str) -> Result<ManifestPreview, StudioError> {
        let item = self.item(id)?;
        if item.kind != GalleryItemKind::Widget {
            return Ok(ManifestPreview::default());
        }
        let installer = self.installer();
        let text = String::from_utf8(installer.download_verified(&item, manifests::FILE_NAME)?).ok();
        let manifest = manifests::parse(text.as_deref()).ok_or_else(|| StudioError("widget.json is invalid.".into()))?;
        let strings = |key: &str| manifest.opt_array(key).map(|items| items.iter().filter_map(|item| item.as_str().map(str::to_owned)).collect()).unwrap_or_default();
        let mut unsupported = None;
        for file in item.files.iter().filter(|file| file.path.ends_with(".js") || file.path.ends_with(".jsx")) {
            let source = String::from_utf8(installer.download_verified(&item, &file.path)?).unwrap_or_default();
            unsupported = unsupported_api(&source);
            if unsupported.is_some() {
                break;
            }
        }
        Ok(ManifestPreview { api_version: manifests::string_value(&manifest, "minimumRuntimeVersion").or_else(|| manifests::string_value(&manifest, "runtimeVersion")), permissions: strings("permissions"), hosts: strings("networkDomains"), unsupported })
    }
}

#[cfg(test)]
mod tests {
    //! The page's logic over a stand-in for GitHub that answers from the catalog checked into
    //! this repository. Nothing here contacts the Internet.

    use std::collections::HashMap;
    use std::path::PathBuf;

    use sw_core::gallery::{GalleryRequest, GalleryResponse};

    use super::*;
    use crate::testing::{Scratch, studio};

    const HELLO: &str = "app.scriptwidget.gallery.hello-card";
    const PRIVACY: &str = "app.scriptwidget.gallery.privacy-review";
    const BASE: &str = "https://raw.githubusercontent.com/everettjf/scriptwidget/main/Gallery/";

    fn checkout() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../Gallery")
    }

    #[derive(Default)]
    struct Checkout {
        replaced: Mutex<HashMap<String, Vec<u8>>>,
        down: Mutex<bool>,
        requests: Mutex<Vec<String>>,
    }

    impl Checkout {
        fn replace(&self, relative: &str, body: &[u8]) {
            self.replaced.lock().unwrap().insert(format!("{BASE}{relative}"), body.to_vec());
        }

        fn count(&self) -> usize {
            self.requests.lock().unwrap().len()
        }
    }

    impl GalleryTransport for Checkout {
        fn fetch(&self, request: &GalleryRequest) -> Result<GalleryResponse, GalleryError> {
            self.requests.lock().unwrap().push(request.url.clone());
            if *self.down.lock().unwrap() {
                return Err(GalleryError::network("GitHub could not be reached."));
            }
            if let Some(body) = self.replaced.lock().unwrap().get(&request.url) {
                return Ok(GalleryResponse::new(200, body.clone(), &[], &request.url));
            }
            let relative = request.url.strip_prefix(BASE).ok_or_else(|| GalleryError::network("not the catalog"))?;
            match std::fs::read(checkout().join(relative)) {
                Ok(body) => Ok(GalleryResponse::new(200, body, &[], &request.url)),
                Err(_) => Ok(GalleryResponse::new(404, Vec::new(), &[], &request.url)),
            }
        }
    }

    struct Fixture {
        studio: Arc<Studio>,
        github: Arc<Checkout>,
        gallery: Gallery,
    }

    fn fixture(scratch: &Scratch) -> Fixture {
        let studio = Arc::new(studio(scratch));
        let github = Arc::new(Checkout::default());
        Fixture { gallery: Gallery::with_transport(studio.clone(), github.clone()), studio, github }
    }

    fn names(cards: &[&GalleryCard]) -> Vec<String> {
        cards.iter().map(|card| card.name.clone()).collect()
    }

    #[test]
    fn the_service_crosses_threads() {
        fn shared<T: Send + Sync>() {}
        shared::<Gallery>();
    }

    #[test]
    fn the_catalog_is_loaded_searched_and_shown_offline_when_github_is_down() {
        let scratch = Scratch::new("gallery-load");
        let fixture = fixture(&scratch);
        assert!(fixture.gallery.states().is_empty(), "nothing is loaded yet");
        assert!(fixture.gallery.install(HELLO).unwrap_err().0.contains("no item"), "nothing is installed from a catalog that was not loaded");
        assert_eq!(fixture.github.count(), 0);

        let view = fixture.gallery.load(false).unwrap();
        assert!(!view.offline && view.cards.len() >= 2 && view.cards.iter().all(|card| card.state == GalleryInstallState::NotInstalled));
        let hello = view.card(HELLO).unwrap();
        assert_eq!((hello.kind, hello.name.as_str(), hello.files, hello.license.as_str()), (GalleryItemKind::Widget, "Gallery Hello Card", 2, "MIT"));
        assert!(hello.source_url.starts_with("https://github.com/"));
        assert_eq!(names(&view.matching("  HELLO ", None)), ["Gallery Hello Card"]);
        assert_eq!(names(&view.matching("", Some(GalleryItemKind::Skill))), ["Privacy Review"]);
        assert_eq!(names(&view.matching("privacy", Some(GalleryItemKind::Widget))), [] as [&str; 0]);
        assert!(view.matching("offline", None).iter().any(|card| card.id == HELLO), "tags are searched");
        assert_eq!(view.matching("", None).len(), view.cards.len());

        // A second look within the quarter hour asks nobody; a refresh with GitHub down shows the saved copy.
        fixture.gallery.load(false).unwrap();
        assert_eq!(fixture.github.count(), 1);
        *fixture.github.down.lock().unwrap() = true;
        let offline = fixture.gallery.load(true).unwrap();
        assert!(offline.offline && offline.offline_reason.is_some());
        assert_eq!((offline.cards, offline.fetched_at), (view.cards, view.fetched_at));
        // Installing needs the connection, and leaves nothing without it.
        assert!(fixture.gallery.install(HELLO).is_err());
        assert!(fixture.studio.widgets().unwrap().is_empty());
    }

    #[test]
    fn without_a_saved_catalog_the_failure_is_the_result() {
        let scratch = Scratch::new("gallery-none");
        let fixture = fixture(&scratch);
        *fixture.github.down.lock().unwrap() = true;
        assert!(fixture.gallery.load(false).unwrap_err().0.contains("GitHub"));
        // A catalog of a version this program does not know is not shown either.
        *fixture.github.down.lock().unwrap() = false;
        fixture.github.replace("index.json", b"{\"schemaVersion\":2,\"generatedAt\":\"2026-11-12T17:07:53.501Z\",\"repository\":\"https://github.com/a/b\",\"items\":[],\"future\":true}");
        assert!(fixture.gallery.load(false).is_err());
        assert!(fixture.gallery.states().is_empty());
        assert!(!scratch.path("data/Cache/Gallery/index.json").exists(), "what was refused is not kept");
    }

    #[test]
    fn a_widget_is_previewed_installed_and_listed_among_the_users_widgets() {
        let scratch = Scratch::new("gallery-widget");
        let fixture = fixture(&scratch);
        fixture.gallery.load(false).unwrap();

        let preview = fixture.gallery.preview(HELLO).unwrap();
        assert_eq!((preview.api_version.as_deref(), preview.hosts.len(), preview.unsupported.as_deref()), (Some("1.0"), 0, None));
        assert_eq!(fixture.gallery.preview("app.scriptwidget.template.health-card").unwrap().unsupported.as_deref(), Some("$health"), "a script the entry imports is read as well");
        let weather = fixture.gallery.preview("app.scriptwidget.template.weather-now-met").unwrap();
        assert!(weather.permissions.contains(&"network".to_owned()) && !weather.hosts.is_empty(), "{weather:?}");
        assert_eq!(fixture.gallery.preview(PRIVACY).unwrap(), ManifestPreview::default(), "a Skill has no manifest of permissions");
        assert!(fixture.studio.widgets().unwrap().is_empty(), "looking installs nothing");

        let installed = fixture.gallery.install(HELLO).unwrap();
        assert_eq!(installed, Installed { kind: GalleryItemKind::Widget, local: "Gallery Hello Card".into(), name: "Gallery Hello Card".into() });
        let widgets = fixture.studio.widgets().unwrap();
        assert_eq!(widgets.iter().map(|card| card.name.as_str()).collect::<Vec<_>>(), ["Gallery Hello Card"]);
        assert_eq!(fixture.studio.read_text("Gallery Hello Card", "main.jsx").unwrap().unwrap().into_bytes(), std::fs::read(checkout().join("widgets/hello-card/main.jsx")).unwrap());
        let states: HashMap<String, GalleryInstallState> = fixture.gallery.states().into_iter().collect();
        assert_eq!((&states[HELLO], &states[PRIVACY]), (&GalleryInstallState::Installed, &GalleryInstallState::NotInstalled));
        // The widget can be drawn like any other.
        let picture = fixture.studio.preview(&crate::model::PreviewRequest { source: crate::model::PreviewSource::Installed { name: "Gallery Hello Card".into(), edits: vec![] }, family: "medium".into(), dark: false, scale: 1.0 });
        assert!(picture.error.is_none() && picture.picture.is_some(), "{:?}", picture.error);

        // Installed again it is the same widget with the same identity; removed, it is offered again.
        let identity = widgets[0].installation.clone();
        fixture.gallery.install(HELLO).unwrap();
        assert_eq!(fixture.studio.widgets().unwrap().iter().map(|card| card.installation.clone()).collect::<Vec<_>>(), [identity]);
        fixture.studio.remove("Gallery Hello Card").unwrap();
        assert_eq!(fixture.gallery.states().into_iter().find(|(id, _)| id == HELLO).unwrap().1, GalleryInstallState::NotInstalled);
    }

    #[test]
    fn a_download_that_does_not_match_the_catalog_installs_nothing() {
        let scratch = Scratch::new("gallery-tampered");
        let fixture = fixture(&scratch);
        fixture.gallery.load(false).unwrap();
        let original = std::fs::read(checkout().join("widgets/hello-card/main.jsx")).unwrap();
        let mut substituted = original.clone();
        substituted[0] ^= 1;
        for body in [substituted, [original.as_slice(), b"\n"].concat(), Vec::new()] {
            fixture.github.replace("widgets/hello-card/main.jsx", &body);
            let error = fixture.gallery.install(HELLO).unwrap_err();
            assert!(error.0.contains("main.jsx") && error.0.contains("SHA-256"), "{}", error.0);
            assert!(fixture.studio.widgets().unwrap().is_empty());
            assert!(!scratch.path("data/gallery-installations.json").exists());
            assert!(std::fs::read_dir(scratch.path("data/Cache/GalleryDownloads")).map_or(true, |mut entries| entries.next().is_none()), "no download is left");
        }
        // The same for the manifest a preview would show.
        fixture.github.replace("widgets/hello-card/widget.json", b"{\"permissions\":[]}");
        assert!(fixture.gallery.preview(HELLO).is_err());
        // An item the loaded catalog does not hold cannot be installed, whatever a view asks for.
        assert!(fixture.gallery.install("com.example.not-in-the-catalog").unwrap_err().0.contains("no item"));
    }

    #[test]
    fn a_skill_is_installed_and_stays_off() {
        let scratch = Scratch::new("gallery-skill");
        let fixture = fixture(&scratch);
        fixture.gallery.load(false).unwrap();
        let installed = fixture.gallery.install(PRIVACY).unwrap();
        assert_eq!((installed.kind, installed.local.as_str(), installed.name.as_str()), (GalleryItemKind::Skill, PRIVACY, "Privacy Review"));
        let skills = crate::skills::Skills::new(fixture.studio.clone());
        let row = skills.rows().into_iter().find(|row| row.id == PRIVACY).expect("the Skill is listed");
        assert!(!row.enabled && !row.built_in);
        assert!(skills.in_effect().is_empty());
        assert!(fixture.studio.widgets().unwrap().is_empty());
        assert_eq!(fixture.gallery.states().into_iter().find(|(id, _)| id == PRIVACY).unwrap().1, GalleryInstallState::Installed);
        skills.remove(PRIVACY).unwrap();
        assert_eq!(fixture.gallery.states().into_iter().find(|(id, _)| id == PRIVACY).unwrap().1, GalleryInstallState::NotInstalled);
    }
}
