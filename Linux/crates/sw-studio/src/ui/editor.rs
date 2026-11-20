//! The editor: the files of one widget, the code editor of gpui-kit with
//! completion from the shared API metadata, and the live preview.

use std::rc::Rc;
use std::sync::Arc;

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{CompletionProvider, Editor, EditorState, InputEvent, Rope};
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{ActiveTheme as _, StyledExt as _, IconName, Selectable as _, Sizable as _, h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{App, AppContext as _, Context, Entity, Focusable as _, InteractiveElement as _, IntoElement, ParentElement as _, Result, SharedString, Styled as _, Subscription, Task, Window, div, px};
use lsp_types::{CompletionContext, CompletionItem, CompletionItemKind, CompletionResponse, CompletionTextEdit, Documentation, Position, Range, TextEdit};

use super::preview_pane::PreviewPane;
use super::window::{Page, StudioWindow};
use crate::completion::{ApiReference, Kind};
use crate::strings::{t, tf};

pub(super) struct EditorSession {
    /// The folder name of the widget.
    pub name: String,
    files: Vec<String>,
    /// The file that is open.
    pub path: String,
    /// `None` for a file that is not text.
    editor: Option<Entity<EditorState>>,
    pub dirty: bool,
    /// The outcome of the last save, shown beside the file name.
    status: Option<(bool, String)>,
    pub pane: PreviewPane,
    /// The AI conversation about this widget, when it is open beside the code.
    pub ai: Option<super::ai::AiView>,
    /// What is granted to and picked for this widget, while "Data access" is shown in place of the code.
    pub access: Option<crate::access::AccessState>,
    _changes: Option<Subscription>,
}

impl EditorSession {
    /// The text of the open file when it differs from what is saved, for the preview to lay over the files on disk.
    pub fn unsaved(&self, cx: &App) -> Vec<(String, String)> {
        match &self.editor {
            Some(editor) if self.dirty => vec![(self.path.clone(), editor.read(cx).value().to_string())],
            _ => Vec::new(),
        }
    }
}

/// Feeds the editor's completion menu from [`ApiReference`].
struct ApiCompletions(Arc<ApiReference>);

impl CompletionProvider for ApiCompletions {
    fn completions(&self, text: &Rope, offset: usize, _: CompletionContext, _: &mut Window, _: &mut App) -> Task<Result<CompletionResponse>> {
        let text = text.to_string();
        let Some(completions) = self.0.complete(&text, offset) else { return Task::ready(Ok(CompletionResponse::Array(Vec::new()))) };
        // The editor takes positions as line and UTF-16 column.
        let position = |byte: usize| {
            let before = &text[..byte];
            let line_start = before.rfind('\n').map_or(0, |index| index + 1);
            Position::new(before.matches('\n').count() as u32, before[line_start..].encode_utf16().count() as u32)
        };
        let range = Range::new(position(completions.from), position(offset.min(text.len())));
        let items = completions
            .items
            .into_iter()
            .map(|item| CompletionItem {
                label: item.label,
                detail: (!item.detail.is_empty()).then_some(item.detail),
                documentation: (!item.documentation.is_empty()).then_some(Documentation::String(item.documentation)),
                kind: Some(match item.kind {
                    Kind::Component => CompletionItemKind::CLASS,
                    Kind::Property => CompletionItemKind::PROPERTY,
                    Kind::Value => CompletionItemKind::ENUM_MEMBER,
                    Kind::Function => CompletionItemKind::FUNCTION,
                    Kind::Global => CompletionItemKind::VARIABLE,
                }),
                text_edit: Some(CompletionTextEdit::Edit(TextEdit { range, new_text: item.insert })),
                ..Default::default()
            })
            .collect();
        Task::ready(Ok(CompletionResponse::Array(items)))
    }

    fn is_completion_trigger(&self, _: usize, new_text: &str, _: &mut App) -> bool {
        ApiReference::is_trigger(new_text)
    }
}

fn is_script(path: &str) -> bool {
    path.ends_with(".js") || path.ends_with(".jsx") || path.ends_with(".mjs")
}

impl StudioWindow {
    /// Opens a widget in the editor at `path`, or at its entry.
    pub(super) fn open_editor(&mut self, name: &str, path: Option<String>, window: &mut Window, cx: &mut Context<Self>) {
        let (Some(card), Ok(files)) = (self.studio.widget(name).filter(|card| card.readable), self.studio.files(name)) else {
            self.page = Page::Library;
            self.reload_library(cx);
            return self.notify_error(tf("editor.missing", &[name]), window, cx);
        };
        let path = path.filter(|path| files.contains(path)).unwrap_or_else(|| self.studio.entry(&card.name));
        // The preview keeps its size and appearance while moving between the files of one widget.
        // So does the AI conversation; one about another widget ends here.
        let (pane, ai) = match self.editor.take() {
            // Opening a file shows its code: "Data access" closes.
            Some(previous) if previous.name == card.name => (previous.pane, previous.ai),
            previous => {
                if let Some(previous) = previous {
                    if let Some(view) = previous.ai {
                        self.retire_ai(view);
                    }
                    self.retired.extend(previous.pane.shown);
                }
                (PreviewPane::new(card.families.clone(), self.dark(cx)), None)
            }
        };
        let text = self.studio.read_text(&card.name, &path).ok().flatten();
        let editor = text.map(|text| {
            let api = self.api.clone();
            let script = is_script(&path);
            cx.new(|cx| {
                let mut state = EditorState::new(window, cx).line_number(true).default_value(text);
                if script {
                    state = state.language("javascript");
                    state.lsp_mut().completion_provider = Some(Rc::new(ApiCompletions(api)));
                }
                state
            })
        });
        let changes = editor.as_ref().map(|editor| {
            cx.subscribe(editor, |this, _, event: &InputEvent, cx| {
                if matches!(event, InputEvent::Change) {
                    this.text_changed(cx);
                }
            })
        });
        if let Some(editor) = &editor {
            let focus = editor.focus_handle(cx);
            window.defer(cx, move |window, cx| focus.focus(window, cx));
        }
        self.editor = Some(EditorSession { name: card.name, files, path, editor, dirty: false, status: None, pane, ai, access: None, _changes: changes });
        self.page = Page::Editor;
        self.request_preview(true, cx);
    }

    fn text_changed(&mut self, cx: &mut Context<Self>) {
        if let Some(session) = &mut self.editor {
            session.dirty = true;
            session.status = None;
        }
        self.request_preview(false, cx);
    }

    /// Saves the open file through the package store.
    pub(super) fn save(&mut self, _: &mut Window, cx: &mut Context<Self>) {
        let Some(session) = self.editor.as_mut().filter(|_| self.page == Page::Editor) else { return };
        let Some(editor) = &session.editor else { return };
        let text = editor.read(cx).value().to_string();
        match self.studio.save_text(&session.name, &session.path, &text) {
            Ok(()) => {
                session.dirty = false;
                session.status = Some((true, t("editor.saved")));
                let name = session.name.clone();
                self.forget_thumbnail(&name);
                // The files on disk now are what the preview shows; run it once more from them.
                self.request_preview(true, cx);
            }
            Err(error) => session.status = Some((false, tf("editor.saveFailed", &[&error.0]))),
        }
        cx.notify();
    }

    /// Asks for the name of a new file of the open widget.
    fn new_file(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.editor.is_none() {
            return;
        }
        let input = cx.new(|cx| gpui_kit::component::input::InputState::new(window, cx).placeholder(t("editor.newFile.hint")));
        self.ask_text(t("editor.newFile.title"), input, window, cx, |this, name, window, cx| this.create_file(name, window, cx));
    }

    /// Creates the file through the package layer, which decides whether the name is a path inside the package, and opens it.
    fn create_file(&mut self, typed: String, window: &mut Window, cx: &mut Context<Self>) {
        let Some(session) = &mut self.editor else { return };
        let name = session.name.clone();
        match self.studio.new_file(&name, &typed) {
            Ok(path) => {
                // Listed at once, also when the open file has changes and the user stays in it.
                if let Ok(files) = self.studio.files(&name) {
                    session.files = files;
                }
                self.forget_thumbnail(&name);
                cx.notify();
                self.open_file(path, window, cx);
            }
            Err(error) => self.notify_error(tf("editor.newFile.failed", &[&error.0]), window, cx),
        }
    }

    fn open_file(&mut self, path: String, window: &mut Window, cx: &mut Context<Self>) {
        let Some(session) = &mut self.editor else { return };
        if session.path == path {
            // Its code, when "Data access" was shown in its place.
            if session.access.take().is_some() {
                cx.notify();
            }
            return;
        }
        let name = session.name.clone();
        if !session.dirty {
            return self.open_editor(&name, Some(path), window, cx);
        }
        // Each file is saved on its own: leaving one with changes asks first.
        let this = cx.weak_entity();
        let current = session.path.clone();
        gpui_kit::component::WindowExt::open_alert_dialog(window, cx, move |alert, _, _| {
            let (this, name, path) = (this.clone(), name.clone(), path.clone());
            alert.title(t("editor.discard.title")).description(tf("editor.discard.detail", &[&current])).confirm().ok_text(t("editor.discard.confirm")).cancel_text(t("action.cancel")).on_ok(move |_, window, cx| {
                let _ = this.update(cx, |this, cx| this.open_editor(&name, Some(path.clone()), window, cx));
                true
            })
        });
    }

    pub(super) fn render_editor(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let Some(session) = &self.editor else { return div().into_any_element() };
        let theme = cx.theme();
        let (muted, border, danger, success) = (theme.muted_foreground, theme.border, theme.danger, theme.success);
        let name = session.name.clone();
        let family = session.pane.family.clone();
        let status = match (&session.status, session.dirty) {
            (Some((false, message)), _) => div().text_color(danger).child(message.clone()),
            (_, true) => div().text_color(muted).child(t("editor.unsaved")),
            (Some((true, message)), false) => div().text_color(success).child(message.clone()),
            (None, false) => div(),
        };
        let header = h_flex()
            .p_3()
            .gap_2()
            .border_b_1()
            .border_color(border)
            .child(Button::new("editor-back").icon(IconName::ArrowLeft).ghost().tooltip(t("action.back")).accessibility_label(t("action.back")).on_click(cx.listener(|this, _, window, cx| this.back(window, cx))))
            .child(
                v_flex()
                    .flex_1()
                    .min_w_0()
                    .child(div().font_semibold().truncate().child(SharedString::from(session.name.clone())))
                    .child(h_flex().gap_2().text_sm().child(div().text_color(muted).truncate().child(SharedString::from(session.path.clone()))).child(status)),
            )
            .child(Button::new("editor-ai").label(t("ai.open")).map(|button| if session.ai.is_some() { button.primary() } else { button.outline() }).selected(session.ai.is_some()).on_click(cx.listener(|this, _, window, cx| this.toggle_ai(window, cx))))
            .child(Button::new("editor-access").label(t("access.open")).map(|button| if session.access.is_some() { button.primary() } else { button.outline() }).selected(session.access.is_some()).on_click(cx.listener(|this, _, _, cx| this.toggle_access(cx))))
            .child(Button::new("editor-export").label(t("action.export")).outline().on_click(cx.listener({
                let name = name.clone();
                move |this, _, window, cx| this.export(name.clone(), window, cx)
            })))
            .child(Button::new("editor-add").label(t("action.addToDesktop")).outline().on_click(cx.listener(move |this, _, window, cx| this.add_to_desktop(name.clone(), Some(family.clone()), window, cx))))
            .child(Button::new("editor-save").label(t("action.save")).primary().tooltip(t("editor.saveHint")).on_click(cx.listener(|this, _, window, cx| this.save(window, cx))));

        let files = v_flex().w(px(190.)).h_full().flex_shrink_0().border_r_1().border_color(border).child(
            h_flex()
                .pl_3()
                .pr_1()
                .py_1()
                .child(div().flex_1().text_sm().font_semibold().text_color(muted).child(t("editor.files")))
                .child(Button::new("editor-new-file").icon(IconName::Plus).ghost().small().tooltip(t("editor.newFile")).accessibility_label(t("editor.newFile")).on_click(cx.listener(|this, _, window, cx| this.new_file(window, cx)))),
        ).child(
            div().id("editor-files").flex_1().min_h_0().overflow_y_scrollbar().child(v_flex().px_1().gap_0p5().children(session.files.iter().enumerate().map(|(index, path)| {
                let target = path.clone();
                // File names come from the package: shown as text.
                Button::new(("editor-file", index)).child(div().w_full().truncate().child(SharedString::from(path.clone()))).small().ghost().w_full().selected(*path == session.path && session.access.is_none()).on_click(cx.listener(move |this, _, window, cx| this.open_file(target.clone(), window, cx)))
            }))),
        );
        let code = match (&session.access, &session.editor) {
            (Some(state), _) => self.render_access(state, cx).into_any_element(),
            (None, Some(editor)) => div().flex_1().min_w_0().h_full().child(Editor::new(editor).bordered(false).aria_label(t("editor.code")).h_full()).into_any_element(),
            (None, None) => div().flex_1().min_w_0().h_full().p_6().text_color(muted).child(t("editor.binary")).into_any_element(),
        };
        v_flex().size_full().child(header).child(h_flex().flex_1().min_h_0().items_start().child(files).child(code).children(session.ai.as_ref().map(|view| self.render_ai(view, session.pane.error.is_some(), cx))).child(self.render_pane(&session.pane, cx))).into_any_element()
    }
}
