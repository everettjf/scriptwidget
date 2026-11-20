//! The window's state, its navigation and what the pages share.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use futures::StreamExt as _;
use futures::channel::mpsc::{UnboundedReceiver, unbounded};
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputState};
use gpui_kit::component::notification::Notification;
use gpui_kit::component::{ActiveTheme as _, IconName, Selectable as _, Theme, WindowExt as _, h_flex, v_flex};
use gpui_kit::{App, AppContext as _, Context, Entity, FocusHandle, Focusable, InteractiveElement as _, IntoElement, ParentElement as _, Render, SharedString, Styled as _, Subscription, Task, Window, div, px};

use super::editor::EditorSession;
use super::preview_pane::{PreviewPane, Shown};
use super::templates::TemplateSession;
use super::{Back, Save};
use crate::completion::ApiReference;
use crate::debounce::Debouncer;
use crate::instance::Request;
use crate::launch::StartPage;
use crate::model::{PreviewRequest, PreviewResult, Studio, TemplateGroup, WidgetCard};
use crate::service::{self, AddOutcome};
use crate::settings::Settings;
use crate::strings::{t, tf};

/// How long after the last key the preview runs again.
const PREVIEW_DELAY: Duration = Duration::from_millis(400);
const ADD_LIMIT: Duration = Duration::from_secs(20);

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Page {
    Library,
    Templates,
    Template,
    Editor,
    Settings,
}

/// Where a navigation goes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Target {
    Library,
    Templates,
    Components,
    Apis,
    Settings,
    Template(String),
    Editor(String),
}

pub struct StudioWindow {
    pub(super) studio: Arc<Studio>,
    pub(super) api: Arc<ApiReference>,
    /// The AI conversation and the provider settings (see [`crate::ai`]).
    pub(super) ai: Arc<crate::ai::AiService>,
    pub(super) ai_settings: Option<super::ai::AiSettingsForm>,
    pub(super) settings: Settings,
    cli: PathBuf,
    pub(super) page: Page,
    pub(super) widgets: Vec<WidgetCard>,
    pub(super) library_error: Option<String>,
    pub(super) template_groups: Vec<TemplateGroup>,
    /// Which list the Templates page shows: "template", "component" or "api".
    pub(super) group: &'static str,
    /// Small pictures of widgets ("w/<name>") and templates ("t/<group/name>").
    pub(super) thumbnails: HashMap<String, Shown>,
    thumbnail_run: u64,
    pub(super) template: Option<TemplateSession>,
    pub(super) editor: Option<EditorSession>,
    pub(super) previews: Debouncer<PreviewRequest>,
    /// Pictures that are no longer shown; their textures are released at the next frame.
    retired: Vec<Shown>,
    pub(super) scale: f32,
    pub(super) refresh_minutes: u32,
    focus: FocusHandle,
    _subscriptions: Vec<Subscription>,
    _tasks: Vec<Task<()>>,
}

