//! What the service starts on the user's behalf: a browser or a mail program
//! for a link, and the management window. Both go through one trait so that
//! tests can record what would have been started instead of starting it.
//!
//! A link comes from a package and is not trusted. Only `http`, `https` and
//! `mailto` are opened: a file path or a `file:` URL would run programs, and
//! many registered handlers were never meant to take input from untrusted
//! content (the same rule as `Windows/src/ScriptWidget.App/SystemIntegration.cs`).
//! Programs are started with an argument vector, never through a shell.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// Longer text is not a link.
pub const MAXIMUM_LINK_LENGTH: usize = 4096;

/// What a link of a widget may do.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LinkTarget {
    /// Open this URL: the canonical form of the parsed text, never the text itself.
    Open(String),
    /// A `scriptwidget:` link: show the management window. Nothing of the link is passed on.
    Application,
}

/// Decides what a link may do, or `None` when it is refused.
pub fn checked_link(text: &str) -> Option<LinkTarget> {
    if text.trim().is_empty() || text.len() > MAXIMUM_LINK_LENGTH {
        return None;
    }
    let url = url::Url::parse(text.trim()).ok()?;
    match url.scheme() {
        "scriptwidget" => Some(LinkTarget::Application),
        "http" | "https" if url.host_str().is_some_and(|host| !host.is_empty()) => Some(LinkTarget::Open(url.as_str().to_owned())),
        "mailto" => Some(LinkTarget::Open(url.as_str().to_owned())),
        _ => None,
    }
}

pub trait Launcher: Send + Sync {
    /// Opens a URL that [`checked_link`] accepted. Returns false when nothing could be started.
    fn open_link(&self, url: &str) -> bool;
    /// Shows the management window, on the package with this name when one is given. Returns false when it is not installed.
    fn open_studio(&self, package: Option<&str>) -> bool;
}

/// Starts `xdg-open` and `scriptwidget-studio`.
pub struct SystemLauncher;

/// Starts a program detached from the service's input and output, and collects it when it ends.
fn start(mut command: Command) -> bool {
    command.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    match command.spawn() {
        Ok(mut child) => {
            // No zombie stays behind, and nothing waits for a program the user may keep open for hours.
            let _ = std::thread::Builder::new().name("scriptwidget-child".into()).spawn(move || {
                let _ = child.wait();
            });
            true
        }
        Err(_) => false,
    }
}

/// The management window program: beside this program, or on the search path.
pub fn studio_program() -> Option<PathBuf> {
    const NAME: &str = "scriptwidget-studio";
    let executable = |path: &Path| {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(path).is_ok_and(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
    };
    let beside = std::env::current_exe().ok().and_then(|program| Some(program.parent()?.join(NAME)));
    let on_path = std::env::var_os("PATH").into_iter().flat_map(|path| std::env::split_paths(&path).collect::<Vec<_>>()).filter(|directory| directory.is_absolute()).map(|directory| directory.join(NAME));
    beside.into_iter().chain(on_path).find(|candidate| executable(candidate))
}

impl Launcher for SystemLauncher {
    fn open_link(&self, url: &str) -> bool {
        // Checked again here, so that nothing reaches xdg-open that the rule above did not produce.
        match checked_link(url) {
            Some(LinkTarget::Open(canonical)) if canonical == url => {
                let mut command = Command::new("xdg-open");
                command.arg(canonical);
                start(command)
            }
            _ => false,
        }
    }

    fn open_studio(&self, package: Option<&str>) -> bool {
        let Some(program) = studio_program() else { return false };
        let mut command = Command::new(program);
        if let Some(package) = package {
            command.arg("--edit").arg(package);
        }
        start(command)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_web_and_mail_links_are_opened() {
        assert_eq!(checked_link("https://example.com/a b?q=1"), Some(LinkTarget::Open("https://example.com/a%20b?q=1".into())));
        assert_eq!(checked_link("  HTTP://Example.COM  "), Some(LinkTarget::Open("http://example.com/".into())));
        assert_eq!(checked_link("mailto:someone@example.com?subject=Hi"), Some(LinkTarget::Open("mailto:someone@example.com?subject=Hi".into())));
        assert_eq!(checked_link("scriptwidget://open?package=x"), Some(LinkTarget::Application));
        for refused in [
            "",
            "   ",
            "example.com",
            "/etc/passwd",
            "file:///etc/passwd",
            "FILE:///etc/passwd",
            "javascript:alert(1)",
            "data:text/html,<script>alert(1)</script>",
            "ssh://host/",
            "smb://host/share",
            "vscode://file/etc/passwd",
            "steam://run/1",
            "tel:+1234",
            "http://",
            "--version",
            "-a https://example.com",
            "x-scheme-handler/http",
        ] {
            assert_eq!(checked_link(refused), None, "{refused:?}");
        }
        assert_eq!(checked_link(&format!("https://example.com/{}", "a".repeat(MAXIMUM_LINK_LENGTH))), None);
    }

    #[test]
    fn an_opened_url_never_starts_like_an_option() {
        // Whatever the text, what is handed to xdg-open begins with one of three schemes.
        for text in ["https://example.com", "http://-x.example.com/", "mailto:-x@example.com", "https://example.com/ --flag"] {
            if let Some(LinkTarget::Open(url)) = checked_link(text) {
                assert!(url.starts_with("http://") || url.starts_with("https://") || url.starts_with("mailto:"), "{url}");
                assert!(!url.contains(' '), "{url}");
            }
        }
    }
}
