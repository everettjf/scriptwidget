//! Running a system program for a native API: a fixed argument list (never a
//! shell), optional data on standard input, a bounded amount of output, and a
//! deadline after which the child is killed. The child is always waited for,
//! so no call leaves a process behind, whatever the program does.

use std::ffi::OsStr;
use std::io::{Read, Write};
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};

/// Why a program gave no usable answer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RunError {
    /// The program is not installed.
    NotFound,
    /// It could not be started.
    Failed,
    /// It did not end in time and was killed.
    TimedOut,
    /// It wrote more than the caller accepts and was killed.
    TooMuchOutput,
}

/// What a program that ended printed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Finished {
    pub success: bool,
    pub stdout: Vec<u8>,
    /// Whether it wrote anything but white space to standard error. What it wrote is not kept.
    pub complained: bool,
}

/// Runs `program` with `arguments` and waits for it, at most `limit`.
/// `input` is written to its standard input, which is then closed. Standard
/// error is read and thrown away. Nothing is inherited from this process
/// except its environment without the names in `scrub`.
pub fn run_bounded<S: AsRef<OsStr>>(program: &Path, arguments: &[S], input: Option<&[u8]>, limit: Duration, maximum_output: usize, scrub: &[&str]) -> Result<Finished, RunError> {
    let mut command = Command::new(program);
    command.args(arguments).stdin(if input.is_some() { Stdio::piped() } else { Stdio::null() }).stdout(Stdio::piped()).stderr(Stdio::piped());
    for name in scrub {
        command.env_remove(name);
    }
    let deadline = Instant::now() + limit;
    // "Text file busy" means some process still holds the program open for writing: another thread of
    // this one that forked just after the file was written, or an installer replacing it. That passes
    // in a moment, so the start is tried again for a short while, inside the limit.
    let mut attempts = 0;
    let mut child = loop {
        match command.spawn() {
            Ok(child) => break child,
            Err(error) if error.kind() == std::io::ErrorKind::ExecutableFileBusy && attempts < 20 && Instant::now() < deadline => {
                attempts += 1;
                std::thread::sleep(Duration::from_millis(10));
            }
            Err(error) => return Err(if error.kind() == std::io::ErrorKind::NotFound { RunError::NotFound } else { RunError::Failed }),
        }
    };
    // Both outputs are read on threads of their own, so a program that fills a pipe cannot stall this one.
    let (output_sender, output_receiver) = mpsc::channel();
    let output_reader = child.stdout.take().and_then(|stdout| {
        std::thread::Builder::new()
            .name("scriptwidget-child-output".into())
            .spawn(move || {
                let mut bytes = Vec::new();
                let _ = stdout.take(maximum_output as u64 + 1).read_to_end(&mut bytes);
                let _ = output_sender.send(bytes);
            })
            .ok()
    });
    let (error_sender, error_receiver) = mpsc::channel();
    let error_reader = child.stderr.take().and_then(|mut stderr| {
        std::thread::Builder::new()
            .name("scriptwidget-child-errors".into())
            .spawn(move || {
                let mut complained = false;
                let mut buffer = [0u8; 4096];
                // Read to the end, so the program never waits for room in the pipe.
                while let Ok(count) = stderr.read(&mut buffer) {
                    if count == 0 {
                        break;
                    }
                    complained |= !buffer[..count].iter().all(u8::is_ascii_whitespace);
                }
                let _ = error_sender.send(complained);
            })
            .ok()
    });
    if let (Some(input), Some(mut stdin)) = (input, child.stdin.take()) {
        // A program that ends without reading is reported by its exit status.
        let _ = stdin.write_all(input);
    }
    let output = match output_reader {
        Some(_) => output_receiver.recv_timeout(deadline.saturating_duration_since(Instant::now())).ok(),
        None => Some(Vec::new()),
    };
    let outcome = match output {
        None => Err(RunError::TimedOut),
        Some(bytes) if bytes.len() > maximum_output => Err(RunError::TooMuchOutput),
        Some(bytes) => loop {
            match child.try_wait() {
                Ok(Some(status)) => break Ok(Finished { success: status.success(), stdout: bytes, complained: false }),
                Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(5)),
                Ok(None) => break Err(RunError::TimedOut),
                Err(_) => break Err(RunError::Failed),
            }
        },
    };
    if outcome.is_err() {
        let _ = child.kill();
    }
    // Reaps the child in every case; after `kill` this returns at once.
    let _ = child.wait();
    // The readers end when the last process that holds their pipe is gone, which is now unless the
    // program left a child of its own behind; they are not waited for longer than a moment.
    drop((output_reader, error_reader));
    outcome.map(|mut finished| {
        finished.complained = error_receiver.recv_timeout(Duration::from_millis(250)).unwrap_or(false);
        finished
    })
}