impl StudioWindow {
    pub fn new(studio: Arc<Studio>, first: Request, page: Option<StartPage>, requests: UnboundedReceiver<Request>, window: &mut Window, cx: &mut Context<Self>) -> Self {
        Theme::sync_system_appearance(Some(window), cx);
        let appearance = cx.observe_window_appearance(window, |_, window, cx| Theme::sync_system_appearance(Some(window), cx));

        // Previews are made on a thread of their own and come back here.
        let (results, mut arrived) = unbounded::<(u64, PreviewResult)>();
        let engine = studio.clone();
        let previews = Debouncer::start(PREVIEW_DELAY, move |request: PreviewRequest| engine.preview(&request), move |ticket, result| {
            let _ = results.unbounded_send((ticket, result));
        });
        let preview_task = cx.spawn(async move |this, cx| {
            while let Some((ticket, result)) = arrived.next().await {
                if this.update(cx, |this, cx| this.preview_arrived(ticket, result, cx)).is_err() {
                    break;
                }
            }
        });
        // What later starts of the program ask for.
        let mut requests = requests;
        let request_task = cx.spawn_in(window, async move |this, cx| {
            while let Some(request) = requests.next().await {
                let handled = this.update_in(cx, |this, window, cx| {
                    window.activate_window();
                    this.handle_request(request, window, cx);
                });
                if handled.is_err() {
                    break;
                }
            }
        });

        let settings = Settings::new(studio.paths().settings());
        let mut this = Self {
            api: Arc::new(ApiReference::embedded()),
            ai: super::ai::service(studio.clone()),
            ai_settings: None,
            refresh_minutes: settings.selected_interval(),
            settings,
            cli: service::command_line(|name| std::env::var_os(name), std::env::current_exe().ok().as_deref()),
            page: Page::Library,
            widgets: Vec::new(),
            library_error: None,
            template_groups: studio.template_groups(),
            group: "template",
            thumbnails: HashMap::new(),
            thumbnail_run: 0,
            template: None,
            editor: None,
            previews,
            retired: Vec::new(),
            scale: window.scale_factor(),
            focus: cx.focus_handle(),
            studio,
            _subscriptions: vec![appearance],
            _tasks: vec![preview_task, request_task],
        };
        this.reload_library(cx);
        // Where the program was asked to start. Not done here but once the
        // window exists: a start that fails (a widget that is not installed, a
        // file that cannot be read) shows a message, and a message needs the
        // window's own state, which is only there after this function returns.
        // Doing it here made `--edit <unknown name>` end the program.
        let start = cx.spawn_in(window, async move |this, cx| {
            let _ = this.update_in(cx, |this, window, cx| {
                match page {
                    Some(StartPage::Library) | None => {}
                    Some(StartPage::Templates) => this.go(Target::Templates, window, cx),
                    Some(StartPage::Components) => this.go(Target::Components, window, cx),
                    Some(StartPage::Apis) => this.go(Target::Apis, window, cx),
                    Some(StartPage::Settings) => this.go(Target::Settings, window, cx),
                    Some(StartPage::Template(reference)) => this.go(Target::Template(reference), window, cx),
                    Some(StartPage::Editor(name)) => this.go(Target::Editor(name), window, cx),
                }
                this.handle_request(first, window, cx);
            });
        });
        this._tasks.push(start);
        this
    }

    pub(super) fn handle_request(&mut self, request: Request, window: &mut Window, cx: &mut Context<Self>) {
        match request {
            Request::Show => {}
            Request::Edit(name) => self.navigate(Target::Editor(name), window, cx),
            Request::Open(path) => self.offer_import(path, window, cx),
        }
    }

    // Navigation

    /// Goes to `target`, asking first when the editor holds unsaved changes.
    pub(super) fn navigate(&mut self, target: Target, window: &mut Window, cx: &mut Context<Self>) {
        let unsaved = self.editor.as_ref().filter(|session| self.page == Page::Editor && session.dirty).map(|session| session.path.clone());
        let Some(path) = unsaved else { return self.go(target, window, cx) };
        let this = cx.weak_entity();
        window.open_alert_dialog(cx, move |alert, _, _| {
            let (this, target) = (this.clone(), target.clone());
            alert.title(t("editor.discard.title")).description(tf("editor.discard.detail", &[&path])).confirm().ok_text(t("editor.discard.confirm")).cancel_text(t("action.cancel")).on_ok(move |_, window, cx| {
                let _ = this.update(cx, |this, cx| this.go(target.clone(), window, cx));
                true
            })
        });
    }

    /// Goes to `target` without asking.
    pub(super) fn go(&mut self, target: Target, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(session) = self.editor.take() {
            // A turn of the conversation that is still running ends with the page it was on.
            if let Some(view) = &session.ai {
                view.panel.cancel();
            }
            self.retired.extend(session.pane.shown);
        }
        if let Some(session) = self.template.take() {
            self.retired.extend(session.pane.shown);
        }
        match target {
            Target::Library => {
                self.page = Page::Library;
                self.reload_library(cx);
            }
            Target::Templates | Target::Components | Target::Apis => {
                self.group = match target {
                    Target::Components => "component",
                    Target::Apis => "api",
                    _ => "template",
                };
                self.page = Page::Templates;
                self.make_thumbnails(cx);
            }
            Target::Settings => {
                self.refresh_minutes = self.settings.selected_interval();
                self.load_ai_settings(window, cx);
                self.page = Page::Settings;
            }
            Target::Template(reference) => self.open_template(&reference, window, cx),
            Target::Editor(name) => self.open_editor(&name, None, window, cx),
        }
        self.focus.focus(window, cx);
        cx.notify();
    }

