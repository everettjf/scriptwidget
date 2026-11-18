//! Asking the background service to put a widget on the desktop. The window
//! does not talk to the service itself: it runs `scriptwidget add <package>
//! [--family F]`, the same command a person would type, as a child process
//! with an argument list (never through a shell).

use std::ffi::OsString;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// The exit code of a command that needs the background service when it is not running.
pub const EXIT_SERVICE_NOT_RUNNING: i32 = 69;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AddOutcome {
    Added,
    ServiceNotRunning,
    /// The `scriptwidget` program was not found.
    CommandMissing,
    Failed(String),
}

/// The `scriptwidget` program: `SCRIPTWIDGET_CLI` when set, the one installed
/// next to this program, otherwise whatever `PATH` finds.
pub fn command_line(variable: impl Fn(&str) -> Option<OsString>, executable: Option<&Path>) -> PathBuf {
    if let Some(named) = variable("SCRIPTWIDGET_CLI").filter(|value| !value.is_empty()) {
        return PathBuf::from(named);
    }
    executable.and_then(Path::parent).map(|folder| folder.join("scriptwidget")).filter(|sibling| sibling.is_file()).unwrap_or_else(|| PathBuf::from("scriptwidget"))
}

/// Runs `<program> add <package> [--family <family>]` and waits for it, at most `limit`.
pub fn add_to_desktop(program: &Path, package: &str, family: Option<&str>, limit: Duration) -> AddOutcome {
    // The command line would read a name that starts with a dash as an option.
    if package.is_empty() || package.starts_with('-') {
        return AddOutcome::Failed(format!("{package:?} cannot be passed to the command line."));
    }
    let mut command = Command::new(program);
    command.arg("add").arg(package);
    if let Some(family) = family {
        command.arg("--family").arg(family);
    }
    let mut child = match command.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::piped()).spawn() {
        Ok(child) => child,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return AddOutcome::CommandMissing,
        Err(error) => return AddOutcome::Failed(error.to_string()),
    };
    let deadline = Instant::now() + limit;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(20)),
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                return AddOutcome::Failed("The scriptwidget command did not answer.".into());
            }
            Err(error) => return AddOutcome::Failed(error.to_string()),
        }
    };
    match status.code() {
        Some(0) => AddOutcome::Added,
        Some(EXIT_SERVICE_NOT_RUNNING) => AddOutcome::ServiceNotRunning,
        code => {
            // What the command said, shortened: `error: [code] message` lines.
            let mut said = String::new();
            if let Some(stderr) = child.stderr.take() {
                let _ = stderr.take(4096).read_to_string(&mut said);
            }
            let line = said.lines().map(str::trim).find(|line| !line.is_empty()).unwrap_or_default().trim_start_matches("error:").trim().to_owned();
            AddOutcome::Failed(if line.is_empty() { format!("scriptwidget add ended with {}", code.map_or_else(|| "a signal".to_owned(), |code| format!("code {code}"))) } else { line })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::Scratch;
    use std::os::unix::fs::PermissionsExt;

    /// A stand-in for the command line that records its arguments, one per line, and exits with `code`.
    fn fake(scratch: &Scratch, code: i32, says: &str) -> PathBuf {
        let program = scratch.path("scriptwidget");
        let record = scratch.path("arguments.txt");
        std::fs::write(&program, format!("#!/bin/sh\nfor argument in \"$@\"; do printf '%s\\n' \"$argument\" >> '{}'; done\n[ -n '{says}' ] && echo '{says}' >&2\nexit {code}\n", record.display())).unwrap();
        std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o755)).unwrap();
        program
    }

    fn recorded(scratch: &Scratch) -> Vec<String> {
        std::fs::read_to_string(scratch.path("arguments.txt")).unwrap_or_default().lines().map(str::to_owned).collect()
    }

    const LIMIT: Duration = Duration::from_secs(10);

    #[test]
    fn the_package_is_one_argument_whatever_it_contains() {
        let scratch = Scratch::new("service-arguments");
        let program = fake(&scratch, 0, "");
        let name = "My Widget; rm -rf ~ $(id) `id` \"quoted\" 小组件";
        assert_eq!(add_to_desktop(&program, name, Some("large"), LIMIT), AddOutcome::Added);
        assert_eq!(recorded(&scratch), ["add", name, "--family", "large"]);
        std::fs::remove_file(scratch.path("arguments.txt")).unwrap();
        assert_eq!(add_to_desktop(&program, "Clock", None, LIMIT), AddOutcome::Added);
        assert_eq!(recorded(&scratch), ["add", "Clock"]);
    }

    #[test]
    fn exit_code_69_means_the_service_is_not_running() {
        let scratch = Scratch::new("service-69");
        assert_eq!(add_to_desktop(&fake(&scratch, 69, "error: [service.not_running] no service"), "Clock", None, LIMIT), AddOutcome::ServiceNotRunning);
    }

    #[test]
    fn other_failures_carry_what_the_command_said() {
        let scratch = Scratch::new("service-failed");
        assert_eq!(add_to_desktop(&fake(&scratch, 1, "error: [package_not_found] No such package"), "Clock", None, LIMIT), AddOutcome::Failed("[package_not_found] No such package".into()));
        let silent = Scratch::new("service-silent");
        assert_eq!(add_to_desktop(&fake(&silent, 3, ""), "Clock", None, LIMIT), AddOutcome::Failed("scriptwidget add ended with code 3".into()));
    }

    #[test]
    fn a_missing_program_and_a_name_that_reads_as_an_option_are_told_apart() {
        let scratch = Scratch::new("service-missing");
        assert_eq!(add_to_desktop(&scratch.path("no-such-program"), "Clock", None, LIMIT), AddOutcome::CommandMissing);
        let program = fake(&scratch, 0, "");
        assert!(matches!(add_to_desktop(&program, "--data", None, LIMIT), AddOutcome::Failed(_)));
        assert!(matches!(add_to_desktop(&program, "", None, LIMIT), AddOutcome::Failed(_)));
        assert_eq!(recorded(&scratch), Vec::<String>::new(), "nothing was run");
    }

    #[test]
    fn a_command_that_hangs_is_stopped() {
        let scratch = Scratch::new("service-hang");
        let program = scratch.path("scriptwidget");
        std::fs::write(&program, "#!/bin/sh\nexec sleep 30\n").unwrap();
        std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o755)).unwrap();
        let started = Instant::now();
        assert!(matches!(add_to_desktop(&program, "Clock", None, Duration::from_millis(300)), AddOutcome::Failed(_)));
        assert!(started.elapsed() < Duration::from_secs(5));
    }

    #[test]
    fn the_program_is_the_one_named_or_the_one_installed_beside_this_one() {
        let scratch = Scratch::new("service-locate");
        let none = |_: &str| None;
        assert_eq!(command_line(none, Some(&scratch.path("bin/scriptwidget-studio"))), PathBuf::from("scriptwidget"), "nothing beside it: PATH decides");
        scratch.write("bin/scriptwidget", b"");
        assert_eq!(command_line(none, Some(&scratch.path("bin/scriptwidget-studio"))), scratch.path("bin/scriptwidget"));
        assert_eq!(command_line(|name| (name == "SCRIPTWIDGET_CLI").then(|| "/opt/sw".into()), Some(&scratch.path("bin/scriptwidget-studio"))), PathBuf::from("/opt/sw"));
        assert_eq!(command_line(none, None), PathBuf::from("scriptwidget"));
    }
}
