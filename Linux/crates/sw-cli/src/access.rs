//! `scriptwidget services`, `notifications`, `documents` and `photos`: what
//! the user connects, allows and picks for the data APIs of the same names.
//! The command-line face of `sw_core::api::SystemStores`; the management
//! window does the same through "Data access" in the editor and "GitHub" in
//! the settings.
//!
//! A package's manifest only says what a widget would like to use. These
//! commands are the user's side of it: which widget may show notifications,
//! which may read the GitHub profile, and which files and pictures each one
//! gets. Everything is per widget and stays on this computer.
//!
//! The GitHub token is read from standard input, or typed without echo. It
//! goes to GitHub once to be verified and then into the system keyring. No
//! report, message or file of these commands ever contains it.

use std::io::{BufRead, IsTerminal, Read, Write};
use std::path::Path;
use std::time::Duration;

use serde_json::{Value, json};
use sw_core::api::SystemStores;
use sw_core::api::documents::{PickError, document_rules};
use sw_core::api::notifications::{NotificationsModule, notification_rules, system_next_local_time};
use sw_core::api::photos::{PhotosModule, photo_limits};
use sw_core::api::services::ServicesModule;
use sw_core::api::support::{SystemReject, iso_dates, system_log};
use sw_core::library::{InstalledPackage, Library};

use crate::arguments::{Arguments, Shape};
use crate::commands::user_data;
use crate::report::{EXIT_FAILED, EXIT_USAGE, Failure, Report};

pub const GROUPS: [&str; 4] = ["services", "notifications", "documents", "photos"];

const HELP: &str = "\
Usage: scriptwidget <services | notifications | documents | photos> <command> [options]

What a widget's manifest asks for, the user grants here, one widget at a time. <package> is the
name of an installed package (scriptwidget list).

services ($services, GitHub):
  services status                     Whether a GitHub account is connected, and which widgets may
                                      read its profile. Never the token.
  services connect                    Connect an account with a fine-grained personal access token
                                      (github_pat_…), read from standard input or typed without echo.
                                      The token is verified with GitHub and kept in the system keyring.
  services disconnect                 Remove the token from the keyring and forget every grant.
  services allow <package>            Let this widget read the connected account's profile.
  services deny <package>             Stop letting it.

notifications ($notifications):
  notifications status [<package>]    Whether a notification service is running, which widgets may
                                      schedule notifications, and what is pending.
  notifications allow <package>       Let this widget schedule notifications.
  notifications deny <package>        Stop letting it, and cancel what it scheduled.

documents ($documents):
  documents list <package>            The JSON and CSV files picked for this widget.
  documents add <package> <file>      Pick a .json or .csv file (at most 256 KiB, 8 files a widget).
                                      The widget gets its content and its name, never its path.
  documents remove <package> <id>     Take a file off the list. The file itself is not touched.

photos ($photos):
  photos list <package>               The pictures picked for this widget.
  photos add <package> <file>         Pick a picture (at most 16 MB, 24 pictures a widget). The
                                      widget gets a small copy without the file's name or metadata.
  photos remove <package> <id>        Take a picture off the list. The file itself is not touched.

  --data <dir>          The data folder (default: yours).
";

pub fn wants_help(arguments: &[String]) -> bool {
    arguments.first().is_some_and(|word| matches!(word.as_str(), "--help" | "-h" | "help"))
}

pub fn help() -> &'static str {
    HELP
}

/// Runs a command of one of the groups. A failure that stopped it becomes its report, under the command's own name.
pub fn run(group: &str, arguments: &[String]) -> Report {
    let name = match arguments.first().filter(|word| !word.starts_with('-')) {
        Some(word) => format!("{group} {word}"),
        None => group.to_owned(),
    };
    let result = dispatch(group, arguments, &SystemStores::for_user, &mut read_token);
    result.unwrap_or_else(|failure| Report::from_failure(&name, &failure))
}

type Stores<'a> = &'a dyn Fn(&sw_core::DataPaths) -> SystemStores;
type TokenReader<'a> = &'a mut dyn FnMut() -> Result<String, Failure>;

