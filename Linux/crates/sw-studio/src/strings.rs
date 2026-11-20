//! Every text the management window shows. The window is in English, like
//! every ScriptWidget application. The keys follow
//! `Windows/src/ScriptWidget.Studio/Services/Loc.cs` where the two windows say
//! the same thing.

/// Key and text. `{0}` and `{1}` are filled by [`tf`].
pub const TEXT: &[(&str, &str)] = &[
    ("app.title", "ScriptWidget"),
    ("nav.library", "My widgets"),
    ("nav.templates", "Templates"),
    ("nav.components", "Components"),
    ("nav.apis", "APIs"),
    ("nav.gallery", "Gallery"),
    ("nav.skills", "Skills"),
    ("nav.settings", "Settings"),
    //
    ("library.title", "My widgets"),
    ("library.new", "New widget"),
    ("library.import", "Import…"),
    ("library.newWithAi", "New with AI"),
    ("library.empty.title", "No widgets yet"),
    ("library.empty.detail", "Start from a template, or create an empty widget and write your own."),
    ("library.empty.templates", "Browse templates"),
    ("library.unreadable", "Its widget.json cannot be read."),
    ("library.failed", "Your widgets could not be listed: {0}"),
    //
    ("action.edit", "Edit"),
    ("action.addToDesktop", "Add to desktop"),
    ("action.export", "Export…"),
    ("action.delete", "Remove"),
    ("action.exportNamed", "Export {0}"),
    ("action.removeNamed", "Remove {0}"),
    ("action.use", "Use this template"),
    ("action.save", "Save"),
    ("action.back", "Back"),
    ("action.cancel", "Cancel"),
    ("action.ok", "OK"),
    //
    ("templates.title", "Templates"),
    ("templates.detail", "Ready-made widgets. Open one to see what it shows and how it is written, then make it yours."),
    ("templates.none", "No templates are installed with this program."),
    ("components.title", "Components"),
    ("components.detail", "What a widget is built from. Open one to see an example of it and how it is written."),
    ("apis.title", "APIs"),
    ("apis.detail", "What a widget's code can call. Open one to see an example that uses it."),
    ("templates.network", "Uses the network"),
    //
    ("detail.code", "Code"),
    ("detail.readOnly", "Read only"),
    ("detail.network", "Connects to {0}"),
    ("detail.noNetwork", "Does not use the network"),
    //
    ("editor.files", "Files"),
    ("editor.code", "Code editor"),
    ("editor.preview", "Preview"),
    ("editor.dark", "Dark"),
    ("editor.light", "Light"),
    ("editor.appearance", "Preview appearance: {0}"),
    ("editor.unsaved", "Unsaved changes"),
    ("editor.saved", "Saved"),
    ("editor.saveFailed", "Could not save: {0}"),
    ("editor.running", "Running…"),
    ("editor.ok", "Ran in {0} ms"),
    ("editor.logs", "Output"),
    ("editor.noLogs", "console.log output appears here."),
    ("editor.binary", "This file is not text and cannot be edited here."),
    ("editor.missing", "“{0}” is not one of your widgets."),
    ("editor.discard.title", "Discard unsaved changes?"),
    ("editor.discard.detail", "Your changes to {0} have not been saved."),
    ("editor.discard.confirm", "Discard"),
    ("editor.saveHint", "Ctrl+S"),
    ("editor.close.confirm", "Close without saving"),
    ("editor.newFile", "New file"),
    ("editor.newFile.title", "New file in this widget"),
    ("editor.newFile.hint", "lib/helpers.js"),
    ("editor.newFile.empty", "Give the file a name."),
    ("editor.newFile.type", "Only text files can be made here: .js, .jsx, .json, .csv, .txt, .md, .svg, .xml, .html, .css or .yaml."),
    ("editor.newFile.reserved", "widget.json describes the widget and cannot be made empty."),
    ("editor.newFile.exists", "There is already a file named {0}."),
    ("editor.newFile.failed", "The file was not made: {0}"),
    ("access.open", "Data access"),
    ("access.title", "Data access"),
    ("access.detail", "The widget's widget.json says which of these it would like to use. Here you decide what it gets. Everything is for this widget only and stays on this computer."),
    ("access.declared", "Asked for by this widget"),
    ("access.undeclared", "Not asked for: widget.json has no “{0}” permission"),
    ("access.allowed", "Allowed"),
    ("access.notAllowed", "Not allowed"),
    ("access.allow", "Allow"),
    ("access.stop", "Stop allowing"),
    ("access.failed", "The change could not be saved."),
    ("access.list.unreadable", "The list of picked files cannot be read."),
    ("access.notifications", "Notifications"),
    ("access.notifications.detail", "The widget may schedule notifications when you tap one of its buttons. They are shown by your desktop's notification service while the ScriptWidget service is running."),
    ("access.github", "GitHub profile"),
    ("access.github.detail", "The widget may read the name and the public numbers of the connected GitHub account. It never gets the token."),
    ("access.github.account", "Connected as {0}"),
    ("access.github.none", "No account is connected. Connect one in Settings."),
    ("access.github.unreadable", "The GitHub connection cannot be read. Disconnect it in Settings and connect again."),
    ("access.github.notAToken", "That is not a fine-grained personal access token. One starts with github_pat_."),
    ("access.github.refused", "GitHub did not accept the token."),
    ("access.github.rateLimit", "GitHub asks to wait before trying again."),
    ("access.github.keyring", "The system keyring could not be used, so the token was not kept. Check that a keyring such as GNOME Keyring or KeePassXC is running and unlocked. Nothing was stored elsewhere."),
    ("access.github.unavailable", "GitHub could not be reached."),
    ("access.documents", "Files"),
    ("access.documents.detail", "JSON and CSV files the widget may read, at most 8 of 256 KB each. It gets a file's name and what the file holds now, never where the file is."),
    ("access.documents.add", "Add a file…"),
    ("access.photos", "Pictures"),
    ("access.photos.detail", "Pictures the widget may show, at most 24. It gets a small copy of each, without the file's name, place or other details."),
    ("access.photos.add", "Add a picture…"),
    ("access.music", "Media player"),
    ("access.music.detail", "The widget may read what a media player on this desktop is playing: title, artist, album and position. It cannot control the player. There is nothing to allow here."),
    ("access.pick.confirm", "Choose"),
    ("access.pick.hint", "/home/you/file"),
    ("access.pick.gone", "This file can no longer be read."),
    ("access.pick.type", "Only .json and .csv files can be picked."),
    ("access.pick.documentTooLarge", "The file is larger than {0} KB."),
    ("access.pick.photoTooLarge", "The picture is larger than {0} MB."),
    ("access.pick.documentInvalid", "The file is not JSON or CSV a widget can read: JSON must be an object or a list; CSV needs a header row of unique names, at most 32 columns and 500 rows."),
    ("access.pick.photoInvalid", "The file is not a picture that can be read."),
    ("access.pick.full", "This widget already has {0}. Remove one first."),
    ("access.pick.duplicate", "That file is already picked for this widget."),
    ("access.pick.unreadable", "The file cannot be read."),
    //
    ("size.small", "Small"),
    ("size.medium", "Medium"),
    ("size.large", "Large"),
    ("size.extraLarge", "Extra large"),
    //
    ("dialog.new.title", "New widget"),
    ("dialog.new.hint", "Name"),
    ("dialog.new.default", "My Widget"),
    ("dialog.delete.title", "Remove “{0}”?"),
    ("dialog.delete.detail", "The widget and its files are deleted from this computer. This cannot be undone."),
    ("dialog.import.title", "Import this widget?"),
    ("dialog.import.detail", "“{0}” will be added to your widgets. Only import widgets from people you trust."),
    ("dialog.import.contents", "{0} files, {1}"),
    ("dialog.import.file", "From {0}"),
    ("dialog.import.confirm", "Import"),
    ("dialog.import.refused", "This file cannot be imported: {0}"),
    ("dialog.path.import", "Import a widget"),
    ("dialog.path.import.hint", "Path of a .swt file"),
    ("dialog.path.export", "Export “{0}”"),
    ("dialog.path.export.hint", "Where to save the .swt file"),
    ("dialog.error.title", "That did not work"),
    //
    ("toast.added", "Added to the desktop"),
    ("toast.exported", "Exported to {0}"),
    ("toast.imported", "“{0}” was added to your widgets"),
    ("toast.removed", "“{0}” was removed"),
    ("toast.hostMissing", "The ScriptWidget background service is not running, so the widget could not be placed. Start it, then try again."),
    ("toast.cliMissing", "The scriptwidget command was not found, so the widget could not be placed."),
    ("toast.addFailed", "The widget could not be placed: {0}"),
    //
    ("settings.title", "Settings"),
    ("settings.refresh", "Refresh interval"),
    ("settings.refresh.detail", "How often widgets without a schedule of their own run again."),
    ("settings.minutes", "{0} minutes"),
    ("settings.hours", "{0} hours"),
    ("settings.hour", "1 hour"),
    ("settings.failed", "The setting could not be saved: {0}"),
    ("settings.ai", "AI"),
    ("settings.ai.detail", "The provider that writes widgets for you in the editor. Your requests and the widget's code go from this computer to the provider you choose, and nowhere else. The address must start with https://."),
    ("settings.ai.baseUrl", "API base URL"),
    ("settings.ai.model", "Model"),
    ("settings.ai.suggested", "Suggested models"),
    ("settings.ai.loadModels", "Load models"),
    ("settings.ai.loadingModels", "Asking the endpoint…"),
    ("settings.ai.listed", "Models the endpoint lists ({0}). Click one to use it."),
    ("settings.ai.noModels", "The endpoint lists no models."),
    ("settings.ai.moreModels", "… and {0} more"),
    ("settings.ai.save", "Save provider"),
    ("settings.ai.saved", "The provider was saved."),
    ("settings.ai.key", "API key"),
    ("settings.ai.key.hint", "Paste the key here"),
    ("settings.ai.key.detail", "The key is kept in the system keyring, never in a file of ScriptWidget."),
    ("settings.ai.key.stored", "A key is stored in the keyring."),
    ("settings.ai.key.missing", "No key is stored for this provider."),
    ("settings.ai.key.environment", "The key from {0} is used for this run and is not saved."),
    ("settings.ai.key.store", "Store key"),
    ("settings.ai.key.remove", "Remove key"),
    ("settings.ai.key.removed", "The key was removed from the keyring."),
    //
    ("ai.open", "Ask AI"),
    ("ai.title", "AI conversation"),
    ("ai.close", "Close the conversation"),
    ("ai.empty", "Say what this widget should show or what to change. The answer is run here first; your widget changes only when you apply it."),
    ("ai.prompt", "What should change?"),
    ("ai.send", "Send"),
    ("ai.stop", "Stop"),
    ("ai.attempt", "Attempt {0} of {1}"),
    ("ai.thinking", "Waiting for the model…"),
    ("ai.writing", "The model is writing…"),
    ("ai.running", "Running the widget…"),
    ("ai.repairing", "That did not run. Asking again…"),
    ("ai.cancelled", "Stopped."),
    ("ai.interrupted", "Interrupted when the window was closed."),
    ("ai.changes", "Lines added: {0}, removed: {1}"),
    ("ai.noChanges", "The code is the same as the version before."),
    ("ai.wholeCode", "The code of this version"),
    ("ai.sizes", "At every size"),
    ("ai.version", "Version {0} of {1}"),
    ("ai.version.previous", "Previous version"),
    ("ai.version.next", "Next version"),
    ("ai.retry", "Try again"),
    ("ai.startOver", "New conversation from this version"),
    ("ai.startedOver", "A new conversation was started from this version."),
    ("ai.fix", "Fix runtime error"),
    ("ai.skills", "Skills ({0})"),
    ("ai.skills.detail", "The Skills of this conversation. Their instructions are added to its requests."),
    ("ai.skills.following", "This conversation uses the Skills that are turned on. Click one to choose for this conversation only."),
    ("ai.skills.follow", "Use the Skills that are turned on"),
    ("ai.examples", "Try an example"),
    ("ai.example.weather", "Weather"),
    ("ai.example.clock", "Clock"),
    ("ai.example.countdown", "Countdown"),
    ("ai.example.cryptoprice", "Crypto Price"),
    ("ai.example.batteryring", "Battery Ring"),
    ("ai.example.quote", "Quote"),
    ("ai.example.habitgrid", "Habit Grid"),
    ("ai.size", "Size"),
    ("ai.draft.title", "New widget with AI"),
    ("ai.draft.empty", "Describe the widget you want. The answer is run here first; nothing is added to your widgets until you save it."),
    ("ai.draft.prompt", "Describe a widget"),
    ("ai.draft.preview", "The widget is shown here once the AI has made it."),
    ("ai.sizes.show", "Show at the {0} size"),
    ("ai.save", "Save as a new widget"),
    ("ai.save.name", "Name of the new widget"),
    ("ai.saved", "“{0}” was saved to your widgets"),
    ("ai.save.hosts.title", "Let the new widget use the network?"),
    ("ai.save.hosts.detail", "This widget connects to {0}. The AI chose these hosts."),
    ("ai.save.hosts.confirm", "Allow and save"),
    ("ai.leave.title", "Leave this conversation?"),
    ("ai.leave.detail", "The widget has not been saved. The conversation is kept as a draft that the scriptwidget ai conversations command lists."),
    ("ai.leave.confirm", "Leave"),
    ("ai.skipped", "… {0} more lines"),
    ("ai.newHosts", "This version lets the widget connect to {0}."),
    ("ai.apply", "Apply to the widget"),
    ("ai.applied", "Applied to the widget."),
    ("ai.unsaved", "Save your changes before applying, or they would be lost."),
    ("ai.failed", "The conversation could not be opened: {0}"),
    ("ai.hosts.title", "Let the widget use the network?"),
    ("ai.hosts.detail", "This version connects to {0}. The widget may not do that yet."),
    ("ai.hosts.confirm", "Allow and apply"),
    //
    ("gallery.title", "Gallery"),
    ("gallery.detail", "Widgets and Skills from the community. Every file is checked against the catalog before it is installed."),
    ("gallery.refresh", "Refresh"),
    ("gallery.loading", "Loading the Gallery…"),
    ("gallery.unavailable.title", "The Gallery is unavailable"),
    ("gallery.unavailable.detail", "No verified copy of the catalog is saved on this computer yet."),
    ("gallery.retry", "Try again"),
    ("gallery.offline.title", "Offline"),
    ("gallery.offline.detail", "Showing the verified catalog saved {0}. Installing still needs a connection."),
    ("gallery.ago.now", "just now"),
    ("gallery.ago.minutes", "{0} minutes ago"),
    ("gallery.ago.hours", "{0} hours ago"),
    ("gallery.ago.days", "{0} days ago"),
    ("gallery.search", "Search widgets and skills"),
    ("gallery.filter.all", "All"),
    ("gallery.filter.widgets", "Widgets"),
    ("gallery.filter.skills", "Skills"),
    ("gallery.none", "Nothing in the Gallery matches."),
    ("gallery.kind.widget", "Widget"),
    ("gallery.kind.skill", "Skill"),
    ("gallery.install", "Install"),
    ("gallery.update", "Update"),
    ("gallery.updateFrom", "Update from {0}"),
    ("gallery.installed", "Installed"),
    ("gallery.installing", "Downloading and checking…"),
    ("gallery.notInstalled", "Not installed: {0}"),
    ("gallery.toast.skill", "“{0}” was installed. Turn it on under Skills to use it with AI."),
    ("gallery.fact.type", "Type"),
    ("gallery.fact.skillType", "Skill (guidance for AI requests)"),
    ("gallery.fact.version", "Version"),
    ("gallery.fact.author", "Author"),
    ("gallery.fact.license", "License"),
    ("gallery.fact.files", "Files"),
    ("gallery.fact.requires", "Requires"),
    ("gallery.fact.api", "Runtime API {0} or later"),
    ("gallery.preview.loading", "Checking what this widget may do…"),
    ("gallery.preview.failed", "What this widget may do could not be checked: {0}"),
    ("gallery.preview.skill", "Skills only add instructions to AI requests. They cannot run code or grant permissions."),
    ("gallery.preview.unsupported", "Uses {0}, which ScriptWidget for Linux does not have. The widget will say so instead of showing its content."),
    ("gallery.preview.permissions", "Permissions: {0}"),
    ("gallery.preview.noPermissions", "Asks for no permission"),
    ("gallery.source", "View source on GitHub"),
    ("gallery.verified", "Every file is checked against the size and SHA-256 in the curated catalog before it is installed. That detects corrupted or substituted downloads; it does not review the code for you."),
    //
    ("skills.title", "Skills"),
    ("skills.detail", "Skills add their instructions to AI requests while they are turned on. They cannot run code, use the network, or grant permissions."),
    ("skills.inEffect", "Added to AI requests now: {0}"),
    ("skills.noneInEffect", "No Skill is turned on."),
    ("skills.importFolder", "Import folder…"),
    ("skills.builtIn", "Built-in"),
    ("skills.on", "On"),
    ("skills.turnOn", "Turn on"),
    ("skills.turnOff", "Turn off"),
    ("skills.turnOnNamed", "Turn on {0}"),
    ("skills.turnOffNamed", "Turn off {0}"),
    ("skills.view", "Instructions"),
    ("skills.hide", "Hide instructions"),
    ("skills.toast.imported", "“{0}” was imported. Turn it on to use it with AI."),
    ("skills.refused", "This Skill cannot be imported: {0}"),
    ("skills.remove.detail", "The Skill is removed from this computer. Export it first if you want to keep a copy."),
    ("skills.path.import", "Import a Skill"),
    ("skills.path.import.hint", "Path of a .swskill file or of a folder"),
    ("skills.path.export.hint", "Where to save the .swskill file"),
    //
    ("settings.github", "GitHub"),
    ("settings.github.detail", "For widgets that show your GitHub profile. Paste a fine-grained personal access token (github.com, Settings, Developer settings); it needs no permissions. It is checked with GitHub and kept in the system keyring, never in a file. Each widget is allowed separately, under Data access in its editor."),
    ("settings.github.account", "Connected as {0}"),
    ("settings.github.none", "No account is connected."),
    ("settings.github.token", "GitHub token"),
    ("settings.github.token.hint", "github_pat_…"),
    ("settings.github.connect", "Connect"),
    ("settings.github.connecting", "Asking GitHub…"),
    ("settings.github.connected", "Connected as {0}. No widget may read the profile until you allow it."),
    ("settings.github.disconnect", "Disconnect"),
    ("settings.github.disconnected", "Disconnected. The token was removed from the keyring."),
    ("settings.data", "Data folder"),
    ("settings.about", "About"),
    ("settings.version", "ScriptWidget for Linux {0} (in development)"),
    ("settings.licence", "ScriptWidget is licensed under Apache-2.0."),
    ("settings.licences", "Built with GPUI and gpui-kit (Apache-2.0), QuickJS-NG (MIT), Skia (BSD-3-Clause), Lucide icons (ISC) and the Inter typeface (SIL OFL 1.1)."),
    ("settings.website", "Website"),
    //
    ("startup.failed", "ScriptWidget could not start: {0}"),
    ("bytes.b", "{0} bytes"),
    ("bytes.kb", "{0} KB"),
    ("bytes.mb", "{0} MB"),
];

