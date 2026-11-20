//! "Skills": the instructions that are added to AI requests while they are
//! turned on. The view of [`crate::skills`].
//!
//! What a Skill says is shown as text and nothing else.

use std::path::PathBuf;

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::notification::Notification;
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{ActiveTheme as _, IconName, Selectable as _, Sizable as _, StyledExt as _, WindowExt as _, h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{Context, InteractiveElement as _, IntoElement, ParentElement as _, SharedString, Styled as _, Window, div, px};

use super::window::{StudioWindow, downloads_folder};
use crate::skills::{SkillRow, Skills};
use crate::strings::{t, tf};

/// As many lines of a Skill's instructions as are drawn; the rest is one line that says how many more there are.
const MAXIMUM_LINES: usize = 200;

/// What the Skills page shows.
#[derive(Default)]
pub(super) struct SkillsPage {
    rows: Vec<SkillRow>,
    /// The Skill whose instructions are open.
    open: Option<String>,
}

impl StudioWindow {
    pub(super) fn reload_skills(&mut self, cx: &mut Context<Self>) {
        self.skills_page.rows = self.skills.rows();
        cx.notify();
    }

    fn toggle_skill(&mut self, id: String, enabled: bool, window: &mut Window, cx: &mut Context<Self>) {
        if let Err(error) = self.skills.set_enabled(&id, enabled) {
            self.notify_error(error.0, window, cx);
        }
        self.reload_skills(cx);
    }

    /// Asks which `.swskill` file, or which folder, to import. A file chooser
    /// of a Linux desktop picks files or folders, not either, so there is a button for each.
    fn choose_skill(&mut self, folder: bool, window: &mut Window, cx: &mut Context<Self>) {
        let chosen = cx.prompt_for_paths(gpui_kit::PathPromptOptions { files: !folder, directories: folder, multiple: false, prompt: Some(t("dialog.import.confirm").into()) });
        cx.spawn_in(window, async move |this, cx| {
            let _ = match chosen.await {
                Ok(Ok(Some(paths))) => this.update_in(cx, |this, window, cx| {
                    if let Some(path) = paths.into_iter().next() {
                        this.import_skill(path, window, cx);
                    }
                }),
                Ok(Ok(None)) => Ok(()),
                // No file chooser on this desktop: ask for the path in the window.
                Ok(Err(_)) | Err(_) => this.update_in(cx, |this, window, cx| {
                    this.ask_path(t("skills.path.import"), t("skills.path.import.hint"), downloads_folder().join(""), window, cx, |this, path, window, cx| this.import_skill(path, window, cx));
                }),
            };
        })
        .detach();
    }

    /// Reads, checks and stores a Skill off this thread. An imported Skill is not turned on.
    fn import_skill(&mut self, path: PathBuf, window: &mut Window, cx: &mut Context<Self>) {
        let skills = self.skills.clone();
        cx.spawn_in(window, async move |this, cx| {
            let result = cx.background_executor().spawn(async move { skills.import(&path) }).await;
            let _ = this.update_in(cx, |this, window, cx| {
                match result {
                    Ok(row) => window.push_notification(Notification::success(tf("skills.toast.imported", &[&row.title])), cx),
                    Err(error) => this.notify_error(tf("skills.refused", &[&error.0]), window, cx),
                }
                this.reload_skills(cx);
            });
        })
        .detach();
    }

    /// Asks where to save, then writes the `.swskill` file.
    fn export_skill(&mut self, id: String, title: String, window: &mut Window, cx: &mut Context<Self>) {
        let folder = downloads_folder();
        let suggested = Skills::export_name(&title);
        let chosen = cx.prompt_for_new_path(&folder, Some(&suggested));
        cx.spawn_in(window, async move |this, cx| {
            let target = match chosen.await {
                Ok(Ok(Some(target))) => target,
                Ok(Ok(None)) => return,
                Ok(Err(_)) | Err(_) => {
                    let _ = this.update_in(cx, |this, window, cx| {
                        this.ask_path(tf("dialog.path.export", &[&title]), t("skills.path.export.hint"), folder.join(&suggested), window, cx, move |this, target, window, cx| this.write_skill(id.clone(), target, window, cx));
                    });
                    return;
                }
            };
            let _ = this.update_in(cx, |this, window, cx| this.write_skill(id, target, window, cx));
        })
        .detach();
    }

    fn write_skill(&mut self, id: String, target: PathBuf, window: &mut Window, cx: &mut Context<Self>) {
        let skills = self.skills.clone();
        let target = if target.extension().is_some() { target } else { target.with_extension("swskill") };
        cx.spawn_in(window, async move |this, cx| {
            let written = target.clone();
            let result = cx.background_executor().spawn(async move { skills.export(&id, &written) }).await;
            let _ = this.update_in(cx, |this, window, cx| match result {
                Ok(()) => window.push_notification(Notification::success(tf("toast.exported", &[&target.display().to_string()])), cx),
                Err(error) => this.notify_error(error.0, window, cx),
            });
        })
        .detach();
    }

    fn confirm_remove_skill(&mut self, id: String, title: String, window: &mut Window, cx: &mut Context<Self>) {
        let this = cx.weak_entity();
        window.open_alert_dialog(cx, move |alert, _, _| {
            let (this, id, title) = (this.clone(), id.clone(), title.clone());
            alert.title(tf("dialog.delete.title", &[&title])).description(t("skills.remove.detail")).confirm().ok_text(t("action.delete")).cancel_text(t("action.cancel")).on_ok(move |_, window, cx| {
                let _ = this.update(cx, |this, cx| {
                    match this.skills.remove(&id) {
                        Ok(()) => window.push_notification(Notification::success(tf("toast.removed", &[&title])), cx),
                        Err(error) => this.notify_error(error.0, window, cx),
                    }
                    this.reload_skills(cx);
                });
                true
            })
        });
    }

    pub(super) fn render_skills(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let muted = cx.theme().muted_foreground;
        let on: Vec<&str> = self.skills_page.rows.iter().filter(|row| row.enabled).map(|row| row.title.as_str()).collect();
        let in_effect = if on.is_empty() { t("skills.noneInEffect") } else { tf("skills.inEffect", &[&on.join(", ")]) };
        let header = h_flex()
            .justify_between()
            .items_start()
            .gap_4()
            .child(v_flex().gap_1().min_w_0().child(div().text_2xl().font_semibold().child(t("skills.title"))).child(div().text_color(muted).child(t("skills.detail"))).child(div().text_sm().text_color(muted).child(SharedString::from(in_effect))))
            .child(
                h_flex()
                    .gap_2()
                    .flex_shrink_0()
                    .child(Button::new("skills-import-folder").label(t("skills.importFolder")).outline().on_click(cx.listener(|this, _, window, cx| this.choose_skill(true, window, cx))))
                    .child(Button::new("skills-import").label(t("library.import")).outline().on_click(cx.listener(|this, _, window, cx| this.choose_skill(false, window, cx)))),
            );
        let rows: Vec<_> = self.skills_page.rows.iter().enumerate().map(|(index, row)| self.skill_row(index, row, cx)).collect();
        div().id("skills").size_full().overflow_y_scrollbar().child(v_flex().p_6().gap_5().max_w(px(860.)).child(header).child(v_flex().gap_3().children(rows)))
    }

    fn skill_row(&self, index: usize, row: &SkillRow, cx: &mut Context<Self>) -> gpui_kit::AnyElement {
        let theme = cx.theme();
        let (muted, border, secondary) = (theme.muted_foreground, theme.border, theme.secondary);
        let open = self.skills_page.open.as_deref() == Some(row.id.as_str());
        let origin = if row.built_in { t("skills.builtIn") } else { t("gallery.installed") };
        let mut facts = vec![origin, row.version.clone()];
        facts.extend(row.author.clone());
        facts.extend(row.tags.iter().cloned());
        let (id, enabled) = (row.id.clone(), row.enabled);
        let toggle = cx.listener(move |this, _: &gpui_kit::ClickEvent, window, cx| this.toggle_skill(id.clone(), !enabled, window, cx));
        let id = row.id.clone();
        let view = cx.listener(move |this, _: &gpui_kit::ClickEvent, _, cx| {
            this.skills_page.open = if this.skills_page.open.as_deref() == Some(id.as_str()) { None } else { Some(id.clone()) };
            cx.notify();
        });
        let (id, title) = (row.id.clone(), row.title.clone());
        let export = cx.listener(move |this, _: &gpui_kit::ClickEvent, window, cx| this.export_skill(id.clone(), title.clone(), window, cx));
        let (id, title) = (row.id.clone(), row.title.clone());
        let remove = cx.listener(move |this, _: &gpui_kit::ClickEvent, window, cx| this.confirm_remove_skill(id.clone(), title.clone(), window, cx));
        let switch = Button::new(("skill-toggle", index))
            .label(if row.enabled { t("skills.turnOff") } else { t("skills.turnOn") })
            .small()
            .map(|button| if row.enabled { button.outline() } else { button.primary() })
            .selected(row.enabled)
            .accessibility_label(if row.enabled { tf("skills.turnOffNamed", &[&row.title]) } else { tf("skills.turnOnNamed", &[&row.title]) })
            .on_click(toggle);
        let actions = h_flex()
            .gap_2()
            .child(switch)
            .child(Button::new(("skill-view", index)).label(if open { t("skills.hide") } else { t("skills.view") }).small().outline().on_click(view))
            .child(div().flex_1())
            .child(Button::new(("skill-export", index)).icon(IconName::ExternalLink).small().ghost().tooltip(t("action.export")).accessibility_label(tf("action.exportNamed", &[&row.title])).on_click(export))
            .when(!row.built_in, |actions| actions.child(Button::new(("skill-remove", index)).icon(IconName::Delete).small().ghost().tooltip(t("action.delete")).accessibility_label(tf("action.removeNamed", &[&row.title])).on_click(remove)));
        // A Skill's name, summary and instructions come from its files: shown as text.
        let title = h_flex()
            .gap_2()
            .child(div().font_semibold().truncate().child(SharedString::from(row.title.clone())))
            .when(row.enabled, |title| title.child(div().px_2().rounded_md().bg(secondary).text_xs().child(t("skills.on"))));
        let mut card = v_flex()
            .p_4()
            .gap_2()
            .border_1()
            .border_color(border)
            .rounded_xl()
            .child(title)
            .child(div().text_sm().text_color(muted).truncate().child(SharedString::from(facts.join(" · "))))
            .child(div().text_sm().child(SharedString::from(row.summary.clone())))
            .child(actions);
        if open {
            let lines: Vec<&str> = row.instruction.lines().collect();
            let mut text = v_flex().p_3().gap_1().rounded_lg().bg(secondary).text_sm().children(lines.iter().take(MAXIMUM_LINES).map(|line| div().child(SharedString::from((*line).to_owned()))));
            if lines.len() > MAXIMUM_LINES {
                text = text.child(div().text_color(muted).child(tf("ai.skipped", &[&(lines.len() - MAXIMUM_LINES).to_string()])));
            }
            card = card.child(text);
        }
        card.into_any_element()
    }
}