fn dispatch(group: &str, arguments: &[String], stores: Stores<'_>, token: TokenReader<'_>) -> Result<Report, Failure> {
    let Some(word) = arguments.first().map(String::as_str) else { return Err(Failure::usage(format!("Missing a {group} command. scriptwidget {group} --help lists them."))) };
    let rest = &arguments[1..];
    match (group, word) {
        ("services", "status") => services_status(rest, stores),
        ("services", "connect") => services_connect(rest, stores, token),
        ("services", "disconnect") => services_disconnect(rest, stores),
        ("services", "allow") => services_grant(rest, stores, true),
        ("services", "deny") => services_grant(rest, stores, false),
        ("notifications", "status") => notifications_status(rest, stores),
        ("notifications", "allow") => notifications_grant(rest, stores, true),
        ("notifications", "deny") => notifications_grant(rest, stores, false),
        ("documents", "list") => picked_list(rest, stores, Kind::Documents),
        ("documents", "add") => picked_add(rest, stores, Kind::Documents),
        ("documents", "remove") => picked_remove(rest, stores, Kind::Documents),
        ("photos", "list") => picked_list(rest, stores, Kind::Photos),
        ("photos", "add") => picked_add(rest, stores, Kind::Photos),
        ("photos", "remove") => picked_remove(rest, stores, Kind::Photos),
        _ => Err(Failure::usage(format!("Unknown {group} command {word}. scriptwidget {group} --help lists them."))),
    }
}

fn shape(minimum: usize, maximum: usize, positionals: &'static str) -> Shape {
    Shape { values: &["data"], flags: &[], minimum_positionals: minimum, maximum_positionals: maximum, positionals }
}

/// The data folder's stores and its library.
fn open(arguments: &Arguments, stores: Stores<'_>) -> Result<(SystemStores, Library), Failure> {
    let paths = user_data(arguments)?;
    Ok((stores(&paths), Library::new(&paths, None)))
}

fn package(library: &Library, name: &str) -> Result<InstalledPackage, Failure> {
    library.find(name).ok_or_else(|| Failure::environment("package.unknown", format!("No installed package is named {name}. scriptwidget list shows them.")))
}

/// Says so when the package does not declare the permission: the grant is recorded, but the widget cannot use it yet.
fn note_undeclared(report: &mut Report, package: &InstalledPackage, permissions: &[&str]) {
    let declared = package.permissions();
    let missing: Vec<&str> = permissions.iter().copied().filter(|permission| !declared.iter().any(|known| known == permission)).collect();
    report.set("declared", json!(missing.is_empty()));
    if !missing.is_empty() {
        report.diagnostic("warning", "permission.undeclared", &format!("{} does not declare {} in the permissions of its widget.json, so it cannot use this yet.", package.name, missing.join(" and ")));
    }
}

/// The bracketed code of a rejection, as the code of a failure; the sentence is its own.
fn rejected(error: SystemReject) -> Failure {
    let code = system_log::code(&error.0).to_owned();
    let message = error.0.split_once("] ").map_or(error.0.as_str(), |(_, sentence)| sentence).to_owned();
    let hint = match code.as_str() {
        "service_credential" => " A fine-grained personal access token starts with github_pat_; create one at github.com/settings/personal-access-tokens.",
        "service_storage" => " Check that a keyring such as GNOME Keyring or KeePassXC is running and unlocked, and that secret-tool (libsecret) is installed. Nothing was stored elsewhere.",
        "service_expired" => " GitHub did not accept the token.",
        _ => "",
    };
    Failure::new(EXIT_USAGE, &format!("services.{code}"), format!("{message}{hint}"))
}

// services

/// More than a token can be.
const MAXIMUM_TOKEN_INPUT_BYTES: u64 = 4 * 1024;

