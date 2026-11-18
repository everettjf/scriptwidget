//! "Templates": the bundled templates in their groups, and one template
//! opened with its preview beside its code.

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Editor, EditorState};
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{ActiveTheme as _, StyledExt as _, IconName, h_flex, v_flex};
use gpui_kit::{AppContext as _, Context, Entity, InteractiveElement as _, IntoElement, ParentElement as _, SharedString, StatefulInteractiveElement as _, Styled as _, Window, div, px};

use super::library::{CARD_WIDTH, picture_frame};
use super::preview_pane::PreviewPane;
use super::window::{Page, StudioWindow, Target};
use crate::model::{TemplateCard, TemplateDetail};
use crate::strings::{t, tf};

pub(super) struct TemplateSession {
    pub detail: TemplateDetail,
    code: Entity<EditorState>,
    pub pane: PreviewPane,
}

impl StudioWindow {
    pub(super) fn render_templates(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let muted = cx.theme().muted_foreground;
        let mut page = v_flex().p_6().gap_5().child(v_flex().gap_1().child(div().text_2xl().font_semibold().child(t("templates.title"))).child(div().text_color(muted).child(t("templates.detail"))));
        if self.template_groups.is_empty() {
            page = page.child(div().pt_8().text_color(muted).child(t("templates.none")));
        }
        let mut index = 0;
        for group in &self.template_groups {
            let cards: Vec<_> = group
                .templates
                .iter()
                .map(|card| {
                    index += 1;
                    self.template_card(index, card, cx)
                })
                .collect();
            page = page.child(v_flex().gap_3().child(div().text_lg().font_semibold().child(t(&format!("templates.group.{}", group.group)))).child(h_flex().flex_wrap().items_start().gap_4().children(cards)));
        }
        div().id("templates").size_full().overflow_y_scrollbar().child(page)
    }

    fn template_card(&self, index: usize, card: &TemplateCard, cx: &mut Context<Self>) -> gpui_kit::AnyElement {
        let theme = cx.theme();
        let (muted, border, secondary, hover) = (theme.muted_foreground, theme.border, theme.secondary, theme.accent);
        let reference = card.reference.clone();
        let placeholder = if card.network { h_flex().gap_1().text_sm().text_color(muted).child(IconName::Globe).child(t("templates.network")) } else { h_flex() };
        v_flex()
            .id(("template", index))
            .p_3()
            .gap_2()
            .border_1()
            .border_color(border)
            .rounded_xl()
            .cursor_pointer()
            .hover(move |style| style.bg(hover))
            .tab_index(0)
            .aria_label(SharedString::from(card.name.clone()))
            .on_click(cx.listener(move |this, _, window, cx| this.navigate(Target::Template(reference.clone()), window, cx)))
            .child(picture_frame(self.thumbnails.get(&format!("t/{}", card.reference)), placeholder, secondary))
            .child(div().w(px(CARD_WIDTH)).font_semibold().truncate().child(SharedString::from(card.name.clone())))
            .into_any_element()
    }

    pub(super) fn open_template(&mut self, reference: &str, window: &mut Window, cx: &mut Context<Self>) {
        let Some(detail) = self.studio.template(reference) else {
            self.page = Page::Templates;
            return;
        };
        let source = detail.source.clone();
        let code = cx.new(|cx| EditorState::new(window, cx).language("javascript").line_number(true).default_value(source));
        self.template = Some(TemplateSession { detail, code, pane: PreviewPane::new(sw_core::library::FAMILIES.to_vec(), self.dark(cx)) });
        self.page = Page::Template;
        self.request_preview(true, cx);
    }

    fn use_template(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(reference) = self.template.as_ref().map(|session| session.detail.reference.clone()) else { return };
        match self.studio.use_template(&reference) {
            Ok(name) => self.go(Target::Editor(name), window, cx),
            Err(error) => self.notify_error(error.0, window, cx),
        }
    }

    pub(super) fn render_template(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let Some(session) = &self.template else { return div().into_any_element() };
        let theme = cx.theme();
        let (muted, border) = (theme.muted_foreground, theme.border);
        let network = if session.detail.hosts.is_empty() { t("detail.noNetwork") } else { tf("detail.network", &[&session.detail.hosts.join(", ")]) };
        let about = if session.detail.description.is_empty() { network } else { format!("{} · {network}", session.detail.description) };
        let header = h_flex()
            .p_3()
            .gap_3()
            .border_b_1()
            .border_color(border)
            .child(Button::new("template-back").icon(IconName::ArrowLeft).ghost().tooltip(t("action.back")).accessibility_label(t("action.back")).on_click(cx.listener(|this, _, window, cx| this.back(window, cx))))
            .child(v_flex().flex_1().min_w_0().child(div().font_semibold().truncate().child(SharedString::from(session.detail.name.clone()))).child(div().text_sm().text_color(muted).truncate().child(SharedString::from(about))))
            .child(Button::new("template-use").label(t("action.use")).primary().on_click(cx.listener(|this, _, window, cx| this.use_template(window, cx))));
        let code = v_flex()
            .flex_1()
            .min_w_0()
            .h_full()
            .child(h_flex().px_3().py_2().justify_between().child(div().font_semibold().child(t("detail.code"))).child(div().text_sm().text_color(muted).child(t("detail.readOnly"))))
            .child(div().flex_1().min_h_0().child(Editor::new(&session.code).readonly(true).bordered(false).aria_label(t("detail.code")).h_full()));
        v_flex().size_full().child(header).child(h_flex().flex_1().min_h_0().items_start().child(code).child(self.render_pane(&session.pane, cx))).into_any_element()
    }
}