    pub(super) fn dark(&self, cx: &App) -> bool {
        cx.theme().is_dark()
    }

    // The list of widgets and the small pictures

    pub(super) fn reload_library(&mut self, cx: &mut Context<Self>) {
        match self.studio.widgets() {
            Ok(widgets) => {
                self.widgets = widgets;
                self.library_error = None;
            }
            Err(error) => {
                self.widgets.clear();
                self.library_error = Some(error.0);
            }
        }
        let listed: Vec<String> = self.widgets.iter().map(|card| format!("w/{}", card.name)).collect();
        let gone: Vec<String> = self.thumbnails.keys().filter(|key| key.starts_with("w/") && !listed.contains(key)).cloned().collect();
        for key in gone {
            self.retired.extend(self.thumbnails.remove(&key));
        }
        self.make_thumbnails(cx);
        cx.notify();
    }

    /// Forgets the picture of a widget whose files changed.
    pub(super) fn forget_thumbnail(&mut self, name: &str) {
        self.retired.extend(self.thumbnails.remove(&format!("w/{name}")));
    }

    /// Draws the pictures the current page still lacks, one after the other, off this thread.
    pub(super) fn make_thumbnails(&mut self, cx: &mut Context<Self>) {
        use crate::model::PreviewSource;
        let dark = self.dark(cx);
        let mut wanted: Vec<(String, PreviewRequest)> = Vec::new();
        let request = |source, family: &str| PreviewRequest { source, family: family.to_owned(), dark, scale: self.scale };
        match self.page {
            Page::Templates => {
                // A template that asks the network is drawn only when it is opened.
                for card in self.template_groups.iter().filter(|group| group.group == self.group).flat_map(|group| &group.templates).filter(|card| !card.network) {
                    wanted.push((format!("t/{}", card.reference), request(PreviewSource::Bundled(card.reference.clone()), "medium")));
                }
            }
            _ => {
                for card in self.widgets.iter().filter(|card| card.readable) {
                    wanted.push((format!("w/{}", card.name), request(PreviewSource::Installed { name: card.name.clone(), edits: vec![] }, card.card_family())));
                }
            }
        }
        wanted.retain(|(key, _)| !self.thumbnails.contains_key(key));
        self.thumbnail_run += 1;
        let run = self.thumbnail_run;
        let studio = self.studio.clone();
        cx.spawn(async move |this, cx| {
            for (key, request) in wanted {
                let engine = studio.clone();
                let result = cx.background_executor().spawn(async move { engine.preview(&request) }).await;
                let keep_going = this.update(cx, |this, cx| {
                    if let Some(shown) = result.picture.and_then(Shown::from_picture) {
                        this.retired.extend(this.thumbnails.insert(key, shown));
                        cx.notify();
                    }
                    // A newer run has taken over when the page changed.
                    this.thumbnail_run == run
                });
                if !matches!(keep_going, Ok(true)) {
                    break;
                }
            }
        })
        .detach();
    }

    // Previews of the open template or widget

    pub(super) fn pane_mut(&mut self) -> Option<&mut PreviewPane> {
        match self.page {
            Page::Editor => self.editor.as_mut().map(|session| &mut session.pane),
            Page::Template => self.template.as_mut().map(|session| &mut session.pane),
            _ => None,
        }
    }

    /// Asks for the preview of what is open: after a pause while typing, or at once.
    pub(super) fn request_preview(&mut self, now: bool, cx: &mut Context<Self>) {
        use crate::model::PreviewSource;
        let source = match self.page {
            Page::Editor => self.editor.as_ref().map(|session| PreviewSource::Installed { name: session.name.clone(), edits: session.unsaved(cx) }),
            Page::Template => self.template.as_ref().map(|session| PreviewSource::Bundled(session.detail.reference.clone())),
            _ => None,
        };
        let scale = self.scale;
        let Some((source, pane)) = source.zip(self.pane_mut()) else { return };
        let request = PreviewRequest { source, family: pane.family.clone(), dark: pane.dark, scale };
        pane.running = true;
        let ticket = if now { self.previews.request_now(request) } else { self.previews.request(request) };
        if let Some(pane) = self.pane_mut() {
            pane.ticket = ticket;
        }
        cx.notify();
    }