/// The token as the user gives it: typed without echo at a terminal, or everything on standard input.
fn read_token() -> Result<String, Failure> {
    let unreadable = || Failure::environment("services.token_input", "The token could not be read.");
    let stdin = std::io::stdin();
    let text = if stdin.is_terminal() {
        let hidden = crate::ai::NoEcho::start().ok_or_else(|| Failure::environment("services.token_input", "The terminal's echo could not be turned off, so the token was not read. Pipe the token to this command instead."))?;
        eprint!("GitHub token (not shown): ");
        let _ = std::io::stderr().flush();
        let mut line = String::new();
        let read = stdin.lock().take(MAXIMUM_TOKEN_INPUT_BYTES + 1).read_line(&mut line);
        drop(hidden);
        eprintln!();
        read.map_err(|_| unreadable())?;
        line
    } else {
        let mut bytes = Vec::new();
        stdin.lock().take(MAXIMUM_TOKEN_INPUT_BYTES + 1).read_to_end(&mut bytes).map_err(|_| unreadable())?;
        // Not valid text is not a token; what was read is not repeated.
        String::from_utf8(bytes).map_err(|_| Failure::environment("services.service_credential", "That is not a GitHub token."))?
    };
    if text.len() as u64 > MAXIMUM_TOKEN_INPUT_BYTES {
        return Err(Failure::environment("services.service_credential", "That is too long to be a GitHub token."));
    }
    Ok(text)
}

fn describe_services(stores: &SystemStores, library: &Library) -> Result<Value, Failure> {
    let Some(summary) = stores.services.summary().map_err(rejected)? else { return Ok(json!({ "service": "github", "connected": false })) };
    let packages = library.list().unwrap_or_default();
    let widgets: Vec<Value> = summary.grants.iter().map(|installation| json!({ "installation": installation, "package": packages.iter().find(|package| package.installation == *installation).map(|package| package.name.clone()) })).collect();
    Ok(json!({ "service": "github", "connected": true, "username": summary.username, "connectedAt": iso_dates::format(summary.connected_at), "allowed": widgets }))
}

fn services_status(arguments: &[String], stores: Stores<'_>) -> Result<Report, Failure> {
    let (stores, library) = open(&Arguments::parse(arguments, &shape(0, 0, ""))?, stores)?;
    let mut report = Report::new("services status");
    report.set("github", describe_services(&stores, &library)?);
    Ok(report)
}

fn services_connect(arguments: &[String], stores: Stores<'_>, token: TokenReader<'_>) -> Result<Report, Failure> {
    let (stores, library) = open(&Arguments::parse(arguments, &shape(0, 0, ""))?, stores)?;
    let token = token()?;
    let username = stores.services.connect(&token).map_err(rejected)?;
    drop(token);
    let mut report = Report::new("services connect");
    report.set("username", json!(username));
    report.set("where", json!("keyring"));
    report.set("github", describe_services(&stores, &library)?);
    Ok(report)
}

fn services_disconnect(arguments: &[String], stores: Stores<'_>) -> Result<Report, Failure> {
    let (stores, _) = open(&Arguments::parse(arguments, &shape(0, 0, ""))?, stores)?;
    let was_connected = stores.services.summary().map(|summary| summary.is_some()).unwrap_or(true);
    stores.services.disconnect().map_err(rejected)?;
    let mut report = Report::new("services disconnect");
    report.set("disconnected", json!(was_connected));
    Ok(report)
}

fn services_grant(arguments: &[String], stores: Stores<'_>, granted: bool) -> Result<Report, Failure> {
    let arguments = Arguments::parse(arguments, &shape(1, 1, "the name of an installed package"))?;
    let (stores, library) = open(&arguments, stores)?;
    let package = package(&library, arguments.positional(0).unwrap_or_default())?;
    if stores.services.summary().map_err(rejected)?.is_none() {
        return Err(Failure::environment("services.service_not_connected", "No GitHub account is connected. Connect one with: scriptwidget services connect"));
    }
    if !stores.services.set_grant(&package.installation, granted) {
        return Err(Failure::environment("services.service_storage", "The grant could not be saved."));
    }
    let mut report = Report::new(if granted { "services allow" } else { "services deny" });
    report.set("package", json!(package.name));
    report.set("allowed", json!(granted));
    if granted {
        note_undeclared(&mut report, &package, &[ServicesModule::PERMISSION, "network"]);
    }
    report.set("github", describe_services(&stores, &library)?);
    Ok(report)
}

// notifications

