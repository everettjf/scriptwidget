//! "Data access" in the editor: what the user allows and picks for the data
//! APIs of the open widget, and the GitHub account on the settings page.
//! The view of [`crate::access`].
//!
//! Paths, names and the account's login are shown as text. The token is
//! typed into a masked field, handed to [`crate::access::DataAccess`] and
//! cleared from the field; nothing here shows or keeps it.

use std::path::PathBuf;

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputState};
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{ActiveTheme as _, Disableable as _, IconName, Sizable as _, StyledExt as _, h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{AppContext as _, Context, Entity, InteractiveElement as _, IntoElement, ParentElement as _, SharedString, Styled as _, Window, div};

use super::window::{Page, StudioWindow, downloads_folder};
use crate::access::{AccessState, PickedItem};
use crate::strings::{t, tf};

/// The GitHub section of the settings page.
pub(super) struct GithubForm {
    token: Entity<InputState>,
    /// The login of the connected account, none, or why that cannot be told.
    account: Result<Option<String>, String>,
    /// The outcome of the last action: whether it worked, and the sentence.
    message: Option<(bool, String)>,
    /// True while GitHub is being asked.
    busy: bool,
}

impl StudioWindow {
    // The panel in the editor

    /// The name of the widget whose data access is open.
    fn access_widget(&self) -> Option<String> {
        self.editor.as_ref().filter(|session| self.page == Page::Editor && session.access.is_some()).map(|session| session.name.clone())
    }

    /// Shows the data access of the open widget in place of its code, or the code again.
    pub(super) fn toggle_access(&mut self, cx: &mut Context<Self>) {
        let Some(session) = &mut self.editor else { return };
        if session.access.take().is_none() {
            session.access = Some(AccessState::default());
            self.reload_access(cx);
        }
        cx.notify();
    }

    fn reload_access(&mut self, cx: &mut Context<Self>) {
        let access = self.access.clone();
        let Some(session) = self.editor.as_mut().filter(|session| session.access.is_some()) else { return };
        session.access = Some(access.state(&session.name).unwrap_or_else(|error| AccessState { problem: Some(error.0), ..AccessState::default() }));
        cx.notify();
    }

    /// After a change: the panel shows the new state and the preview runs with it.
    fn access_changed(&mut self, result: Result<(), crate::model::StudioError>, window: &mut Window, cx: &mut Context<Self>) {
        if let Err(error) = result {
            self.notify_error(error.0, window, cx);
        }
        self.reload_access(cx);
        self.request_preview(true, cx);
    }

    fn allow_notifications(&mut self, allowed: bool, window: &mut Window, cx: &mut Context<Self>) {
        let Some(name) = self.access_widget() else { return };
        let result = self.access.set_notifications(&name, allowed);
        self.access_changed(result, window, cx);
    }

    fn allow_github(&mut self, allowed: bool, window: &mut Window, cx: &mut Context<Self>) {
        let Some(name) = self.access_widget() else { return };
        let result = self.access.set_github(&name, allowed);
        self.access_changed(result, window, cx);
    }

    /// Asks which file to pick: a JSON or CSV file, or a picture.
    fn choose_access_file(&mut self, photo: bool, window: &mut Window, cx: &mut Context<Self>) {
        let chosen = cx.prompt_for_paths(gpui_kit::PathPromptOptions { files: true, directories: false, multiple: false, prompt: Some(t("access.pick.confirm").into()) });
        cx.spawn_in(window, async move |this, cx| {
            let _ = match chosen.await {
                Ok(Ok(Some(paths))) => this.update_in(cx, |this, window, cx| {
                    if let Some(path) = paths.into_iter().next() {
                        this.add_access_file(path, photo, window, cx);
                    }
                }),
                Ok(Ok(None)) => Ok(()),
                // No file chooser on this desktop: ask for the path in the window.
                Ok(Err(_)) | Err(_) => this.update_in(cx, |this, window, cx| {
                    let title = if photo { t("access.photos.add") } else { t("access.documents.add") };
                    this.ask_path(title, t("access.pick.hint"), downloads_folder().join(""), window, cx, move |this, path, window, cx| this.add_access_file(path, photo, window, cx));
                }),
            };
        })
        .detach();
    }

    /// Records the picked file off this thread: a picture is decoded to make its thumbnail.
    fn add_access_file(&mut self, path: PathBuf, photo: bool, window: &mut Window, cx: &mut Context<Self>) {
        let Some(name) = self.access_widget() else { return };
        let access = self.access.clone();
        cx.spawn_in(window, async move |this, cx| {
            let widget = name.clone();
            let result = cx.background_executor().spawn(async move { if photo { access.add_photo(&widget, &path) } else { access.add_document(&widget, &path).map(|_| ()) } }).await;
            let _ = this.update_in(cx, |this, window, cx| {
                // The answer is for the widget it was asked for; another may be open by now.
                if this.access_widget().as_deref() == Some(name.as_str()) {
                    this.access_changed(result, window, cx);
                } else if let Err(error) = result {
                    this.notify_error(error.0, window, cx);
                }
            });
        })
        .detach();
    }

    fn remove_access_file(&mut self, id: String, photo: bool, window: &mut Window, cx: &mut Context<Self>) {
        let Some(name) = self.access_widget() else { return };
        let result = if photo { self.access.remove_photo(&name, &id) } else { self.access.remove_document(&name, &id) };
        self.access_changed(result, window, cx);
    }

    pub(super) fn render_access(&self, state: &AccessState, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.theme();
        let (muted, border, danger, success) = (theme.muted_foreground, theme.border, theme.danger, theme.success);
        // A section: its title, what it is, and whether the widget's manifest asks for it.
        let section = |title: String, detail: String, permission: &'static str| {
            let declared = state.declares(permission);
            v_flex()
                .p_4()
                .gap_2()
                .border_1()
                .border_color(border)
                .rounded_xl()
                .child(h_flex().gap_2().child(div().font_semibold().child(title)).child(div().text_sm().text_color(if declared { success } else { muted }).child(if declared { t("access.declared") } else { tf("access.undeclared", &[permission]) })))
                .child(div().text_sm().text_color(muted).child(detail))
        };
        let switch = |id: &'static str, allowed: bool, on: fn(&mut Self, bool, &mut Window, &mut Context<Self>), cx: &mut Context<Self>| {
            h_flex().gap_2().child(div().text_sm().text_color(if allowed { success } else { muted }).child(if allowed { t("access.allowed") } else { t("access.notAllowed") })).child(
                Button::new(id).label(if allowed { t("access.stop") } else { t("access.allow") }).small().map(|button| if allowed { button.outline() } else { button.primary() }).on_click(cx.listener(move |this, _, window, cx| on(this, !allowed, window, cx))),
            )
        };
        // The picked files: name and path as text, and a button that takes one off the list.
        let list = |prefix: &'static str, items: &[PickedItem], photo: bool, cx: &mut Context<Self>| {
            v_flex().gap_1().children(items.iter().enumerate().map(|(index, item)| {
                let id = item.id.clone();
                h_flex()
                    .gap_2()
                    .child(
                        v_flex()
                            .flex_1()
                            .min_w_0()
                            .child(div().truncate().child(SharedString::from(item.name.clone())))
                            .child(div().text_sm().text_color(muted).truncate().child(SharedString::from(item.path.clone())))
                            .when(!item.readable, |column| column.child(div().text_sm().text_color(danger).child(t("access.pick.gone")))),
                    )
                    .child(Button::new((prefix, index)).icon(IconName::Delete).ghost().small().tooltip(tf("action.removeNamed", &[&item.name])).accessibility_label(tf("action.removeNamed", &[&item.name])).on_click(cx.listener(move |this, _, window, cx| this.remove_access_file(id.clone(), photo, window, cx))))
            }))
        };
        let notifications = section(t("access.notifications"), t("access.notifications.detail"), "notifications").child(switch("access-notifications", state.notifications, Self::allow_notifications, cx));
        let github = section(t("access.github"), t("access.github.detail"), "services").map(|section| match &state.github {
            Some(login) => section.child(div().text_sm().child(tf("access.github.account", &[login]))).child(switch("access-github", state.github_allowed, Self::allow_github, cx)),
            None => section.child(div().text_sm().text_color(muted).child(t("access.github.none"))),
        });
        let documents = section(t("access.documents"), t("access.documents.detail"), "documents")
            .child(list("access-document", &state.documents, false, cx))
            .child(h_flex().child(Button::new("access-add-document").label(t("access.documents.add")).small().outline().on_click(cx.listener(|this, _, window, cx| this.choose_access_file(false, window, cx)))));
        let photos = section(t("access.photos"), t("access.photos.detail"), "photos")
            .child(list("access-photo", &state.photos, true, cx))
            .child(h_flex().child(Button::new("access-add-photo").label(t("access.photos.add")).small().outline().on_click(cx.listener(|this, _, window, cx| this.choose_access_file(true, window, cx)))));
        let music = section(t("access.music"), t("access.music.detail"), "music");
        div().id("access").flex_1().min_w_0().h_full().overflow_y_scrollbar().child(
            v_flex()
                .p_4()
                .gap_3()
                .child(div().text_lg().font_semibold().child(t("access.title")))
                .child(div().text_sm().text_color(muted).child(t("access.detail")))
                .children(state.problem.as_ref().map(|problem| div().text_sm().text_color(danger).child(SharedString::from(problem.clone()))))
                .child(notifications)
                .child(github)
                .child(documents)
                .child(photos)
                .child(music),
        )
    }

    // The GitHub account, on the settings page

    pub(super) fn load_github_settings(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let token = cx.new(|cx| InputState::new(window, cx).placeholder(t("settings.github.token.hint")).masked(true));
        self.github_form = Some(GithubForm { token, account: self.access.github().map_err(|error| error.0), message: None, busy: false });
    }

    /// Verifies the typed token with GitHub, off this thread, and keeps it in the keyring.
    fn connect_github(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let access = self.access.clone();
        let Some(form) = self.github_form.as_mut().filter(|form| !form.busy) else { return };
        let typed = form.token.read(cx).value().to_string();
        // The field is emptied at once: the token is on its way and is shown nowhere.
        form.token.update(cx, |field, cx| field.set_value("", window, cx));
        form.busy = true;
        form.message = None;
        cx.notify();
        cx.spawn(async move |this, cx| {
            let reader = access.clone();
            let result = cx.background_executor().spawn(async move { access.connect_github(&typed) }).await;
            let _ = this.update(cx, |this, cx| {
                if let Some(form) = this.github_form.as_mut() {
                    form.busy = false;
                    form.message = Some(match result {
                        Ok(login) => (true, tf("settings.github.connected", &[&login])),
                        Err(error) => (false, error.0),
                    });
                    form.account = reader.github().map_err(|error| error.0);
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn disconnect_github(&mut self, cx: &mut Context<Self>) {
        let access = self.access.clone();
        let Some(form) = self.github_form.as_mut().filter(|form| !form.busy) else { return };
        form.message = Some(match access.disconnect_github() {
            Ok(()) => (true, t("settings.github.disconnected")),
            Err(error) => (false, error.0),
        });
        form.account = access.github().map_err(|error| error.0);
        cx.notify();
    }

    pub(super) fn render_github_settings(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.theme();
        let (muted, border, danger, success) = (theme.muted_foreground, theme.border, theme.danger, theme.success);
        let section = v_flex().p_4().gap_2().border_1().border_color(border).rounded_xl().child(div().font_semibold().child(t("settings.github"))).child(div().text_sm().text_color(muted).child(t("settings.github.detail")));
        let Some(form) = &self.github_form else { return section };
        let account = match &form.account {
            // The login is text from GitHub.
            Ok(Some(login)) => div().text_color(success).child(tf("settings.github.account", &[login])),
            Ok(None) => div().text_color(muted).child(t("settings.github.none")),
            Err(problem) => div().text_color(danger).child(SharedString::from(problem.clone())),
        };
        let message = match &form.message {
            Some((true, text)) => div().text_sm().text_color(success).child(SharedString::from(text.clone())),
            Some((false, text)) => div().text_sm().text_color(danger).child(SharedString::from(text.clone())),
            None => div(),
        };
        let connected = !matches!(form.account, Ok(None));
        section.child(div().text_sm().child(account)).child(Input::new(&form.token).aria_label(t("settings.github.token"))).child(
            h_flex()
                .gap_2()
                .child(Button::new("github-connect").label(if form.busy { t("settings.github.connecting") } else { t("settings.github.connect") }).small().outline().disabled(form.busy).on_click(cx.listener(|this, _, window, cx| this.connect_github(window, cx))))
                .when(connected, |row| row.child(Button::new("github-disconnect").label(t("settings.github.disconnect")).small().outline().disabled(form.busy).on_click(cx.listener(|this, _, _, cx| this.disconnect_github(cx))))),
        )
        .child(message)
    }
}