    fn preview_arrived(&mut self, ticket: u64, result: PreviewResult, cx: &mut Context<Self>) {
        // A result for something that is no longer open, or that was typed over, is dropped.
        let Some(pane) = self.pane_mut().filter(|pane| pane.ticket == ticket) else { return };
        let replaced = pane.take(result);
        self.retired.extend(replaced);
        cx.notify();
    }

    pub(super) fn set_preview_family(&mut self, family: &'static str, cx: &mut Context<Self>) {
        if let Some(pane) = self.pane_mut() {
            pane.family = family.to_owned();
        }
        self.request_preview(true, cx);
    }

    pub(super) fn toggle_preview_appearance(&mut self, cx: &mut Context<Self>) {
        if let Some(pane) = self.pane_mut() {
            pane.dark = !pane.dark;
        }
        self.request_preview(true, cx);
    }

    // What several pages do

    pub(super) fn notify_error(&self, message: impl Into<SharedString>, window: &mut Window, cx: &mut App) {
        window.push_notification(Notification::error(message).title(t("dialog.error.title")), cx);
    }

    /// Asks the background service to place a widget, through the `scriptwidget` command.
    pub(super) fn add_to_desktop(&mut self, name: String, family: Option<String>, window: &mut Window, cx: &mut Context<Self>) {
        let cli = self.cli.clone();
        cx.spawn_in(window, async move |this, cx| {
            let outcome = cx.background_executor().spawn(async move { service::add_to_desktop(&cli, &name, family.as_deref(), ADD_LIMIT) }).await;
            let _ = this.update_in(cx, |this, window, cx| match outcome {
                AddOutcome::Added => window.push_notification(Notification::success(t("toast.added")), cx),
                AddOutcome::ServiceNotRunning => window.push_notification(Notification::warning(t("toast.hostMissing")), cx),
                AddOutcome::CommandMissing => this.notify_error(t("toast.cliMissing"), window, cx),
                AddOutcome::Failed(reason) => this.notify_error(tf("toast.addFailed", &[&reason]), window, cx),
            });
        })
        .detach();
    }

    /// Asks where to save, then writes the `.swt` file.
    pub(super) fn export(&mut self, name: String, window: &mut Window, cx: &mut Context<Self>) {
        let folder = downloads_folder();
        let suggested = format!("{name}.swt");
        let chosen = cx.prompt_for_new_path(&folder, Some(&suggested));
        cx.spawn_in(window, async move |this, cx| {
            let target = match chosen.await {
                Ok(Ok(Some(target))) => target,
                Ok(Ok(None)) => return,
                // No file chooser on this desktop: ask for the path in the window.
                Ok(Err(_)) | Err(_) => {
                    let _ = this.update_in(cx, |this, window, cx| {
                        let title = tf("dialog.path.export", &[&name]);
                        this.ask_path(title, t("dialog.path.export.hint"), folder.join(&suggested), window, cx, move |this, target, window, cx| this.write_export(name.clone(), target, window, cx));
                    });
                    return;
                }
            };
            let _ = this.update_in(cx, |this, window, cx| this.write_export(name, target, window, cx));
        })
        .detach();
    }

    fn write_export(&mut self, name: String, target: PathBuf, window: &mut Window, cx: &mut Context<Self>) {
        let studio = self.studio.clone();
        let target = if target.extension().is_some() { target } else { target.with_extension("swt") };
        cx.spawn_in(window, async move |this, cx| {
            let written = target.clone();
            let result = cx.background_executor().spawn(async move { studio.export(&name, &written) }).await;
            let _ = this.update_in(cx, |this, window, cx| match result {
                Ok(()) => window.push_notification(Notification::success(tf("toast.exported", &[&target.display().to_string()])), cx),
                Err(error) => this.notify_error(error.0, window, cx),
            });
        })
        .detach();
    }

