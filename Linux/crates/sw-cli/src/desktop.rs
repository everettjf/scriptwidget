//! The commands that talk to the background service (`docs/linux/protocol.md`),
//! and the service itself (`scriptwidget host run`).
//!
//! Each command checks its arguments, sends one line to the service's socket
//! and prints the answer as the usual report. Two commands do not print a
//! report, because something reads their output line by line for as long as
//! they run: `watch` prints the display events, and `dev` prints one line for
//! every time it copied the folder.
//!
//! When the service is not running these commands exit with 69 and say how
//! to start it.

use std::collections::BTreeMap;
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use serde_json::{Value, json};
use sw_core::library::{InstalledPackage, Library};
use sw_core::packages::limits::{MAX_FILE_BYTES, MAX_METADATA_BYTES, MAX_PATH_DEPTH};
use sw_core::packages::{self, ArchiveLimits, DiskPackageFiles, PackageError, codes, manifests, path_rules};
use sw_host::client::{self, ClientError, WatchEnd};
use sw_host::protocol::{self, Request, Switch};
use sw_host::{RuntimePaths, service};

use crate::arguments::{Arguments, Shape};
use crate::commands::{archive_name, package_directory, resources, user_data};
use crate::report::{EXIT_FAILED, EXIT_NEEDS_SERVICE, EXIT_USAGE, Failure, Report};

/// How to start the service; part of every "not running" message.
const HOW_TO_START: &str = "Start it with: systemctl --user start scriptwidget.service (or run: scriptwidget host run)";

pub fn needs_service(command: &str) -> Failure {
    Failure::new(EXIT_NEEDS_SERVICE, "service.unavailable", format!("scriptwidget {command} needs the background service, which is not running. {HOW_TO_START}"))
}

/// The service's socket in this session. Without a runtime directory there is no session and so no service.
fn socket(command: &str) -> Result<PathBuf, Failure> {
    RuntimePaths::from_environment().map(|paths| paths.socket()).map_err(|_| needs_service(command))
}

fn failure_of(command: &str, error: ClientError) -> Failure {
    match error {
        ClientError::NotRunning => needs_service(command),
        ClientError::Lost => Failure::new(EXIT_NEEDS_SERVICE, "service.lost", format!("The background service did not answer scriptwidget {command}.")),
        ClientError::Refused { code, message } => {
            // What a package did is the package's fault; everything else is how the command was used.
            let exit = if matches!(code.as_str(), "link.refused" | "family.unsupported") { EXIT_FAILED } else { EXIT_USAGE };
            Failure::new(exit, &code, message)
        }
    }
}

/// Checks the request here, sends it, and returns the service's answer.
fn ask(command: &str, request: Request) -> Result<Value, Failure> {
    let request = request.checked().map_err(|refusal| Failure::usage(refusal.message))?;
    client::request(&socket(command)?, &request).map_err(|error| failure_of(command, error))
}

/// The report of a command: the members of the service's answer.
fn report(command: &str, answer: Value) -> Report {
    let mut report = Report::new(command);
    if let Value::Object(members) = answer {
        for (name, value) in members {
            if name != "ok" {
                report.set(&name, value);
            }
        }
    }
    report
}

fn shape(minimum: usize, maximum: usize, positionals: &'static str) -> Shape {
    Shape { values: &[], flags: &[], minimum_positionals: minimum, maximum_positionals: maximum, positionals }
}

fn identifier(text: &str) -> Result<String, Failure> {
    if protocol::is_identifier(text) { Ok(text.to_owned()) } else { Err(Failure::usage(format!("{text} is not a widget identifier; scriptwidget widgets lists them"))) }
}

fn integer(text: &str, what: &str) -> Result<i64, Failure> {
    text.parse::<i64>().map_err(|_| Failure::usage(format!("{what} must be a whole number, not {text}")))
}

/// A position in logical pixels. A display may compute half a pixel; it is rounded to a whole one.
fn coordinate(text: &str, what: &str) -> Result<i64, Failure> {
    let plain = !text.is_empty() && text.len() <= 16 && text.bytes().enumerate().all(|(index, byte)| byte.is_ascii_digit() || byte == b'.' || (index == 0 && byte == b'-'));
    text.parse::<f64>().ok().filter(|value| plain && value.is_finite()).map(|value| value.round() as i64).ok_or_else(|| Failure::usage(format!("{what} must be a number, not {text}")))
}

