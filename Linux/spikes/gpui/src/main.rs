// Phase 0 spike: a GPUI window with a gpui-component code editor showing JSX,
// plus a completion provider with three fixed items offered after `$`.
// Throwaway code.

use std::rc::Rc;

use gpui_kit::component::input::{CompletionProvider, Editor, EditorState, Rope};
use gpui_kit::*;
use lsp_types::{
    CompletionContext, CompletionItem, CompletionItemKind, CompletionResponse, CompletionTextEdit,
    Position, Range, TextEdit,
};

const SAMPLE: &str = include_str!("sample.jsx");

struct ApiCompletions;

fn is_ident(ch: char) -> bool {
    ch.is_alphanumeric() || ch == '_' || ch == '$'
}

impl CompletionProvider for ApiCompletions {
    fn completions(
        &self,
        text: &Rope,
        offset: usize,
        _trigger: CompletionContext,
        _: &mut Window,
        _: &mut App,
    ) -> Task<Result<CompletionResponse>> {
        let text = text.to_string();
        let before = &text[..offset.min(text.len())];
        let line_start = before.rfind('\n').map(|i| i + 1).unwrap_or(0);
        let line = before.matches('\n').count() as u32;
        let word_start = before
            .char_indices()
            .rev()
            .take_while(|(_, c)| is_ident(*c))
            .last()
            .map(|(i, _)| i)
            .unwrap_or(before.len());
        let word = &before[word_start..];
        if !word.starts_with('$') {
            return Task::ready(Ok(CompletionResponse::Array(vec![])));
        }
        // LSP columns are UTF-16 code units.
        let col = |byte: usize| before[line_start..byte].encode_utf16().count() as u32;
        let range = Range::new(
            Position::new(line, col(word_start)),
            Position::new(line, col(before.len())),
        );
        let items = [
            ("$storage", "Package-namespaced key/value storage"),
            ("$device", "Device and screen information"),
            ("fetch", "HTTP request (needs the network permission)"),
        ]
        .into_iter()
        .map(|(label, detail)| CompletionItem {
            label: label.into(),
            detail: Some(detail.into()),
            kind: Some(CompletionItemKind::VARIABLE),
            text_edit: Some(CompletionTextEdit::Edit(TextEdit {
                range,
                new_text: label.into(),
            })),
            ..Default::default()
        })
        .collect();
        Task::ready(Ok(CompletionResponse::Array(items)))
    }

    fn is_completion_trigger(&self, _offset: usize, new_text: &str, _: &mut App) -> bool {
        !new_text.is_empty() && new_text.chars().all(is_ident)
    }
}

struct Studio {
    editor: Entity<EditorState>,
}

impl Render for Studio {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div()
            .size_full()
            .flex()
            .flex_col()
            .p_2()
            .child(Editor::new(&self.editor).flex_1())
    }
}

fn main() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();

    gpui_kit::application().run(move |cx| {
        gpui_kit::init(cx);
        cx.activate(true);

        gpui_kit::open_window(WindowOptions::default(), cx, |window, cx| {
            let editor = cx.new(|cx| {
                let mut state = EditorState::new(window, cx)
                    .language("javascript")
                    .line_number(true)
                    .default_value(SAMPLE);
                state.lsp_mut().completion_provider = Some(Rc::new(ApiCompletions));
                state
            });
            let focus = editor.focus_handle(cx);
            window.defer(cx, move |window, cx| focus.focus(window, cx));
            window.set_window_title("ScriptWidget GPUI spike");
            cx.new(|_| Studio { editor })
        })
        .expect("failed to open window");
    });
}