    /// Asks which `.swt` file to import.
    pub(super) fn choose_import(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let chosen = cx.prompt_for_paths(gpui_kit::PathPromptOptions { files: true, directories: false, multiple: false, prompt: Some(t("dialog.import.confirm").into()) });
        cx.spawn_in(window, async move |this, cx| {
            let _ = match chosen.await {
                Ok(Ok(Some(paths))) => this.update_in(cx, |this, window, cx| {
                    if let Some(path) = paths.into_iter().next() {
                        this.offer_import(path, window, cx);
                    }
                }),
                Ok(Ok(None)) => Ok(()),
                Ok(Err(_)) | Err(_) => this.update_in(cx, |this, window, cx| {
                    this.ask_path(t("dialog.path.import"), t("dialog.path.import.hint"), downloads_folder().join(""), window, cx, |this, path, window, cx| this.offer_import(path, window, cx));
                }),
            };
        })
        .detach();
    }

    /// A dialog with one line for a path, for desktops without a file chooser.
    fn ask_path(&mut self, title: String, hint: String, initial: PathBuf, window: &mut Window, cx: &mut Context<Self>, then: impl Fn(&mut Self, PathBuf, &mut Window, &mut Context<Self>) + 'static) {
        let input = cx.new(|cx| InputState::new(window, cx).placeholder(hint.clone()).default_value(initial.display().to_string()));
        self.ask_text(title, input, window, cx, move |this, text, window, cx| {
            let path = PathBuf::from(text);
            if path.is_absolute() {
                then(this, path, window, cx);
            }
        });
    }

    /// A dialog with one text field; `then` receives the trimmed text when it is not empty.
    pub(super) fn ask_text(&mut self, title: String, input: Entity<InputState>, window: &mut Window, cx: &mut Context<Self>, then: impl Fn(&mut Self, String, &mut Window, &mut Context<Self>) + 'static) {
        let this = cx.weak_entity();
        let then = std::rc::Rc::new(then);
        let focused = std::rc::Rc::new(std::cell::Cell::new(false));
        window.open_alert_dialog(cx, move |alert, window, cx| {
            if !focused.replace(true) {
                input.focus_handle(cx).focus(window, cx);
            }
            let (this, then, field) = (this.clone(), then.clone(), input.clone());
            alert.title(title.clone()).child(Input::new(&input).aria_label(title.clone())).confirm().ok_text(t("action.ok")).cancel_text(t("action.cancel")).on_ok(move |_, window, cx| {
                let text = field.read(cx).value().trim().to_owned();
                if text.is_empty() {
                    return false;
                }
                let _ = this.update(cx, |this, cx| then(this, text, window, cx));
                true
            })
        });
    }

    /// Reads what a `.swt` file holds, shows it, and imports it when the user agrees.
    pub(super) fn offer_import(&mut self, path: PathBuf, window: &mut Window, cx: &mut Context<Self>) {
        let studio = self.studio.clone();
        cx.spawn_in(window, async move |this, cx| {
            let file = path.clone();
            let summary = cx.background_executor().spawn(async move { studio.inspect(&file) }).await;
            let _ = this.update_in(cx, |this, window, cx| {
                let summary = match summary {
                    Ok(summary) => summary,
                    Err(error) => return this.notify_error(tf("dialog.import.refused", &[&error.0]), window, cx),
                };
                let entity = cx.weak_entity();
                let mut lines = vec![tf("dialog.import.file", &[&path.display().to_string()]), tf("dialog.import.contents", &[&summary.files.to_string(), &crate::strings::bytes(summary.bytes)])];
                lines.push(if summary.hosts.is_empty() { t("detail.noNetwork") } else { tf("detail.network", &[&summary.hosts.join(", ")]) });
                window.open_alert_dialog(cx, move |alert, _, cx| {
                    let (entity, path) = (entity.clone(), path.clone());
                    let muted = cx.theme().muted_foreground;
                    alert
                        .title(t("dialog.import.title"))
                        .description(tf("dialog.import.detail", &[&summary.name]))
                        // What the archive says about itself is shown as text.
                        .child(v_flex().gap_1().text_sm().text_color(muted).children(lines.iter().map(|line| div().child(SharedString::from(line.clone())))))
                        .confirm()
                        .ok_text(t("dialog.import.confirm"))
                        .cancel_text(t("action.cancel"))
                        .on_ok(move |_, window, cx| {
                            let _ = entity.update(cx, |this, cx| this.import(path.clone(), window, cx));
                            true
                        })
                });
            });
        })
        .detach();
    }