pub fn add(command: &str, arguments: &[String]) -> Result<Report, Failure> {
    let arguments = Arguments::parse(arguments, &Shape { values: &["family"], flags: &[], minimum_positionals: 1, maximum_positionals: 1, positionals: "the name of an installed package" })?;
    let request = Request::Add { package: arguments.positional(0).unwrap_or_default().to_owned(), family: arguments.value("family").map(str::to_owned) };
    Ok(report(command, ask(command, request)?))
}

pub fn remove(command: &str, arguments: &[String]) -> Result<Report, Failure> {
    let arguments = Arguments::parse(arguments, &shape(1, 1, "a widget identifier"))?;
    Ok(report(command, ask(command, Request::Remove { id: identifier(arguments.positional(0).unwrap_or_default())? })?))
}

pub fn widgets(command: &str, arguments: &[String]) -> Result<Report, Failure> {
    Arguments::parse(arguments, &shape(0, 0, ""))?;
    Ok(report(command, ask(command, Request::Widgets)?))
}

pub fn refresh(command: &str, arguments: &[String]) -> Result<Report, Failure> {
    let arguments = Arguments::parse(arguments, &Shape { values: &["package"], flags: &[], minimum_positionals: 0, maximum_positionals: 1, positionals: "at most one widget identifier" })?;
    let id = arguments.positional(0).map(identifier).transpose()?;
    Ok(report(command, ask(command, Request::Refresh { id, package: arguments.value("package").map(str::to_owned) })?))
}

pub fn switch(command: &str, arguments: &[String]) -> Result<Report, Failure> {
    let arguments = Arguments::parse(arguments, &shape(0, 1, "on, off or toggle"))?;
    let switch = Switch::parse(arguments.positional(0).unwrap_or("toggle")).ok_or_else(|| Failure::usage("Use on, off or toggle"))?;
    Ok(report(command, ask(command, if command == "peek" { Request::Peek(switch) } else { Request::Arrange(switch) })?))
}

pub fn tap(command: &str, arguments: &[String]) -> Result<Report, Failure> {
    let arguments = Arguments::parse(arguments, &shape(2, 3, "a widget identifier, a region number and, optionally, the version of the picture"))?;
    let number = |index: usize, what: &str| integer(arguments.positional(index).unwrap_or_default(), what);
    let n = u32::try_from(number(1, "The region number")?).map_err(|_| Failure::usage("The region number must not be negative"))?;
    let version = if arguments.positional(2).is_some() { Some(u64::try_from(number(2, "The version")?).map_err(|_| Failure::usage("The version must not be negative"))?) } else { None };
    Ok(report(command, ask(command, Request::Tap { id: identifier(arguments.positional(0).unwrap_or_default())?, n, version })?))
}

pub fn move_widget(command: &str, arguments: &[String]) -> Result<Report, Failure> {
    let arguments = Arguments::parse(arguments, &shape(4, 4, "a widget identifier, a screen name, x and y"))?;
    let request = Request::Move {
        id: identifier(arguments.positional(0).unwrap_or_default())?,
        screen: arguments.positional(1).unwrap_or_default().to_owned(),
        x: coordinate(arguments.positional(2).unwrap_or_default(), "x")?,
        y: coordinate(arguments.positional(3).unwrap_or_default(), "y")?,
    };
    Ok(report(command, ask(command, request)?))
}

pub fn screen(command: &str, arguments: &[String]) -> Result<Report, Failure> {
    let arguments = Arguments::parse(arguments, &shape(4, 4, "a screen name, its scale, width and height"))?;
    let scale = arguments.positional(1).unwrap_or_default();
    let request = Request::Screen {
        name: arguments.positional(0).unwrap_or_default().to_owned(),
        scale: protocol::scale_thousandths(scale).ok_or_else(|| Failure::usage(format!("The scale must be a number such as 1, 1.5 or 2, not {scale}")))?,
        width: integer(arguments.positional(2).unwrap_or_default(), "The width")?,
        height: integer(arguments.positional(3).unwrap_or_default(), "The height")?,
    };
    Ok(report(command, ask(command, request)?))
}

pub fn theme(command: &str, arguments: &[String]) -> Result<Report, Failure> {
    let arguments = Arguments::parse(arguments, &shape(1, 1, "dark or light"))?;
    let dark = match arguments.positional(0) {
        Some("dark") => true,
        Some("light") => false,
        _ => return Err(Failure::usage("Use dark or light")),
    };
    Ok(report(command, ask(command, Request::Theme { dark })?))
}

