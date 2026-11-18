//! What the management window knows and does, without the window: the
//! installed widgets, the bundled templates, copies of them, files of a
//! package, archives, and previews. Everything goes through the hardened
//! package store and the runtime of `sw-core`; nothing here interprets
//! package content itself.

use std::collections::HashMap;
use std::fmt;
use std::io::{Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use sw_core::compiler::is_text_file;
use sw_core::json::ObjectExt;
use sw_core::packages::limits::MAX_FILE_BYTES;
use sw_core::packages::{ArchiveLimits, DiskPackageFiles, PackageError, archive, manifest_present, manifests};
use sw_core::{BundledPackage, DataPaths, InstalledPackage, Library, MemoryPackageFiles, PackageFiles, Resources, RunRequest, SharedScripts, WidgetRuntime};
use sw_render::{Presentation, WidgetRenderer};

/// What a new, empty widget starts with.
pub const STARTER: &str = r##"// A ScriptWidget widget. The preview on the right follows what you type.

const size = $getenv("widget-size");

$render(
  <vstack frame="max" background="#0f172a" padding="14" spacing="6" alignment="leading">
    <text font="caption" color="#94a3b8">HELLO</text>
    <text font="title2" color="white">ScriptWidget</text>
    <text font="caption" color="#64748b">{size}</text>
  </vstack>
);
"##;

/// A failure with a sentence for the user.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StudioError(pub String);

impl fmt::Display for StudioError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for StudioError {}

impl From<PackageError> for StudioError {
    fn from(error: PackageError) -> Self {
        Self(error.message)
    }
}

impl From<std::io::Error> for StudioError {
    fn from(error: std::io::Error) -> Self {
        Self(error.to_string())
    }
}

/// One installed widget, as a card shows it.
#[derive(Debug, Clone, PartialEq)]
pub struct WidgetCard {
    /// The folder name: what every command takes, and what the card shows, because it is unique
    /// (an imported copy keeps the name its manifest gives and gets a numbered folder).
    pub name: String,
    /// The name the manifest gives.
    pub title: String,
    pub description: String,
    pub families: Vec<&'static str>,
    /// False when `widget.json` is present but cannot be read: such a package is listed and can be removed, nothing else.
    pub readable: bool,
    pub installation: String,
}

impl WidgetCard {
    /// The size a card shows: medium when the widget has it, otherwise its first size.
    pub fn card_family(&self) -> &'static str {
        if self.families.contains(&"medium") { "medium" } else { self.families.first().copied().unwrap_or("medium") }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TemplateCard {
    /// "group/name", as [`Library::find_bundled`] takes it.
    pub reference: String,
    pub name: String,
    pub network: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TemplateGroup {
    /// "template", "component" or "api".
    pub group: String,
    pub templates: Vec<TemplateCard>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TemplateDetail {
    pub reference: String,
    pub name: String,
    pub description: String,
    /// The text of its `main.jsx`.
    pub source: String,
    /// The Internet hosts a copy would be allowed to ask.
    pub hosts: Vec<String>,
}

/// What a `.swt` file holds, read without installing or running anything.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ArchiveSummary {
    pub name: String,
    pub description: String,
    pub files: usize,
    pub bytes: u64,
    pub permissions: Vec<String>,
    pub hosts: Vec<String>,
}

/// What to draw.
#[derive(Debug, Clone, PartialEq)]
pub enum PreviewSource {
    /// An installed widget by name; `edits` replace the text of files that are not saved yet.
    Installed { name: String, edits: Vec<(String, String)> },
    /// A bundled template by "group/name".
    Bundled(String),
}

#[derive(Debug, Clone, PartialEq)]
pub struct PreviewRequest {
    pub source: PreviewSource,
    pub family: String,
    pub dark: bool,
    /// Pixels per point of the display the window is on.
    pub scale: f32,
}

/// A drawn widget: straight (not premultiplied) RGBA, rows from the top.
#[derive(Debug, Clone, PartialEq)]
pub struct Picture {
    pub pixels: Vec<u8>,
    pub pixel_width: u32,
    pub pixel_height: u32,
    /// The size in points.
    pub width: f32,
    pub height: f32,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct PreviewResult {
    /// The widget, or the card that explains its error. `None` only when nothing at all could be drawn.
    pub picture: Option<Picture>,
    /// Category and message of a script, compile or drawing error.
    pub error: Option<(String, String)>,
    /// Level and message of what the script printed.
    pub logs: Vec<(String, String)>,
    pub elapsed_milliseconds: u64,
}

pub struct Studio {
    paths: DataPaths,
    library: Library,
    runtime: WidgetRuntime,
    renderer: WidgetRenderer,
    /// One run at a time: previews are asked for from several threads.
    engine: Mutex<()>,
}

impl Studio {
    /// The installation's runtime files and templates, and the user's data folder (`data`, or the environment's).
    pub fn open(data: Option<&Path>) -> Result<Self, StudioError> {
        let resources = Resources::locate()?;
        Self::with(&DataPaths::new(data)?, &resources.runtime, resources.templates)
    }

    pub fn with(paths: &DataPaths, runtime_files: &Path, templates: Option<PathBuf>) -> Result<Self, StudioError> {
        let scripts = Arc::new(SharedScripts::new(runtime_files)?);
        Ok(Self {
            paths: paths.clone(),
            library: Library::new(paths, templates),
            runtime: WidgetRuntime::new(scripts.clone(), paths)?,
            renderer: WidgetRenderer::new(scripts)?,
            engine: Mutex::new(()),
        })
    }

    pub fn paths(&self) -> &DataPaths {
        &self.paths
    }

    // My widgets

    pub fn widgets(&self) -> Result<Vec<WidgetCard>, StudioError> {
        Ok(self.library.list()?.iter().map(card).collect())
    }

    pub fn widget(&self, name: &str) -> Option<WidgetCard> {
        self.library.find(name).as_ref().map(card)
    }

    /// Creates an empty widget; a taken name gets a numbered suffix. Returns the name it got.
    pub fn new_widget(&self, name: &str) -> Result<String, StudioError> {
        Ok(self.library.create(name.trim(), STARTER, None)?.name)
    }

    pub fn remove(&self, name: &str) -> Result<(), StudioError> {
        Ok(self.library.delete(name)?)
    }

    /// Writes the widget as a `.swt` file. The archive is written next to
    /// `target` under a private temporary name and renamed over it, so a
    /// crash or a full disk never leaves half a file under the chosen name.
    pub fn export(&self, name: &str, target: &Path) -> Result<(), StudioError> {
        let mut archive = Vec::new();
        self.library.export_archive(name, &mut archive)?;
        write_atomically(target, &archive, 0o644)?;
        Ok(())
    }

    /// Reads a `.swt` file the way an import would, as far as the checks of
    /// the archive and its files, and says what it holds. Nothing is
    /// installed, compiled or run, and nothing stays on disk.
    pub fn inspect(&self, file: &Path) -> Result<ArchiveSummary, StudioError> {
        let limits = ArchiveLimits::default();
        let mut input = open_archive(file)?;
        let extracted = archive::extract(&mut input, &self.paths.package_staging(), &limits)?;
        let directory = extracted.directory();
        let files = DiskPackageFiles::new(directory);
        let manifest = if manifest_present(directory)? {
            let text = files.read_text(manifests::FILE_NAME);
            Some(manifests::parse(text.as_deref()).ok_or_else(|| StudioError("widget.json is invalid.".into()))?)
        } else {
            if !files.exists(manifests::LEGACY_ENTRY) {
                return Err(StudioError("Entry file main.jsx does not exist.".into()));
            }
            None
        };
        let strings = |key: &str| manifest.as_ref().and_then(|manifest| manifest.opt_array(key)).map(|items| items.iter().filter_map(|item| item.as_str().map(str::to_owned)).collect()).unwrap_or_default();
        let name = manifest
            .as_ref()
            .and_then(|manifest| manifests::string_value(manifest, "name"))
            .or_else(|| extracted.root_name().map(str::to_owned))
            .or_else(|| file.file_stem().and_then(|stem| stem.to_str()).map(str::to_owned))
            .unwrap_or_else(|| "Imported Widget".into());
        let paths = files.list()?;
        let bytes = paths.iter().filter_map(|path| files.read_bytes_up_to(path, MAX_FILE_BYTES)).map(|content| content.len() as u64).sum();
        Ok(ArchiveSummary {
            name,
            description: manifest.as_ref().map(|manifest| manifest.opt_string("description")).unwrap_or_default(),
            files: paths.len(),
            bytes,
            permissions: strings("permissions"),
            hosts: strings("networkDomains"),
        })
    }

    /// Installs a `.swt` file. Its manifest and scripts are compiled first; a package that does not compile is refused.
    pub fn import(&self, file: &Path) -> Result<String, StudioError> {
        let mut input = open_archive(file)?;
        let suggested = file.file_stem().and_then(|stem| stem.to_str()).map(str::to_owned);
        let validate = |files: &dyn PackageFiles| self.runtime.validate_package(files).map_err(|error| PackageError::new(sw_core::packages::codes::INVALID_MANIFEST, error.message));
        Ok(self.library.import_archive(&mut input, suggested.as_deref(), Some(&validate))?.name)
    }

    // Templates

    /// The bundled templates that run on Linux, in the groups the library reports.
    pub fn template_groups(&self) -> Vec<TemplateGroup> {
        let mut groups: Vec<TemplateGroup> = Vec::new();
        for bundled in self.library.bundled() {
            let card = TemplateCard { reference: format!("{}/{}", bundled.group, bundled.name), name: bundled.name, network: bundled.network };
            match groups.last_mut().filter(|group| group.group == bundled.group) {
                Some(group) => group.templates.push(card),
                None => groups.push(TemplateGroup { group: bundled.group, templates: vec![card] }),
            }
        }
        groups
    }

    pub fn template(&self, reference: &str) -> Option<TemplateDetail> {
        let bundled = self.library.find_bundled(reference)?;
        let files = self.library.bundled_files(&bundled);
        let (source, manifest) = Library::bundled_sources(&bundled.name, &files).ok()?;
        let manifest = manifests::parse(Some(&manifest))?;
        let hosts = manifest.opt_array("networkDomains").map(|items| items.iter().filter_map(|item| item.as_str().map(str::to_owned)).collect()).unwrap_or_default();
        Some(TemplateDetail { reference: reference.to_owned(), name: bundled.name, description: manifest.opt_string("description"), source, hosts })
    }

    /// Copies a template into the user's widgets; a taken name gets a numbered suffix. Returns the name of the copy.
    pub fn use_template(&self, reference: &str) -> Result<String, StudioError> {
        let bundled = self.library.find_bundled(reference).ok_or_else(|| StudioError(format!("There is no template {reference}.")))?;
        Ok(self.library.install_bundled(&bundled)?.name)
    }

    // Files of a widget

    /// The script the widget starts from.
    pub fn entry(&self, name: &str) -> String {
        self.library.find(name).and_then(|package| package.manifest.as_ref().and_then(|manifest| manifests::string_value(manifest, "entry"))).unwrap_or_else(|| manifests::LEGACY_ENTRY.to_owned())
    }

    /// Every file of the widget, the entry first.
    pub fn files(&self, name: &str) -> Result<Vec<String>, StudioError> {
        let package = self.installed(name)?;
        let entry = self.entry(name);
        let mut paths = package.files().list()?;
        paths.sort_by_key(|path| (*path != entry, path.to_lowercase()));
        Ok(paths)
    }

    /// The text of a file, or `None` for a file that is not text.
    pub fn read_text(&self, name: &str, path: &str) -> Result<Option<String>, StudioError> {
        if !is_text_file(path) {
            return Ok(None);
        }
        let bytes = self.library.store().read_file(name, path)?;
        Ok(String::from_utf8(bytes).ok())
    }

    /// Saves a file through the package store: written beside the old file and renamed over it.
    pub fn save_text(&self, name: &str, path: &str, text: &str) -> Result<(), StudioError> {
        Ok(self.library.write_file(name, path, text.as_bytes())?)
    }

    fn installed(&self, name: &str) -> Result<InstalledPackage, StudioError> {
        self.library.find(name).ok_or_else(|| StudioError(format!("There is no widget named {name}.")))
    }

    // Previews

    /// Compiles, runs and draws. The package runs inside the engine with the
    /// limits every run has; an error becomes the picture of its error card.
    /// Blocks for as long as the script runs: call it off the window's thread.
    pub fn preview(&self, request: &PreviewRequest) -> PreviewResult {
        let failed = |message: String| PreviewResult { error: Some(("internalError".into(), message)), ..PreviewResult::default() };
        let (files, package_id): (Arc<dyn PackageFiles>, String) = match &request.source {
            PreviewSource::Installed { name, edits } => {
                let Some(package) = self.library.find(name) else { return failed(format!("There is no widget named {name}.")) };
                let files = Overlay { base: package.files(), edits: edits.iter().cloned().collect() };
                (Arc::new(files), package.installation)
            }
            PreviewSource::Bundled(reference) => {
                let Some(bundled) = self.library.find_bundled(reference) else { return failed(format!("There is no template {reference}.")) };
                match self.bundled_view(&bundled) {
                    Ok(files) => (Arc::new(files), format!("studio:{reference}")),
                    Err(error) => return failed(error.0),
                }
            }
        };
        let Some(presentation) = Presentation::for_family(&request.family, request.scale.clamp(0.5, 4.0)) else { return failed(format!("Unknown size {}", request.family)) };
        let mut run = RunRequest::new(files, package_id);
        run.family = request.family.clone();
        run.dark_mode = request.dark;

        let _one_at_a_time = self.engine.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let result = self.runtime.run(&run);
        let mut error = result.execution.error.as_ref().map(|error| (error.kind.clone(), error.message.clone()));
        let picture = match sw_render::render_run(&self.renderer, &self.runtime, &run, &result, &presentation) {
            Ok(rendered) => {
                if let (None, Some(failure)) = (&error, &rendered.failure) {
                    error = Some(("internalError".into(), failure.message.clone()));
                }
                let output = rendered.output;
                Some(Picture { pixels: output.straight_pixels(), pixel_width: output.pixel_width, pixel_height: output.pixel_height, width: presentation.width, height: presentation.height })
            }
            Err(failure) => {
                error.get_or_insert(("internalError".into(), failure.message));
                None
            }
        };
        PreviewResult {
            picture,
            error,
            logs: result.execution.logs.iter().map(|entry| (entry.level.clone(), entry.message.clone())).collect(),
            elapsed_milliseconds: result.execution.elapsed.as_millis() as u64,
        }
    }

    /// A template as a copy of it would be: with the manifest the library gives a copy, so that its network requests are allowed in the preview.
    fn bundled_view(&self, bundled: &BundledPackage) -> Result<MemoryPackageFiles, StudioError> {
        let mut files = self.library.bundled_files(bundled);
        let (_, manifest) = Library::bundled_sources(&bundled.name, &files)?;
        files.insert(manifests::FILE_NAME.to_owned(), manifest.into_bytes());
        let (mut text, mut binary) = (Vec::new(), Vec::new());
        for (path, bytes) in files {
            match String::from_utf8(bytes) {
                Ok(content) if is_text_file(&path) => text.push((path, content)),
                Ok(content) => binary.push((path, content.into_bytes())),
                Err(error) => binary.push((path, error.into_bytes())),
            }
        }
        Ok(MemoryPackageFiles::new(text, binary))
    }
}

fn card(package: &InstalledPackage) -> WidgetCard {
    WidgetCard {
        name: package.name.clone(),
        title: package.display_name(),
        description: package.description(),
        families: package.families(),
        readable: !package.manifest_present || package.manifest.is_some(),
        installation: package.installation.clone(),
    }
}

/// The files of an installed package with the text of unsaved files laid over them.
struct Overlay {
    base: DiskPackageFiles,
    edits: HashMap<String, String>,
}

impl PackageFiles for Overlay {
    fn paths(&self) -> Vec<String> {
        let mut paths = self.base.paths();
        paths.extend(self.edits.keys().filter(|path| !self.base.exists(path)).cloned());
        paths.sort_unstable();
        paths
    }

    fn exists(&self, path: &str) -> bool {
        self.edits.contains_key(path) || self.base.exists(path)
    }

    fn read_text(&self, path: &str) -> Option<String> {
        self.edits.get(path).cloned().or_else(|| self.base.read_text(path))
    }

    fn read_bytes(&self, path: &str) -> Option<Vec<u8>> {
        self.edits.get(path).map(|text| text.clone().into_bytes()).or_else(|| self.base.read_bytes(path))
    }
}

/// A `.swt` file the user named: a regular file, never a device or a pipe, read up to the archive limit by the store.
fn open_archive(file: &Path) -> Result<impl Read, StudioError> {
    let opened = std::fs::OpenOptions::new().read(true).custom_flags(libc::O_CLOEXEC | libc::O_NONBLOCK).open(file).map_err(|error| StudioError(format!("{}: {error}", file.display())))?;
    if !opened.metadata()?.is_file() {
        return Err(StudioError(format!("{} is not a file.", file.display())));
    }
    Ok(opened)
}

/// Writes `bytes` under a private temporary name in the folder of `target` and renames it over `target`.
pub fn write_atomically(target: &Path, bytes: &[u8], mode: u32) -> std::io::Result<()> {
    let folder = target.parent().filter(|parent| !parent.as_os_str().is_empty()).unwrap_or(Path::new("."));
    let name = target.file_name().ok_or_else(|| std::io::Error::new(std::io::ErrorKind::InvalidInput, "no file name"))?;
    let mut random = [0u8; 8];
    getrandom::fill(&mut random).map_err(|error| std::io::Error::other(error.to_string()))?;
    let suffix: String = random.iter().map(|byte| format!("{byte:02x}")).collect();
    let temporary = folder.join(format!(".{}.{suffix}.tmp", name.to_string_lossy()));
    let written = (|| {
        // Created new, never through a link, private until it is complete.
        let mut file = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC).open(&temporary)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        std::fs::set_permissions(&temporary, std::os::unix::fs::PermissionsExt::from_mode(mode))?;
        std::fs::rename(&temporary, target)
    })();
    if written.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    written
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::{Scratch, studio};

    #[test]
    fn the_engine_is_shared_between_threads() {
        fn shared<T: Send + Sync>() {}
        shared::<Studio>();
    }

    #[test]
    fn an_empty_library_lists_nothing_and_templates_come_in_groups() {
        let scratch = Scratch::new("groups");
        let studio = studio(&scratch);
        assert_eq!(studio.widgets().unwrap(), []);
        let groups = studio.template_groups();
        assert_eq!(groups.iter().map(|group| group.group.as_str()).collect::<Vec<_>>(), ["template", "api"], "the group with nothing Linux can run is not shown");
        assert_eq!(groups[0].templates.iter().map(|card| (card.reference.as_str(), card.network)).collect::<Vec<_>>(), [("template/Clock", false), ("template/Quote", true)]);
        assert!(groups.iter().all(|group| group.templates.iter().all(|card| card.name != "steps")), "a template that needs $health is not offered");
    }

    #[test]
    fn a_template_shows_its_code_and_the_hosts_a_copy_may_ask() {
        let scratch = Scratch::new("detail");
        let studio = studio(&scratch);
        let quote = studio.template("template/Quote").unwrap();
        assert_eq!(quote.name, "Quote");
        assert!(quote.source.contains("zenquotes.io"));
        assert_eq!(quote.hosts, ["zenquotes.io"]);
        let clock = studio.template("template/Clock").unwrap();
        assert_eq!((clock.description.as_str(), clock.hosts.len()), ("A clock", 0));
        assert!(studio.template("component/steps").is_none() && studio.template("template/Missing").is_none());
    }

    #[test]
    fn using_a_template_makes_an_editable_copy_and_leaves_the_template_alone() {
        let scratch = Scratch::new("copy");
        let studio = studio(&scratch);
        let before = std::fs::read_to_string(scratch.path("templates/template/Clock/main.jsx")).unwrap();
        let first = studio.use_template("template/Clock").unwrap();
        let second = studio.use_template("template/Clock").unwrap();
        assert_eq!((first.as_str(), second.as_str()), ("Clock", "Clock (1)"));
        assert_eq!(studio.files(&first).unwrap(), ["main.jsx", "lib/label.js", "meta.json", "widget.json"], "the entry comes first");
        assert_eq!(studio.entry(&first), "main.jsx");

        studio.save_text(&first, "main.jsx", "$render(<text>mine</text>);").unwrap();
        assert_eq!(studio.read_text(&first, "main.jsx").unwrap().as_deref(), Some("$render(<text>mine</text>);"));
        assert_eq!(std::fs::read_to_string(scratch.path("templates/template/Clock/main.jsx")).unwrap(), before);
        assert_eq!(studio.read_text(&second, "main.jsx").unwrap().as_deref(), Some(before.as_str()), "the second copy is its own");
        let cards = studio.widgets().unwrap();
        assert_eq!(cards.iter().map(|card| card.name.as_str()).collect::<Vec<_>>(), ["Clock", "Clock (1)"]);
        assert_ne!(cards[0].installation, cards[1].installation);
        assert!(studio.use_template("component/steps").is_err());
    }

    #[test]
    fn saving_is_a_round_trip_and_refuses_paths_outside_the_package() {
        let scratch = Scratch::new("save");
        let studio = studio(&scratch);
        let name = studio.new_widget("  My Widget ").unwrap();
        assert_eq!(name, "My Widget");
        assert_eq!(studio.read_text(&name, "main.jsx").unwrap().as_deref(), Some(STARTER));

        let text = "// 你好\n$render(<text>saved</text>);\n";
        studio.save_text(&name, "main.jsx", text).unwrap();
        studio.save_text(&name, "lib/helper.js", "function helper() {}\n").unwrap();
        assert_eq!(studio.read_text(&name, "main.jsx").unwrap().as_deref(), Some(text));
        assert_eq!(studio.files(&name).unwrap(), ["main.jsx", "lib/helper.js", "widget.json"]);
        // Nothing but the files themselves is left in the folder: no temporary file survives a save.
        let mut left: Vec<String> = std::fs::read_dir(scratch.path("data/Packages/My Widget")).unwrap().map(|entry| entry.unwrap().file_name().into_string().unwrap()).filter(|name| !name.starts_with(".scriptwidget")).collect();
        left.sort();
        assert_eq!(left, ["lib", "main.jsx", "widget.json"]);

        for path in ["../escape.js", "/tmp/escape.js", "lib/../../escape.js", "a\\b.js", ""] {
            assert!(studio.save_text(&name, path, "x").is_err(), "{path:?} must be refused");
        }
        assert!(!scratch.path("data/Packages/escape.js").exists() && !scratch.path("data/escape.js").exists());
        assert!(studio.save_text("No Such Widget", "main.jsx", "x").is_err());

        // A link in the place of a file is not written through.
        std::fs::write(scratch.path("outside.txt"), "untouched").unwrap();
        std::os::unix::fs::symlink(scratch.path("outside.txt"), scratch.path("data/Packages/My Widget/link.js")).unwrap();
        assert!(studio.save_text(&name, "link.js", "overwritten").is_err());
        assert_eq!(std::fs::read_to_string(scratch.path("outside.txt")).unwrap(), "untouched");
    }

    #[test]
    fn a_file_that_is_not_text_is_not_opened_as_text() {
        let scratch = Scratch::new("binary");
        let studio = studio(&scratch);
        let name = studio.new_widget("Pictures").unwrap();
        std::fs::write(scratch.path("data/Packages/Pictures/photo.png"), [0x89, b'P', b'N', b'G', 0xff]).unwrap();
        std::fs::write(scratch.path("data/Packages/Pictures/broken.json"), [0xff, 0xfe, 0x00]).unwrap();
        assert_eq!(studio.read_text(&name, "photo.png").unwrap(), None);
        assert_eq!(studio.read_text(&name, "broken.json").unwrap(), None, "not UTF-8");
    }

    #[test]
    fn export_then_import_gives_the_same_widget_under_a_new_name() {
        let scratch = Scratch::new("archive");
        let studio = studio(&scratch);
        let name = studio.use_template("template/Clock").unwrap();
        let target = scratch.path("out/Clock.swt");
        std::fs::create_dir_all(scratch.path("out")).unwrap();
        std::fs::write(&target, "an older export").unwrap();
        studio.export(&name, &target).unwrap();
        assert_eq!(std::fs::read_dir(scratch.path("out")).unwrap().count(), 1, "no temporary file is left beside the export");

        let summary = studio.inspect(&target).unwrap();
        assert_eq!((summary.name.as_str(), summary.files), ("Clock", 4));
        assert!(summary.bytes > 0 && summary.hosts.is_empty() && summary.permissions.is_empty());
        assert_eq!(studio.widgets().unwrap().len(), 1, "looking at an archive installs nothing");
        assert_eq!(std::fs::read_dir(scratch.path("data/Staging")).map(|entries| entries.count()).unwrap_or(0), 0, "and leaves nothing in staging");

        let imported = studio.import(&target).unwrap();
        assert_eq!(imported, "Clock (1)");
        assert_eq!(studio.read_text(&imported, "lib/label.js").unwrap(), studio.read_text(&name, "lib/label.js").unwrap());
        let cards = studio.widgets().unwrap();
        assert_ne!(cards[0].installation, cards[1].installation, "an archive never carries an installation's identity");

        studio.remove(&name).unwrap();
        assert_eq!(studio.widgets().unwrap().iter().map(|card| card.name.as_str()).collect::<Vec<_>>(), ["Clock (1)"]);
        assert!(studio.remove(&name).is_err());
    }

    #[test]
    fn what_is_not_a_package_is_refused_before_anything_is_installed() {
        let scratch = Scratch::new("refuse");
        let studio = studio(&scratch);
        let not_an_archive = scratch.write("notes.swt", b"this is not a zip file");
        assert!(studio.inspect(&not_an_archive).is_err());
        assert!(studio.import(&not_an_archive).is_err());
        assert!(studio.inspect(&scratch.path("missing.swt")).is_err());
        assert!(studio.inspect(&scratch.path("data")).is_err(), "a folder is not an archive");
        // An archive whose script does not compile is shown, and refused on import.
        let broken = scratch.write("broken.swt", &crate::testing::zip(&[("Broken/main.jsx", "$render(<text>unclosed"), ("Broken/widget.json", &crate::testing::manifest("Broken"))]));
        assert_eq!(studio.inspect(&broken).unwrap().name, "Broken");
        assert!(studio.import(&broken).is_err());
        // An entry that points outside the package fails the whole archive.
        let escaping = scratch.write("escape.swt", &crate::testing::zip(&[("main.jsx", "$render(<text>x</text>);"), ("../evil.js", "x")]));
        assert!(studio.inspect(&escaping).is_err() && studio.import(&escaping).is_err());
        assert_eq!(studio.widgets().unwrap(), []);
        assert!(!scratch.path("data/evil.js").exists() && !scratch.path("evil.js").exists());
    }

    #[test]
    fn a_widget_with_an_unreadable_manifest_is_listed_as_such() {
        let scratch = Scratch::new("unreadable");
        let studio = studio(&scratch);
        let name = studio.new_widget("Odd").unwrap();
        std::fs::write(scratch.path("data/Packages/Odd/widget.json"), "{ not json").unwrap();
        let card = studio.widget(&name).unwrap();
        assert!(!card.readable);
        assert_eq!(card.title, "Odd");
    }

    #[test]
    fn a_preview_draws_the_widget_at_the_size_asked_for() {
        let scratch = Scratch::new("preview");
        let studio = studio(&scratch);
        let name = studio.new_widget("Shown").unwrap();
        studio.save_text(&name, "main.jsx", "console.log('ran ' + $getenv('widget-size'));\n$render(<vstack frame=\"max\" background=\"#ff0000\"><text>hi</text></vstack>);").unwrap();
        let request = |family: &str, scale: f32| PreviewRequest { source: PreviewSource::Installed { name: name.clone(), edits: vec![] }, family: family.into(), dark: false, scale };

        let medium = studio.preview(&request("medium", 1.0));
        let picture = medium.picture.expect("a picture");
        assert_eq!((picture.pixel_width, picture.pixel_height, picture.width, picture.height), (329, 170, 329.0, 170.0));
        assert_eq!(picture.pixels.len(), 329 * 170 * 4);
        let middle = (85 * 329 + 20) * 4;
        assert_eq!(&picture.pixels[middle..middle + 4], [255, 0, 0, 255], "the script's background");
        assert_eq!(&picture.pixels[..4], [0, 0, 0, 0], "the corner is rounded away");
        assert_eq!(medium.error, None);
        assert_eq!(medium.logs, [("log".to_owned(), "ran medium".to_owned())]);

        let small = studio.preview(&request("small", 2.0)).picture.unwrap();
        assert_eq!((small.pixel_width, small.pixel_height, small.width), (340, 340, 170.0));
        assert!(studio.preview(&request("huge", 1.0)).picture.is_none());
    }

    #[test]
    fn unsaved_text_is_previewed_without_being_written() {
        let scratch = Scratch::new("unsaved");
        let studio = studio(&scratch);
        let name = studio.new_widget("Draft").unwrap();
        let edits = vec![("main.jsx".to_owned(), "console.log('draft');\n$render(<text>draft</text>);".to_owned())];
        let result = studio.preview(&PreviewRequest { source: PreviewSource::Installed { name: name.clone(), edits }, family: "small".into(), dark: true, scale: 1.0 });
        assert_eq!(result.logs, [("log".to_owned(), "draft".to_owned())]);
        assert_eq!(studio.read_text(&name, "main.jsx").unwrap().as_deref(), Some(STARTER));
        assert!(!scratch.path("data/Packages/Draft/__Build").exists(), "a preview caches nothing in the package");
    }

    #[test]
    fn a_script_error_is_reported_and_still_drawn_as_a_card() {
        let scratch = Scratch::new("error");
        let studio = studio(&scratch);
        let name = studio.new_widget("Broken").unwrap();
        let preview = |source: &str| studio.preview(&PreviewRequest { source: PreviewSource::Installed { name: name.clone(), edits: vec![("main.jsx".into(), source.into())] }, family: "medium".into(), dark: false, scale: 1.0 });

        let thrown = preview("console.log('before');\nthrow new Error('boom');");
        let (_, message) = thrown.error.expect("an error");
        assert!(message.contains("boom"), "{message}");
        assert!(thrown.logs.iter().any(|(_, printed)| printed == "before"), "{:?}", thrown.logs);
        assert!(thrown.picture.is_some(), "the error card");

        let syntax = preview("$render(<text>unclosed");
        assert!(syntax.error.is_some() && syntax.picture.is_some());
        // A script that never ends is stopped by the engine's deadline, not by the window.
        let missing = studio.preview(&PreviewRequest { source: PreviewSource::Installed { name: "Nobody".into(), edits: vec![] }, family: "medium".into(), dark: false, scale: 1.0 });
        assert!(missing.error.is_some() && missing.picture.is_none());
    }

    #[test]
    fn a_package_cannot_reach_files_outside_itself_through_a_preview() {
        let scratch = Scratch::new("contained");
        let studio = studio(&scratch);
        let name = studio.new_widget("Curious").unwrap();
        scratch.write("secret.txt", b"secret");
        let source = "let seen = 'nothing';\ntry { seen = String($file.read('../../../secret.txt')); } catch (error) { seen = 'refused'; }\nconsole.log(seen);\n$render(<text>x</text>);";
        let result = studio.preview(&PreviewRequest { source: PreviewSource::Installed { name, edits: vec![("main.jsx".into(), source.into())] }, family: "small".into(), dark: false, scale: 1.0 });
        let printed: Vec<&str> = result.logs.iter().map(|(_, message)| message.as_str()).collect();
        assert!(!printed.iter().any(|line| line.contains("secret")), "{printed:?}");
    }

    #[test]
    fn a_template_is_previewed_without_being_installed() {
        let scratch = Scratch::new("template-preview");
        let studio = studio(&scratch);
        let result = studio.preview(&PreviewRequest { source: PreviewSource::Bundled("template/Clock".into()), family: "medium".into(), dark: false, scale: 1.0 });
        assert_eq!(result.error, None);
        assert!(result.picture.is_some());
        assert_eq!(studio.widgets().unwrap(), []);
        assert!(studio.preview(&PreviewRequest { source: PreviewSource::Bundled("component/steps".into()), family: "medium".into(), dark: false, scale: 1.0 }).picture.is_none());
    }

    #[test]
    fn an_atomic_write_replaces_the_file_and_never_follows_a_link_for_its_temporary_file() {
        let scratch = Scratch::new("atomic");
        let target = scratch.path("settings.json");
        write_atomically(&target, b"one", 0o600).unwrap();
        write_atomically(&target, b"two", 0o600).unwrap();
        assert_eq!(std::fs::read(&target).unwrap(), b"two");
        assert_eq!(std::fs::metadata(&target).unwrap().permissions().mode() & 0o777, 0o600);
        assert_eq!(std::fs::read_dir(scratch.root()).unwrap().count(), 1);
        assert!(write_atomically(&scratch.path("missing-folder/file"), b"x", 0o600).is_err());
        // A link at the target is replaced by the file, not written through.
        std::fs::write(scratch.path("elsewhere"), "kept").unwrap();
        std::os::unix::fs::symlink(scratch.path("elsewhere"), scratch.path("linked")).unwrap();
        write_atomically(&scratch.path("linked"), b"new", 0o600).unwrap();
        assert_eq!(std::fs::read_to_string(scratch.path("elsewhere")).unwrap(), "kept");
        assert!(!std::fs::symlink_metadata(scratch.path("linked")).unwrap().file_type().is_symlink());
    }

    use std::os::unix::fs::PermissionsExt;
}