fn notifications_status(arguments: &[String], stores: Stores<'_>) -> Result<Report, Failure> {
    let arguments = Arguments::parse(arguments, &shape(0, 1, "at most one package name"))?;
    let (stores, library) = open(&arguments, stores)?;
    let only = arguments.positional(0).map(|name| package(&library, name)).transpose()?;
    let pending = stores.notifications.all().map_err(|_| Failure::environment("notifications.unavailable", "The list of pending notifications cannot be read."))?;
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |elapsed| elapsed.as_millis() as i64);
    let next_local = system_next_local_time();
    let widgets: Vec<Value> = library
        .list()
        .unwrap_or_default()
        .iter()
        .filter(|package| only.as_ref().is_none_or(|only| only.installation == package.installation))
        .filter(|package| only.is_some() || package.permissions().iter().any(|permission| permission == NotificationsModule::PERMISSION) || pending.iter().any(|entry| entry.owner == package.installation))
        .map(|package| {
            let mine: Vec<Value> = pending
                .iter()
                .filter(|entry| entry.owner == package.installation)
                .map(|entry| json!({ "key": entry.key, "title": entry.title, "repeats": entry.repeats(), "date": iso_dates::format(notification_rules::next_trigger(entry, now, &next_local)) }))
                .collect();
            json!({
                "package": package.name,
                "declared": package.permissions().iter().any(|permission| permission == NotificationsModule::PERMISSION),
                "allowed": stores.grants.capabilities(&package.installation).iter().any(|capability| capability == NotificationsModule::PERMISSION),
                "pending": mine,
            })
        })
        .collect();
    let mut report = Report::new("notifications status");
    // Asked of the session bus with a short limit; no service, no bus and no busctl all read as false.
    report.set("serviceRunning", json!(stores.bus.has_notification_service(Duration::from_secs(2)).unwrap_or(false)));
    report.set("widgets", Value::Array(widgets));
    Ok(report)
}

fn notifications_grant(arguments: &[String], stores: Stores<'_>, granted: bool) -> Result<Report, Failure> {
    let arguments = Arguments::parse(arguments, &shape(1, 1, "the name of an installed package"))?;
    let (stores, library) = open(&arguments, stores)?;
    let package = package(&library, arguments.positional(0).unwrap_or_default())?;
    if !stores.grants.set(&package.installation, NotificationsModule::PERMISSION, granted) {
        return Err(Failure::environment("notifications.unavailable", "The grant could not be saved."));
    }
    let mut cancelled = 0;
    if !granted {
        // What it scheduled while it was allowed is not shown after the user said no.
        for entry in stores.notifications.all().unwrap_or_default().iter().filter(|entry| entry.owner == package.installation) {
            cancelled += usize::from(stores.notifications.remove(&entry.owner, &entry.key));
        }
    }
    let mut report = Report::new(if granted { "notifications allow" } else { "notifications deny" });
    report.set("package", json!(package.name));
    report.set("allowed", json!(granted));
    if granted {
        note_undeclared(&mut report, &package, &[NotificationsModule::PERMISSION]);
    } else {
        report.set("cancelled", json!(cancelled));
    }
    Ok(report)
}

// documents and photos

#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    Documents,
    Photos,
}

impl Kind {
    fn word(self) -> &'static str {
        match self {
            Self::Documents => "documents",
            Self::Photos => "photos",
        }
    }

    fn permission(self) -> &'static str {
        match self {
            Self::Documents => sw_core::api::documents::DocumentsModule::PERMISSION,
            Self::Photos => PhotosModule::PERMISSION,
        }
    }
}

/// The list as its owner sees it: with the paths, which a widget never gets.
fn describe_picked(stores: &SystemStores, package: &InstalledPackage, kind: Kind) -> Result<Value, Failure> {
    let unreadable = || Failure::environment(&format!("{}.unavailable", kind.word()), format!("The list of picked files of {} cannot be read. Removing the package's picked files and picking them again repairs it.", package.name));
    Ok(match kind {
        Kind::Documents => stores.documents.list(&package.installation).map_err(|_| unreadable())?.iter().map(|entry| json!({ "id": entry.id, "name": entry.name, "type": entry.kind, "path": entry.path.display().to_string(), "bytes": stores.documents.bytes(entry) })).collect(),
        Kind::Photos => stores
            .photos
            .list(&package.installation)
            .map_err(|_| unreadable())?
            .iter()
            .map(|entry| json!({ "id": entry.id, "path": entry.path.display().to_string(), "width": entry.width, "height": entry.height, "readable": std::fs::symlink_metadata(&entry.path).is_ok_and(|metadata| metadata.is_file()) }))
            .collect(),
    })
}