pub fn menu(command: &str, arguments: &[String]) -> Result<Report, Failure> {
    let arguments = Arguments::parse(arguments, &shape(2, 2, "a widget identifier and a menu word"))?;
    let word = arguments.positional(1).unwrap_or_default();
    if !protocol::MENU_WORDS.contains(&word) {
        return Err(Failure::usage(format!("The menu word must be one of: {}", protocol::MENU_WORDS.join(", "))));
    }
    Ok(report(command, ask(command, Request::Menu { id: identifier(arguments.positional(0).unwrap_or_default())?, word: word.to_owned() })?))
}

pub fn session(command: &str, arguments: &[String]) -> Result<Report, Failure> {
    let arguments = Arguments::parse(arguments, &shape(1, 1, "locked or unlocked"))?;
    let locked = match arguments.positional(0) {
        Some("locked") => true,
        Some("unlocked") => false,
        _ => return Err(Failure::usage("Use locked or unlocked")),
    };
    Ok(report(command, ask(command, Request::Session { locked })?))
}

/// What `doctor` says about the service: its status when it runs, `None` when it does not.
pub fn status() -> Result<Option<Value>, Failure> {
    let Ok(socket) = socket("doctor") else { return Ok(None) };
    match client::request(&socket, &Request::Status) {
        Ok(status) => Ok(Some(status)),
        Err(ClientError::NotRunning) => Ok(None),
        Err(error) => Err(failure_of("doctor", error)),
    }
}

// Commands whose output is read line by line

fn print_line(line: &str) -> bool {
    let mut output = std::io::stdout().lock();
    writeln!(output, "{line}").and_then(|()| output.flush()).is_ok()
}

fn fail(command: &str, failure: &Failure) -> i32 {
    Report::from_failure(command, failure).finish()
}

/// `watch`, `dev` and `host`: the exit code when `command` is one of them.
pub fn stream(command: &str, arguments: &[String]) -> Option<i32> {
    match command {
        "watch" => Some(watch(command, arguments)),
        "dev" => Some(dev(command, arguments).unwrap_or_else(|failure| fail(command, &failure))),
        "host" => Some(host(command, arguments)),
        _ => None,
    }
}

/// Prints the display events, one JSON object a line, until the service
/// says `bye` or the connection ends. The last line is always a `bye`: the
/// service's own, or one this command writes with the reason `not-running`
/// (there was no service) or `lost` (the connection ended without one).
fn watch(command: &str, arguments: &[String]) -> i32 {
    if let Err(failure) = Arguments::parse(arguments, &shape(0, 0, "")) {
        return fail(command, &failure);
    }
    let end = match socket(command) {
        Ok(socket) => client::watch(&socket, print_line),
        Err(_) => WatchEnd::NotRunning,
    };
    match end {
        WatchEnd::Bye | WatchEnd::Stopped => 0,
        WatchEnd::NotRunning => {
            print_line(&protocol::bye("not-running").to_string());
            eprintln!("error: [service.unavailable] {}", needs_service(command).message);
            EXIT_NEEDS_SERVICE
        }
        WatchEnd::Lost => {
            print_line(&protocol::bye("lost").to_string());
            eprintln!("error: [service.lost] The connection to the background service ended.");
            EXIT_NEEDS_SERVICE
        }
    }
}

/// `scriptwidget host run`: the background service. It prints nothing on
/// standard output; what it has to say goes to standard error, for the journal.
fn host(command: &str, arguments: &[String]) -> i32 {
    let parsed = match Arguments::parse(arguments, &Shape { values: &["data"], flags: &[], minimum_positionals: 1, maximum_positionals: 1, positionals: "run" }) {
        Ok(parsed) => parsed,
        Err(failure) => return fail(command, &failure),
    };
    if parsed.positional(0) != Some("run") {
        return fail(command, &Failure::usage("Use: scriptwidget host run"));
    }
    service::run_process(parsed.value("data").map(Path::new))
}

// dev

/// The dot-file in an installed package that says which folder `dev` copies into it. Listings and exports skip dot-files.
const DEV_MARKER: &str = ".scriptwidget-dev";
const POLL: Duration = Duration::from_millis(400);
/// A folder with more entries than this is not watched.
const MAXIMUM_WATCHED: usize = 4000;

