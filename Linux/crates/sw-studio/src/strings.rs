//! Every text the management window shows, in English and Simplified
//! Chinese. The keys follow `Windows/src/ScriptWidget.Studio/Services/Loc.cs`
//! where the two windows say the same thing.

use std::sync::atomic::{AtomicU8, Ordering};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Language {
    English,
    Chinese,
}

/// Key, English, Simplified Chinese. `{0}` and `{1}` are filled by [`tf`].
pub const TEXT: &[(&str, &str, &str)] = &[
    ("app.title", "ScriptWidget", "ScriptWidget"),
    ("nav.library", "My widgets", "我的小组件"),
    ("nav.templates", "Templates", "模板"),
    ("nav.settings", "Settings", "设置"),
    //
    ("library.title", "My widgets", "我的小组件"),
    ("library.new", "New widget", "新建小组件"),
    ("library.import", "Import…", "导入…"),
    ("library.empty.title", "No widgets yet", "还没有小组件"),
    ("library.empty.detail", "Start from a template, or create an empty widget and write your own.", "从模板开始，或者新建一个空白小组件自己写。"),
    ("library.empty.templates", "Browse templates", "浏览模板"),
    ("library.unreadable", "Its widget.json cannot be read.", "它的 widget.json 无法读取。"),
    ("library.failed", "Your widgets could not be listed: {0}", "无法列出你的小组件：{0}"),
    //
    ("action.edit", "Edit", "编辑"),
    ("action.addToDesktop", "Add to desktop", "添加到桌面"),
    ("action.export", "Export…", "导出…"),
    ("action.delete", "Remove", "移除"),
    ("action.exportNamed", "Export {0}", "导出“{0}”"),
    ("action.removeNamed", "Remove {0}", "移除“{0}”"),
    ("action.use", "Use this template", "使用此模板"),
    ("action.save", "Save", "保存"),
    ("action.back", "Back", "返回"),
    ("action.cancel", "Cancel", "取消"),
    ("action.ok", "OK", "确定"),
    //
    ("templates.title", "Templates", "模板"),
    ("templates.detail", "Ready-made widgets. Open one to see what it shows and how it is written, then make it yours.", "现成的小组件。点开可以看它的效果和代码，再变成你自己的。"),
    ("templates.none", "No templates are installed with this program.", "这个程序没有附带模板。"),
    ("templates.group.template", "Widgets", "小组件"),
    ("templates.group.component", "Component examples", "组件示例"),
    ("templates.group.api", "API examples", "API 示例"),
    ("templates.network", "Uses the network", "会访问网络"),
    //
    ("detail.code", "Code", "代码"),
    ("detail.readOnly", "Read only", "只读"),
    ("detail.network", "Connects to {0}", "会访问 {0}"),
    ("detail.noNetwork", "Does not use the network", "不访问网络"),
    //
    ("editor.files", "Files", "文件"),
    ("editor.code", "Code editor", "代码编辑器"),
    ("editor.preview", "Preview", "预览"),
    ("editor.dark", "Dark", "深色"),
    ("editor.light", "Light", "浅色"),
    ("editor.appearance", "Preview appearance: {0}", "预览外观：{0}"),
    ("editor.unsaved", "Unsaved changes", "有未保存的修改"),
    ("editor.saved", "Saved", "已保存"),
    ("editor.saveFailed", "Could not save: {0}", "保存失败：{0}"),
    ("editor.running", "Running…", "运行中…"),
    ("editor.ok", "Ran in {0} ms", "运行用时 {0} 毫秒"),
    ("editor.logs", "Output", "输出"),
    ("editor.noLogs", "console.log output appears here.", "console.log 的输出显示在这里。"),
    ("editor.binary", "This file is not text and cannot be edited here.", "这个文件不是文本，不能在这里编辑。"),
    ("editor.missing", "“{0}” is not one of your widgets.", "“{0}”不在你的小组件里。"),
    ("editor.discard.title", "Discard unsaved changes?", "放弃未保存的修改？"),
    ("editor.discard.detail", "Your changes to {0} have not been saved.", "{0} 的修改还没有保存。"),
    ("editor.discard.confirm", "Discard", "放弃"),
    ("editor.saveHint", "Ctrl+S", "Ctrl+S"),
    //
    ("size.small", "Small", "小"),
    ("size.medium", "Medium", "中"),
    ("size.large", "Large", "大"),
    ("size.extraLarge", "Extra large", "特大"),
    //
    ("dialog.new.title", "New widget", "新建小组件"),
    ("dialog.new.hint", "Name", "名称"),
    ("dialog.new.default", "My Widget", "我的小组件"),
    ("dialog.delete.title", "Remove “{0}”?", "移除“{0}”？"),
    ("dialog.delete.detail", "The widget and its files are deleted from this computer. This cannot be undone.", "这个小组件和它的文件会从这台电脑上删除，无法恢复。"),
    ("dialog.import.title", "Import this widget?", "导入这个小组件？"),
    ("dialog.import.detail", "“{0}” will be added to your widgets. Only import widgets from people you trust.", "“{0}”会加入你的小组件。请只导入你信任的来源。"),
    ("dialog.import.contents", "{0} files, {1}", "{0} 个文件，{1}"),
    ("dialog.import.file", "From {0}", "来自 {0}"),
    ("dialog.import.confirm", "Import", "导入"),
    ("dialog.import.refused", "This file cannot be imported: {0}", "这个文件无法导入：{0}"),
    ("dialog.path.import", "Import a widget", "导入小组件"),
    ("dialog.path.import.hint", "Path of a .swt file", ".swt 文件的路径"),
    ("dialog.path.export", "Export “{0}”", "导出“{0}”"),
    ("dialog.path.export.hint", "Where to save the .swt file", ".swt 文件保存到哪里"),
    ("dialog.error.title", "That did not work", "操作没有成功"),
    //
    ("toast.added", "Added to the desktop", "已添加到桌面"),
    ("toast.exported", "Exported to {0}", "已导出到 {0}"),
    ("toast.imported", "“{0}” was added to your widgets", "“{0}”已加入你的小组件"),
    ("toast.removed", "“{0}” was removed", "已移除“{0}”"),
    ("toast.hostMissing", "The ScriptWidget background service is not running, so the widget could not be placed. Start it, then try again.", "ScriptWidget 后台服务没有运行，无法放置小组件。请先启动它再试。"),
    ("toast.cliMissing", "The scriptwidget command was not found, so the widget could not be placed.", "找不到 scriptwidget 命令，无法放置小组件。"),
    ("toast.addFailed", "The widget could not be placed: {0}", "无法放置小组件：{0}"),
    //
    ("settings.title", "Settings", "设置"),
    ("settings.refresh", "Refresh interval", "刷新间隔"),
    ("settings.refresh.detail", "How often widgets without a schedule of their own run again.", "没有自己时间表的小组件多久重新运行一次。"),
    ("settings.minutes", "{0} minutes", "{0} 分钟"),
    ("settings.hours", "{0} hours", "{0} 小时"),
    ("settings.hour", "1 hour", "1 小时"),
    ("settings.failed", "The setting could not be saved: {0}", "设置保存失败：{0}"),
    ("settings.data", "Data folder", "数据文件夹"),
    ("settings.about", "About", "关于"),
    ("settings.version", "ScriptWidget for Linux {0} (in development)", "ScriptWidget Linux 版 {0}（开发中）"),
    ("settings.licence", "ScriptWidget is licensed under Apache-2.0.", "ScriptWidget 以 Apache-2.0 许可证发布。"),
    (
        "settings.licences",
        "Built with GPUI and gpui-kit (Apache-2.0), QuickJS-NG (MIT), Skia (BSD-3-Clause), Lucide icons (ISC) and the Inter typeface (SIL OFL 1.1).",
        "使用了 GPUI 和 gpui-kit（Apache-2.0）、QuickJS-NG（MIT）、Skia（BSD-3-Clause）、Lucide 图标（ISC）和 Inter 字体（SIL OFL 1.1）。",
    ),
    ("settings.website", "Website", "官方网站"),
    //
    ("startup.failed", "ScriptWidget could not start: {0}", "ScriptWidget 无法启动：{0}"),
    ("bytes.b", "{0} bytes", "{0} 字节"),
    ("bytes.kb", "{0} KB", "{0} KB"),
    ("bytes.mb", "{0} MB", "{0} MB"),
];

