//! `scriptwidget skills`: the Skills of the AI conversation. The
//! command-line face of `sw_core::skills`; `Android/app/.../ui/SkillsScreen.kt`
//! is what the commands follow.
//!
//! A Skill is two text files. Nothing here runs anything from a Skill: it is
//! validated, stored, listed, and its instructions are added to an AI request
//! while it is enabled. A Skill that was imported is not enabled until the
//! user says so.

use std::path::Path;

use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use sw_core::skills::{Skill, SkillError, SkillStore, errors, validator};

use crate::arguments::{Arguments, Shape};
use crate::commands::user_data;
use crate::output;
use crate::report::{EXIT_FAILED, EXIT_USAGE, Failure, Report};

const HELP: &str = "\
Usage: scriptwidget skills <command> [options]

  list                  The Skills shipped with the program and the ones you imported, and which
                        of them are enabled.
  show <id>             One Skill with its instructions.
  import <file | dir>   Import a Skill from a .swskill archive or from a folder. Either holds exactly
                        skill.json and SKILL.md. An imported Skill is not enabled.
  export <id> [--output <file.swskill>] [--force]
                        Write a Skill as a .swskill archive (default: <name>.swskill here).
  enable <id>           Add the Skill's instructions to every AI request (ai new, ai continue, and
                        the conversation in the editor).
  disable <id>          Stop adding them.
  remove <id>           Delete an imported Skill. The Skills shipped with the program stay.

  --data <dir>          The data folder (default: yours).

A Skill only adds text to what the model is asked. It cannot run code, use the network, or give a
widget a permission.
";

impl From<SkillError> for Failure {
    /// A Skill that is refused is at fault itself; a Skill that is not there, or a folder that
    /// cannot be written, is the command line's or the machine's.
    fn from(error: SkillError) -> Self {
        let exit = if [errors::NOT_FOUND, errors::BUILT_IN, errors::STORAGE_UNAVAILABLE].contains(&error.code) { EXIT_USAGE } else { EXIT_FAILED };
        Failure::new(exit, &format!("skills.{}", error.code), error.message)
    }
}

pub fn wants_help(arguments: &[String]) -> bool {
    arguments.first().is_some_and(|word| matches!(word.as_str(), "--help" | "-h" | "help"))
}

pub fn help() -> &'static str {
    HELP
}

/// Runs a `skills` command. A failure that stopped it becomes its report, under the command's own name.
pub fn run(arguments: &[String]) -> Report {
    let name = match arguments.first().filter(|word| !word.starts_with('-')) {
        Some(word) => format!("skills {word}"),
        None => "skills".to_owned(),
    };
    dispatch(arguments).unwrap_or_else(|failure| Report::from_failure(&name, &failure))
}

fn dispatch(arguments: &[String]) -> Result<Report, Failure> {
    let Some(word) = arguments.first().map(String::as_str) else { return Err(Failure::usage("Missing a skills command. scriptwidget skills --help lists them.")) };
    let rest = &arguments[1..];
    match word {
        "list" => list(rest),
        "show" => show(rest),
        "import" => import(rest),
        "export" => export(rest),
        "enable" => set_enabled(rest, true),
        "disable" => set_enabled(rest, false),
        "remove" => remove(rest),
        _ => Err(Failure::usage(format!("Unknown skills command {word}. scriptwidget skills --help lists them."))),
    }
}

fn shape(values: &'static [&'static str], flags: &'static [&'static str], positionals: usize, what: &'static str) -> Shape {
    Shape { values, flags, minimum_positionals: positionals, maximum_positionals: positionals, positionals: what }
}

pub(crate) fn store(arguments: &Arguments) -> Result<SkillStore, Failure> {
    Ok(SkillStore::new(user_data(arguments)?.skills()))
}

/// A Skill as a report shows it. The instructions are included only where they were asked for.
pub(crate) fn describe(skill: &Skill, enabled: bool, with_instruction: bool) -> Value {
    let mut value = json!({
        "id": skill.id,
        "title": skill.title,
        "version": skill.version,
        "summary": skill.summary,
        "symbol": skill.symbol,
        "tags": skill.tags,
        "author": skill.author,
        "builtIn": skill.is_built_in,
        "enabled": enabled,
    });
    if with_instruction {
        value["instruction"] = json!(skill.instruction);
    }
    value
}

fn find(store: &SkillStore, id: &str) -> Result<Skill, Failure> {
    store.find(id).ok_or_else(|| Failure::environment("skills.skill_not_found", format!("There is no Skill with the id {id}. scriptwidget skills list shows them.")))
}

