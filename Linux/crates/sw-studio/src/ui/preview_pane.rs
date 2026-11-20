//! The preview beside the code: the widget as `sw-render` draws it at a
//! chosen size, and under it what the script printed or why it failed.

use std::sync::Arc;

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{ActiveTheme as _, StyledExt as _, IconName, Selectable as _, Sizable as _, h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{Context, InteractiveElement as _, IntoElement, ParentElement as _, RenderImage, SharedString, Styled as _, div, img, px};
use image::{Frame, RgbaImage};
use smallvec::SmallVec;

use super::window::StudioWindow;
use crate::model::{Picture, PreviewResult};
use crate::strings::{self, t, tf};

/// The widest a preview is shown; a wider size is scaled down to it.
pub const PANE_WIDTH: f32 = 372.0;

/// A picture GPUI can draw, with its size in points.
#[derive(Clone)]
pub struct Shown {
    pub image: Arc<RenderImage>,
    pub width: f32,
    pub height: f32,
}

impl Shown {
    /// Hands the pixels to GPUI as they are (it wants BGRA), without encoding them.
    pub fn from_picture(picture: Picture) -> Option<Self> {
        let Picture { mut pixels, pixel_width, pixel_height, width, height } = picture;
        for pixel in pixels.chunks_exact_mut(4) {
            pixel.swap(0, 2);
        }
        let buffer = RgbaImage::from_raw(pixel_width, pixel_height, pixels)?;
        Some(Self { image: Arc::new(RenderImage::new(SmallVec::from_elem(Frame::new(buffer), 1))), width, height })
    }

    /// The size to draw at so that it fits `maximum_width` and `maximum_height`.
    pub fn fitted(&self, maximum_width: f32, maximum_height: f32) -> (f32, f32) {
        let factor = (maximum_width / self.width).min(maximum_height / self.height).min(1.0);
        (self.width * factor, self.height * factor)
    }
}

pub struct PreviewPane {
    pub family: String,
    pub families: Vec<&'static str>,
    pub dark: bool,
    pub shown: Option<Shown>,
    pub error: Option<(String, String)>,
    pub logs: Vec<(String, String)>,
    pub elapsed: Option<u64>,
    pub running: bool,
    /// The request whose result this pane is waiting for.
    pub ticket: u64,
}

impl PreviewPane {
    pub fn new(families: Vec<&'static str>, dark: bool) -> Self {
        let family = if families.contains(&"medium") { "medium" } else { families.first().copied().unwrap_or("medium") };
        Self { family: family.to_owned(), families, dark, shown: None, error: None, logs: Vec::new(), elapsed: None, running: false, ticket: 0 }
    }

    /// Empties the pane: nothing is shown and nothing is waited for. Returns the picture to release.
    pub fn clear(&mut self) -> Option<Shown> {
        self.running = false;
        self.error = None;
        self.logs.clear();
        self.elapsed = None;
        // No request has this ticket: a result that is still on its way is dropped.
        self.ticket = 0;
        self.shown.take()
    }

    /// Takes a result; returns the picture it replaces, for the caller to release.
    pub fn take(&mut self, result: PreviewResult) -> Option<Shown> {
        self.running = false;
        self.error = result.error;
        self.logs = result.logs;
        self.elapsed = Some(result.elapsed_milliseconds);
        let shown = result.picture.and_then(Shown::from_picture);
        std::mem::replace(&mut self.shown, shown)
    }
}

/// Where a preview pane stands.
pub(super) enum PaneLayout {
    /// Beside the code, at [`PANE_WIDTH`].
    Beside,
    /// The rest of the page, `width` points wide; `empty` is said while there is nothing to show.
    Filling { width: f32, empty: String },
}

impl StudioWindow {
    pub(super) fn render_pane(&self, pane: &PreviewPane, cx: &mut Context<Self>) -> impl IntoElement {
        self.render_pane_in(pane, PaneLayout::Beside, cx)
    }

    pub(super) fn render_pane_in(&self, pane: &PreviewPane, layout: PaneLayout, cx: &mut Context<Self>) -> impl IntoElement {
        // The box the picture is fitted into, and what an empty pane says.
        let (filling, box_width, box_height, empty) = match layout {
            PaneLayout::Beside => (false, PANE_WIDTH - 24.0, 226.0, String::new()),
            PaneLayout::Filling { width, empty } => (true, (width - 48.0).max(120.0), 380.0, empty),
        };
        let theme = cx.theme();
        let (muted, danger, border, secondary, mono) = (theme.muted_foreground, theme.danger, theme.border, theme.secondary, theme.mono_font_family.clone());
        let appearance = if pane.dark { t("editor.dark") } else { t("editor.light") };

        let sizes = h_flex().gap_1().flex_wrap().children(pane.families.iter().map(|family| {
            let family = *family;
            Button::new(SharedString::from(format!("family-{family}")))
                .label(strings::family(family))
                .small()
                .map(|button| if pane.family == family { button.primary() } else { button.outline() })
                .selected(pane.family == family)
                .on_click(cx.listener(move |this, _, _, cx| this.set_preview_family(family, cx)))
        }));

        let picture = div().w_full().h(px(box_height + 24.0)).flex().items_center().justify_center().rounded_lg().bg(secondary).map(|area| match &pane.shown {
            Some(shown) => {
                let (width, height) = shown.fitted(box_width, box_height);
                area.child(img(shown.image.clone()).w(px(width)).h(px(height)))
            }
            None => area.child(div().px_4().text_sm().text_color(muted).child(if pane.running { t("editor.running") } else { empty })),
        });

        let status = match (&pane.error, pane.elapsed) {
            (Some((_, message)), _) => div().text_sm().text_color(danger).child(message.clone()),
            (None, _) if pane.running && pane.elapsed.is_none() => div().text_sm().text_color(muted).child(t("editor.running")),
            (None, Some(elapsed)) => div().text_sm().text_color(muted).child(tf("editor.ok", &[&elapsed.to_string()])),
            (None, None) => div(),
        };
        let logs = if pane.logs.is_empty() {
            div().text_sm().text_color(muted).child(t("editor.noLogs"))
        } else {
            v_flex().gap_0p5().children(pane.logs.iter().map(|(level, message)| {
                let color = if level == "error" { danger } else { cx.theme().foreground };
                // What a script printed is text and nothing else.
                div().text_sm().font_family(mono.clone()).text_color(color).child(SharedString::from(message.clone()))
            }))
        };

        v_flex()
            .h_full()
            .p_3()
            .gap_3()
            // A pane that fills the page stands beside a panel that draws the line between them.
            .map(|pane| if filling { pane.flex_1().min_w_0() } else { pane.w(px(PANE_WIDTH)).flex_shrink_0().border_l_1() })
            .border_color(border)
            .child(
                h_flex().justify_between().child(div().font_semibold().child(t("editor.preview"))).child(
                    Button::new("preview-appearance")
                        .icon(if pane.dark { IconName::Moon } else { IconName::Sun })
                        .small()
                        .ghost()
                        .tooltip(tf("editor.appearance", &[&appearance]))
                        .accessibility_label(tf("editor.appearance", &[&appearance]))
                        .on_click(cx.listener(|this, _, _, cx| this.toggle_preview_appearance(cx))),
                ),
            )
            .child(sizes)
            .child(picture)
            .child(div().text_sm().font_semibold().text_color(muted).child(t("editor.logs")))
            .child(div().id("preview-output").flex_1().min_h_0().overflow_y_scrollbar().child(v_flex().gap_2().child(status).child(logs)))
    }
}