static LANGUAGE: AtomicU8 = AtomicU8::new(0);

/// The language a locale asks for: the window follows the system language
/// when it is one of the two it has, and is English for every other.
/// `variable` reads an environment variable. `SCRIPTWIDGET_LANGUAGE=zh` or
/// `en` chooses for one run, as on Windows; otherwise the first of `LC_ALL`,
/// `LC_MESSAGES` and `LANG` that is set decides, as gettext does.
pub fn detect(variable: impl Fn(&str) -> Option<String>) -> Language {
    let locale = ["SCRIPTWIDGET_LANGUAGE", "LC_ALL", "LC_MESSAGES", "LANG"].into_iter().find_map(|name| variable(name).filter(|value| !value.is_empty())).unwrap_or_default();
    language_of(&locale)
}

/// Simplified Chinese for a Chinese locale written in simplified characters
/// (`zh`, `zh_CN`, `zh-Hans`, `zh_SG`), English for everything else: other
/// languages, Traditional Chinese (`zh_TW`, `zh_HK`, `zh-Hant`), `C`, `POSIX`
/// and anything that is not a locale name.
pub fn language_of(locale: &str) -> Language {
    // language[_territory][.codeset][@modifier], or a BCP 47 tag with hyphens.
    let name = locale.split(['.', '@']).next().unwrap_or_default().to_ascii_lowercase();
    let mut parts = name.split(['_', '-']);
    if parts.next() != Some("zh") {
        return Language::English;
    }
    let rest: Vec<&str> = parts.collect();
    let traditional = rest.iter().any(|part| matches!(*part, "hant" | "tw" | "hk" | "mo"));
    let known = rest.iter().all(|part| matches!(*part, "hans" | "hant" | "cn" | "sg" | "my" | "tw" | "hk" | "mo"));
    if known && !traditional { Language::Chinese } else { Language::English }
}

