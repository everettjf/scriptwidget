//! "Settings": the refresh interval, where the data is, and what the program is made of.

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{ActiveTheme as _, StyledExt as _, Selectable as _, Sizable as _, h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{Context, InteractiveElement as _, IntoElement, ParentElement as _, SharedString, Styled as _, Window, div};

use super::window::StudioWindow;
use crate::settings::INTERVALS;
use crate::strings::{self, t, tf};

const WEBSITE: &str = "https://atomsprout.com/scriptwidget/";

impl StudioWindow {
    fn set_refresh(&mut self, minutes: u32, window: &mut Window, cx: &mut Context<Self>) {
        match self.settings.set_refresh_minutes(minutes) {
            Ok(()) => {
                self.refresh_minutes = minutes;
                // The service plans the next runs by the new interval now, not after the ones it had planned.
                self.reload_service_settings(cx);
            }
            Err(error) => self.notify_error(tf("settings.failed", &[&error.to_string()]), window, cx),
        }
        cx.notify();
    }

    pub(super) fn render_settings(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.theme();
        let (muted, border) = (theme.muted_foreground, theme.border);
        let section = || v_flex().p_4().gap_2().border_1().border_color(border).rounded_xl();
        let intervals = h_flex().gap_1().flex_wrap().children(INTERVALS.iter().map(|minutes| {
            let minutes = *minutes;
            Button::new(("refresh", minutes as usize)).label(strings::interval(minutes)).small().map(|button| if self.refresh_minutes == minutes { button.primary() } else { button.outline() }).selected(self.refresh_minutes == minutes).on_click(cx.listener(move |this, _, window, cx| this.set_refresh(minutes, window, cx)))
        }));
        let refresh = section().child(div().font_semibold().child(t("settings.refresh"))).child(div().text_sm().text_color(muted).child(t("settings.refresh.detail"))).child(intervals);
        let data = section().child(div().font_semibold().child(t("settings.data"))).child(div().text_sm().text_color(muted).child(SharedString::from(self.studio.paths().root().display().to_string())));
        let about = section()
            .child(div().font_semibold().child(t("settings.about")))
            .child(div().child(tf("settings.version", &[crate::VERSION])))
            .child(div().text_sm().text_color(muted).child(t("settings.licence")))
            .child(div().text_sm().text_color(muted).child(t("settings.licences")))
            .child(h_flex().child(Button::new("settings-website").label(t("settings.website")).small().link().on_click(cx.listener(|_, _, _, cx| cx.open_url(WEBSITE)))));
        div().id("settings").size_full().overflow_y_scrollbar().child(v_flex().p_6().gap_4().max_w(gpui_kit::px(760.)).child(div().text_2xl().font_semibold().child(t("settings.title"))).child(refresh).child(self.render_ai_settings(cx)).child(self.render_github_settings(cx)).child(data).child(about))
    }
}