/// The text for `key`, or `None` for a key the table does not have.
pub fn text(key: &str) -> Option<&'static str> {
    TEXT.iter().find(|(name, _)| *name == key).map(|(_, text)| *text)
}

/// The text for `key`. An unknown key shows as itself, so a mistake is visible.
pub fn t(key: &str) -> String {
    text(key).map_or_else(|| key.to_owned(), str::to_owned)
}

/// [`t`] with `{0}`, `{1}`… replaced. The arguments are inserted as they are, never interpreted again.
pub fn tf(key: &str, arguments: &[&str]) -> String {
    fill(&t(key), arguments)
}

fn fill(pattern: &str, arguments: &[&str]) -> String {
    let mut result = String::with_capacity(pattern.len() + 16);
    let mut rest = pattern;
    while let Some(open) = rest.find('{') {
        result.push_str(&rest[..open]);
        let after = &rest[open + 1..];
        match after.find('}').and_then(|close| after[..close].parse::<usize>().ok().map(|index| (index, close))) {
            Some((index, close)) => {
                result.push_str(arguments.get(index).copied().unwrap_or(""));
                rest = &after[close + 1..];
            }
            None => {
                result.push('{');
                rest = after;
            }
        }
    }
    result.push_str(rest);
    result
}

/// The label of an example prompt, by the English title the shared list gives it; an example
/// that has no text here keeps that title.
pub fn example(title: &str) -> String {
    let key = format!("ai.example.{}", title.to_lowercase().replace(' ', ""));
    text(&key).map_or_else(|| title.to_owned(), str::to_owned)
}