pub fn set_language(language: Language) {
    LANGUAGE.store(language as u8, Ordering::Relaxed);
}

pub fn language() -> Language {
    if LANGUAGE.load(Ordering::Relaxed) == Language::Chinese as u8 { Language::Chinese } else { Language::English }
}

pub fn text_in(language: Language, key: &str) -> Option<&'static str> {
    TEXT.iter().find(|(name, _, _)| *name == key).map(|(_, english, chinese)| if language == Language::Chinese { *chinese } else { *english })
}

/// The text for `key` in the current language. An unknown key shows as itself, so a mistake is visible.
pub fn t(key: &str) -> String {
    text_in(language(), key).map_or_else(|| key.to_owned(), str::to_owned)
}

/// [`t`] with `{0}`, `{1}`… replaced. The arguments are inserted as they are, never interpreted again.
pub fn tf(key: &str, arguments: &[&str]) -> String {
    fill(&t(key), arguments)
}

fn fill(pattern: &str, arguments: &[&str]) -> String {
    let mut result = String::with_capacity(pattern.len() + 16);
    let mut rest = pattern;
    while let Some(open) = rest.find('{') {
        result.push_str(&rest[..open]);
        let after = &rest[open + 1..];
        match after.find('}').and_then(|close| after[..close].parse::<usize>().ok().map(|index| (index, close))) {
            Some((index, close)) => {
                result.push_str(arguments.get(index).copied().unwrap_or(""));
                rest = &after[close + 1..];
            }
            None => {
                result.push('{');
                rest = after;
            }
        }
    }
    result.push_str(rest);
    result
}

/// The name of a widget family ("small", "extraLarge").
pub fn family(name: &str) -> String {
    t(&format!("size.{name}"))
}

pub fn bytes(count: u64) -> String {
    if count < 1024 {
        tf("bytes.b", &[&count.to_string()])
    } else if count < 1024 * 1024 {
        tf("bytes.kb", &[&format!("{:.1}", count as f64 / 1024.0)])
    } else {
        tf("bytes.mb", &[&format!("{:.1}", count as f64 / (1024.0 * 1024.0))])
    }
}