fn picked_list(arguments: &[String], stores: Stores<'_>, kind: Kind) -> Result<Report, Failure> {
    let arguments = Arguments::parse(arguments, &shape(1, 1, "the name of an installed package"))?;
    let (stores, library) = open(&arguments, stores)?;
    let package = package(&library, arguments.positional(0).unwrap_or_default())?;
    let mut report = Report::new(&format!("{} list", kind.word()));
    report.set("package", json!(package.name));
    report.set(kind.word(), describe_picked(&stores, &package, kind)?);
    note_undeclared(&mut report, &package, &[kind.permission()]);
    Ok(report)
}

fn pick_failure(kind: Kind, error: PickError, file: &Path) -> Failure {
    let shown = file.display();
    let message = match (error, kind) {
        (PickError::NotInstalled, _) => "That package is not an installed one.".to_owned(),
        (PickError::UnsupportedType, _) => format!("{shown} is not a .json or .csv file."),
        (PickError::TooLarge, Kind::Documents) => format!("{shown} is larger than {} KiB.", document_rules::MAXIMUM_BYTES / 1024),
        (PickError::TooLarge, Kind::Photos) => format!("{shown} is larger than {} MB.", photo_limits::MAXIMUM_SOURCE_BYTES / (1024 * 1024)),
        (PickError::Unreadable, _) => format!("{shown} is not a file that can be read."),
        (PickError::InvalidContent, Kind::Documents) => format!("{shown} is not valid JSON or CSV as a widget may read it: JSON must be an object or a list; CSV needs a header row of unique names, at most 32 columns and 500 rows."),
        (PickError::InvalidContent, Kind::Photos) => format!("{shown} is not a picture that can be read."),
        (PickError::Full, Kind::Documents) => format!("This widget already has {} files. Remove one first.", document_rules::MAXIMUM_FILES),
        (PickError::Full, Kind::Photos) => format!("This widget already has {} pictures. Remove one first.", photo_limits::MAXIMUM_SELECTED),
        (PickError::Duplicate, _) => format!("{shown} is already picked for this widget."),
        (PickError::Storage, _) => "The list of picked files could not be read or saved.".to_owned(),
    };
    // A file that cannot be used is at fault itself; a list that cannot be saved is the machine's.
    let exit = if matches!(error, PickError::Storage | PickError::NotInstalled) { EXIT_USAGE } else { EXIT_FAILED };
    Failure::new(exit, &format!("{}.{}", kind.word(), error.code()), message)
}

fn picked_add(arguments: &[String], stores: Stores<'_>, kind: Kind) -> Result<Report, Failure> {
    let arguments = Arguments::parse(arguments, &shape(2, 2, "the name of an installed package and a file"))?;
    let (stores, library) = open(&arguments, stores)?;
    let package = package(&library, arguments.positional(0).unwrap_or_default())?;
    let file = std::path::absolute(Path::new(arguments.positional(1).unwrap_or_default())).map_err(|_| Failure::usage("Missing a file"))?;
    let added = match kind {
        Kind::Documents => stores.documents.add(&package.installation, &file).map(|entry| json!({ "id": entry.id, "name": entry.name, "type": entry.kind, "path": entry.path.display().to_string() })),
        Kind::Photos => {
            stores.photos.set_maker(std::sync::Arc::new(sw_render::SkiaThumbnails));
            let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |elapsed| elapsed.as_millis() as i64);
            stores.photos.add(&package.installation, &file, now).map(|entry| json!({ "id": entry.id, "path": entry.path.display().to_string(), "width": entry.width, "height": entry.height }))
        }
    }
    .map_err(|error| pick_failure(kind, error, &file))?;
    let mut report = Report::new(&format!("{} add", kind.word()));
    report.set("package", json!(package.name));
    report.set("added", added);
    report.set(kind.word(), describe_picked(&stores, &package, kind)?);
    note_undeclared(&mut report, &package, &[kind.permission()]);
    Ok(report)
}

