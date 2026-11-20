//! "Gallery": the verified catalog of community widgets and Skills, and one
//! item of it with what it may do. The view of [`crate::gallery`].
//!
//! Loading the catalog, the look at a widget's manifest and installing all
//! ask the network and run off this thread. What the catalog says about an
//! item is shown as text and nothing else.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::notification::Notification;
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{ActiveTheme as _, Disableable as _, IconName, Selectable as _, Sizable as _, StyledExt as _, WindowExt as _, h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{AppContext as _, Context, Entity, InteractiveElement as _, IntoElement, ParentElement as _, SharedString, StatefulInteractiveElement as _, Styled as _, Subscription, Window, div, px};
use sw_core::gallery::{GalleryInstallState, GalleryItemKind};

use super::window::{Page, StudioWindow};
use crate::gallery::{GalleryCard, GalleryView, ManifestPreview};
use crate::strings::{self, t, tf};

/// What a widget of the catalog may do, once its manifest was fetched and checked.
enum Preview {
    Loading,
    Loaded(ManifestPreview),
    Failed(String),
}

/// What the Gallery page shows.
pub(super) struct GalleryPage {
    view: Option<GalleryView>,
    loading: bool,
    /// Why the catalog could not be loaded at all.
    failure: Option<String>,
    search: Entity<InputState>,
    kind: Option<GalleryItemKind>,
    /// The item whose detail is open.
    selected: Option<String>,
    installing: HashSet<String>,
    /// Why the last install of an item did not go through.
    failures: HashMap<String, String>,
    preview: Option<(String, Preview)>,
    _search: Subscription,
}

impl StudioWindow {
    /// Shows the Gallery, loading the catalog when the page has none yet.
    pub(super) fn open_gallery(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.gallery_page.is_none() {
            let search = cx.new(|cx| InputState::new(window, cx).placeholder(t("gallery.search")));
            let typed = cx.subscribe_in(&search, window, |_, _, event: &InputEvent, _, cx| {
                if matches!(event, InputEvent::Change) {
                    cx.notify();
                }
            });
            self.gallery_page = Some(GalleryPage { view: None, loading: false, failure: None, search, kind: None, selected: None, installing: HashSet::new(), failures: HashMap::new(), preview: None, _search: typed });
        }
        self.page = Page::Gallery;
        if let Some(page) = self.gallery_page.as_mut() {
            page.selected = None;
            // What was installed or removed on another page since the last look.
            let states: HashMap<String, GalleryInstallState> = self.gallery.states().into_iter().collect();
            for card in page.view.iter_mut().flat_map(|view| &mut view.cards) {
                if let Some(state) = states.get(&card.id) {
                    card.state = state.clone();
                }
            }
        }
        self.refresh_gallery(false, window, cx);
    }

    fn refresh_gallery(&mut self, force: bool, window: &mut Window, cx: &mut Context<Self>) {
        let Some(page) = self.gallery_page.as_mut().filter(|page| !page.loading) else { return };
        page.loading = true;
        let gallery = self.gallery.clone();
        cx.spawn_in(window, async move |this, cx| {
            let result = cx.background_executor().spawn(async move { gallery.load(force) }).await;
            let _ = this.update(cx, |this, cx| {
                let Some(page) = this.gallery_page.as_mut() else { return };
                page.loading = false;
                match result {
                    Ok(view) => {
                        page.view = Some(view);
                        page.failure = None;
                    }
                    // A catalog that is already shown stays; without one the page says why there is none.
                    Err(error) => page.failure = Some(error.0),
                }
                cx.notify();
            });
        })
        .detach();
        cx.notify();
    }

    /// Opens the detail of an item and looks at what a widget may do.
    fn select_gallery_item(&mut self, id: String, window: &mut Window, cx: &mut Context<Self>) {
        let Some(page) = self.gallery_page.as_mut() else { return };
        let Some(card) = page.view.as_ref().and_then(|view| view.card(&id)) else { return };
        let widget = card.kind == GalleryItemKind::Widget;
        page.selected = Some(id.clone());
        page.preview = None;
        if widget {
            page.preview = Some((id.clone(), Preview::Loading));
            let gallery = self.gallery.clone();
            cx.spawn_in(window, async move |this, cx| {
                let asked = id.clone();
                let result = cx.background_executor().spawn(async move { gallery.preview(&asked) }).await;
                let _ = this.update(cx, |this, cx| {
                    // An answer for an item that is no longer open is dropped.
                    if let Some(preview) = this.gallery_page.as_mut().and_then(|page| page.preview.as_mut()).filter(|(shown, _)| *shown == id) {
                        preview.1 = match result {
                            Ok(preview) => Preview::Loaded(preview),
                            Err(error) => Preview::Failed(error.0),
                        };
                        cx.notify();
                    }
                });
            })
            .detach();
        }
        cx.notify();
    }

    fn close_gallery_item(&mut self, cx: &mut Context<Self>) {
        if let Some(page) = self.gallery_page.as_mut() {
            page.selected = None;
            page.preview = None;
        }
        cx.notify();
    }

    /// True when the Gallery shows one item: the back shortcut then closes it.
    pub(super) fn gallery_item_open(&self) -> bool {
        self.page == Page::Gallery && self.gallery_page.as_ref().is_some_and(|page| page.selected.is_some())
    }

    pub(super) fn back_in_gallery(&mut self, cx: &mut Context<Self>) {
        self.close_gallery_item(cx);
    }

    /// Downloads, checks and installs an item off this thread.
    fn install_gallery_item(&mut self, id: String, window: &mut Window, cx: &mut Context<Self>) {
        let Some(page) = self.gallery_page.as_mut() else { return };
        if !page.installing.insert(id.clone()) {
            return;
        }
        page.failures.remove(&id);
        let gallery: Arc<crate::gallery::Gallery> = self.gallery.clone();
        cx.spawn_in(window, async move |this, cx| {
            let (service, asked) = (gallery.clone(), id.clone());
            let result = cx.background_executor().spawn(async move { service.install(&asked) }).await;
            let states: HashMap<String, GalleryInstallState> = gallery.states().into_iter().collect();
            let _ = this.update_in(cx, |this, window, cx| {
                if let Some(page) = this.gallery_page.as_mut() {
                    page.installing.remove(&id);
                    for card in page.view.iter_mut().flat_map(|view| &mut view.cards) {
                        if let Some(state) = states.get(&card.id) {
                            card.state = state.clone();
                        }
                    }
                    if let Err(error) = &result {
                        page.failures.insert(id.clone(), error.0.clone());
                    }
                }
                if let Ok(installed) = result {
                    match installed.kind {
                        GalleryItemKind::Widget => {
                            // The picture of the widget this one replaced is not this one's.
                            this.forget_thumbnail(&installed.local);
                            window.push_notification(Notification::success(tf("toast.imported", &[&installed.local])), cx);
                        }
                        GalleryItemKind::Skill => window.push_notification(Notification::success(tf("gallery.toast.skill", &[&installed.name])), cx),
                    }
                }
                cx.notify();
            });
        })
        .detach();
        cx.notify();
    }

    fn set_gallery_kind(&mut self, kind: Option<GalleryItemKind>, cx: &mut Context<Self>) {
        if let Some(page) = self.gallery_page.as_mut() {
            page.kind = kind;
        }
        cx.notify();
    }

    pub(super) fn render_gallery(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let Some(page) = &self.gallery_page else { return div().into_any_element() };
        if let Some(card) = page.selected.as_ref().and_then(|id| page.view.as_ref()?.card(id)) {
            return self.render_gallery_item(page, card, cx).into_any_element();
        }
        let theme = cx.theme();
        let (muted, border, warning) = (theme.muted_foreground, theme.border, theme.warning);
        let header = h_flex()
            .justify_between()
            .items_start()
            .gap_4()
            .child(v_flex().gap_1().min_w_0().child(div().text_2xl().font_semibold().child(t("gallery.title"))).child(div().text_color(muted).child(t("gallery.detail"))))
            .child(Button::new("gallery-refresh").label(if page.loading { t("gallery.loading") } else { t("gallery.refresh") }).outline().disabled(page.loading).on_click(cx.listener(|this, _, window, cx| this.refresh_gallery(true, window, cx))));
        let mut content = v_flex().p_6().gap_5().max_w(px(860.)).child(header);
        let Some(view) = &page.view else {
            let body = match &page.failure {
                Some(failure) if !page.loading => v_flex()
                    .items_center()
                    .gap_2()
                    .pt_16()
                    .child(div().text_lg().font_semibold().child(t("gallery.unavailable.title")))
                    .child(div().text_color(muted).child(SharedString::from(failure.clone())))
                    .child(div().text_sm().text_color(muted).child(t("gallery.unavailable.detail")))
                    .child(Button::new("gallery-retry").label(t("gallery.retry")).primary().on_click(cx.listener(|this, _, window, cx| this.refresh_gallery(true, window, cx)))),
                _ => v_flex().items_center().pt_16().child(div().text_color(muted).child(t("gallery.loading"))),
            };
            return div().id("gallery").size_full().overflow_y_scrollbar().child(content.child(body)).into_any_element();
        };
        if view.offline {
            let mut notice = v_flex().p_3().gap_1().border_1().border_color(warning).rounded_lg().child(div().font_semibold().child(t("gallery.offline.title"))).child(div().text_sm().child(tf("gallery.offline.detail", &[&ago(view.fetched_at)])));
            if let Some(reason) = &view.offline_reason {
                notice = notice.child(div().text_sm().text_color(muted).child(SharedString::from(reason.clone())));
            }
            content = content.child(notice);
        }
        let filter = |id: &'static str, label: String, kind: Option<GalleryItemKind>, cx: &mut Context<Self>| {
            Button::new(id).label(label).small().map(|button| if page.kind == kind { button.primary() } else { button.outline() }).selected(page.kind == kind).on_click(cx.listener(move |this, _, _, cx| this.set_gallery_kind(kind, cx)))
        };
        content = content.child(
            h_flex()
                .gap_2()
                .child(div().flex_1().min_w_0().child(Input::new(&page.search).prefix(gpui_kit::component::Icon::new(IconName::Search)).aria_label(t("gallery.search"))))
                .child(filter("gallery-all", t("gallery.filter.all"), None, cx))
                .child(filter("gallery-widgets", t("gallery.filter.widgets"), Some(GalleryItemKind::Widget), cx))
                .child(filter("gallery-skills", t("gallery.filter.skills"), Some(GalleryItemKind::Skill), cx)),
        );
        let query = page.search.read(cx).value().to_string();
        let cards = view.matching(&query, page.kind);
        if cards.is_empty() {
            content = content.child(div().pt_8().text_color(muted).child(t("gallery.none")));
        }
        let rows: Vec<_> = cards
            .into_iter()
            .enumerate()
            .map(|(index, card)| {
                let id = card.id.clone();
                let hover = cx.theme().accent;
                let mut row = v_flex()
                    .id(("gallery-item", index))
                    .p_4()
                    .gap_1()
                    .border_1()
                    .border_color(border)
                    .rounded_xl()
                    .cursor_pointer()
                    .hover(move |style| style.bg(hover))
                    .tab_index(0)
                    .aria_label(SharedString::from(card.name.clone()))
                    .on_click(cx.listener(move |this, _, window, cx| this.select_gallery_item(id.clone(), window, cx)))
                    .child(
                        h_flex()
                            .gap_3()
                            .child(v_flex().flex_1().min_w_0().child(div().font_semibold().truncate().child(SharedString::from(card.name.clone()))).child(div().text_sm().text_color(muted).truncate().child(SharedString::from(format!("{} · {} · {}", kind_name(card.kind), card.version, card.author)))))
                            .child(self.install_control(page, card, index, true, cx)),
                    )
                    .child(div().text_sm().child(SharedString::from(card.summary.clone())));
                if let Some(failure) = page.failures.get(&card.id) {
                    row = row.child(div().text_sm().text_color(cx.theme().danger).child(tf("gallery.notInstalled", &[failure])));
                }
                row
            })
            .collect();
        div().id("gallery").size_full().overflow_y_scrollbar().child(content.child(v_flex().gap_3().children(rows))).into_any_element()
    }

    /// Install, Update or Installed, and what is going on while the item is downloaded and checked.
    fn install_control(&self, page: &GalleryPage, card: &GalleryCard, index: usize, compact: bool, cx: &mut Context<Self>) -> gpui_kit::AnyElement {
        let muted = cx.theme().muted_foreground;
        if page.installing.contains(&card.id) {
            return div().text_sm().text_color(muted).child(t("gallery.installing")).into_any_element();
        }
        let id = card.id.clone();
        let install = cx.listener(move |this, _: &gpui_kit::ClickEvent, window, cx| {
            // The row behind the button is not opened by the same click.
            cx.stop_propagation();
            this.install_gallery_item(id.clone(), window, cx);
        });
        let button = Button::new((if compact { "gallery-install" } else { "gallery-install-detail" }, index)).small();
        match &card.state {
            GalleryInstallState::Installed => button.label(t("gallery.installed")).outline().disabled(true).into_any_element(),
            GalleryInstallState::UpdateAvailable { current } => button.label(if compact { t("gallery.update") } else { tf("gallery.updateFrom", &[current]) }).primary().accessibility_label(format!("{} {}", t("gallery.update"), card.name)).on_click(install).into_any_element(),
            GalleryInstallState::NotInstalled => button.label(t("gallery.install")).primary().accessibility_label(format!("{} {}", t("gallery.install"), card.name)).on_click(install).into_any_element(),
        }
    }

    fn render_gallery_item(&self, page: &GalleryPage, card: &GalleryCard, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.theme();
        let (muted, border, secondary, danger, warning) = (theme.muted_foreground, theme.border, theme.secondary, theme.danger, theme.warning);
        let header = h_flex()
            .p_3()
            .gap_3()
            .border_b_1()
            .border_color(border)
            .child(Button::new("gallery-back").icon(IconName::ArrowLeft).ghost().tooltip(t("action.back")).accessibility_label(t("action.back")).on_click(cx.listener(|this, _, _, cx| this.close_gallery_item(cx))))
            // What the catalog says about the item is shown as text, one line each.
            .child(v_flex().flex_1().min_w_0().child(div().font_semibold().truncate().child(SharedString::from(card.name.clone()))).child(div().text_sm().text_color(muted).truncate().child(SharedString::from(format!("{} · {}", kind_name(card.kind), card.author)))))
            .child(self.install_control(page, card, 0, false, cx));
        let fact = |label: String, value: String| h_flex().gap_3().child(div().w(px(120.)).flex_shrink_0().text_color(muted).child(label)).child(div().flex_1().min_w_0().child(SharedString::from(value)));
        let loaded = match &page.preview {
            Some((_, Preview::Loaded(preview))) => Some(preview),
            _ => None,
        };
        let mut facts = v_flex()
            .p_4()
            .gap_2()
            .border_1()
            .border_color(border)
            .rounded_xl()
            .child(fact(t("gallery.fact.type"), if card.kind == GalleryItemKind::Widget { t("gallery.kind.widget") } else { t("gallery.fact.skillType") }))
            .child(fact(t("gallery.fact.version"), card.version.clone()))
            .child(fact(t("gallery.fact.author"), card.author.clone()))
            .child(fact(t("gallery.fact.license"), card.license.clone()))
            .child(fact(t("gallery.fact.files"), tf("dialog.import.contents", &[&card.files.to_string(), &strings::bytes(card.bytes)])));
        if let Some(api) = loaded.and_then(|preview| preview.api_version.as_deref()) {
            facts = facts.child(fact(t("gallery.fact.requires"), tf("gallery.fact.api", &[api])));
        }
        let mut body = v_flex().p_6().gap_4().max_w(px(760.)).child(div().text_lg().child(SharedString::from(card.summary.clone())));
        if let Some(failure) = page.failures.get(&card.id) {
            body = body.child(v_flex().p_3().gap_1().border_1().border_color(danger).rounded_lg().child(div().text_sm().text_color(danger).child(tf("gallery.notInstalled", &[failure]))));
        }
        body = body.child(facts);
        if !card.tags.is_empty() {
            body = body.child(h_flex().flex_wrap().gap_2().children(card.tags.iter().map(|tag| div().px_2().rounded_md().bg(secondary).text_sm().child(SharedString::from(tag.clone())))));
        }
        let note = |text: String| div().text_sm().text_color(muted).child(SharedString::from(text));
        body = match &page.preview {
            None => body.child(note(t("gallery.preview.skill"))),
            Some((_, Preview::Loading)) => body.child(note(t("gallery.preview.loading"))),
            Some((_, Preview::Failed(reason))) => body.child(note(tf("gallery.preview.failed", &[reason]))),
            Some((_, Preview::Loaded(preview))) => {
                let mut may = v_flex().gap_1().text_sm();
                if let Some(api) = &preview.unsupported {
                    may = may.child(div().p_3().border_1().border_color(warning).rounded_lg().child(tf("gallery.preview.unsupported", &[api])));
                }
                // The permissions and hosts are the widget's own words: shown as text.
                may = may.child(SharedString::from(if preview.permissions.is_empty() { t("gallery.preview.noPermissions") } else { tf("gallery.preview.permissions", &[&preview.permissions.join(", ")]) }));
                may = may.child(SharedString::from(if preview.hosts.is_empty() { t("detail.noNetwork") } else { tf("detail.network", &[&preview.hosts.join(", ")]) }));
                body.child(may)
            }
        };
        // The address passed the catalog's check: HTTPS on github.com and nothing else.
        let source = card.source_url.clone();
        body = body
            .child(h_flex().child(Button::new("gallery-source").icon(IconName::ExternalLink).label(t("gallery.source")).small().outline().on_click(cx.listener(move |_, _, _, cx| cx.open_url(&source)))))
            .child(note(t("gallery.verified")));
        v_flex().size_full().child(header).child(div().id("gallery-item").flex_1().min_h_0().overflow_y_scrollbar().child(body))
    }
}

fn kind_name(kind: GalleryItemKind) -> String {
    match kind {
        GalleryItemKind::Widget => t("gallery.kind.widget"),
        GalleryItemKind::Skill => t("gallery.kind.skill"),
    }
}

/// How long ago a time in milliseconds since 1970 was, in words.
fn ago(milliseconds: i64) -> String {
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |elapsed| elapsed.as_millis() as i64);
    let minutes = (now - milliseconds).max(0) / 60_000;
    match minutes {
        0 => t("gallery.ago.now"),
        1..60 => tf("gallery.ago.minutes", &[&minutes.to_string()]),
        60..1440 => tf("gallery.ago.hours", &[&(minutes / 60).to_string()]),
        _ => tf("gallery.ago.days", &[&(minutes / 1440).to_string()]),
    }
}
