//! `scriptwidget`: the ScriptWidget command line for Linux. It creates,
//! checks, runs, draws, packs and installs widget packages with the same
//! runtime the desktop service uses, and needs no graphical session.
//!
//! Every command prints one JSON report on standard output and exits with one
//! of the codes in [`report`]. See `commands::USAGE`.

mod arguments;
mod commands;
mod output;
mod report;

use std::process::ExitCode;

use report::{EXIT_INTERNAL, EXIT_USAGE, Failure, Report};

/// Room for the JSON of the deepest element tree the runtime contract allows.
const MAIN_STACK: usize = 64 * 1024 * 1024;

fn dispatch(command: &str, rest: &[String]) -> Result<Report, Failure> {
    match command {
        "new" => commands::new(command, rest),
        // `validate` is what the Windows command line calls it.
        "check" | "validate" => commands::check("check", rest),
        "run" => commands::run(command, rest),
        "render" => commands::render(command, rest),
        "timeline" => commands::timeline(command, rest),
        "pack" => commands::pack(command, rest),
        "install" => commands::install(command, rest),
        "list" => commands::list(command, rest),
        "templates" => commands::templates(command, rest),
        "doctor" => commands::doctor(command, rest),
        "--version" | "version" => {
            let mut report = Report::new("--version");
            report.set("version", serde_json::json!(env!("CARGO_PKG_VERSION")));
            Ok(report)
        }
        _ if commands::SERVICE_COMMANDS.contains(&command) => Err(commands::needs_service(command)),
        _ => Err(Failure::usage(format!("Unknown command {command}. scriptwidget --help lists the commands."))),
    }
}

fn execute() -> i32 {
    // A broken pipe ends the write with an error instead of the process with a signal.
    // SAFETY: called once, before any other thread exists; SIG_IGN is a valid disposition.
    unsafe { libc::signal(libc::SIGPIPE, libc::SIG_IGN) };
    let mut arguments = Vec::new();
    for argument in std::env::args_os().skip(1) {
        match argument.into_string() {
            Ok(text) => arguments.push(text),
            Err(_) => return Report::from_failure("", &Failure::usage("Arguments must be valid UTF-8")).finish(),
        }
    }
    let Some(command) = arguments.first().cloned() else {
        eprint!("{}", commands::USAGE);
        return EXIT_USAGE;
    };
    if matches!(command.as_str(), "--help" | "-h" | "help") {
        print!("{}", commands::USAGE);
        return 0;
    }
    let report = dispatch(&command, &arguments[1..]).unwrap_or_else(|failure| Report::from_failure(&command, &failure));
    report.finish()
}

fn main() -> ExitCode {
    let worker = std::thread::Builder::new().name("scriptwidget".into()).stack_size(MAIN_STACK).spawn(execute);
    let code = match worker.map(|worker| worker.join()) {
        Ok(Ok(code)) => code,
        // A panic has already printed its message to standard error.
        _ => EXIT_INTERNAL,
    };
    ExitCode::from(code as u8)
}