/// The name of a widget family ("small", "extraLarge").
pub fn family(name: &str) -> String {
    t(&format!("size.{name}"))
}

pub fn bytes(count: u64) -> String {
    if count < 1024 {
        tf("bytes.b", &[&count.to_string()])
    } else if count < 1024 * 1024 {
        tf("bytes.kb", &[&format!("{:.1}", count as f64 / 1024.0)])
    } else {
        tf("bytes.mb", &[&format!("{:.1}", count as f64 / (1024.0 * 1024.0))])
    }
}

/// The label of a refresh interval in minutes.
pub fn interval(minutes: u32) -> String {
    match minutes {
        60 => t("settings.hour"),
        minutes if minutes > 60 && minutes % 60 == 0 => tf("settings.hours", &[&(minutes / 60).to_string()]),
        minutes => tf("settings.minutes", &[&minutes.to_string()]),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;

    fn placeholders(text: &str) -> BTreeSet<String> {
        let mut found = BTreeSet::new();
        let mut rest = text;
        while let Some(open) = rest.find('{') {
            let after = &rest[open + 1..];
            if let Some(close) = after.find('}') {
                found.insert(after[..close].to_owned());
            }
            rest = after;
        }
        found
    }

    #[test]
    fn every_key_is_listed_once_and_has_a_text() {
        let mut seen = BTreeSet::new();
        for (key, text) in TEXT {
            assert!(seen.insert(*key), "{key} is listed twice");
            assert!(!text.trim().is_empty(), "{key} has no text");
            assert!(!text.chars().any(|character| ('\u{2e80}'..='\u{9fff}').contains(&character)), "{key} is not English");
            for argument in placeholders(text) {
                assert!(argument.parse::<usize>().is_ok(), "{key} has the placeholder {{{argument}}}");
            }
        }
    }

    /// The keys the window's source asks for, read from the source itself.
    fn used_keys(source: &str) -> Vec<String> {
        let mut keys = Vec::new();
        for call in ["t(\"", "tf(\""] {
            let mut rest = source;
            while let Some(at) = rest.find(call) {
                // `t(` must be the whole name of the function called.
                let named = rest[..at].chars().next_back().is_some_and(|before| before.is_alphanumeric() || before == '_');
                let after = &rest[at + call.len()..];
                if let (false, Some(end)) = (named, after.find('"')) {
                    keys.push(after[..end].to_owned());
                }
                rest = after;
            }
        }
        keys
    }

    #[test]
    fn every_key_the_window_uses_exists() {
        let sources = [
            include_str!("ui/mod.rs"),
            include_str!("ui/window.rs"),
            include_str!("ui/library.rs"),
            include_str!("ui/templates.rs"),
            include_str!("ui/editor.rs"),
            include_str!("ui/settings.rs"),
            include_str!("ui/preview_pane.rs"),
            include_str!("ui/ai.rs"),
            include_str!("ui/gallery.rs"),
            include_str!("ui/skills.rs"),
            include_str!("ui/access.rs"),
            include_str!("access.rs"),
            include_str!("model.rs"),
            include_str!("main.rs"),
        ];
        let mut used = BTreeSet::new();
        for source in sources {
            for key in used_keys(source) {
                assert!(text(&key).is_some(), "the window asks for the unknown text {key}");
                used.insert(key);
            }
        }
        assert!(used.len() > 40, "the scan found only {} keys", used.len());
        // Keys that are built at run time or used by this module.
        let indirect = |key: &str| key.starts_with("size.") || key.starts_with("bytes.") || key.starts_with("ai.example.") || ["settings.hour", "settings.hours", "settings.minutes"].contains(&key);
        let unused: Vec<&str> = TEXT.iter().map(|(key, _)| *key).filter(|key| !used.contains(*key) && !indirect(key)).collect();
        assert!(unused.is_empty(), "texts nothing shows: {unused:?}");
    }

    #[test]
    fn every_example_prompt_has_a_label() {
        for example in sw_core::ai::AiExamplePrompts::all() {
            let key = format!("ai.example.{}", example.title.to_lowercase().replace(' ', ""));
            assert_eq!(text(&key), Some(example.title), "{key}");
            assert_eq!(super::example(example.title), example.title);
        }
        assert_eq!(example("Not An Example"), "Not An Example", "an example without a text keeps its title");
        let labelled = TEXT.iter().filter(|(key, _)| key.starts_with("ai.example.")).count();
        assert_eq!(labelled, sw_core::ai::AiExamplePrompts::all().len(), "no label is left without its example");
    }

    #[test]
    fn arguments_are_inserted_and_never_read_again() {
        assert_eq!(fill("Remove “{0}”?", &["Clock"]), "Remove “Clock”?");
        assert_eq!(fill("{0} files, {1}", &["3", "2 KB"]), "3 files, 2 KB");
        assert_eq!(fill("{0} and {0}", &["{1}", "never"]), "{1} and {1}", "a package name with braces stays text");
        assert_eq!(fill("{1}", &["only"]), "");
        assert_eq!(fill("{x} {", &[]), "{x} {");
        assert_eq!(interval(15), fill(text("settings.minutes").unwrap(), &["15"]));
        assert_eq!(interval(120), fill(text("settings.hours").unwrap(), &["2"]));
    }
}
