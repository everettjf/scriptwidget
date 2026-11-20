//! `scriptwidget`: the ScriptWidget command line for Linux. It creates,
//! checks, runs, draws, packs and installs widget packages with the same
//! runtime the desktop service uses, and needs no graphical session.
//!
//! Every command prints one JSON report on standard output and exits with one
//! of the codes in [`report`]. See `commands::USAGE`. The exceptions are in
//! [`desktop`]: `watch` and `dev` print one line of JSON at a time, and
//! `host run` is the background service itself. The service is this same
//! program so that one file is installed and the command line can never be a
//! different version from the service it talks to.

mod ai;
mod arguments;
mod commands;
mod desktop;
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
        "add" => desktop::add(command, rest),
        "remove" => desktop::remove(command, rest),
        "widgets" => desktop::widgets(command, rest),
        "refresh" => desktop::refresh(command, rest),
        "peek" | "arrange" => desktop::switch(command, rest),
        "tap" => desktop::tap(command, rest),
        "move" => desktop::move_widget(command, rest),
        "screen" => desktop::screen(command, rest),
        "theme" => desktop::theme(command, rest),
        "menu" => desktop::menu(command, rest),
        "session" => desktop::session(command, rest),
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
    // Installed under the name the plan gives the service, the program is the service.
    if std::env::args_os().next().is_some_and(|program| std::path::Path::new(&program).file_name().is_some_and(|name| name == "scriptwidget-host")) {
        arguments.splice(0..0, ["host".to_owned(), "run".to_owned()]);
    }
    let Some(command) = arguments.first().cloned() else {
        eprint!("{}", commands::USAGE);
        return EXIT_USAGE;
    };
    if matches!(command.as_str(), "--help" | "-h" | "help") {
        print!("{}", commands::USAGE);
        return 0;
    }
    if command == "ai" {
        if arguments.len() == 1 || ai::wants_help(&arguments[1..]) {
            print!("{}", ai::help());
            return if arguments.len() == 1 { EXIT_USAGE } else { 0 };
        }
        return ai::run(&arguments[1..]).finish();
    }
    // The commands that print lines for as long as they run, and the service itself.
    if let Some(code) = desktop::stream(&command, &arguments[1..]) {
        return code;
    }
    let report = dispatch(&command, &arguments[1..]).unwrap_or_else(|failure| Report::from_failure(&command, &failure));
    report.finish()
}

fn main() -> ExitCode {
    // A key given for this run is taken out of the environment before any thread or child exists,
    // so that nothing this program starts (secret-tool, the service, a browser for a link) inherits it.
    let one_run_key = std::env::var_os(sw_core::ai::credentials::ENVIRONMENT_KEY);
    if one_run_key.is_some() {
        // SAFETY: the process has only this thread; nothing else reads or writes the environment yet.
        unsafe { std::env::remove_var(sw_core::ai::credentials::ENVIRONMENT_KEY) };
    }
    ai::set_one_run_key(one_run_key);
    let worker = std::thread::Builder::new().name("scriptwidget".into()).stack_size(MAIN_STACK).spawn(execute);
    let code = match worker.map(|worker| worker.join()) {
        Ok(Ok(code)) => code,
        // A panic has already printed its message to standard error.
        _ => EXIT_INTERNAL,
    };
    ExitCode::from(code as u8)
}
