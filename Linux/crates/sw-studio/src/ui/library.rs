//! "My widgets": the installed widgets as cards with a small picture each.

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::InputState;
use gpui_kit::component::notification::Notification;
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{ActiveTheme as _, StyledExt as _, Disableable as _, IconName, Sizable as _, WindowExt as _, h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{AppContext as _, Context, InteractiveElement as _, IntoElement, ParentElement as _, SharedString, Styled as _, Window, div, img, px};

use super::preview_pane::Shown;
use super::window::{StudioWindow, Target};
use crate::model::WidgetCard;
use crate::strings::{t, tf};

/// The inside of a card is as wide as a medium widget.
pub(super) const CARD_WIDTH: f32 = 329.0;
pub(super) const CARD_PICTURE_HEIGHT: f32 = 170.0;

/// The frame around a card's picture, shared with the template cards.
pub(super) fn picture_frame(shown: Option<&Shown>, placeholder: impl IntoElement, background: gpui_kit::Hsla) -> impl IntoElement {
    div().w(px(CARD_WIDTH)).h(px(CARD_PICTURE_HEIGHT)).flex().items_center().justify_center().rounded_lg().bg(background).map(|frame| match shown {
        Some(shown) => {
            let (width, height) = shown.fitted(CARD_WIDTH, CARD_PICTURE_HEIGHT);
            frame.child(img(shown.image.clone()).w(px(width)).h(px(height)))
        }
        None => frame.child(placeholder),
    })
}

impl StudioWindow {
    pub(super) fn render_library(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let muted = cx.theme().muted_foreground;
        let header = h_flex()
            .justify_between()
            .child(div().text_2xl().font_semibold().child(t("library.title")))
            .child(
                h_flex()
                    .gap_2()
                    .child(Button::new("library-import").label(t("library.import")).outline().on_click(cx.listener(|this, _, window, cx| this.choose_import(window, cx))))
                    .child(Button::new("library-new-ai").label(t("library.newWithAi")).outline().on_click(cx.listener(|this, _, window, cx| this.navigate(Target::Draft, window, cx))))
                    .child(Button::new("library-new").icon(IconName::Plus).label(t("library.new")).primary().on_click(cx.listener(|this, _, window, cx| this.ask_new_widget(window, cx)))),
            );
        let body = if let Some(error) = &self.library_error {
            div().text_color(cx.theme().danger).child(tf("library.failed", &[error])).into_any_element()
        } else if self.widgets.is_empty() {
            v_flex()
                .items_center()
                .gap_2()
                .pt_16()
                .child(div().text_lg().font_semibold().child(t("library.empty.title")))
                .child(div().text_color(muted).child(t("library.empty.detail")))
                .child(Button::new("library-browse").label(t("library.empty.templates")).primary().on_click(cx.listener(|this, _, window, cx| this.navigate(Target::Templates, window, cx))))
                .into_any_element()
        } else {
            let cards: Vec<_> = self.widgets.iter().enumerate().map(|(index, card)| self.widget_card(index, card, cx)).collect();
            h_flex().flex_wrap().items_start().gap_4().children(cards).into_any_element()
        };
        div().id("library").size_full().overflow_y_scrollbar().child(v_flex().p_6().gap_5().child(header).child(body))
    }

    fn widget_card(&self, index: usize, card: &WidgetCard, cx: &mut Context<Self>) -> gpui_kit::AnyElement {
        let theme = cx.theme();
        let (muted, border, secondary, danger) = (theme.muted_foreground, theme.border, theme.secondary, theme.danger);
        let name = card.name.clone();
        let detail = if card.readable { card.description.clone() } else { t("library.unreadable") };
        let (for_add, for_edit, for_export, for_remove) = (name.clone(), name.clone(), name.clone(), name);
        let add = cx.listener(move |this, _: &gpui_kit::ClickEvent, window, cx| this.add_to_desktop(for_add.clone(), None, window, cx));
        let edit = cx.listener(move |this, _: &gpui_kit::ClickEvent, window, cx| this.navigate(Target::Editor(for_edit.clone()), window, cx));
        let export = cx.listener(move |this, _: &gpui_kit::ClickEvent, window, cx| this.export(for_export.clone(), window, cx));
        let remove = cx.listener(move |this, _: &gpui_kit::ClickEvent, window, cx| this.confirm_remove(for_remove.clone(), window, cx));
        v_flex()
            .p_3()
            .gap_2()
            .border_1()
            .border_color(border)
            .rounded_xl()
            .child(picture_frame(self.thumbnails.get(&format!("w/{}", card.name)), div(), secondary))
            // A widget's name and description come from its package: shown as text, one line each.
            .child(div().w(px(CARD_WIDTH)).font_semibold().truncate().child(SharedString::from(card.name.clone())))
            .child(div().w(px(CARD_WIDTH)).h_5().text_sm().text_color(if card.readable { muted } else { danger }).truncate().child(SharedString::from(detail)))
            .child(
                h_flex()
                    .w(px(CARD_WIDTH))
                    .gap_2()
                    .child(Button::new(("card-add", index)).label(t("action.addToDesktop")).small().primary().disabled(!card.readable).on_click(add))
                    .child(Button::new(("card-edit", index)).label(t("action.edit")).small().outline().disabled(!card.readable).on_click(edit))
                    .child(div().flex_1())
                    .child(
                        Button::new(("card-export", index))
                            .icon(IconName::ExternalLink)
                            .small()
                            .ghost()
                            .disabled(!card.readable)
                            .tooltip(t("action.export"))
                            .accessibility_label(tf("action.exportNamed", &[&card.name]))
                            .on_click(export),
                    )
                    .child(
                        Button::new(("card-remove", index))
                            .icon(IconName::Delete)
                            .small()
                            .ghost()
                            .tooltip(t("action.delete"))
                            .accessibility_label(tf("action.removeNamed", &[&card.name]))
                            .on_click(remove),
                    ),
            )
            .into_any_element()
    }

    fn ask_new_widget(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let input = cx.new(|cx| InputState::new(window, cx).placeholder(t("dialog.new.hint")).default_value(t("dialog.new.default")));
        self.ask_text(t("dialog.new.title"), input, window, cx, |this, name, window, cx| match this.studio.new_widget(&name) {
            Ok(created) => this.go(Target::Editor(created), window, cx),
            Err(error) => this.notify_error(error.0, window, cx),
        });
    }

    fn confirm_remove(&mut self, name: String, window: &mut Window, cx: &mut Context<Self>) {
        let this = cx.weak_entity();
        window.open_alert_dialog(cx, move |alert, _, _| {
            let (this, name) = (this.clone(), name.clone());
            alert.title(tf("dialog.delete.title", &[&name])).description(t("dialog.delete.detail")).confirm().ok_text(t("action.delete")).cancel_text(t("action.cancel")).on_ok(move |_, window, cx| {
                let _ = this.update(cx, |this, cx| {
                    match this.studio.remove(&name) {
                        Ok(()) => window.push_notification(Notification::success(tf("toast.removed", &[&name])), cx),
                        Err(error) => this.notify_error(error.0, window, cx),
                    }
                    this.reload_library(cx);
                });
                true
            })
        });
    }
}
