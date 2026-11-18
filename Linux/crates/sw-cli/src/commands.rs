//! The commands. Each one returns its report, or the failure that stopped it
//! before it had one. Ported from `Windows/src/ScriptWidget.Cli/Program.cs`;
//! the report envelope and the output rules follow the Mac command line
//! (`Tools/ScriptWidgetCLI`).
//!
//! Everything a command is pointed at is untrusted: a package folder is
//! verified as a whole before anything in it is compiled, a present manifest
//! that cannot be read fails the command, and archives go through the
//! package store's preflight and staging.

use std::cell::RefCell;
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use sw_core::compiler::PrepareOptions;
use sw_core::json::ObjectExt;
use sw_core::library::{FAMILIES, Library};
use sw_core::packages::limits::{MAX_FILE_BYTES, MAX_METADATA_BYTES};
use sw_core::packages::{self, ArchiveLimits, DiskPackageFiles, PackageError, codes, manifests, names, path_rules};
use sw_core::{DataPaths, MemoryPackageFiles, PackageCompiler, PackageFiles, Resources, RunRequest, RunResult, SharedScripts, TimelinePlanner, WidgetRuntime};
use sw_render::{Presentation, RenderOutput, WidgetRenderer};

use crate::arguments::{Arguments, Shape};
use crate::output;
use crate::report::{EXIT_FAILED, Failure, Report};

pub const USAGE: &str = "\
Usage: scriptwidget <command> [options]

Package commands (take a package folder):
  new <name> [--template <group/name>] [--directory <folder>]
                                      Create a package folder from the starter or a bundled template.
  check <dir>                         Check widget.json and compile the package; nothing is executed.
  run <dir> [options]                 Run the script and print the element tree, logs and errors.
  render <dir> --output <png> [opts]  Run the script and draw the widget to a PNG file.
  timeline <dir> [--now <ms>]         Print the current timeline slot and the next transition.
  pack <dir> [--output <file.swt>] [--force]
                                      Write the package as a .swt archive (default: <name>.swt here).