fn picked_remove(arguments: &[String], stores: Stores<'_>, kind: Kind) -> Result<Report, Failure> {
    let arguments = Arguments::parse(arguments, &shape(2, 2, "the name of an installed package and the id of a picked file"))?;
    let (stores, library) = open(&arguments, stores)?;
    let package = package(&library, arguments.positional(0).unwrap_or_default())?;
    let id = arguments.positional(1).unwrap_or_default();
    let removed = match kind {
        Kind::Documents => stores.documents.remove(&package.installation, id).is_some(),
        Kind::Photos => stores.photos.remove(&package.installation, id),
    };
    if !removed {
        return Err(Failure::environment(&format!("{}.not_found", kind.word()), format!("{} has no picked file with the id {id}. scriptwidget {} list {} shows them.", package.name, kind.word(), package.name)));
    }
    let mut report = Report::new(&format!("{} remove", kind.word()));
    report.set("package", json!(package.name));
    report.set("removed", json!(id));
    report.set(kind.word(), describe_picked(&stores, &package, kind)?);
    Ok(report)
}

#[cfg(test)]
mod tests {
    //! The `services` commands against a GitHub that answers in this process
    //! and a keyring in memory. The token here is made up, and nothing is sent anywhere.

    use std::path::PathBuf;
    use std::sync::{Arc, Mutex};

    use sw_core::DataPaths;
    use sw_core::ai::credentials::{CredentialStore, MemoryCredentialStore};
    use sw_core::api::bus::SessionBus;
    use sw_core::api::services::{KEYRING_ACCOUNT, ServiceHttpResponse, ServiceTransport};

    use super::*;

    const TOKEN: &str = "github_pat_FAKEFAKEFAKEFAKEFAKE_notARealToken00000001";

    struct FakeGitHub {
        status: u16,
        seen: Mutex<Vec<String>>,
    }