/// Path, modification time and size of every file below `directory` that
/// can be part of a package. Links are not followed.
fn snapshot(directory: &Path) -> BTreeMap<String, (Option<SystemTime>, u64)> {
    fn walk(directory: &Path, prefix: &str, depth: usize, found: &mut BTreeMap<String, (Option<SystemTime>, u64)>) {
        let Ok(entries) = std::fs::read_dir(directory) else { return };
        for entry in entries.flatten() {
            let Ok(name) = entry.file_name().into_string() else { continue };
            if path_rules::is_excluded(&name) || found.len() >= MAXIMUM_WATCHED {
                continue;
            }
            let Ok(metadata) = std::fs::symlink_metadata(entry.path()) else { continue };
            let path = if prefix.is_empty() { name } else { format!("{prefix}/{name}") };
            if metadata.is_dir() {
                if depth < MAX_PATH_DEPTH {
                    walk(&entry.path(), &path, depth + 1, found);
                }
            } else {
                found.insert(path, (metadata.modified().ok(), metadata.len()));
            }
        }
    }
    let mut found = BTreeMap::new();
    walk(directory, "", 1, &mut found);
    found
}

fn read_marker(installed: &InstalledPackage) -> Option<String> {
    use std::io::Read;
    let file = std::fs::OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK).open(installed.directory.join(DEV_MARKER)).ok()?;
    let mut text = String::new();
    file.take(8192).read_to_string(&mut text).ok()?;
    Some(text)
}

fn write_marker(installed: &InstalledPackage, source: &Path) {
    let marker = installed.directory.join(DEV_MARKER);
    let _ = std::fs::remove_file(&marker);
    if let Ok(mut file) = std::fs::OpenOptions::new().write(true).create_new(true).custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC).mode(0o600).open(&marker) {
        let _ = file.write_all(source.display().to_string().as_bytes());
    }
}

struct Developed {
    library: Library,
    source: PathBuf,
    /// The name of the installed package the folder is copied into.
    name: String,
}

impl Developed {
    /// Makes the installed package hold exactly the files of the folder.
    /// The folder is verified as a whole first; every write and removal goes
    /// through the package store. Returns the paths written and removed.
    fn sync(&self) -> Result<(Vec<String>, Vec<String>), Failure> {
        packages::validate_source_tree(&self.source, &ArchiveLimits::default())?;
        let source = DiskPackageFiles::new(&self.source);
        let paths = source.list()?;
        let installed = self.library.find(&self.name).ok_or_else(|| PackageError::new(codes::PACKAGE_NOT_FOUND, "The installed package is gone."))?;
        let target = DiskPackageFiles::new(&installed.directory);
        let mut written = Vec::new();
        for path in &paths {
            let bytes = source.read_bytes_up_to(path, MAX_FILE_BYTES).ok_or_else(|| PackageError::new(codes::FILE_NOT_FOUND, format!("{path} cannot be read.")))?;
            if target.read_bytes_up_to(path, MAX_FILE_BYTES).as_deref() != Some(&bytes[..]) {
                self.library.write_file(&self.name, path, &bytes)?;
                written.push(path.clone());
            }
        }
        let mut removed = Vec::new();
        for path in target.list()? {
            if !paths.contains(&path) {
                self.library.delete_file(&self.name, &path)?;
                removed.push(path);
            }
        }
        Ok((written, removed))
    }
}

/// Finds or creates the installed package a folder is developed into.
fn develop(library: Library, source: PathBuf, adopt: bool) -> Result<(Developed, InstalledPackage), Failure> {
    packages::validate_source_tree(&source, &ArchiveLimits::default())?;
    let files = DiskPackageFiles::new(&source);
    // A present manifest is authoritative: unreadable is an error, never "legacy".
    let manifest_text = if packages::manifest_present(&source)? {
        let invalid = || Failure::new(EXIT_FAILED, codes::INVALID_MANIFEST, "widget.json is invalid.");
        let text = files.read_bytes_up_to(manifests::FILE_NAME, MAX_METADATA_BYTES as u64).and_then(|bytes| String::from_utf8(bytes).ok()).ok_or_else(invalid)?;
        manifests::parse(Some(&text)).ok_or_else(invalid)?;
        Some(text)
    } else {
        None
    };
    let manifest = manifests::parse(manifest_text.as_deref());
    let name = archive_name(&source, manifest.as_ref());
    let canonical = std::fs::canonicalize(&source).unwrap_or_else(|_| source.clone());
    let installed = match library.find(&name) {
        Some(installed) => {
            let ours = read_marker(&installed).is_some_and(|marker| Path::new(&marker) == canonical);
            if !ours && !adopt {
                return Err(Failure::new(
                    EXIT_FAILED,
                    "dev.package_exists",
                    format!("A package named {} is already installed and does not come from this folder. Pass --adopt to replace its files with the folder's, or rename the folder.", installed.name),
                ));
            }
            installed
        }
        None => {
            let entry = manifest.as_ref().and_then(|manifest| manifests::string_value(manifest, "entry")).unwrap_or_else(|| manifests::LEGACY_ENTRY.to_owned());
            let main = files.read_bytes_up_to(&entry, MAX_FILE_BYTES).and_then(|bytes| String::from_utf8(bytes).ok()).ok_or_else(|| PackageError::new(codes::MISSING_ENTRY, format!("The folder has no {entry}.")))?;
            library.create(&name, &main, manifest_text.as_deref())?
        }
    };
    write_marker(&installed, &canonical);
    Ok((Developed { library, source, name: installed.name.clone() }, installed))
}