    fn import(&mut self, path: PathBuf, window: &mut Window, cx: &mut Context<Self>) {
        let studio = self.studio.clone();
        cx.spawn_in(window, async move |this, cx| {
            let result = cx.background_executor().spawn(async move { studio.import(&path) }).await;
            let _ = this.update_in(cx, |this, window, cx| match result {
                Ok(name) => {
                    window.push_notification(Notification::success(tf("toast.imported", &[&name])), cx);
                    if this.page == Page::Library {
                        this.reload_library(cx);
                    } else if this.page != Page::Editor {
                        this.go(Target::Library, window, cx);
                    }
                }
                Err(error) => this.notify_error(tf("dialog.import.refused", &[&error.0]), window, cx),
            });
        })
        .detach();
    }

    fn sidebar(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.theme();
        let (background, border) = (theme.sidebar, theme.sidebar_border);
        let entry = |id: &'static str, icon: IconName, label: String, selected: bool, target: Target, cx: &mut Context<Self>| {
            Button::new(id).child(h_flex().w_full().gap_2().child(gpui_kit::component::Icon::new(icon)).child(label)).ghost().selected(selected).w_full().on_click(cx.listener(move |this, _, window, cx| this.navigate(target.clone(), window, cx)))
        };
        let library = entry("nav-library", IconName::LayoutDashboard, t("nav.library"), matches!(self.page, Page::Library | Page::Editor), Target::Library, cx);
        let listing = matches!(self.page, Page::Templates | Page::Template);
        let templates = entry("nav-templates", IconName::GalleryVerticalEnd, t("nav.templates"), listing && self.group == "template", Target::Templates, cx);
        let components = entry("nav-components", IconName::Frame, t("nav.components"), listing && self.group == "component", Target::Components, cx);
        let apis = entry("nav-apis", IconName::SquareTerminal, t("nav.apis"), listing && self.group == "api", Target::Apis, cx);
        let settings = entry("nav-settings", IconName::Settings, t("nav.settings"), self.page == Page::Settings, Target::Settings, cx);
        v_flex().w(px(208.)).h_full().flex_shrink_0().p_2().gap_1().bg(background).border_r_1().border_color(border).child(library).child(templates).child(components).child(apis).child(div().flex_1()).child(settings)
    }
}

/// Where exports go by default: the user's download folder, or the home folder.
fn downloads_folder() -> PathBuf {
    let home = std::env::var_os("HOME").map(PathBuf::from).filter(|path| path.is_absolute()).unwrap_or_else(|| PathBuf::from("/"));
    let named = std::env::var_os("XDG_DOWNLOAD_DIR").map(PathBuf::from).filter(|path| path.is_absolute());
    named.or_else(|| Some(home.join("Downloads")).filter(|folder| folder.is_dir())).unwrap_or(home)
}

impl Focusable for StudioWindow {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus.clone()
    }
}

impl Render for StudioWindow {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        for shown in self.retired.drain(..) {
            cx.drop_image(shown.image, Some(window));
        }
        self.scale = window.scale_factor();
        let theme = cx.theme();
        let (background, foreground) = (theme.background, theme.foreground);
        let page = match self.page {
            Page::Library => self.render_library(cx).into_any_element(),
            Page::Templates => self.render_templates(cx).into_any_element(),
            Page::Template => self.render_template(cx).into_any_element(),
            Page::Editor => self.render_editor(cx).into_any_element(),
            Page::Settings => self.render_settings(cx).into_any_element(),
        };
        h_flex()
            .id("studio")
            .size_full()
            .items_start()
            .bg(background)
            .text_color(foreground)
            .track_focus(&self.focus)
            .on_action(cx.listener(|this, _: &Save, window, cx| this.save(window, cx)))
            .on_action(cx.listener(|this, _: &Back, window, cx| this.back(window, cx)))
            .child(self.sidebar(cx))
            .child(div().flex_1().min_w_0().h_full().child(page))
    }
}

impl StudioWindow {
    /// The list of one group of bundled packages.
    pub(super) fn list_of(group: &str) -> Target {
        match group {
            "component" => Target::Components,
            "api" => Target::Apis,
            _ => Target::Templates,
        }
    }

    /// The page above the one shown: the list a template or a widget was opened from.
    pub(super) fn back(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        match self.page {
            Page::Editor => self.navigate(Target::Library, window, cx),
            Page::Template => self.navigate(Self::list_of(self.group), window, cx),
            _ => {}
        }
    }
}