/// Whether `program`, a bare name, is an executable file in one of the `PATH` directories.
pub fn on_path(program: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    let executable = |file: &Path| std::fs::metadata(file).is_ok_and(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0);
    if program.components().count() > 1 {
        return executable(program);
    }
    std::env::var_os("PATH").is_some_and(|path| std::env::split_paths(&path).any(|directory| directory.is_absolute() && executable(&directory.join(program))))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::path::PathBuf;

    fn script(name: &str, body: &str) -> PathBuf {
        let directory = std::env::temp_dir().join(format!("scriptwidget-test-process-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&directory);
        std::fs::create_dir_all(&directory).unwrap();
        let program = directory.join("program");
        std::fs::write(&program, format!("#!/bin/sh\n{body}\n")).unwrap();
        std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o755)).unwrap();
        program
    }

    const LIMIT: Duration = Duration::from_secs(10);

    #[test]
    fn arguments_and_input_arrive_as_given() {
        let program = script("echo", "printf '%s|' \"$@\"; cat");
        let finished = run_bounded(&program, &["a b", "--c", "$(id)"], Some(b"secret"), LIMIT, 1024, &[]).unwrap();
        assert!(finished.success);
        assert_eq!(String::from_utf8(finished.stdout).unwrap(), "a b|--c|$(id)|secret");
        let failing = script("fail", "echo out; echo err >&2; exit 3");
        assert_eq!(run_bounded::<&str>(&failing, &[], None, LIMIT, 1024, &[]).unwrap(), Finished { success: false, stdout: b"out\n".to_vec(), complained: true });
        assert!(!finished.complained);
    }

    #[test]
    fn a_program_that_hangs_or_floods_is_killed() {
        let hanging = script("hang", "echo $$ > \"$0.pid\"; exec sleep 30");
        let started = Instant::now();
        assert_eq!(run_bounded::<&str>(&hanging, &[], None, Duration::from_millis(300), 1024, &[]), Err(RunError::TimedOut));
        assert!(started.elapsed() < Duration::from_secs(5));
        // The child is gone: signal 0 finds no such process.
        let pid: i32 = std::fs::read_to_string(format!("{}.pid", hanging.display())).unwrap().trim().parse().unwrap();
        // SAFETY: signal 0 only asks whether the process exists.
        assert_eq!(unsafe { libc::kill(pid, 0) }, -1, "the child was reaped");

        let flooding = script("flood", "while :; do echo 0123456789012345678901234567890123456789; done");
        assert_eq!(run_bounded::<&str>(&flooding, &[], None, LIMIT, 4096, &[]), Err(RunError::TooMuchOutput));
    }

    #[test]
    fn a_missing_program_is_told_apart() {
        assert_eq!(run_bounded::<&str>(Path::new("/nonexistent/scriptwidget-no-such-program"), &[], None, LIMIT, 16, &[]), Err(RunError::NotFound));
        assert!(!on_path(Path::new("scriptwidget-no-such-program")));
        assert!(on_path(Path::new("sh")));
    }

    #[test]
    fn named_variables_do_not_reach_the_child() {
        let program = script("environment", "printf '%s' \"${HOME:-unset}\"");
        assert_ne!(run_bounded::<&str>(&program, &[], None, LIMIT, 4096, &[]).unwrap().stdout, b"unset");
        assert_eq!(run_bounded::<&str>(&program, &[], None, LIMIT, 4096, &["HOME"]).unwrap().stdout, b"unset");
    }
}
