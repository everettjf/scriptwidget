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
use gpui_kit::component::notification::Notification;
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{ActiveTheme as _, Disableable as _, IconName, Selectable as _, Sizable as _, StyledExt as _, WindowExt as _, h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{AppContext as _, Context, Entity, InteractiveElement as _, IntoElement, ParentElement as _, SharedString, Styled as _, Subscription, Window, div, img, px};
use sw_core::ai::source_diff::Kind;
use sw_core::ai::{AgentLoopEvent, AgentLoopOutcome, AiExamplePrompts, AiProviderKind, AiWidgetSize, Status};

use super::preview_pane::{PaneLayout, PreviewPane, Shown};
use super::window::{Page, SIDEBAR_WIDTH, StudioWindow, Target};
use crate::ai::{AiPanel, AiService, Applied, KeyStatus, Phase, Saved, TurnJob};
use crate::model::PreviewSource;
use crate::strings::{self, t, tf};

/// The width of the conversation beside the code.
const PANEL_WIDTH: f32 = 340.0;
/// The width of the conversation about a widget that does not exist yet, which has the page to itself.
const DRAFT_WIDTH: f32 = 560.0;
/// As many lines of a reply or of a result as are drawn; the rest is one line that says how many more there are.
const MAXIMUM_LINES: usize = 400;
/// The box one of the small pictures of a version fits in.
const THUMBNAIL: f32 = 66.0;
/// As many models of an endpoint as the settings page lists.
const MAXIMUM_MODELS: usize = 60;

/// The conversation that is open beside the code, or the one about a new widget.
pub(super) struct AiView {
    pub panel: AiPanel,
    prompt: Entity<InputState>,
    /// The name a draft is saved under; empty until a version exists or the user types one.
    name: Entity<InputState>,
    /// Why the last request or the last apply did not go through.
    error: Option<String>,
    /// The current version drawn at each size: the size's name and the picture.
    pub previews: Vec<(String, Shown)>,
    /// Counts the times the pictures were asked for; pictures of an older time are dropped.
    preview_run: u64,
    /// The Skills of the conversation are listed.
    skills_open: bool,
    /// The version shown, drawn large at one size: only on the page of a widget that does not
    /// exist yet, where no editor shows a preview.
    pub pane: Option<PreviewPane>,
    _enter: Subscription,
}

impl AiView {
    /// What the large preview of a new widget draws: the version shown, in memory.
    pub(super) fn shown_candidate(&self) -> Option<PreviewSource> {
        let version = self.panel.proposal.as_ref().and(self.panel.conversation.current_version())?;
        Some(PreviewSource::Candidate { widget: self.panel.widget.clone(), source: version.source.clone(), domains: version.network_domains.clone() })
    }
}

/// The text in an empty prompt: what should change in a widget that exists, a description of one that does not.
fn prompt_hint(draft: bool) -> String {
    if draft { t("ai.draft.prompt") } else { t("ai.prompt") }
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
    /// What the endpoint listed when it was last asked; `None` until it was.
    models: Option<Vec<String>>,
    loading_models: bool,
}

impl StudioWindow {
    // The conversation

    fn new_ai_view(&mut self, panel: AiPanel, window: &mut Window, cx: &mut Context<Self>) -> AiView {
        let hint = prompt_hint(panel.is_draft());
        let prompt = cx.new(|cx| InputState::new(window, cx).placeholder(hint));
        let name = cx.new(|cx| InputState::new(window, cx).placeholder(t("ai.save.name")));
        let enter = cx.subscribe_in(&prompt, window, |this, _, event: &InputEvent, window, cx| {
            if matches!(event, InputEvent::PressEnter { .. }) {
                this.send_to_ai(window, cx);
            }
        });
        let focus = gpui_kit::Focusable::focus_handle(prompt.read(cx), cx);
        window.defer(cx, move |window, cx| focus.focus(window, cx));
        let pane = panel.is_draft().then(|| {
            let mut pane = PreviewPane::new(AiWidgetSize::ALL.iter().map(|size| size.family()).collect(), self.dark(cx));
            pane.family = panel.conversation.size.family().to_owned();
            pane
        });
        AiView { panel, prompt, name, error: None, previews: Vec::new(), preview_run: 0, skills_open: false, pane, _enter: enter }
    }

    /// The conversation on the page that is shown.
    fn ai_view_mut(&mut self) -> Option<&mut AiView> {
        match self.page {
            Page::Editor => self.editor.as_mut().and_then(|session| session.ai.as_mut()),
            Page::Draft => self.draft.as_mut(),
            _ => None,
        }
    }

    /// Stops what a conversation that is no longer shown was doing and releases its pictures.
    pub(super) fn retire_ai(&mut self, view: AiView) {
        view.panel.cancel();
        self.retired.extend(view.previews.into_iter().map(|(_, shown)| shown));
        self.retired.extend(view.pane.and_then(|pane| pane.shown));
    }

    /// Shows or hides the conversation about the open widget. Hiding it stops a turn that is running.
    pub(super) fn toggle_ai(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(session) = self.editor.as_mut().filter(|_| self.page == Page::Editor) else { return };
        if let Some(view) = session.ai.take() {
            self.retire_ai(view);
            return cx.notify();
        }
        let name = session.name.clone();
        match self.ai.open(&name) {
            Ok(panel) => {
                let view = self.new_ai_view(panel, window, cx);
                if let Some(session) = self.editor.as_mut() {
                    session.ai = Some(view);
                }
                // A version that was made and not applied is shown again, with its pictures.
                self.refresh_ai_previews(cx);
            }
            Err(error) => self.notify_error(tf("ai.failed", &[&error.0]), window, cx),
        }
        cx.notify();
    }

    /// Opens a conversation about a widget that does not exist yet ("New with AI").
    pub(super) fn open_draft(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let panel = self.ai.new_draft();
        let view = self.new_ai_view(panel, window, cx);
        self.draft = Some(view);
        self.page = Page::Draft;
        cx.notify();
    }

    /// True when leaving the page would leave a widget behind that was made and not saved.
    pub(super) fn draft_has_unsaved_widget(&self) -> bool {
        self.page == Page::Draft && self.draft.as_ref().is_some_and(|view| view.panel.is_draft() && (view.panel.is_running() || view.panel.conversation.current_version().is_some()))
    }

    /// Whether the editor holds unsaved changes, and the size and the appearance a turn is run at.
    fn ai_context(&self, cx: &Context<Self>) -> Option<(bool, String, bool)> {
        match self.page {
            Page::Editor => self.editor.as_ref().map(|session| (session.dirty, session.pane.family.clone(), session.pane.dark)),
            Page::Draft => self.draft.as_ref().map(|view| (false, view.panel.conversation.size.family().to_owned(), self.dark(cx))),
            _ => None,
        }
    }

    /// Sends what is in the prompt as the next turn.
    fn send_to_ai(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.ask_ai(None, window, cx);
    }

    /// Sends the prompt, or a request to fix the error, with what the widget's last run reported:
    /// the error and the last console lines of that run.
    fn fix_with_ai(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(diagnostic) = self.editor.as_ref().filter(|_| self.page == Page::Editor).and_then(|session| session.pane.error.as_ref().map(|error| crate::ai::runtime_diagnostic(error, &session.pane.logs))) else { return };
        self.ask_ai(Some(diagnostic), window, cx);
    }

    fn ask_ai(&mut self, diagnostic: Option<String>, window: &mut Window, cx: &mut Context<Self>) {
        let service = self.ai.clone();
        let Some((dirty, family, dark)) = self.ai_context(cx) else { return };
        let Some(view) = self.ai_view_mut() else { return };
        let request = view.prompt.read(cx).value().to_string();
        let started = match &diagnostic {
            Some(diagnostic) => service.start_fix(&mut view.panel, &request, diagnostic, dirty, &family, dark),
            None => service.start(&mut view.panel, &request, dirty, &family, dark),
        };
        match started {
            Ok(job) => {
                view.error = None;
                view.prompt.update(cx, |prompt, cx| prompt.set_value("", window, cx));
                self.run_ai(job, window, cx);
            }
            Err(error) => view.error = Some(error.0),
        }
        cx.notify();
    }

    /// Sends a turn that did not succeed again, from the version it started from.
    fn retry_ai(&mut self, turn: String, window: &mut Window, cx: &mut Context<Self>) {
        let service = self.ai.clone();
        let Some((_, _, dark)) = self.ai_context(cx) else { return };
        let Some(view) = self.ai_view_mut() else { return };
        match service.retry(&mut view.panel, &turn, dark) {
            Ok(job) => {
                view.error = None;
                self.run_ai(job, window, cx);
            }
            Err(error) => view.error = Some(error.0),
        }
        cx.notify();
    }

    /// The model is asked and its answer is run on a thread of its own; what happens comes back here.
    fn run_ai(&mut self, job: TurnJob, window: &mut Window, cx: &mut Context<Self>) {
        // The pictures were of the version before this turn.
        self.refresh_ai_previews(cx);
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
        cx.spawn_in(window, async move |this, cx| {
            while let Some(update) = arrived.next().await {
                if this.update_in(cx, |this, window, cx| this.ai_arrived(update, window, cx)).is_err() {
                    break;
                }
            }
        })
        .detach();
    }

    fn ai_arrived(&mut self, update: Update, window: &mut Window, cx: &mut Context<Self>) {
        let service = self.ai.clone();
        // A turn whose conversation is no longer open is dropped; its file says it was interrupted.
        let Some(view) = self.ai_view_mut() else { return };
        match update {
            Update::Event(turn, event) => view.panel.event(&turn, &event),
            Update::Done(turn, outcome) => {
                service.finish(&mut view.panel, &turn, &outcome);
                // A draft that now has a version is offered a name; one the user typed is kept.
                if view.panel.is_draft() && view.panel.proposal.is_some() && view.name.read(cx).value().trim().is_empty() {
                    let suggested = AiService::suggested_name(&view.panel);
                    view.name.update(cx, |field, cx| field.set_value(suggested, window, cx));
                }
                self.refresh_ai_previews(cx);
            }
        }
        cx.notify();
    }

    /// Draws the version shown of a new widget large, at the size the pane is set to; without a
    /// version the pane is emptied.
    fn refresh_draft_pane(&mut self, cx: &mut Context<Self>) {
        if self.page != Page::Draft {
            return;
        }
        if self.draft.as_ref().is_some_and(|view| view.shown_candidate().is_some()) {
            return self.request_preview(true, cx);
        }
        let old = self.draft.as_mut().and_then(|view| view.pane.as_mut()).and_then(PreviewPane::clear);
        self.retired.extend(old);
        cx.notify();
    }

    /// Shows a new widget at another size in the large preview. The size it is made for stays.
    fn show_draft_size(&mut self, family: &str, cx: &mut Context<Self>) {
        let Some(pane) = self.draft.as_mut().filter(|_| self.page == Page::Draft).and_then(|view| view.pane.as_mut()) else { return };
        if pane.family != family {
            pane.family = family.to_owned();
            self.refresh_draft_pane(cx);
        }
        cx.notify();
    }

    /// Draws the current version at every size, one after the other, off this thread. Without a
    /// version to show the pictures are only taken away.
    fn refresh_ai_previews(&mut self, cx: &mut Context<Self>) {
        self.refresh_draft_pane(cx);
        let (service, studio, scale) = (self.ai.clone(), self.studio.clone(), self.scale);
        let Some((_, _, dark)) = self.ai_context(cx) else { return };
        let Some(view) = self.ai_view_mut() else { return };
        view.preview_run += 1;
        let run = view.preview_run;
        let wanted = if view.panel.proposal.is_some() { service.size_previews(&view.panel, dark, scale) } else { Vec::new() };
        let old: Vec<Shown> = std::mem::take(&mut view.previews).into_iter().map(|(_, shown)| shown).collect();
        self.retired.extend(old);
        if wanted.is_empty() {
            return;
        }
        cx.spawn(async move |this, cx| {
            for (family, request) in wanted {
                let engine = studio.clone();
                let result = cx.background_executor().spawn(async move { engine.preview(&request) }).await;
                let keep_going = this.update(cx, |this, cx| {
                    // Another version is shown by now, or the conversation was closed.
                    let Some(view) = this.ai_view_mut().filter(|view| view.preview_run == run) else { return false };
                    if let Some(shown) = result.picture.and_then(Shown::from_picture) {
                        view.previews.push((family, shown));
                        cx.notify();
                    }
                    true
                });
                if !matches!(keep_going, Ok(true)) {
                    break;
                }
            }
        })
        .detach();
    }

    fn stop_ai(&mut self, cx: &mut Context<Self>) {
        if let Some(view) = self.ai_view_mut() {
            view.panel.cancel();
        }
        cx.notify();
    }

    /// Shows the version before or after the current one. Nothing is sent and nothing is written.
    fn step_ai_version(&mut self, step: i32, cx: &mut Context<Self>) {
        let service = self.ai.clone();
        let Some(view) = self.ai_view_mut() else { return };
        if service.step_version(&mut view.panel, step) {
            view.error = None;
            self.refresh_ai_previews(cx);
        }
        cx.notify();
    }

    /// Starts a new conversation from the version that is shown, with no earlier turn to send.
    fn start_ai_over(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let service = self.ai.clone();
        let Some(view) = self.ai_view_mut() else { return };
        match service.start_over(&mut view.panel) {
            Ok(()) => {
                view.error = None;
                window.push_notification(Notification::success(t("ai.startedOver")), cx);
                self.refresh_ai_previews(cx);
            }
            Err(error) => view.error = Some(error.0),
        }
        cx.notify();
    }

    fn toggle_ai_skills(&mut self, cx: &mut Context<Self>) {
        if let Some(view) = self.ai_view_mut() {
            view.skills_open = !view.skills_open;
        }
        cx.notify();
    }

    /// Adds a Skill to this conversation or takes it out; `None` gives the choice back to the Skills page.
    fn choose_ai_skill(&mut self, id: Option<String>, cx: &mut Context<Self>) {
        let service = self.ai.clone();
        let Some(view) = self.ai_view_mut() else { return };
        match id {
            Some(id) => view.error = service.toggle_skill(&mut view.panel, &id).err().map(|error| error.0),
            None => service.follow_enabled_skills(&mut view.panel),
        }
        cx.notify();
    }

    /// Puts an example into the prompt, at the size it is written for when that size can be shown.
    fn use_ai_example(&mut self, index: usize, window: &mut Window, cx: &mut Context<Self>) {
        let Some(example) = AiExamplePrompts::all().get(index) else { return };
        let Some(view) = self.ai_view_mut() else { return };
        view.prompt.update(cx, |prompt, cx| prompt.set_value(example.prompt, window, cx));
        let focus = gpui_kit::Focusable::focus_handle(view.prompt.read(cx), cx);
        focus.focus(window, cx);
        if view.panel.is_draft() {
            view.panel.conversation.size = example.size;
            self.show_draft_size(example.size.family(), cx);
        } else if self.editor.as_ref().is_some_and(|session| session.pane.families.contains(&example.size.family())) {
            self.set_preview_family(example.size.family(), cx);
        }
        cx.notify();
    }

    /// The size a new widget is made for.
    fn set_draft_size(&mut self, size: AiWidgetSize, cx: &mut Context<Self>) {
        if let Some(view) = self.draft.as_mut().filter(|view| view.panel.is_draft() && !view.panel.is_running()) {
            view.panel.conversation.size = size;
            // The large preview follows the size the widget is made for.
            self.show_draft_size(size.family(), cx);
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

    /// Saves the version a draft holds as a new widget under the name in the field, and opens it
    /// in the editor with the conversation beside it. A widget that declares hosts is saved only
    /// after the user agreed in a dialog: the hosts are the model's choice.
    fn save_draft(&mut self, allow_hosts: bool, window: &mut Window, cx: &mut Context<Self>) {
        let service = self.ai.clone();
        let Some(view) = self.draft.as_mut().filter(|_| self.page == Page::Draft) else { return };
        let typed = view.name.read(cx).value().trim().to_owned();
        let name = if typed.is_empty() { AiService::suggested_name(&view.panel) } else { typed };
        match service.save_new(&mut view.panel, &name, allow_hosts) {
            Ok(Saved::Done { name }) => {
                view.error = None;
                window.push_notification(Notification::success(tf("ai.saved", &[&name])), cx);
                // The conversation moves to the editor with the widget it now belongs to. There the
                // editor's own preview shows the widget, and the prompt asks what should change.
                let mut moved = self.draft.take();
                if let Some(view) = moved.as_mut() {
                    self.retired.extend(view.pane.take().and_then(|pane| pane.shown));
                    view.prompt.update(cx, |prompt, cx| prompt.set_placeholder(prompt_hint(false), window, cx));
                }
                self.go(Target::Editor(name.clone()), window, cx);
                match (self.editor.as_mut().filter(|session| session.name == name), moved) {
                    (Some(session), Some(view)) => session.ai = Some(view),
                    (None, Some(view)) => self.retire_ai(view),
                    _ => {}
                }
            }
            Ok(Saved::NeedsConsent(hosts)) => {
                let this = cx.weak_entity();
                let hosts = hosts.join(", ");
                window.open_alert_dialog(cx, move |alert, _, _| {
                    let this = this.clone();
                    // Host names come from the model: shown as text.
                    alert.title(t("ai.save.hosts.title")).description(tf("ai.save.hosts.detail", &[&hosts])).confirm().ok_text(t("ai.save.hosts.confirm")).cancel_text(t("action.cancel")).on_ok(move |_, window, cx| {
                        let _ = this.update(cx, |this, cx| this.save_draft(true, window, cx));
                        true
                    })
                });
            }
            Err(error) => view.error = Some(error.0),
        }
        cx.notify();
    }

    /// The page of a conversation about a widget that does not exist yet.
    pub(super) fn render_draft(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let Some(view) = &self.draft else { return div().into_any_element() };
        let border = cx.theme().border;
        let header = h_flex()
            .p_3()
            .gap_2()
            .border_b_1()
            .border_color(border)
            .child(Button::new("draft-back").icon(IconName::ArrowLeft).ghost().tooltip(t("action.back")).accessibility_label(t("action.back")).on_click(cx.listener(|this, _, window, cx| this.back(window, cx))))
            .child(div().font_semibold().child(t("ai.draft.title")));
        // The room beside the conversation: the version shown, large, at the size chosen.
        let room = (self.width - SIDEBAR_WIDTH - DRAFT_WIDTH).max(0.0);
        let preview = view.pane.as_ref().map(|pane| self.render_pane_in(pane, PaneLayout::Filling { width: room, empty: t("ai.draft.preview") }, cx).into_any_element());
        v_flex().size_full().child(header).child(h_flex().flex_1().min_h_0().items_start().child(self.render_ai(view, false, cx)).children(preview)).into_any_element()
    }

    /// The conversation. `fixable` says that the widget's last run failed, so fixing that can be asked for.
    pub(super) fn render_ai(&self, view: &AiView, fixable: bool, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.theme();
        let (muted, border, danger, success, foreground, secondary, mono) = (theme.muted_foreground, theme.border, theme.danger, theme.success, theme.foreground, theme.secondary, theme.mono_font_family.clone());
        let panel = &view.panel;
        let (draft, running) = (panel.is_draft(), panel.is_running());
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
        if panel.is_empty() {
            let examples = h_flex().gap_1().flex_wrap().children(AiExamplePrompts::all().iter().enumerate().map(|(index, example)| {
                Button::new(("ai-example", index)).label(strings::example(example.title)).small().outline().on_click(cx.listener(move |this, _, window, cx| this.use_ai_example(index, window, cx)))
            }));
            body = body
                .child(div().text_sm().text_color(muted).child(if draft { t("ai.draft.empty") } else { t("ai.empty") }))
                .child(v_flex().gap_1().child(div().text_sm().font_semibold().child(t("ai.examples"))).child(examples));
        }
        if draft {
            let size = panel.conversation.size;
            let sizes = h_flex().gap_1().flex_wrap().children(AiWidgetSize::ALL.into_iter().enumerate().map(|(index, choice)| {
                Button::new(("ai-size", index))
                    .label(strings::family(choice.family()))
                    .small()
                    .map(|button| if size == choice { button.primary() } else { button.outline() })
                    .selected(size == choice)
                    .disabled(running)
                    .on_click(cx.listener(move |this, _, _, cx| this.set_draft_size(choice, cx)))
            }));
            body = body.child(v_flex().gap_1().child(div().text_sm().font_semibold().child(t("ai.size"))).child(sizes));
        }
        for (index, row) in rows.iter().enumerate().filter(|(_, row)| !row.manual_edit) {
            let detail = match row.status {
                Status::Succeeded => div().text_color(muted).child(SharedString::from(row.detail.clone())),
                Status::Cancelled => div().text_color(muted).child(t("ai.cancelled")),
                Status::Interrupted => div().text_color(muted).child(t("ai.interrupted")),
                _ => div().text_color(danger).child(SharedString::from(row.detail.clone())),
            };
            let turn = row.id.clone();
            body = body.child(
                v_flex()
                    .gap_0p5()
                    .text_sm()
                    // What the user asked, and what a model or a failure said: text.
                    .child(div().font_semibold().child(SharedString::from(row.request.clone())))
                    .child(detail)
                    .when(row.can_retry, |section| section.child(h_flex().child(Button::new(("ai-retry", index)).label(t("ai.retry")).small().outline().on_click(cx.listener(move |this, _, window, cx| this.retry_ai(turn.clone(), window, cx)))))),
            );
        }
        if let Some(advice) = panel.advice() {
            body = body.child(
                v_flex()
                    .gap_1()
                    .child(div().text_xs().text_color(muted).child(SharedString::from(advice)))
                    .when(panel.conversation.current_version().is_some(), |section| section.child(h_flex().child(Button::new("ai-start-over").label(t("ai.startOver")).small().outline().disabled(running).on_click(cx.listener(|this, _, window, cx| this.start_ai_over(window, cx)))))),
            );
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
                    .child(h_flex().gap_2().text_sm().child(div().font_semibold().child(tf("ai.attempt", &[&running.attempt.to_string(), &running.limit.to_string()]))).child(div().text_color(muted).child(phase)))
                    .when(!running.reply.is_empty(), |section| section.child(div().p_2().rounded_md().bg(secondary).child(code(&running.reply)))),
            );
        }
        if let Some(place) = panel.version_place().filter(|place| !running && (place.has_previous || place.has_next)) {
            body = body.child(
                h_flex()
                    .gap_2()
                    .items_center()
                    .child(Button::new("ai-version-previous").icon(IconName::ChevronLeft).small().outline().disabled(!place.has_previous).tooltip(t("ai.version.previous")).accessibility_label(t("ai.version.previous")).on_click(cx.listener(|this, _, _, cx| this.step_ai_version(-1, cx))))
                    .child(div().text_sm().font_semibold().child(tf("ai.version", &[&place.number.to_string(), &place.latest.to_string()])))
                    .child(Button::new("ai-version-next").icon(IconName::ChevronRight).small().outline().disabled(!place.has_next).tooltip(t("ai.version.next")).accessibility_label(t("ai.version.next")).on_click(cx.listener(|this, _, _, cx| this.step_ai_version(1, cx)))),
            );
        }
        if let Some(proposal) = &panel.proposal {
            let summary = match &proposal.lines {
                // Nothing to compare with, or too long to compare: the code as it is.
                None => t("ai.wholeCode"),
                Some(_) if proposal.added == 0 && proposal.removed == 0 => t("ai.noChanges"),
                Some(_) => tf("ai.changes", &[&proposal.added.to_string(), &proposal.removed.to_string()]),
            };
            let changes = match &proposal.lines {
                Some(lines) => v_flex().text_xs().font_family(mono.clone()).children(lines.iter().take(MAXIMUM_LINES).map(|line| match line.kind {
                    Kind::Added => div().text_color(success).child(SharedString::from(format!("+ {}", line.text))),
                    Kind::Removed => div().text_color(danger).child(SharedString::from(format!("- {}", line.text))),
                    Kind::Same => div().text_color(foreground).child(SharedString::from(format!("  {}", line.text))),
                    Kind::Skipped => div().text_color(muted).child(tf("ai.skipped", &[&line.skipped.to_string()])),
                })),
                None => code(&proposal.source),
            };
            // On the page of a new widget a picture is also the switch to its size in the large preview.
            let large = view.pane.as_ref().map(|pane| pane.family.clone());
            let pictures = h_flex().gap_2().flex_wrap().items_end().children(view.previews.iter().enumerate().map(|(index, (family, shown))| {
                let (width, height) = shown.fitted(THUMBNAIL, THUMBNAIL);
                let chosen = large.as_deref() == Some(family.as_str());
                let picture = v_flex().gap_0p5().items_center().child(img(shown.image.clone()).w(px(width)).h(px(height))).child(div().text_xs().text_color(if chosen { foreground } else { muted }).child(strings::family(family)));
                if large.is_none() {
                    return picture.into_any_element();
                }
                let (target, label) = (family.clone(), tf("ai.sizes.show", &[&strings::family(family)]));
                Button::new(("ai-size-picture", index))
                    .child(picture)
                    .ghost()
                    .h_auto()
                    .p_1()
                    .selected(chosen)
                    .tooltip(label.clone())
                    .accessibility_label(label)
                    .on_click(cx.listener(move |this, _, _, cx| this.show_draft_size(&target, cx)))
                    .into_any_element()
            }));
            let action = if draft {
                v_flex()
                    .gap_1()
                    .child(Input::new(&view.name).aria_label(t("ai.save.name")))
                    .child(h_flex().child(Button::new("ai-save").label(t("ai.save")).primary().small().disabled(running).on_click(cx.listener(|this, _, window, cx| this.save_draft(false, window, cx)))))
            } else if proposal.applied {
                v_flex().child(div().text_sm().text_color(success).child(t("ai.applied")))
            } else {
                v_flex().child(h_flex().child(Button::new("ai-apply").label(t("ai.apply")).primary().small().disabled(running).on_click(cx.listener(|this, _, window, cx| this.apply_ai(false, window, cx)))))
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
                    .when(!view.previews.is_empty(), |section| section.child(div().text_xs().font_semibold().text_color(muted).child(t("ai.sizes"))).child(pictures))
                    .child(action),
            );
        }
        if let Some(error) = &view.error {
            body = body.child(div().text_sm().text_color(danger).child(SharedString::from(error.clone())));
        }

        // Under the conversation: the Skills of this conversation, fixing an error, and the prompt.
        let choices = self.ai.skill_choices(panel);
        let chosen = choices.iter().filter(|choice| choice.chosen).count();
        let own = panel.conversation.skill_ids.is_some();
        let tools = h_flex()
            .gap_2()
            .flex_wrap()
            .child(Button::new("ai-skills").label(tf("ai.skills", &[&chosen.to_string()])).small().map(|button| if view.skills_open { button.primary() } else { button.outline() }).selected(view.skills_open).on_click(cx.listener(|this, _, _, cx| this.toggle_ai_skills(cx))))
            .when(fixable && !draft, |tools| tools.child(Button::new("ai-fix").label(t("ai.fix")).small().outline().disabled(running).on_click(cx.listener(|this, _, window, cx| this.fix_with_ai(window, cx)))));
        let skills = v_flex()
            .gap_1()
            .child(div().text_xs().text_color(muted).child(if own { t("ai.skills.detail") } else { t("ai.skills.following") }))
            .child(h_flex().gap_1().flex_wrap().children(choices.iter().enumerate().map(|(index, choice)| {
                let id = choice.id.clone();
                // The title of a Skill comes from its package: shown as text.
                Button::new(("ai-skill", index))
                    .label(SharedString::from(choice.title.clone()))
                    .small()
                    .map(|button| if choice.chosen { button.primary() } else { button.outline() })
                    .selected(choice.chosen)
                    .disabled(running)
                    .on_click(cx.listener(move |this, _, _, cx| this.choose_ai_skill(Some(id.clone()), cx)))
            })))
            .when(own, |section| section.child(h_flex().child(Button::new("ai-skills-follow").label(t("ai.skills.follow")).small().ghost().disabled(running).on_click(cx.listener(|this, _, _, cx| this.choose_ai_skill(None, cx))))));

        let send = if running {
            Button::new("ai-stop").label(t("ai.stop")).outline().small().on_click(cx.listener(|this, _, _, cx| this.stop_ai(cx)))
        } else {
            Button::new("ai-send").label(t("ai.send")).primary().small().on_click(cx.listener(|this, _, window, cx| this.send_to_ai(window, cx)))
        };
        let hint = prompt_hint(draft);
        let title = h_flex().p_3().justify_between().border_b_1().border_color(border).child(div().font_semibold().child(t("ai.title"))).when(!draft, |title| {
            title.child(Button::new("ai-close").icon(IconName::Close).small().ghost().tooltip(t("ai.close")).accessibility_label(t("ai.close")).on_click(cx.listener(|this, _, window, cx| this.toggle_ai(window, cx))))
        });
        v_flex()
            .w(px(if draft { DRAFT_WIDTH } else { PANEL_WIDTH }))
            .h_full()
            .flex_shrink_0()
            .map(|panel| if draft { panel.border_r_1() } else { panel.border_l_1() })
            .border_color(border)
            .child(title)
            .child(div().id("ai-conversation").flex_1().min_h_0().overflow_y_scrollbar().child(body))
            .child(
                v_flex()
                    .p_3()
                    .gap_2()
                    .border_t_1()
                    .border_color(border)
                    .child(tools)
                    .when(view.skills_open, |footer| footer.child(skills))
                    .child(h_flex().gap_2().child(div().flex_1().min_w_0().child(Input::new(&view.prompt).aria_label(hint))).child(send)),
            )
    }

    // The provider, on the settings page

    /// Reads the saved provider into the fields of the settings page.
    pub(super) fn load_ai_settings(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let settings = self.ai.settings();
        let profile = settings.profile;
        let base_url = cx.new(|cx| InputState::new(window, cx).placeholder("https://").default_value(profile.base_url.clone()));
        let model = cx.new(|cx| InputState::new(window, cx).default_value(profile.model.clone()));
        let key = cx.new(|cx| InputState::new(window, cx).placeholder(t("settings.ai.key.hint")).masked(true));
        self.ai_settings = Some(AiSettingsForm { kind: profile.kind, base_url, model, key, status: self.ai.key_status(profile.kind), message: None, models: None, loading_models: false });
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
        // The list was another endpoint's.
        form.models = None;
        cx.notify();
    }

    /// Puts a model's name into the field; it is saved with "Save provider".
    fn choose_ai_model(&mut self, model: String, window: &mut Window, cx: &mut Context<Self>) {
        let Some(form) = self.ai_settings.as_mut() else { return };
        form.model.update(cx, |field, cx| field.set_value(model, window, cx));
        form.message = None;
        cx.notify();
    }

    /// Asks the endpoint in the field which models it lists, with the stored key, off this thread.
    fn load_ai_models(&mut self, cx: &mut Context<Self>) {
        let service = self.ai.clone();
        let Some(form) = self.ai_settings.as_mut().filter(|form| !form.loading_models) else { return };
        let (kind, base_url) = (form.kind, form.base_url.read(cx).value().to_string());
        form.loading_models = true;
        form.message = None;
        cx.spawn(async move |this, cx| {
            let asked = base_url.clone();
            let result = cx.background_executor().spawn(async move { service.models(kind, &asked) }).await;
            let _ = this.update(cx, |this, cx| {
                let Some(form) = this.ai_settings.as_mut() else { return };
                form.loading_models = false;
                // An answer for an endpoint that is no longer in the fields is dropped.
                if form.kind == kind && form.base_url.read(cx).value().as_ref() == base_url {
                    match result {
                        Ok(models) => form.models = Some(models),
                        Err(error) => {
                            form.models = None;
                            form.message = Some((false, error.0));
                        }
                    }
                }
                cx.notify();
            });
        })
        .detach();
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
        // A model's name is put into the field by a click. The names of an endpoint are text from a server.
        let chips = |prefix: &'static str, names: Vec<String>, cx: &mut Context<Self>| {
            h_flex().gap_1().flex_wrap().children(names.into_iter().enumerate().map(|(index, name)| {
                let chosen = name.clone();
                Button::new((prefix, index)).label(SharedString::from(name)).small().outline().on_click(cx.listener(move |this, _, window, cx| this.choose_ai_model(chosen.clone(), window, cx)))
            }))
        };
        let suggested: Vec<String> = form.kind.suggested_models().iter().map(|name| name.to_string()).collect();
        let listed = match &form.models {
            None => div(),
            Some(models) if models.is_empty() => div().text_sm().text_color(muted).child(t("settings.ai.noModels")),
            Some(models) => {
                let more = models.len().saturating_sub(MAXIMUM_MODELS);
                div().child(
                    v_flex()
                        .gap_1()
                        .child(div().text_sm().text_color(muted).child(tf("settings.ai.listed", &[&models.len().to_string()])))
                        .child(chips("ai-model-listed", models.iter().take(MAXIMUM_MODELS).cloned().collect(), cx))
                        .when(more > 0, |list| list.child(div().text_sm().text_color(muted).child(tf("settings.ai.moreModels", &[&more.to_string()])))),
                )
            }
        };
        let load = Button::new("ai-load-models").label(if form.loading_models { t("settings.ai.loadingModels") } else { t("settings.ai.loadModels") }).small().outline().disabled(form.loading_models).on_click(cx.listener(|this, _, _, cx| this.load_ai_models(cx)));
        section
            .child(providers)
            .child(field(t("settings.ai.baseUrl"), &form.base_url))
            .child(field(t("settings.ai.model"), &form.model))
            .when(!suggested.is_empty(), |section| section.child(v_flex().gap_1().child(div().text_sm().text_color(muted).child(t("settings.ai.suggested"))).child(chips("ai-model-suggested", suggested, cx))))
            .child(h_flex().child(load))
            .child(listed)
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