/// The label of a refresh interval in minutes.
pub fn interval(minutes: u32) -> String {
    match minutes {
        60 => t("settings.hour"),
        minutes if minutes > 60 && minutes % 60 == 0 => tf("settings.hours", &[&(minutes / 60).to_string()]),
        minutes => tf("settings.minutes", &[&minutes.to_string()]),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;

    fn placeholders(text: &str) -> BTreeSet<String> {
        let mut found = BTreeSet::new();
        let mut rest = text;
        while let Some(open) = rest.find('{') {
            let after = &rest[open + 1..];
            if let Some(close) = after.find('}') {
                found.insert(after[..close].to_owned());
            }
            rest = after;
        }
        found
    }

    #[test]
    fn every_key_has_both_languages_and_the_same_placeholders() {
        let mut seen = BTreeSet::new();
        for (key, english, chinese) in TEXT {
            assert!(seen.insert(*key), "{key} is listed twice");
            assert!(!english.trim().is_empty(), "{key} has no English text");
            assert!(!chinese.trim().is_empty(), "{key} has no Chinese text");
            assert_eq!(placeholders(english), placeholders(chinese), "{key} takes different arguments in the two languages");
        }
    }

    #[test]
    fn chinese_texts_are_translated() {
        // The same text in both languages is right only for names and key names.
        let same: Vec<&str> = TEXT.iter().filter(|(_, english, chinese)| english == chinese).map(|(key, _, _)| *key).collect();
        assert_eq!(same, ["app.title", "editor.saveHint", "bytes.kb", "bytes.mb"]);
    }

    /// The keys the window's source asks for, read from the source itself.
    fn used_keys(source: &str) -> Vec<String> {
        let mut keys = Vec::new();
        for call in ["t(\"", "tf(\""] {
            let mut rest = source;
            while let Some(at) = rest.find(call) {
                // `t(` must be the whole name of the function called.
                let named = rest[..at].chars().next_back().is_some_and(|before| before.is_alphanumeric() || before == '_');
                let after = &rest[at + call.len()..];
                if let (false, Some(end)) = (named, after.find('"')) {
                    keys.push(after[..end].to_owned());
                }
                rest = after;
            }
        }
        keys
    }

    #[test]
    fn every_key_the_window_uses_exists() {
        let sources = [
            include_str!("ui/mod.rs"),
            include_str!("ui/window.rs"),
            include_str!("ui/library.rs"),
            include_str!("ui/templates.rs"),
            include_str!("ui/editor.rs"),
            include_str!("ui/settings.rs"),
            include_str!("ui/preview_pane.rs"),
            include_str!("main.rs"),
        ];
        let mut used = BTreeSet::new();
        for source in sources {
            for key in used_keys(source) {
                assert!(text_in(Language::English, &key).is_some(), "the window asks for the unknown text {key}");
                used.insert(key);
            }
        }
        assert!(used.len() > 40, "the scan found only {} keys", used.len());
        // Keys that are built at run time or used by this module.
        let indirect = |key: &str| key.starts_with("size.") || key.starts_with("bytes.") || key.starts_with("templates.group.") || ["settings.hour", "settings.hours", "settings.minutes"].contains(&key);
        let unused: Vec<&str> = TEXT.iter().map(|(key, _, _)| *key).filter(|key| !used.contains(*key) && !indirect(key)).collect();
        assert!(unused.is_empty(), "texts nothing shows: {unused:?}");
    }

    #[test]
    fn a_supported_locale_chooses_its_language_and_every_other_is_english() {
        for locale in ["zh", "zh_CN", "zh_CN.UTF-8", "zh-CN", "zh-Hans", "zh_Hans_CN", "zh-Hans-CN", "zh_SG.UTF-8", "ZH_cn.utf8", "zh_CN@pinyin"] {
            assert_eq!(language_of(locale), Language::Chinese, "{locale}");
        }
        for locale in ["en_US.UTF-8", "en", "C", "C.UTF-8", "POSIX", "", "fr_FR.UTF-8", "ja_JP.UTF-8", "de", "ko_KR", "zh_TW.UTF-8", "zh_HK", "zh-Hant", "zh_Hant_TW", "zh_XX", "zhx", "zha_CN", "not a locale", "\u{0}\u{ff}", "_CN", ".UTF-8"] {
            assert_eq!(language_of(locale), Language::English, "{locale:?}");
        }
    }

    #[test]
    fn the_environment_names_the_locale() {
        let with = |pairs: &[(&str, &str)]| {
            let pairs: Vec<(String, String)> = pairs.iter().map(|(name, value)| (name.to_string(), value.to_string())).collect();
            detect(move |name| pairs.iter().find(|(key, _)| key == name).map(|(_, value)| value.clone()))
        };
        assert_eq!(with(&[]), Language::English, "no locale at all");
        assert_eq!(with(&[("LANG", "zh_CN.UTF-8")]), Language::Chinese);
        assert_eq!(with(&[("LANG", "fr_FR.UTF-8")]), Language::English, "a language the window does not have");
        assert_eq!(with(&[("LANG", "zh_CN.UTF-8"), ("LC_ALL", "en_US.UTF-8")]), Language::English, "LC_ALL wins");
        assert_eq!(with(&[("LANG", "en_US.UTF-8"), ("LC_MESSAGES", "zh_CN.UTF-8")]), Language::Chinese);
        assert_eq!(with(&[("LANG", "zh_CN.UTF-8"), ("LC_ALL", "")]), Language::Chinese, "an empty variable is unset");
        assert_eq!(with(&[("LANG", "en_US.UTF-8"), ("SCRIPTWIDGET_LANGUAGE", "zh")]), Language::Chinese);
        assert_eq!(with(&[("LANG", "zh_CN.UTF-8"), ("SCRIPTWIDGET_LANGUAGE", "en")]), Language::English);
    }

    #[test]
    fn arguments_are_inserted_and_never_read_again() {
        assert_eq!(fill("Remove “{0}”?", &["Clock"]), "Remove “Clock”?");
        assert_eq!(fill("{0} files, {1}", &["3", "2 KB"]), "3 files, 2 KB");
        assert_eq!(fill("{0} and {0}", &["{1}", "never"]), "{1} and {1}", "a package name with braces stays text");
        assert_eq!(fill("{1}", &["only"]), "");
        assert_eq!(fill("{x} {", &[]), "{x} {");
        assert_eq!(interval(15), fill(text_in(language(), "settings.minutes").unwrap(), &["15"]));
        assert_eq!(interval(120), fill(text_in(language(), "settings.hours").unwrap(), &["2"]));
    }
}