/// Copies a package folder into the library whenever a file in it changes,
/// and asks the service to run the widgets of that package again. The folder
/// is looked at a few times a second, in this command; the service is not
/// told a path and watches nothing.
fn dev(command: &str, arguments: &[String]) -> Result<i32, Failure> {
    let arguments = Arguments::parse(arguments, &Shape { values: &["family", "data"], flags: &["adopt"], minimum_positionals: 1, maximum_positionals: 1, positionals: "a package folder" })?;
    let source = package_directory(arguments.positional(0).unwrap_or_default())?;
    let family = arguments.value("family").map(str::to_owned);
    if family.as_deref().is_some_and(|family| !protocol::is_family(family)) {
        return Err(Failure::usage("Unknown family: use small, medium, large or extraLarge"));
    }
    // Nothing is copied when there is no service to show it.
    ask(command, Request::Status)?;
    let library = Library::new(&user_data(&arguments)?, resources().ok().and_then(|resources| resources.templates));
    let (developed, installed) = develop(library, source, arguments.flag("adopt"))?;
    developed.sync()?;

    // A widget of this package on the desktop, placed now when there is none.
    let placed = |answer: &Value| -> Vec<Value> { answer["widgets"].as_array().into_iter().flatten().filter(|widget| widget["installation"] == installed.installation.as_str()).map(|widget| widget["id"].clone()).collect() };
    let mut widgets = placed(&ask(command, Request::Widgets)?);
    let added = widgets.is_empty();
    if added {
        widgets.push(ask(command, Request::Add { package: developed.name.clone(), family })?["id"].clone());
    } else {
        ask(command, Request::Refresh { id: None, package: Some(developed.name.clone()) })?;
    }
    if !print_line(&json!({ "event": "ready", "package": developed.name, "installation": installed.installation, "widgets": widgets, "added": added }).to_string()) {
        return Ok(0);
    }

    let mut seen = snapshot(&developed.source);
    loop {
        std::thread::sleep(POLL);
        let now = snapshot(&developed.source);
        if now == seen {
            continue;
        }
        // An editor writes a file in several steps: wait until the folder holds still.
        let mut settled = now;
        loop {
            std::thread::sleep(Duration::from_millis(100));
            let again = snapshot(&developed.source);
            if again == settled {
                break;
            }
            settled = again;
        }
        seen = settled;
        let line = match developed.sync() {
            Ok((written, removed)) if written.is_empty() && removed.is_empty() => continue,
            Ok((written, removed)) => match ask(command, Request::Refresh { id: None, package: Some(developed.name.clone()) }) {
                Ok(answer) => json!({ "event": "synced", "package": developed.name, "written": written, "removed": removed, "refreshed": answer["refreshed"] }),
                Err(failure) if failure.exit == EXIT_NEEDS_SERVICE => {
                    print_line(&protocol::bye("not-running").to_string());
                    eprintln!("error: [{}] {}", failure.code, failure.message);
                    return Ok(EXIT_NEEDS_SERVICE);
                }
                Err(failure) => json!({ "event": "error", "code": failure.code, "message": failure.message }),
            },
            // The folder is wrong for the moment (a link, a file too large): say so and keep watching.
            Err(failure) => json!({ "event": "error", "code": failure.code, "message": failure.message }),
        };
        if !print_line(&line.to_string()) {
            return Ok(0);
        }
    }
}
