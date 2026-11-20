//! `scriptwidget-studio`: the ScriptWidget management window.

use std::process::ExitCode;
use std::sync::Arc;

use futures::channel::mpsc::unbounded;
use sw_studio::instance::{self, Claim, Request};
use sw_studio::launch::{self, Parsed};
use sw_studio::model::Studio;
use sw_studio::strings::{self, tf};

fn main() -> ExitCode {
    // A key given for this run is taken out of the environment before any thread or child exists,
    // so that nothing the window starts (the scriptwidget command, a browser) inherits it.
    let one_run_key = std::env::var_os(sw_core::ai::credentials::ENVIRONMENT_KEY);
    if one_run_key.is_some() {
        // SAFETY: the process has only this thread; nothing else reads or writes the environment yet.
        unsafe { std::env::remove_var(sw_core::ai::credentials::ENVIRONMENT_KEY) };
    }
    if let Err(problem) = sw_studio::ai::set_one_run_key(one_run_key) {
        eprintln!("warning: {problem}");
    }
    strings::set_language(strings::detect(|name| std::env::var(name).ok()));
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let launch = match launch::parse(&arguments, std::env::current_dir().ok().as_deref()) {
        Ok(Parsed::Run(launch)) => launch,
        Ok(Parsed::Help) => {
            print!("{}", launch::USAGE);
            return ExitCode::SUCCESS;
        }
        Ok(Parsed::Version) => {
            println!("scriptwidget-studio {}", sw_studio::VERSION);
            return ExitCode::SUCCESS;
        }
        Err(problem) => {
            eprintln!("error: {problem}\n\n{}", launch::USAGE);
            return ExitCode::from(2);
        }
    };

    // One window per user: a second start hands its request to the first and ends.
    let (requests, received) = unbounded::<Request>();
    if launch.single_instance {
        let claimed = std::env::var_os("XDG_RUNTIME_DIR")
            .filter(|value| !value.is_empty())
            .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::NotFound, "XDG_RUNTIME_DIR is not set"))
            .and_then(|runtime| instance::private_directory(std::path::Path::new(&runtime)))
            .and_then(|directory| instance::claim(&directory, &launch.request));
        match claimed {
            Ok(Claim::Forwarded) => return ExitCode::SUCCESS,
            Ok(Claim::Primary(primary)) => primary.listen(move |request| {
                let _ = requests.unbounded_send(request);
            }),
            // Without a runtime folder there is no handshake; the window still opens.
            Err(error) => eprintln!("warning: single-instance check skipped: {error}"),
        }
    }

    let studio = match Studio::open(launch.data.as_deref()) {
        Ok(studio) => Arc::new(studio),
        Err(error) => {
            eprintln!("{}", tf("startup.failed", &[&error.0]));
            return ExitCode::from(2);
        }
    };
    sw_studio::ui::run(studio, launch.request, launch.page, received);
    ExitCode::SUCCESS
}
