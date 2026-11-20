//! The AI conversation about the widget in the editor, and the provider
//! settings: the view of [`crate::ai`]. A turn runs on a thread of its own
//! and comes back as messages; the reply is shown while it is written, the
//! result as changed lines (or as the code), and nothing is written into the
//! widget until "Apply".
//!
//! What a model writes is shown as text and nothing else.

use std::sync::Arc;

use futures::StreamExt as _;
use futures::channel::mpsc::unbounded;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{ActiveTheme as _, Disableable as _, IconName, Selectable as _, Sizable as _, StyledExt as _, WindowExt as _, h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{AppContext as _, Context, Entity, InteractiveElement as _, IntoElement, ParentElement as _, SharedString, Styled as _, Subscription, Window, div, px};
use sw_core::ai::source_diff::Kind;
use sw_core::ai::{AgentLoopEvent, AgentLoopOutcome, AiProviderKind, Status};

use super::window::{Page, StudioWindow};
use crate::ai::{AiPanel, AiService, Applied, KeyStatus, Phase};
use crate::strings::{t, tf};

/// The width of the conversation beside the code.
const PANEL_WIDTH: f32 = 340.0;
/// As many lines of a reply or of a result as are drawn; the rest is one line that says how many more there are.
const MAXIMUM_LINES: usize = 400;

/// The conversation that is open beside the code.
pub(super) struct AiView {
    pub panel: AiPanel,
    prompt: Entity<InputState>,
    /// Why the last request or the last apply did not go through.
    error: Option<String>,
    _enter: Subscription,
}

/// What a worker thread sends back.
enum Update {
    Event(String, AgentLoopEvent),
    Done(String, AgentLoopOutcome),
}

/// The fields of the provider section on the settings page.
pub(super) struct AiSettingsForm {
    kind: AiProviderKind,
    base_url: Entity<InputState>,
    model: Entity<InputState>,
    key: Entity<InputState>,
    status: KeyStatus,
    /// The outcome of the last save: whether it worked, and the sentence.
    message: Option<(bool, String)>,
}

impl StudioWindow {
    // The conversation

    /// Shows or hides the conversation about the open widget. Hiding it stops a turn that is running.
    pub(super) fn toggle_ai(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(session) = self.editor.as_mut().filter(|_| self.page == Page::Editor) else { return };
        if let Some(view) = session.ai.take() {
            view.panel.cancel();
            return cx.notify();
        }
        match self.ai.open(&session.name) {
            Ok(panel) => {
                let prompt = cx.new(|cx| InputState::new(window, cx).placeholder(t("ai.prompt")));
                let enter = cx.subscribe_in(&prompt, window, |this, _, event: &InputEvent, window, cx| {
                    if matches!(event, InputEvent::PressEnter { .. }) {
                        this.send_to_ai(window, cx);
                    }
                });
                let focus = gpui_kit::Focusable::focus_handle(prompt.read(cx), cx);
                window.defer(cx, move |window, cx| focus.focus(window, cx));
                session.ai = Some(AiView { panel, prompt, error: None, _enter: enter });
            }
            Err(error) => self.notify_error(tf("ai.failed", &[&error.0]), window, cx),
        }
        cx.notify();
    }

    /// Sends what is in the prompt as the next turn.
    fn send_to_ai(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(session) = self.editor.as_mut().filter(|_| self.page == Page::Editor) else { return };
        let (dirty, family, dark) = (session.dirty, session.pane.family.clone(), session.pane.dark);
        let Some(view) = session.ai.as_mut() else { return };
        let request = view.prompt.read(cx).value().to_string();
        let job = match self.ai.start(&mut view.panel, &request, dirty, &family, dark) {
            Ok(job) => job,
            Err(error) => {
                view.error = Some(error.0);
                return cx.notify();
            }
        };
        view.error = None;
        view.prompt.update(cx, |prompt, cx| prompt.set_value("", window, cx));

        // The model is asked and its answer is run on a thread of its own; what happens comes back here.
        let (updates, mut arrived) = unbounded::<Update>();
        let service = self.ai.clone();
        std::thread::spawn(move || {
            let turn = job.turn_id.clone();
            let events = updates.clone();
            let outcome = service.run(&job, &mut |event| {
                let _ = events.unbounded_send(Update::Event(turn.clone(), event.clone()));
            });
            let _ = updates.unbounded_send(Update::Done(job.turn_id.clone(), outcome));
        });
        cx.spawn(async move |this, cx| {
            while let Some(update) = arrived.next().await {
                if this.update(cx, |this, cx| this.ai_arrived(update, cx)).is_err() {
                    break;
                }
            }
        })
        .detach();
        cx.notify();
    }

    fn ai_arrived(&mut self, update: Update, cx: &mut Context<Self>) {
        let service = self.ai.clone();
        // A turn whose conversation is no longer open is dropped; its file says it was interrupted.
        let Some(view) = self.editor.as_mut().and_then(|session| session.ai.as_mut()) else { return };
        match update {
            Update::Event(turn, event) => view.panel.event(&turn, &event),
            Update::Done(turn, outcome) => service.finish(&mut view.panel, &turn, &outcome),
        }
        cx.notify();
    }

    fn stop_ai(&mut self, cx: &mut Context<Self>) {
        if let Some(view) = self.editor.as_ref().and_then(|session| session.ai.as_ref()) {
            view.panel.cancel();
        }
        cx.notify();
    }

    /// Writes the proposed version into the widget and shows it in the editor. Hosts the widget
    /// may not contact yet are added only after the user agreed in a dialog.
    fn apply_ai(&mut self, allow_new_hosts: bool, window: &mut Window, cx: &mut Context<Self>) {
        let service = self.ai.clone();
        let Some(session) = self.editor.as_mut().filter(|_| self.page == Page::Editor) else { return };
        let (name, dirty) = (session.name.clone(), session.dirty);
        let Some(view) = session.ai.as_mut() else { return };
        if dirty {
            view.error = Some(t("ai.unsaved"));
            return cx.notify();
        }
        match service.apply(&mut view.panel, allow_new_hosts) {
            Ok(Applied::Done { path, .. }) => {
                view.error = None;
                self.forget_thumbnail(&name);
                // The editor shows the file as it is now, and the preview runs from it.
                self.open_editor(&name, Some(path), window, cx);
            }
            Ok(Applied::NeedsConsent(hosts)) => {
                let this = cx.weak_entity();
                let hosts = hosts.join(", ");
                window.open_alert_dialog(cx, move |alert, _, _| {
                    let this = this.clone();
                    // Host names come from the model: shown as text.
                    alert.title(t("ai.hosts.title")).description(tf("ai.hosts.detail", &[&hosts])).confirm().ok_text(t("ai.hosts.confirm")).cancel_text(t("action.cancel")).on_ok(move |_, window, cx| {
                        let _ = this.update(cx, |this, cx| this.apply_ai(true, window, cx));
                        true
                    })
                });
            }
            Err(error) => view.error = Some(error.0),
        }
        cx.notify();
    }

    pub(super) fn render_ai(&self, view: &AiView, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.theme();
        let (muted, border, danger, success, foreground, secondary, mono) = (theme.muted_foreground, theme.border, theme.danger, theme.success, theme.foreground, theme.secondary, theme.mono_font_family.clone());
        let panel = &view.panel;
        // Text of the model, of a package or of an error: one line a row, as text.
        let code = |text: &str| {
            let lines: Vec<&str> = text.lines().collect();
            let more = lines.len().saturating_sub(MAXIMUM_LINES);
            v_flex()
                .text_xs()
                .font_family(mono.clone())
                .children(lines.into_iter().take(MAXIMUM_LINES).map(|line| div().child(SharedString::from(line.to_owned()))))
                .when(more > 0, |list| list.child(div().text_color(muted).child(tf("ai.skipped", &[&more.to_string()]))))
        };

        let mut body = v_flex().p_3().gap_3();
        let rows = panel.rows();
        if rows.iter().all(|row| row.manual_edit) && !panel.is_running() {
            body = body.child(div().text_sm().text_color(muted).child(t("ai.empty")));
        }
        for row in rows.iter().filter(|row| !row.manual_edit) {
            let detail = match row.status {
                Status::Succeeded => div().text_color(muted).child(SharedString::from(row.detail.clone())),
                Status::Cancelled => div().text_color(muted).child(t("ai.cancelled")),
                Status::Interrupted => div().text_color(muted).child(t("ai.interrupted")),
                _ => div().text_color(danger).child(SharedString::from(row.detail.clone())),
            };
            body = body.child(v_flex().gap_0p5().text_sm().child(div().font_semibold().child(SharedString::from(row.request.clone()))).child(detail));
        }
        if let Some(advice) = panel.advice() {
            body = body.child(div().text_xs().text_color(muted).child(SharedString::from(advice)));
        }
        if let Some(running) = &panel.running {
            let phase = match running.phase {
                Phase::Thinking => t("ai.thinking"),
                Phase::Writing => t("ai.writing"),
                Phase::Running => t("ai.running"),
                Phase::Repairing => t("ai.repairing"),
            };
            body = body.child(
                v_flex()
                    .gap_1()
                    .child(h_flex().gap_2().text_sm().child(div().font_semibold().child(tf("ai.attempt", &[&running.attempt.to_string()]))).child(div().text_color(muted).child(phase)))
                    .when(!running.reply.is_empty(), |section| section.child(div().p_2().rounded_md().bg(secondary).child(code(&running.reply)))),
            );
        }
        if let Some(proposal) = &panel.proposal {
            let summary = if proposal.added == 0 && proposal.removed == 0 && proposal.lines.is_some() { t("ai.noChanges") } else { tf("ai.changes", &[&proposal.added.to_string(), &proposal.removed.to_string()]) };
            let changes = match &proposal.lines {
                Some(lines) => v_flex().text_xs().font_family(mono.clone()).children(lines.iter().take(MAXIMUM_LINES).map(|line| match line.kind {
                    Kind::Added => div().text_color(success).child(SharedString::from(format!("+ {}", line.text))),
                    Kind::Removed => div().text_color(danger).child(SharedString::from(format!("- {}", line.text))),
                    Kind::Same => div().text_color(foreground).child(SharedString::from(format!("  {}", line.text))),
                    Kind::Skipped => div().text_color(muted).child(tf("ai.skipped", &[&line.skipped.to_string()])),
                })),
                // Too long to compare: the new code as it is.
                None => code(&proposal.source),
            };
            let action = if proposal.applied {
                div().text_sm().text_color(success).child(t("ai.applied"))
            } else {
                div().child(Button::new("ai-apply").label(t("ai.apply")).primary().small().disabled(panel.is_running()).on_click(cx.listener(|this, _, window, cx| this.apply_ai(false, window, cx))))
            };
            body = body.child(
                v_flex()
                    .gap_2()
                    .p_2()
                    .border_1()
                    .border_color(border)
                    .rounded_md()
                    .child(div().text_sm().font_semibold().child(summary))
                    .child(changes)
                    .when(!proposal.new_hosts.is_empty(), |section| section.child(div().text_sm().text_color(muted).child(tf("ai.newHosts", &[&proposal.new_hosts.join(", ")]))))
                    .child(action),
            );
        }
        if let Some(error) = &view.error {
            body = body.child(div().text_sm().text_color(danger).child(SharedString::from(error.clone())));
        }

        let send = if panel.is_running() {
            Button::new("ai-stop").label(t("ai.stop")).outline().small().on_click(cx.listener(|this, _, _, cx| this.stop_ai(cx)))
        } else {
            Button::new("ai-send").label(t("ai.send")).primary().small().on_click(cx.listener(|this, _, window, cx| this.send_to_ai(window, cx)))
        };
        v_flex()
            .w(px(PANEL_WIDTH))
            .h_full()
            .flex_shrink_0()
            .border_l_1()
            .border_color(border)
            .child(
                h_flex().p_3().justify_between().border_b_1().border_color(border).child(div().font_semibold().child(t("ai.title"))).child(
                    Button::new("ai-close").icon(IconName::Close).small().ghost().tooltip(t("ai.close")).accessibility_label(t("ai.close")).on_click(cx.listener(|this, _, window, cx| this.toggle_ai(window, cx))),
                ),
            )
            .child(div().id("ai-conversation").flex_1().min_h_0().overflow_y_scrollbar().child(body))
            .child(h_flex().p_3().gap_2().border_t_1().border_color(border).child(div().flex_1().min_w_0().child(Input::new(&view.prompt).aria_label(t("ai.prompt")))).child(send))
    }

    // The provider, on the settings page

    /// Reads the saved provider into the fields of the settings page.
    pub(super) fn load_ai_settings(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let settings = self.ai.settings();
        let profile = settings.profile;
        let base_url = cx.new(|cx| InputState::new(window, cx).placeholder("https://").default_value(profile.base_url.clone()));
        let model = cx.new(|cx| InputState::new(window, cx).default_value(profile.model.clone()));
        let key = cx.new(|cx| InputState::new(window, cx).placeholder(t("settings.ai.key.hint")).masked(true));
        self.ai_settings = Some(AiSettingsForm { kind: profile.kind, base_url, model, key, status: self.ai.key_status(profile.kind), message: None });
    }

    /// Another provider: its own endpoint and model in the fields, and its own key.
    fn choose_ai_provider(&mut self, kind: AiProviderKind, window: &mut Window, cx: &mut Context<Self>) {
        let service = self.ai.clone();
        let Some(form) = self.ai_settings.as_mut() else { return };
        if form.kind == kind {
            return;
        }
        form.kind = kind;
        form.base_url.update(cx, |field, cx| field.set_value(kind.default_base_url(), window, cx));
        form.model.update(cx, |field, cx| field.set_value(kind.default_model(), window, cx));
        form.status = service.key_status(kind);
        form.message = None;
        cx.notify();
    }

    fn save_ai_profile(&mut self, cx: &mut Context<Self>) {
        let service = self.ai.clone();
        let Some(form) = self.ai_settings.as_mut() else { return };
        let (base_url, model) = (form.base_url.read(cx).value().to_string(), form.model.read(cx).value().to_string());
        form.message = Some(match service.save_profile(form.kind, &base_url, &model) {
            Ok(_) => (true, t("settings.ai.saved")),
            Err(error) => (false, error.0),
        });
        cx.notify();
    }

    /// Puts the typed key into the system keyring and empties the field. The key is kept nowhere else.
    fn store_ai_key(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let service = self.ai.clone();
        let Some(form) = self.ai_settings.as_mut() else { return };
        let typed = form.key.read(cx).value().to_string();
        form.message = Some(match service.store_key(form.kind, &typed) {
            Ok(()) => {
                form.key.update(cx, |field, cx| field.set_value("", window, cx));
                (true, t("settings.ai.key.stored"))
            }
            Err(error) => (false, error.0),
        });
        form.status = service.key_status(form.kind);
        cx.notify();
    }

    fn remove_ai_key(&mut self, cx: &mut Context<Self>) {
        let service = self.ai.clone();
        let Some(form) = self.ai_settings.as_mut() else { return };
        form.message = Some(match service.remove_key(form.kind) {
            Ok(_) => (true, t("settings.ai.key.removed")),
            Err(error) => (false, error.0),
        });
        form.status = service.key_status(form.kind);
        cx.notify();
    }

    pub(super) fn render_ai_settings(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.theme();
        let (muted, border, danger, success) = (theme.muted_foreground, theme.border, theme.danger, theme.success);
        let section = v_flex().p_4().gap_2().border_1().border_color(border).rounded_xl().child(div().font_semibold().child(t("settings.ai"))).child(div().text_sm().text_color(muted).child(t("settings.ai.detail")));
        let Some(form) = &self.ai_settings else { return section };
        let providers = h_flex().gap_1().flex_wrap().children(AiProviderKind::ALL.into_iter().enumerate().map(|(index, kind)| {
            // The names of the providers are names: the same in every language.
            Button::new(("ai-provider", index)).label(kind.display_name()).small().map(|button| if form.kind == kind { button.primary() } else { button.outline() }).selected(form.kind == kind).on_click(cx.listener(move |this, _, window, cx| this.choose_ai_provider(kind, window, cx)))
        }));
        let field = |label: String, input: &Entity<InputState>| v_flex().gap_1().child(div().text_sm().text_color(muted).child(label.clone())).child(Input::new(input).aria_label(label));
        let status = match &form.status {
            KeyStatus::Stored => div().text_color(success).child(t("settings.ai.key.stored")),
            KeyStatus::Missing => div().text_color(muted).child(t("settings.ai.key.missing")),
            KeyStatus::ForThisRun => div().text_color(muted).child(tf("settings.ai.key.environment", &[AiService::environment_key()])),
            // The sentence of the keyring layer, which says what to do.
            KeyStatus::Unavailable(problem) => div().text_color(danger).child(SharedString::from(problem.clone())),
        };
        let message = match &form.message {
            Some((true, text)) => div().text_sm().text_color(success).child(SharedString::from(text.clone())),
            Some((false, text)) => div().text_sm().text_color(danger).child(SharedString::from(text.clone())),
            None => div(),
        };
        section
            .child(providers)
            .child(field(t("settings.ai.baseUrl"), &form.base_url))
            .child(field(t("settings.ai.model"), &form.model))
            .child(h_flex().child(Button::new("ai-save-profile").label(t("settings.ai.save")).small().outline().on_click(cx.listener(|this, _, _, cx| this.save_ai_profile(cx)))))
            .child(div().pt_2().font_semibold().child(t("settings.ai.key")))
            .child(div().text_sm().text_color(muted).child(t("settings.ai.key.detail")))
            .child(div().text_sm().child(status))
            .child(Input::new(&form.key).aria_label(t("settings.ai.key")))
            .child(
                h_flex()
                    .gap_2()
                    .child(Button::new("ai-store-key").label(t("settings.ai.key.store")).small().outline().on_click(cx.listener(|this, _, window, cx| this.store_ai_key(window, cx))))
                    .child(Button::new("ai-remove-key").label(t("settings.ai.key.remove")).small().ghost().disabled(form.status != KeyStatus::Stored).on_click(cx.listener(|this, _, _, cx| this.remove_ai_key(cx)))),
            )
            .child(message)
    }
}

/// The service of the window: the keyring, the HTTPS transport, and the key the environment gave for this run.
pub(super) fn service(studio: Arc<crate::model::Studio>) -> Arc<AiService> {
    Arc::new(AiService::new(studio, crate::ai::one_run_key()))
}