    impl ServiceTransport for FakeGitHub {
        fn get(&self, url: &str, headers: &[(String, String)]) -> Result<ServiceHttpResponse, ()> {
            self.seen.lock().unwrap().push(format!("{url} {}", headers.iter().find(|(name, _)| name == "Authorization").map_or("", |(_, value)| value.as_str())));
            Ok(ServiceHttpResponse { status: self.status, content_type: Some("application/json".into()), rate_limited: false, body: br#"{"login":"octocat","id":583231,"public_repos":2,"email":"private@example.com"}"#.to_vec() })
        }
    }

    struct Fixture {
        root: PathBuf,
        keyring: Arc<MemoryCredentialStore>,
        github: Arc<FakeGitHub>,
    }

    impl Fixture {
        fn new(name: &str, status: u16) -> Self {
            let root = std::env::temp_dir().join(format!("scriptwidget-cli-access-{name}-{}", std::process::id()));
            let _ = std::fs::remove_dir_all(&root);
            let paths = DataPaths::new(Some(&root)).unwrap();
            let manifest = r#"{"formatVersion":2,"id":"com.example.profile","name":"Profile","version":"1.0.0","runtimeVersion":"1.0","entry":"main.jsx","supportedFamilies":["systemSmall"],"permissions":["services","network"],"networkDomains":["api.github.com"]}"#;
            Library::new(&paths, None).create("Profile", "$render(<text>p</text>);", Some(manifest)).unwrap();
            Library::new(&paths, None).create("Plain", "$render(<text>p</text>);", None).unwrap();
            Self { root, keyring: Arc::new(MemoryCredentialStore::new()), github: Arc::new(FakeGitHub { status, seen: Mutex::default() }) }
        }

        /// Runs one command and returns its report as JSON and its exit code.
        fn run(&self, group: &str, words: &[&str], token: Option<&str>) -> (Value, i32) {
            let (keyring, github) = (self.keyring.clone(), self.github.clone());
            let stores = move |paths: &DataPaths| SystemStores::with_parts(paths, keyring.clone(), github.clone(), SessionBus::with_program("/nonexistent/busctl"));
            let mut arguments: Vec<String> = words.iter().map(|word| word.to_string()).collect();
            arguments.extend(["--data".to_owned(), self.root.display().to_string()]);
            let mut asked = 0;
            let mut reader = || {
                asked += 1;
                token.map(str::to_owned).ok_or_else(|| Failure::usage("no token was expected"))
            };
            let report = dispatch(group, &arguments, &stores, &mut reader).unwrap_or_else(|failure| Report::from_failure(group, &failure));
            let (text, code) = report.rendered();
            let typed = token.map(str::trim).filter(|typed| !typed.is_empty());
            assert!(!text.contains("notARealToken") && typed.is_none_or(|typed| !text.contains(typed)), "a report shows what was typed: {text}");
            (serde_json::from_str(&text).unwrap(), code)
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }

    #[test]
    fn connecting_keeps_the_token_out_of_every_report_and_file() {
        let fixture = Fixture::new("connect", 200);
        assert_eq!(fixture.run("services", &["status"], None).0["github"], json!({"service": "github", "connected": false}));
        let (report, code) = fixture.run("services", &["connect"], Some(&format!("{TOKEN}\n")));
        assert_eq!((code, report["username"].as_str(), report["where"].as_str(), report["github"]["connected"].as_bool()), (0, Some("octocat"), Some("keyring"), Some(true)));
        assert_eq!(*fixture.github.seen.lock().unwrap(), [format!("https://api.github.com/user Bearer {TOKEN}")]);
        assert_eq!(fixture.keyring.load(KEYRING_ACCOUNT).unwrap().unwrap().expose(), TOKEN);
        // Nothing below the data folder holds the token.
        fn files(directory: &Path, found: &mut Vec<PathBuf>) {
            for entry in std::fs::read_dir(directory).into_iter().flatten().flatten() {
                if entry.path().is_dir() { files(&entry.path(), found) } else { found.push(entry.path()) }
            }
        }
        let mut all = Vec::new();
        files(&fixture.root, &mut all);
        assert!(all.iter().any(|file| file.ends_with("System/services.json")));
        for file in all {
            let text = String::from_utf8_lossy(&std::fs::read(&file).unwrap()).into_owned();
            assert!(!text.contains("github_pat_") && !text.contains("private@example.com"), "{} holds a secret", file.display());
        }

        // A widget is allowed by name; one that does not declare the permission is allowed with a warning.
        let (report, code) = fixture.run("services", &["allow", "Profile"], None);
        assert_eq!((code, report["declared"].as_bool(), report["github"]["allowed"][0]["package"].as_str()), (0, Some(true), Some("Profile")));
        let (report, _) = fixture.run("services", &["allow", "Plain"], None);
        assert_eq!((report["declared"].as_bool(), report["diagnostics"][0]["code"].as_str()), (Some(false), Some("permission.undeclared")));
        assert_eq!(fixture.run("services", &["deny", "Plain"], None).0["github"]["allowed"].as_array().unwrap().len(), 1);
        let (report, code) = fixture.run("services", &["allow", "Missing"], None);
        assert_eq!((code, report["error"]["kind"].as_str()), (EXIT_USAGE, Some("package.unknown")));

        let (report, code) = fixture.run("services", &["disconnect"], None);
        assert_eq!((code, report["disconnected"].as_bool()), (0, Some(true)));
        assert_eq!(fixture.keyring.load(KEYRING_ACCOUNT), Ok(None));
        assert_eq!(fixture.run("services", &["status"], None).0["github"]["connected"], false);
        let (report, code) = fixture.run("services", &["allow", "Profile"], None);
        assert_eq!((code, report["error"]["kind"].as_str()), (EXIT_USAGE, Some("services.service_not_connected")));
    }

    #[test]
    fn what_is_not_a_token_or_is_refused_is_not_stored() {
        // Not a fine-grained token: GitHub is never asked.
        let fixture = Fixture::new("refused", 200);
        for text in ["", "ghp_0123456789012345678901234567890123456789", "hunter2"] {
            let (report, code) = fixture.run("services", &["connect"], Some(text));
            assert_eq!((code, report["error"]["kind"].as_str()), (EXIT_USAGE, Some("services.service_credential")), "{text:?}");
        }
        assert!(fixture.github.seen.lock().unwrap().is_empty());
        // A token GitHub does not accept.
        let expired = Fixture::new("expired", 401);
        let (report, code) = expired.run("services", &["connect"], Some(TOKEN));
        assert_eq!((code, report["error"]["kind"].as_str()), (EXIT_USAGE, Some("services.service_expired")));
        assert_eq!(expired.keyring.load(KEYRING_ACCOUNT), Ok(None));
        assert!(!expired.root.join("System/services.json").exists());
        // Mistakes in the command line.
        for words in [&["connect", "extra"][..], &["sign-in"], &[]] {
            assert_eq!(fixture.run("services", words, None).1, EXIT_USAGE, "{words:?}");
        }
    }
}
