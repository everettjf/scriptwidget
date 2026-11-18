//! The command line of `scriptwidget-studio`.

use std::path::PathBuf;

use crate::instance::Request;

pub const USAGE: &str = "\
usage: scriptwidget-studio [options] [file.swt]

  file.swt             offer to import this widget
  --edit <widget>      open one of your widgets in the editor
  --data <folder>      use this data folder instead of the user's
  --version            print the version
  --help               print this text

For development:
  --page <page>        start on library, templates, components, apis, settings, template:<group/name> or editor:<widget>
  --no-single-instance always open a window of its own
";

/// The pages `--page` can name.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StartPage {
    Library,
    Templates,
    Components,
    Apis,
    Settings,
    Template(String),
    Editor(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Launch {
    pub request: Request,
    pub data: Option<PathBuf>,
    pub page: Option<StartPage>,
    pub single_instance: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Parsed {
    Run(Launch),
    Help,
    Version,
}

/// Reads the arguments after the program name. `current` is the folder a relative `.swt` path is taken from.
pub fn parse(arguments: &[String], current: Option<&std::path::Path>) -> Result<Parsed, String> {
    let mut launch = Launch { request: Request::Show, data: None, page: None, single_instance: true };
    let mut chosen = false;
    let mut choose = |launch: &mut Launch, request: Request| {
        if std::mem::replace(&mut chosen, true) {
            return Err("Give one widget to edit or one file to import, not several.".to_owned());
        }
        launch.request = request;
        Ok(())
    };
    let absolute = |text: &str| {
        let path = PathBuf::from(text);
        if path.is_absolute() { Ok(path) } else { current.map(|folder| folder.join(&path)).ok_or_else(|| format!("{text} is not an absolute path.")) }
    };
    let mut rest = arguments.iter();
    let mut options = true;
    while let Some(argument) = rest.next() {
        let mut value = |name: &str| rest.next().filter(|value| !value.is_empty()).cloned().ok_or_else(|| format!("{name} needs a value."));
        match argument.as_str() {
            "--help" | "-h" if options => return Ok(Parsed::Help),
            "--version" if options => return Ok(Parsed::Version),
            "--edit" if options => {
                let name = value("--edit")?;
                choose(&mut launch, Request::Edit(name))?;
            }
            "--data" if options => launch.data = Some(absolute(&value("--data")?)?),
            "--page" if options => {
                let page = value("--page")?;
                launch.page = Some(match (page.as_str(), page.split_once(':')) {
                    ("library", _) => StartPage::Library,
                    ("templates", _) => StartPage::Templates,
                    ("components", _) => StartPage::Components,
                    ("apis", _) => StartPage::Apis,
                    ("settings", _) => StartPage::Settings,
                    (_, Some(("template", reference))) if !reference.is_empty() => StartPage::Template(reference.to_owned()),
                    (_, Some(("editor", name))) if !name.is_empty() => StartPage::Editor(name.to_owned()),
                    _ => return Err(format!("Unknown page {page}.")),
                });
            }
            "--no-single-instance" if options => launch.single_instance = false,
            "--" if options => options = false,
            option if options && option.starts_with('-') => return Err(format!("Unknown option {option}.")),
            // A file manager may pass a file:// address for %U; this program asks for %f, a path.
            file => choose(&mut launch, Request::Open(absolute(file)?))?,
        }
    }
    Ok(Parsed::Run(launch))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    fn run(arguments: &[&str]) -> Result<Launch, String> {
        let arguments: Vec<String> = arguments.iter().map(|argument| argument.to_string()).collect();
        match parse(&arguments, Some(Path::new("/home/u")))? {
            Parsed::Run(launch) => Ok(launch),
            other => Err(format!("{other:?}")),
        }
    }

    #[test]
    fn the_ways_to_start() {
        assert_eq!(run(&[]).unwrap(), Launch { request: Request::Show, data: None, page: None, single_instance: true });
        assert_eq!(run(&["--edit", "My Widget"]).unwrap().request, Request::Edit("My Widget".into()));
        assert_eq!(run(&["/tmp/a b.swt"]).unwrap().request, Request::Open("/tmp/a b.swt".into()));
        assert_eq!(run(&["Downloads/clock.swt"]).unwrap().request, Request::Open("/home/u/Downloads/clock.swt".into()), "a relative path is made absolute before it is handed on");
        assert_eq!(run(&["--", "-odd.swt"]).unwrap().request, Request::Open("/home/u/-odd.swt".into()));
        let launch = run(&["--data", "/tmp/data", "--page", "template:template/Clock", "--no-single-instance"]).unwrap();
        assert_eq!((launch.data, launch.page, launch.single_instance), (Some("/tmp/data".into()), Some(StartPage::Template("template/Clock".into())), false));
        assert_eq!(run(&["--page", "editor:Clock"]).unwrap().page, Some(StartPage::Editor("Clock".into())));
        assert_eq!(run(&["--page", "settings"]).unwrap().page, Some(StartPage::Settings));
        assert_eq!(run(&["--page", "components"]).unwrap().page, Some(StartPage::Components));
        assert_eq!(run(&["--page", "apis"]).unwrap().page, Some(StartPage::Apis));
    }

    #[test]
    fn mistakes_are_refused_with_a_reason() {
        for arguments in [&["--edit"][..], &["--edit", ""], &["--edit", "A", "--edit", "B"], &["--edit", "A", "/tmp/b.swt"], &["--page", "nowhere"], &["--page", "editor:"], &["--frobnicate"], &["--data"]] {
            assert!(run(arguments).is_err(), "{arguments:?}");
        }
        assert_eq!(parse(&["--help".to_owned()], None), Ok(Parsed::Help));
        assert_eq!(parse(&["--version".to_owned()], None), Ok(Parsed::Version));
        assert!(parse(&["relative.swt".to_owned()], None).is_err());
    }
}