Options for run and render:
  --family <name>      small, medium, large or extraLarge (default medium)
  --param <text>       value of $getenv(\"widget-param\")
  --dark               run and draw in the dark theme (also --appearance dark)
  --scale <n>          pixels per point for render, 0.5 to 8 (default 2)
  --now <ms>           fixed clock for dates in render (milliseconds since 1970)
  --data <dir>         data folder for storage and caches (default: a temporary folder)
  --fail-on-warning    exit 1 when a warning was reported (check, run, render)

Library commands (use your data folder, or --data <dir>):
  install <file.swt | dir>            Install an archive or a package folder into the library.
  list                                List installed packages.
  templates                           List the bundled templates that run on Linux.
  doctor                              Check this installation.

Desktop commands (need the background service):
  add <package> [--family <name>]     Put a widget of an installed package on the desktop.
  remove <id>                         Take a widget off the desktop.
  widgets                             List the widgets on the desktop.
  refresh [<id>] [--package <name>]   Run one widget, the widgets of a package, or all of them again.
  dev <dir> [--family <name>] [--adopt]
                                      Copy a package folder into the library whenever it changes and
                                      refresh its widgets; prints one JSON line each time.
  peek [on|off|toggle]                Raise the widgets above the windows, or put them back.
  arrange [on|off|toggle]             Turn arrange mode on or off.

For the display (see docs/linux/protocol.md):
  watch                               Print the display events, one JSON object a line.
  tap <id> <n> [<version>]            Region n of a widget was tapped.
  move <id> <screen> <x> <y>          A widget was dragged to a new place.
  screen <name> <scale> <width> <height>
                                      A screen's name, scale and logical size.
  theme <dark|light>                  The theme of the desktop.
  menu <id> <word>                    resize-small, resize-medium, resize-large, resize-extraLarge,
                                      edit, remove or refresh.
  session <locked|unlocked>           The session was locked or unlocked.

The background service:
  host run                            Run the service in this session until it is told to stop.
                                      Usually started by systemd: systemctl --user start scriptwidget.service

Every command except watch, dev and host prints one JSON report on standard
output; errors and warnings also go to standard error. Exit codes: 0 passed,
1 the package is at fault, 2 usage or environment, 3 internal error,
69 the background service is not running.
";

// What every command needs

pub(crate) fn resources() -> Result<Resources, Failure> {
    Resources::locate().map_err(|error| Failure::environment("tool.resources_missing", error.to_string()))
}

fn shared_scripts(resources: &Resources) -> Result<Arc<SharedScripts>, Failure> {
    SharedScripts::new(&resources.runtime).map(Arc::new).map_err(|error| Failure::environment("tool.resources_missing", error.to_string()))
}

fn compiler(scripts: &Arc<SharedScripts>) -> Result<PackageCompiler, Failure> {
    PackageCompiler::new(scripts.clone()).map_err(|error| Failure::internal(format!("The compiler could not be started: {error}")))
}

fn runtime(scripts: &Arc<SharedScripts>, paths: &DataPaths) -> Result<WidgetRuntime, Failure> {
    WidgetRuntime::new(scripts.clone(), paths).map_err(|error| Failure::internal(format!("The runtime could not be started: {error}")))
}

/// The data folder of the user, or the one `--data` names.
pub(crate) fn user_data(arguments: &Arguments) -> Result<DataPaths, Failure> {
    DataPaths::new(arguments.value("data").map(Path::new)).map_err(|error| Failure::environment("tool.data_directory", format!("The data folder cannot be used: {error}")))
}

/// Where a run keeps `$storage` and caches: the folder `--data` names, or a private temporary one that is removed afterwards.
struct RunData {
    paths: DataPaths,
    temporary: Option<PathBuf>,
}

impl RunData {
    fn new(arguments: &Arguments) -> Result<Self, Failure> {
        if arguments.value("data").is_some() {
            return Ok(Self { paths: user_data(arguments)?, temporary: None });
        }
        let unusable = |error: std::io::Error| Failure::environment("tool.data_directory", format!("No temporary data folder could be created: {error}"));
        let mut token = [0u8; 12];
        getrandom::fill(&mut token).map_err(|error| Failure::internal(format!("No random source: {error}")))?;
        let directory = std::env::temp_dir().join(format!("scriptwidget-cli-{}", hex(&token)));
        // Created exclusively and private: nobody else can have put anything at this name.
        std::os::unix::fs::DirBuilderExt::mode(&mut std::fs::DirBuilder::new(), 0o700).create(&directory).map_err(unusable)?;
        let data = Self { paths: DataPaths::at(&directory).map_err(unusable)?, temporary: Some(directory) };
        DataPaths::new(Some(data.paths.root())).map_err(unusable)?;
        Ok(data)
    }
}

impl Drop for RunData {
    fn drop(&mut self) {
        if let Some(directory) = &self.temporary {
            let _ = std::fs::remove_dir_all(directory);
        }
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn round(value: f64, digits: i32) -> f64 {
    let factor = 10f64.powi(digits);
    (value * factor).round() / factor
}

// The package stage

/// The absolute path of a package folder the user named. It must be a directory itself, not a link to one.
pub(crate) fn package_directory(text: &str) -> Result<PathBuf, Failure> {
    let directory = std::path::absolute(Path::new(text)).unwrap_or_else(|_| PathBuf::from(text));
    match std::fs::symlink_metadata(&directory) {
        Ok(metadata) if metadata.is_dir() => Ok(directory),
        _ => Err(Failure::environment("input.directory", format!("Not a package folder: {} (it must be an existing directory, not a symbolic link)", directory.display()))),
    }
}

struct Inspected {
    files: Arc<DiskPackageFiles>,
    /// The parsed manifest, when the package has one.
    manifest: Option<sw_core::json::Object>,
}

/// `ScriptWidgetSource/v1`, the fingerprint the Mac command line and Web Studio report for the same files.
fn source_hash(files: &DiskPackageFiles, paths: &[String]) -> Option<String> {
    let mut digest = Sha256::new();
    digest.update(b"ScriptWidgetSource/v1\n");
    digest.update((paths.len() as u64).to_be_bytes());
    for path in paths {
        let bytes = files.read_bytes_up_to(path, MAX_FILE_BYTES)?;
        digest.update((path.len() as u64).to_be_bytes());
        digest.update(path.as_bytes());
        digest.update((bytes.len() as u64).to_be_bytes());
        digest.update(&bytes);
    }
    Some(hex(&digest.finalize()))
}

/// Verifies the folder as a whole and validates its manifest; nothing is compiled or executed.
fn inspect(report: &mut Report, directory: &Path, compiler: &PackageCompiler) -> Result<Inspected, Failure> {
    report.set("package", json!(directory.display().to_string()));
    packages::validate_source_tree(directory, &ArchiveLimits::default())?;
    let has_manifest = packages::manifest_present(directory)?;
    let files = DiskPackageFiles::new(directory);
    let paths = files.list()?;
    if let Some(hash) = source_hash(&files, &paths) {
        report.set("sourceHash", json!(hash));
        report.set("sourceHashAlgorithm", json!("ScriptWidgetSource/v1"));
    }
    if !has_manifest {
        report.set("manifest", Value::Null);
        if !files.exists(manifests::LEGACY_ENTRY) {
            return Err(PackageError::new(codes::MISSING_ENTRY, "The folder has neither widget.json nor main.jsx.").into());
        }
        return Ok(Inspected { files: Arc::new(files), manifest: None });
    }
    // A present manifest is authoritative: unreadable is an error, never "legacy".
    let invalid = || Failure::new(EXIT_FAILED, codes::INVALID_MANIFEST, "widget.json is invalid.");
    let text = files.read_bytes_up_to(manifests::FILE_NAME, MAX_METADATA_BYTES as u64).and_then(|bytes| String::from_utf8(bytes).ok()).ok_or_else(invalid)?;
    let validation = compiler.validate_manifest(&text, &paths).map_err(|error| Failure::internal(format!("The manifest validator failed: {error}")))?;
    report.diagnostics(validation.opt_array("issues").cloned().unwrap_or_default());
    let valid = validation.opt_bool("ok", false);
    let first_error = validation.opt_array("issues").and_then(|issues| issues.iter().filter_map(Value::as_object).find(|issue| issue.opt_string("severity") == "error").cloned());
    let manifest = validation.opt_object("manifest").cloned();
    // What the decoder said when the text is not a manifest at all (not JSON, unknown fields, a wrong type).
    let undecodable = validation.opt_string_or_none("error").filter(|message| !message.is_empty());
    report.set("manifest", Value::Object(validation));
    if !valid {
        return Err(match (first_error, undecodable) {
            // The issue itself is already among the diagnostics.
            (Some(issue), _) => Failure::new(EXIT_FAILED, codes::INVALID_MANIFEST, format!("widget.json is invalid: [{}] {}", issue.opt_string("code"), issue.opt_string("message"))),
            (None, Some(message)) => Failure::new(EXIT_FAILED, codes::INVALID_MANIFEST, message),
            (None, None) => invalid(),
        });
    }
    Ok(Inspected { files: Arc::new(files), manifest: Some(manifest.ok_or_else(invalid)?) })
}

/// Runs one stage of a package command and records how it went. `None` means the report now carries the failure.
fn stage<T>(report: &mut Report, name: &str, work: impl FnOnce(&mut Report) -> Result<T, Failure>) -> Option<T> {
    match work(report) {
        Ok(value) => {
            report.check(name, true);
            Some(value)
        }
        Err(failure) => {
            report.check(name, false);
            report.absorb(&failure);
            None
        }
    }
}

fn finish_warnings(report: &mut Report, arguments: &Arguments) {
    if arguments.flag("fail-on-warning") {
        report.fail_on_warnings();
    }
}

// check

pub fn check(command: &str, arguments: &[String]) -> Result<Report, Failure> {
    let arguments = Arguments::parse(arguments, &Shape { values: &[], flags: &["fail-on-warning"], minimum_positionals: 1, maximum_positionals: 1, positionals: "a package folder" })?;
    let directory = package_directory(arguments.positional(0).unwrap_or_default())?;
    let scripts = shared_scripts(&resources()?)?;
    let compiler = compiler(&scripts)?;
    let mut report = Report::with_stages(command, "static");
    let Some(inspected) = stage(&mut report, "package", |report| inspect(report, &directory, &compiler)) else { return Ok(report) };
    stage(&mut report, "compile", |_| compiler.prepare(inspected.files.as_ref(), &PrepareOptions::default()).map(|_| ()).map_err(|error| Failure::new(EXIT_FAILED, &error.kind, error.message)));
    finish_warnings(&mut report, &arguments);
    Ok(report)
}

// run and render

const RUN_VALUES: [&str; 4] = ["family", "param", "appearance", "data"];
const RUN_FLAGS: [&str; 2] = ["dark", "fail-on-warning"];

fn run_request(arguments: &Arguments, files: Arc<DiskPackageFiles>, directory: &Path) -> Result<RunRequest, Failure> {
    let family = arguments.value("family").unwrap_or("medium");
    if !FAMILIES.contains(&family) {
        return Err(Failure::usage(format!("Unknown family {family}: use small, medium, large or extraLarge")));
    }
    let dark = match arguments.value("appearance") {
        None | Some("light") => false,
        Some("dark") => true,
        Some(other) => return Err(Failure::usage(format!("--appearance must be light or dark, not {other}: one run draws one picture"))),
    };
    let mut request = RunRequest::new(files, format!("cli:{}", directory.display()));
    request.family = family.to_owned();
    request.parameter = arguments.value("param").unwrap_or_default().to_owned();
    request.dark_mode = dark || arguments.flag("dark");
    Ok(request)
}

/// The members of a run that `run` and `render` share, and the stage results.
fn describe(report: &mut Report, result: &RunResult) {
    let execution = &result.execution;
    report.set("elapsedMilliseconds", json!(round(execution.elapsed.as_secs_f64() * 1000.0, 2)));
    report.set("logs", execution.logs.iter().map(|entry| json!({ "level": entry.level, "message": entry.message })).collect());
    report.diagnostics(execution.diagnostics.iter().cloned());
    report.set("nextTimelineTransition", json!(result.next_timeline_transition));
    let failed_stage = if result.prepared.is_none() { "compile" } else { "execute" };
    if failed_stage == "execute" {
        report.check("compile", true);
    }
    match &execution.error {
        Some(error) => {
            report.check(failed_stage, false);
            report.fail(EXIT_FAILED, &error.kind, &error.message);
        }
        None => report.check("execute", true),
    }
}

/// The tree as JSON. It nests deeper than serde_json reads by default; its depth is bounded by the runtime contract.
fn parse_tree(text: &str) -> Value {
    let mut deserializer = serde_json::Deserializer::from_str(text);
    deserializer.disable_recursion_limit();
    serde::Deserialize::deserialize(&mut deserializer).unwrap_or(Value::Null)
}

struct Started {
    report: Report,
    arguments: Arguments,
    scripts: Arc<SharedScripts>,
    runtime: WidgetRuntime,
    /// `None` when the package stage failed; the report says why.
    run: Option<(RunRequest, RunResult)>,
    _data: RunData,
}

fn start(command: &str, arguments: Arguments, before_running: impl FnOnce(&Path) -> Result<(), Failure>) -> Result<Started, Failure> {
    let directory = package_directory(arguments.positional(0).unwrap_or_default())?;
    // Reject a wrong family or appearance before anything runs.
    run_request(&arguments, Arc::new(DiskPackageFiles::new(&directory)), &directory)?;
    before_running(&directory)?;
    let scripts = shared_scripts(&resources()?)?;
    let data = RunData::new(&arguments)?;
    let runtime = runtime(&scripts, &data.paths)?;
    let mut report = Report::with_stages(command, "linux-native");
    let inspected = stage(&mut report, "package", |report| inspect(report, &directory, runtime.compiler()));
    let run = match inspected {
        Some(inspected) => {
            let request = run_request(&arguments, inspected.files, &directory)?;
            let result = runtime.run(&request);
            describe(&mut report, &result);
            Some((request, result))
        }
        None => None,
    };
    Ok(Started { report, arguments, scripts, runtime, run, _data: data })
}

pub fn run(command: &str, arguments: &[String]) -> Result<Report, Failure> {
    let arguments = Arguments::parse(arguments, &Shape { values: &RUN_VALUES, flags: &RUN_FLAGS, minimum_positionals: 1, maximum_positionals: 1, positionals: "a package folder" })?;
    let mut started = start(command, arguments, |_| Ok(()))?;
    if let Some((_, result)) = &started.run {
        started.report.set("tree", result.execution.tree.as_deref().map_or(Value::Null, parse_tree));
    }
    finish_warnings(&mut started.report, &started.arguments);
    Ok(started.report)
}

/// How much of a bitmap shows something: the pixels that are not fully
/// transparent, and how many different colors there are (counted up to 256).
/// A picture with no visible pixel, or with one color only, is empty.
fn picture(output: &RenderOutput) -> Value {
    let mut colors = HashSet::new();
    let mut visible = 0u64;
    for pixel in output.pixels.chunks_exact(4) {
        if pixel[3] != 0 {
            visible += 1;
        }
        if colors.len() < 256 {
            colors.insert([pixel[0], pixel[1], pixel[2], pixel[3]]);
        }
    }
    json!({ "visiblePixels": visible, "colors": colors.len() })
}

pub fn render(command: &str, arguments: &[String]) -> Result<Report, Failure> {
    const VALUES: [&str; 7] = ["family", "param", "appearance", "data", "output", "scale", "now"];
    let arguments = Arguments::parse(arguments, &Shape { values: &VALUES, flags: &RUN_FLAGS, minimum_positionals: 1, maximum_positionals: 1, positionals: "a package folder" })?;
    let target = output::resolve(arguments.value("output").ok_or_else(|| Failure::usage("render needs --output <png>"))?)?;
    let scale = arguments.value("scale").unwrap_or("2").parse::<f32>().ok().filter(|scale| (0.5..=8.0).contains(scale)).ok_or_else(|| Failure::usage("--scale must be between 0.5 and 8"))?;
    let now = arguments.value("now").map(|text| text.parse::<i64>().map_err(|_| Failure::usage("--now must be a whole number of milliseconds since 1970"))).transpose()?;
    let mut started = start(command, arguments, |directory| output::require_outside(&target, directory))?;
    let Some((request, result)) = &started.run else { return Ok(started.report) };
    let report = &mut started.report;

    let renderer = WidgetRenderer::new(started.scripts.clone()).map_err(|error| Failure::internal(format!("The renderer could not be started: {error}")))?;
    let mut presentation = Presentation::for_family(&request.family, scale).ok_or_else(|| Failure::usage(format!("Unknown family {}", request.family)))?;
    presentation.now_milliseconds = now;
    let drawn = sw_render::render_run(&renderer, &started.runtime, request, result, &presentation).and_then(|rendered| Ok((rendered.output.encode_png()?, rendered)));
    let (png, rendered) = match drawn {
        Ok(drawn) => drawn,
        Err(error) => {
            report.check("render", false);
            report.absorb(&Failure::internal(format!("The widget could not be drawn: {error}")));
            return Ok(started.report);
        }
    };
    match &rendered.failure {
        // The picture shows a card with the reason instead of the widget.
        Some(failure) => {
            report.check("render", false);
            report.fail(EXIT_FAILED, "internalError", &failure.message);
        }
        // After a script error the picture is the error card; the widget itself was not drawn.
        None if result.execution.error.is_none() => report.check("render", true),
        None => {}
    }
    output::write(&target, &png, true)?;

    let output = &rendered.output;
    report.set("output", json!(target.display().to_string()));
    report.set("artifacts", json!([{ "path": target.display().to_string(), "sha256": hex(&Sha256::digest(&png)), "bytes": png.len() }]));
    report.set("family", json!(request.family));
    report.set("scale", json!(round(f64::from(output.scale), 4)));
    report.set("pixelWidth", json!(output.pixel_width));
    report.set("pixelHeight", json!(output.pixel_height));
    report.set("picture", picture(output));
    report.set("layoutMilliseconds", json!(round(output.layout_time.as_secs_f64() * 1000.0, 2)));
    report.set("paintMilliseconds", json!(round(output.paint_time.as_secs_f64() * 1000.0, 2)));
    report.set("renderDiagnostics", Value::Array(output.diagnostics.clone()));
    let regions: Vec<Value> = output
        .hit_regions
        .iter()
        .map(|region| {
            let bounds = &region.bounds;
            json!({
                "x": round(f64::from(bounds.left), 1), "y": round(f64::from(bounds.top), 1),
                "width": round(f64::from(bounds.width()), 1), "height": round(f64::from(bounds.height()), 1),
                "interaction": region.interaction,
            })
        })
        .collect();
    report.set("hitRegions", Value::Array(regions));
    report.set("animatedImages", json!(output.gif_slots.len()));
    finish_warnings(&mut started.report, &started.arguments);
    Ok(started.report)
}

// timeline

pub fn timeline(command: &str, arguments: &[String]) -> Result<Report, Failure> {
    let arguments = Arguments::parse(arguments, &Shape { values: &["now"], flags: &[], minimum_positionals: 1, maximum_positionals: 1, positionals: "a package folder" })?;
    let directory = package_directory(arguments.positional(0).unwrap_or_default())?;
    let now = arguments.value("now").map(|text| text.parse::<i64>().map_err(|_| Failure::usage("--now must be a whole number of milliseconds since 1970"))).transpose()?;
    let scripts = shared_scripts(&resources()?)?;
    let mut report = Report::new(command);
    report.set("package", json!(directory.display().to_string()));
    let manifest = (|| -> Result<Option<sw_core::json::Object>, Failure> {
        packages::validate_source_tree(&directory, &ArchiveLimits::default())?;
        if !packages::manifest_present(&directory)? {
            return Ok(None);
        }
        let text = DiskPackageFiles::new(&directory).read_bytes_up_to(manifests::FILE_NAME, MAX_METADATA_BYTES as u64).and_then(|bytes| String::from_utf8(bytes).ok());
        // A present manifest that cannot be read has no schedule to report; it is an error.
        manifests::parse(text.as_deref()).map(Some).ok_or_else(|| Failure::new(EXIT_FAILED, codes::INVALID_MANIFEST, "widget.json is invalid."))
    })();
    let manifest = match manifest {
        Ok(manifest) => manifest,
        Err(failure) => {
            report.absorb(&failure);
            return Ok(report);
        }
    };
    let planner = TimelinePlanner::new(scripts);
    let state = match now {
        Some(now) => planner.state_at(manifest.as_ref(), now),
        None => planner.state(manifest.as_ref()),
    };
    report.set("hasSchedule", json!(state.is_some()));
    report.set("environments", state.as_ref().map_or(Value::Null, |state| Value::Object(state.environments.iter().map(|(name, value)| (name.clone(), json!(value))).collect())));
    report.set("nextTransition", json!(state.and_then(|state| state.next_transition_milliseconds)));
    Ok(report)
}

// pack

/// The name of the archive's top-level folder: the folder's own name when it is a package name, else the manifest's.
pub(crate) fn archive_name(directory: &Path, manifest: Option<&sw_core::json::Object>) -> String {
    let folder = directory.file_name().and_then(|name| name.to_str()).filter(|name| names::is_valid(name)).map(str::to_owned);
    folder.or_else(|| manifest.and_then(|manifest| manifests::string_value(manifest, "name")).filter(|name| names::is_valid(name))).unwrap_or_else(|| "Widget".into())
}

pub fn pack(command: &str, arguments: &[String]) -> Result<Report, Failure> {
    let arguments = Arguments::parse(arguments, &Shape { values: &["output"], flags: &["force"], minimum_positionals: 1, maximum_positionals: 2, positionals: "a package folder and, optionally, the .swt file to write" })?;
    let directory = package_directory(arguments.positional(0).unwrap_or_default())?;
    let named = match (arguments.value("output"), arguments.positional(1)) {
        (Some(_), Some(_)) => return Err(Failure::usage("Name the output once: either --output or the second argument")),
        (first, second) => first.or(second),
    };
    let check_target = |target: &Path| {
        if target.extension().is_none_or(|extension| extension != "swt") {
            return Err(Failure::usage("The pack output must end in .swt"));
        }
        output::require_outside(target, &directory)?;
        if !arguments.flag("force") && std::fs::symlink_metadata(target).is_ok() {
            return Err(Failure::environment("output.exists", format!("{} exists; choose a new file or pass --force.", target.display())));
        }
        Ok(())
    };
    let named = named.map(output::resolve).transpose()?;
    if let Some(target) = &named {
        check_target(target)?;
    }
    let scripts = shared_scripts(&resources()?)?;
    let compiler = compiler(&scripts)?;
    let mut report = Report::with_stages(command, "static");
    let Some(inspected) = stage(&mut report, "package", |report| inspect(report, &directory, &compiler)) else { return Ok(report) };
    let compiled = stage(&mut report, "compile", |_| compiler.prepare(inspected.files.as_ref(), &PrepareOptions::default()).map(|_| ()).map_err(|error| Failure::new(EXIT_FAILED, &error.kind, error.message)));
    if compiled.is_none() {
        return Ok(report);
    }
    let name = archive_name(&directory, inspected.manifest.as_ref());
    let target = match named {
        Some(target) => target,
        None => {
            let target = output::resolve(&format!("{}.swt", names::archive_root_name(&name)))?;
            check_target(&target)?;
            target
        }
    };
    let exported = stage(&mut report, "export", |_| {
        let mut archive = Vec::new();
        packages::export_directory(&directory, &name, &mut archive, &ArchiveLimits::default())?;
        output::write(&target, &archive, arguments.flag("force"))?;
        Ok(archive)
    });
    if let Some(archive) = exported {
        report.set("name", json!(names::archive_root_name(&name)));
        report.set("output", json!(target.display().to_string()));
        report.set("artifacts", json!([{ "path": target.display().to_string(), "sha256": hex(&Sha256::digest(&archive)), "bytes": archive.len() }]));
    }
    Ok(report)
}

// install, list, templates

fn library(arguments: &Arguments, resources: Option<&Resources>) -> Result<Library, Failure> {
    Ok(Library::new(&user_data(arguments)?, resources.and_then(|resources| resources.templates.clone())))
}

pub fn install(command: &str, arguments: &[String]) -> Result<Report, Failure> {
    let arguments = Arguments::parse(arguments, &Shape { values: &["data"], flags: &[], minimum_positionals: 1, maximum_positionals: 1, positionals: "a .swt file or a package folder" })?;
    let source = std::path::absolute(Path::new(arguments.positional(0).unwrap_or_default())).map_err(|_| Failure::usage("Missing a .swt file or a package folder"))?;
    let metadata = std::fs::symlink_metadata(&source).map_err(|_| Failure::environment("input.file", format!("Not a .swt file or a package folder: {}", source.display())))?;
    let resources = resources()?;
    let scripts = shared_scripts(&resources)?;
    let paths = user_data(&arguments)?;
    let runtime = runtime(&scripts, &paths)?;
    let library = Library::new(&paths, resources.templates.clone());
    let mut report = Report::with_stages(command, "static");

    // A folder is packed in memory and installed like any archive, so both ways pass the same checks and publish atomically.
    let (archive, suggested): (Box<dyn std::io::Read>, Option<String>) = if metadata.is_dir() {
        let packed = stage(&mut report, "package", |report| {
            let inspected = inspect(report, &source, runtime.compiler())?;
            let mut archive = Vec::new();
            packages::export_directory(&source, &archive_name(&source, inspected.manifest.as_ref()), &mut archive, &ArchiveLimits::default())?;
            Ok(archive)
        });
        let Some(packed) = packed else { return Ok(report) };
        (Box::new(std::io::Cursor::new(packed)), None)
    } else {
        let file = std::fs::File::open(&source).ok().filter(|file| file.metadata().is_ok_and(|metadata| metadata.is_file()));
        let file = file.ok_or_else(|| Failure::environment("input.file", format!("Not a readable .swt file: {}", source.display())))?;
        report.set("package", json!(source.display().to_string()));
        (Box::new(file), source.file_stem().and_then(|stem| stem.to_str()).map(str::to_owned))
    };
    let mut archive = archive;

    // The staged files are compiled before anything is published; what the compiler said is kept for the report.
    let compile_error: RefCell<Option<sw_core::RuntimeError>> = RefCell::new(None);
    let reached_compile = std::cell::Cell::new(false);
    let validate = |files: &dyn PackageFiles| {
        reached_compile.set(true);
        runtime.validate_package(files).map_err(|error| {
            let refused = PackageError::new(codes::INVALID_MANIFEST, error.message.clone());
            *compile_error.borrow_mut() = Some(error);
            refused
        })
    };
    match library.import_archive(&mut archive, suggested.as_deref(), Some(&validate)) {
        Ok(installed) => {
            report.check("package", true);
            report.check("compile", true);
            report.set("name", json!(installed.name));
            report.set("title", json!(installed.display_name()));
            report.set("installation", json!(installed.installation));
            report.set("directory", json!(installed.directory.display().to_string()));
        }
        Err(error) => {
            let failure = match compile_error.into_inner() {
                Some(error) => Failure::new(EXIT_FAILED, &error.kind, error.message),
                None => error.into(),
            };
            let failed_stage = if reached_compile.get() { "compile" } else { "package" };
            if failed_stage == "compile" {
                report.check("package", true);
            }
            report.check(failed_stage, false);
            report.absorb(&failure);
        }
    }
    Ok(report)
}

pub fn list(command: &str, arguments: &[String]) -> Result<Report, Failure> {
    let arguments = Arguments::parse(arguments, &Shape { values: &["data"], flags: &[], minimum_positionals: 0, maximum_positionals: 0, positionals: "" })?;
    let library = library(&arguments, None)?;
    let packages: Vec<Value> = library
        .list()?
        .iter()
        .map(|package| json!({ "name": package.name, "title": package.display_name(), "installation": package.installation, "directory": package.directory.display().to_string() }))
        .collect();
    let mut report = Report::new(command);
    report.set("library", json!(library.root().display().to_string()));
    report.set("packages", Value::Array(packages));
    Ok(report)
}

fn templates_directory(resources: &Resources) -> Result<PathBuf, Failure> {
    resources.templates.clone().filter(|directory| directory.is_dir()).ok_or_else(|| {
        Failure::environment("tool.templates_missing", format!("The bundled templates were not found. Install the package, or set {} or {}.", sw_core::resources::ROOT_VARIABLE, sw_core::resources::TEMPLATES_VARIABLE))
    })
}

/// The template list needs no data folder: only the shipped templates are read.
fn template_library(resources: &Resources) -> Result<Library, Failure> {
    let directory = templates_directory(resources)?;
    let nowhere = DataPaths::at(Path::new("/nonexistent/scriptwidget")).map_err(|error| Failure::internal(error.to_string()))?;
    Ok(Library::new(&nowhere, Some(directory)))
}

pub fn templates(command: &str, arguments: &[String]) -> Result<Report, Failure> {
    Arguments::parse(arguments, &Shape { values: &[], flags: &[], minimum_positionals: 0, maximum_positionals: 0, positionals: "" })?;
    let library = template_library(&resources()?)?;
    let mut report = Report::new(command);
    report.set("templates", library.bundled().iter().map(|template| json!({ "group": template.group, "name": template.name, "network": template.network, "directory": template.directory.display().to_string() })).collect());
    report.set("unavailable", library.unavailable().iter().map(|template| json!({ "group": template.group, "name": template.name, "api": template.api })).collect());
    Ok(report)
}

// new

const STARTER: &str = r##"// A ScriptWidget package. Edit this file, then:
//   scriptwidget check .
//   scriptwidget render . --output /tmp/widget.png

const size = $getenv("widget-size");

$render(
  <vstack frame="max" alignment="leading" spacing="8" padding="16" background="#1d4ed8">
    <hstack>
      <icon systemName="wand.and.stars" size="22" color="#60a5fa"/>
      <spacer/>
      <badge text={size} color="#93c5fd"/>
    </hstack>
    <vstack frame="max,bottomLeading" alignment="leading" spacing="8">
      <text font={size === "small" ? "headline" : "title2"} weight="bold" color="white">Your next idea</text>
      <text font="caption" color="#94a3b8">Start editing main.jsx to make it yours.</text>
    </vstack>
  </vstack>
);
"##;

pub fn new(command: &str, arguments: &[String]) -> Result<Report, Failure> {
    let arguments = Arguments::parse(arguments, &Shape { values: &["template", "directory"], flags: &[], minimum_positionals: 1, maximum_positionals: 1, positionals: "a package name" })?;
    let name = arguments.positional(0).unwrap_or_default();
    if !names::is_valid(name) {
        return Err(Failure::usage(format!("{name:?} cannot be a package name: no path separators, leading dot or control characters, at most 80 characters")));
    }
    let parent = std::path::absolute(Path::new(arguments.value("directory").unwrap_or("."))).map_err(|_| Failure::usage("--directory is not a usable path"))?;
    if !parent.is_dir() {
        return Err(Failure::environment("output.path", format!("Not a folder: {}", parent.display())));
    }
    let (template, files): (String, Vec<(String, Vec<u8>)>) = match arguments.value("template") {
        None => ("starter".into(), vec![(manifests::LEGACY_ENTRY.into(), STARTER.as_bytes().to_vec()), (manifests::FILE_NAME.into(), manifests::encode(&manifests::new_manifest(name)))]),
        Some(reference) => {
            let library = template_library(&resources()?)?;
            let bundled = library.find_bundled(reference).ok_or_else(|| Failure::usage(format!("No bundled template named {reference}. scriptwidget templates lists them.")))?;
            let mut files = library.bundled_files(&bundled);
            let (_, manifest) = Library::bundled_sources(name, &files)?;
            files.insert(manifests::FILE_NAME.into(), manifest.into_bytes());
            (format!("{}/{}", bundled.group, bundled.name), files.into_iter().collect())
        }
    };

    let target = parent.join(name);
    // Created here and now: an existing folder, or anything else at this name, is never written into.
    std::fs::create_dir(&target).map_err(|error| match error.kind() {
        std::io::ErrorKind::AlreadyExists => Failure::new(EXIT_FAILED, codes::PACKAGE_EXISTS, format!("{} already exists.", target.display())),
        _ => Failure::environment("output.write", format!("{}: {error}", target.display())),
    })?;
    let written = (|| -> std::io::Result<Vec<String>> {
        let mut paths = Vec::new();
        for (path, bytes) in &files {
            let parts = path_rules::visible_components(path).ok_or_else(|| std::io::Error::other(format!("{path} is not a package path")))?;
            let file = parts.iter().fold(target.clone(), |file, part| file.join(part));
            if let Some(folder) = file.parent() {
                std::fs::create_dir_all(folder)?;
            }
            std::io::Write::write_all(&mut std::fs::OpenOptions::new().write(true).create_new(true).open(&file)?, bytes)?;
            paths.push(path.clone());
        }
        Ok(paths)
    })();
    let paths = written.map_err(|error| {
        let _ = std::fs::remove_dir_all(&target);
        Failure::environment("output.write", format!("{}: {error}", target.display()))
    })?;
    let mut report = Report::new(command);
    report.set("name", json!(name));
    report.set("directory", json!(target.display().to_string()));
    report.set("template", json!(template));
    report.set("files", json!(paths));
    Ok(report)
}

// doctor

fn writable(directory: &Path) -> bool {
    // The folder itself, or the nearest one above it that exists and would hold it.
    let mut existing = directory.to_owned();
    while !existing.exists() {
        if !existing.pop() {
            return false;
        }
    }
    std::ffi::CString::new(std::os::unix::ffi::OsStrExt::as_bytes(existing.as_os_str())).is_ok_and(|path| {
        // SAFETY: `path` is a valid NUL-terminated string for the duration of the call.
        existing.is_dir() && unsafe { libc::access(path.as_ptr(), libc::W_OK | libc::X_OK) } == 0
    })
}

pub fn doctor(command: &str, arguments: &[String]) -> Result<Report, Failure> {
    let arguments = Arguments::parse(arguments, &Shape { values: &["data"], flags: &[], minimum_positionals: 0, maximum_positionals: 0, positionals: "" })?;
    let mut report = Report::new(command);
    let release = sw_core::api::system::os_release(Path::new("/"));
    report.set("system", json!({ "name": release.get("PRETTY_NAME").or_else(|| release.get("NAME")), "id": release.get("ID"), "architecture": std::env::consts::ARCH, "icu": sw_core::intl::icu_version(), "locale": sw_core::intl::default_locale_tag(), "timeZone": sw_core::intl::default_time_zone() }));
    let set = |name: &str| std::env::var_os(name).is_some_and(|value| !value.is_empty());
    // Nothing here needs a graphical session; this only says what the desktop commands will find.
    report.set("session", json!({ "wayland": set("WAYLAND_DISPLAY"), "x11": set("DISPLAY"), "desktop": std::env::var("XDG_CURRENT_DESKTOP").ok() }));

    // Where things are.
    let data = match arguments.value("data") {
        Some(root) => DataPaths::at(Path::new(root)),
        None => DataPaths::locate(|name| std::env::var_os(name)),
    };
    let resources = Resources::locate();
    report.set(
        "paths",
        json!({
            "runtime": resources.as_ref().ok().map(|resources| resources.runtime.display().to_string()),
            "templates": resources.as_ref().ok().and_then(|resources| resources.templates.as_ref()).map(|path| path.display().to_string()),
            "data": data.as_ref().ok().map(|paths| paths.root().display().to_string()),
            "cache": data.as_ref().ok().map(|paths| paths.cache().display().to_string()),
        }),
    );
    match &data {
        Ok(paths) if writable(paths.root()) && writable(paths.cache()) => report.check("dataDirectory", true),
        Ok(paths) => {
            report.check("dataDirectory", false);
            report.fail(EXIT_FAILED, "tool.data_directory", &format!("The data folder {} or the cache folder {} cannot be written.", paths.root().display(), paths.cache().display()));
        }
        Err(error) => {
            report.check("dataDirectory", false);
            report.fail(EXIT_FAILED, "tool.data_directory", &format!("No data folder: {error}"));
        }
    }

    // The runtime files, then what needs them.
    let scripts = resources.as_ref().map_err(|error| error.to_string()).and_then(|resources| SharedScripts::new(&resources.runtime).map(Arc::new).map_err(|error| error.to_string()));
    for name in ["templates", "engine", "render"] {
        report.check_not_run(name);
    }
    let scripts = match scripts {
        Ok(scripts) => {
            report.check("resources", true);
            scripts
        }
        Err(message) => {
            report.check("resources", false);
            report.fail(EXIT_FAILED, "tool.resources_missing", &message);
            report.check_not_run("service");
            return Ok(report);
        }
    };
    let contract = scripts.contract();
    report.set("runtime", json!({ "apiVersion": contract.get("apiVersion"), "compilerFingerprint": contract.get("compilerFingerprint") }));

    match resources.as_ref().ok().and_then(|resources| template_library(resources).ok()) {
        Some(library) if !library.bundled().is_empty() => {
            report.check("templates", true);
            report.set("templateCount", json!({ "available": library.bundled().len(), "unavailable": library.unavailable().len() }));
        }
        _ => {
            report.check("templates", false);
            report.fail(EXIT_FAILED, "tool.templates_missing", "The bundled templates were not found.");
        }
    }

    // One small package through the compiler, the engine and the painter, with its data in a temporary folder.
    let scratch = RunData::new(&Arguments::default())?;
    let runtime = runtime(&scripts, &scratch.paths)?;
    let files: Arc<dyn PackageFiles> = Arc::new(MemoryPackageFiles::new([("main.jsx".to_owned(), "$render(<vstack frame=\"max\" background=\"#1d4ed8\"><text color=\"white\">ScriptWidget 你好</text></vstack>);".to_owned())], []));
    let request = RunRequest::new(files, "cli:doctor");
    let result = runtime.run(&request);
    match &result.execution.error {
        None => report.check("engine", true),
        Some(error) => {
            report.check("engine", false);
            report.fail(EXIT_FAILED, &error.kind, &format!("The self-test package did not run: {}", error.message));
        }
    }
    if result.execution.error.is_none() {
        let drawn = WidgetRenderer::new(scripts.clone()).map_err(|error| error.to_string()).and_then(|renderer| {
            let fonts = renderer.fonts().map_err(|error| error.message)?;
            let presentation = Presentation::for_family("small", 1.0).ok_or("no small family")?;
            let rendered = sw_render::render_run(&renderer, &runtime, &request, &result, &presentation).map_err(|error| error.message)?;
            match rendered.failure {
                Some(failure) => Err(failure.message),
                None => Ok((fonts, picture(&rendered.output))),
            }
        });
        match drawn {
            Ok((fonts, picture)) if picture["visiblePixels"].as_u64() > Some(0) && picture["colors"].as_u64() > Some(1) => {
                report.check("render", true);
                report.set("fonts", json!({ "bundled": fonts.bundled, "locale": fonts.locale, "cjkFamilies": fonts.cjk_families, "monospace": fonts.monospace, "serif": fonts.serif }));
                if fonts.cjk_families.is_empty() {
                    report.diagnostic("warning", "fonts.no_cjk", "No Chinese, Japanese or Korean font is installed; such text will show as empty boxes.");
                }
            }
            Ok(_) => {
                report.check("render", false);
                report.fail(EXIT_FAILED, "tool.render", "The self-test picture is empty.");
            }
            Err(message) => {
                report.check("render", false);
                report.fail(EXIT_FAILED, "tool.render", &format!("The self-test package could not be drawn: {message}"));
            }
        }
    }
    // The background service is optional for everything above: not running is not a fault of the installation.
    match crate::desktop::status() {
        Ok(Some(status)) => {
            report.check("service", true);
            report.set("service", json!({ "running": true, "protocol": status["protocol"], "version": status["service"], "widgets": status["widgets"], "watchers": status["watchers"], "locked": status["locked"] }));
        }
        Ok(None) => {
            report.check_not_run("service");
            report.set("service", json!({ "running": false }));
        }
        Err(failure) => {
            report.check("service", false);
            report.fail(EXIT_FAILED, &failure.code, &failure.message);
        }
    }
    Ok(report)
}