fn list(arguments: &[String]) -> Result<Report, Failure> {
    let arguments = Arguments::parse(arguments, &shape(&["data"], &[], 0, ""))?;
    let store = store(&arguments)?;
    let enabled = store.enabled_ids();
    let mut report = Report::new("skills list");
    report.set("directory", json!(store.root().display().to_string()));
    report.set("skills", store.list().iter().map(|skill| describe(skill, enabled.contains(&skill.id), false)).collect());
    Ok(report)
}

fn show(arguments: &[String]) -> Result<Report, Failure> {
    let arguments = Arguments::parse(arguments, &shape(&["data"], &[], 1, "the id of a Skill"))?;
    let store = store(&arguments)?;
    let skill = find(&store, arguments.positional(0).unwrap_or_default())?;
    let mut report = Report::new("skills show");
    report.set("skill", describe(&skill, store.is_enabled(&skill.id), true));
    Ok(report)
}

fn import(arguments: &[String]) -> Result<Report, Failure> {
    let arguments = Arguments::parse(arguments, &shape(&["data"], &[], 1, "a .swskill file or a folder with skill.json and SKILL.md"))?;
    let source = std::path::absolute(Path::new(arguments.positional(0).unwrap_or_default())).map_err(|_| Failure::usage("Missing a .swskill file or a folder"))?;
    let unreadable = || Failure::environment("input.file", format!("Not a .swskill file or a folder: {}", source.display()));
    let metadata = std::fs::symlink_metadata(&source).map_err(|_| unreadable())?;
    let store = store(&arguments)?;
    let skill = if metadata.is_dir() {
        store.import_directory(&source)?
    } else {
        let mut file = std::fs::File::open(&source).ok().filter(|file| file.metadata().is_ok_and(|metadata| metadata.is_file())).ok_or_else(unreadable)?;
        store.import_archive(&mut file)?
    };
    let mut report = Report::new("skills import");
    report.set("source", json!(source.display().to_string()));
    report.set("skill", describe(&skill, store.is_enabled(&skill.id), false));
    Ok(report)
}

fn export(arguments: &[String]) -> Result<Report, Failure> {
    let arguments = Arguments::parse(arguments, &shape(&["data", "output"], &["force"], 1, "the id of a Skill"))?;
    let store = store(&arguments)?;
    let skill = find(&store, arguments.positional(0).unwrap_or_default())?;
    let target = output::resolve(&arguments.value("output").map_or_else(|| format!("{}.swskill", validator::slug(&skill.title)), str::to_owned))?;
    if target.extension().is_none_or(|extension| extension != "swskill" && extension != "zip") {
        return Err(Failure::usage("The export output must end in .swskill or .zip"));
    }
    let archive = store.export_archive(&skill.id)?;
    output::write(&target, &archive, arguments.flag("force"))?;
    let mut report = Report::new("skills export");
    report.set("skill", describe(&skill, store.is_enabled(&skill.id), false));
    report.set("output", json!(target.display().to_string()));
    report.set("artifacts", json!([{ "path": target.display().to_string(), "sha256": Sha256::digest(&archive).iter().map(|byte| format!("{byte:02x}")).collect::<String>(), "bytes": archive.len() }]));
    Ok(report)
}

fn set_enabled(arguments: &[String], enabled: bool) -> Result<Report, Failure> {
    let arguments = Arguments::parse(arguments, &shape(&["data"], &[], 1, "the id of a Skill"))?;
    let store = store(&arguments)?;
    let id = arguments.positional(0).unwrap_or_default();
    // Turning off a Skill that is gone is not an error: its text is not added either way.
    let skill = if enabled { Some(find(&store, id)?) } else { store.find(id) };
    store.set_enabled(id, enabled)?;
    let mut report = Report::new(if enabled { "skills enable" } else { "skills disable" });
    report.set("id", json!(id));
    report.set("enabled", json!(enabled));
    report.set("skill", skill.map_or(Value::Null, |skill| describe(&skill, enabled, false)));
    report.set("enabledSkills", json!(store.enabled_skills().iter().map(|skill| skill.id.clone()).collect::<Vec<_>>()));
    Ok(report)
}

fn remove(arguments: &[String]) -> Result<Report, Failure> {
    let arguments = Arguments::parse(arguments, &shape(&["data"], &[], 1, "the id of a Skill"))?;
    let store = store(&arguments)?;
    let id = arguments.positional(0).unwrap_or_default();
    store.delete(id)?;
    let mut report = Report::new("skills remove");
    report.set("id", json!(id));
    Ok(report)
}
