using System.Globalization;
using Microsoft.UI.Xaml.Markup;

namespace ScriptWidget.Studio.Services;

/// <summary>The management window's text in English and Simplified Chinese, chosen by the Windows display language.</summary>
public static class Loc
{
    /// <summary>Chinese when Windows is shown in Chinese. SCRIPTWIDGET_LANGUAGE=zh or en chooses for one run.</summary>
    public static bool Chinese { get; } = (Environment.GetEnvironmentVariable("SCRIPTWIDGET_LANGUAGE") ?? CultureInfo.CurrentUICulture.TwoLetterISOLanguageName).StartsWith("zh", StringComparison.OrdinalIgnoreCase);

    private static readonly Dictionary<string, (string English, string Chinese)> Text = new()
    {
        ["nav.library"] = ("My widgets", "我的小组件"),
        ["nav.templates"] = ("Templates", "模板"),
        ["nav.settings"] = ("Settings", "设置"),

        ["library.title"] = ("My widgets", "我的小组件"),
        ["library.new"] = ("New widget", "新建小组件"),
        ["library.import"] = ("Import…", "导入…"),
        ["library.empty.title"] = ("No widgets yet", "还没有小组件"),
        ["library.empty.detail"] = ("Start from a template, or create an empty widget and write your own.", "从模板开始，或者新建一个空白小组件自己写。"),
        ["library.empty.templates"] = ("Browse templates", "浏览模板"),
        ["library.onDesktop"] = ("On desktop: {0}", "桌面上 {0} 个"),

        ["action.edit"] = ("Edit", "编辑"),
        ["action.addToDesktop"] = ("Add to desktop", "添加到桌面"),
        ["action.duplicate"] = ("Duplicate", "复制一份"),
        ["action.rename"] = ("Rename…", "重命名…"),
        ["action.export"] = ("Export…", "导出…"),
        ["action.delete"] = ("Delete", "删除"),
        ["action.more"] = ("More actions", "更多操作"),
        ["action.use"] = ("Use this template", "使用此模板"),
        ["action.save"] = ("Save", "保存"),
        ["action.format"] = ("Format", "格式化"),
        ["action.back"] = ("Back", "返回"),
        ["action.cancel"] = ("Cancel", "取消"),
        ["action.ok"] = ("OK", "确定"),
        ["action.newFile"] = ("New file…", "新建文件…"),
        ["action.deleteFile"] = ("Delete file", "删除文件"),
        ["action.openFolder"] = ("Open folder", "打开文件夹"),

        ["templates.title"] = ("Templates", "模板"),
        ["templates.detail"] = ("Ready-made widgets you can put on the desktop and change.", "现成的小组件，可以放到桌面上再改成自己的。"),
        ["templates.group.template"] = ("Widgets", "小组件"),
        ["templates.group.component"] = ("Components", "组件示例"),
        ["templates.group.api"] = ("APIs", "API 示例"),
        ["templates.search"] = ("Search templates", "搜索模板"),

        ["editor.files"] = ("Files", "文件"),
        ["editor.preview"] = ("Preview", "预览"),
        ["editor.size"] = ("Size", "尺寸"),
        ["editor.dark"] = ("Dark", "深色"),
        ["editor.parameter"] = ("Parameter", "参数"),
        ["editor.parameter.hint"] = ("Value of $getenv(\"widget-param\")", "$getenv(\"widget-param\") 的值"),
        ["editor.unsaved"] = ("Unsaved changes", "有未保存的修改"),
        ["editor.saved"] = ("Saved", "已保存"),
        ["editor.saveFailed"] = ("Could not save: {0}", "保存失败：{0}"),
        ["editor.running"] = ("Running…", "运行中…"),
        ["editor.ok"] = ("Ran in {0} ms", "运行用时 {0} 毫秒"),
        ["editor.logs"] = ("Output", "输出"),
        ["editor.noLogs"] = ("console.log output appears here.", "console.log 的输出显示在这里。"),
        ["editor.binary"] = ("This file is not text and cannot be edited here.", "这个文件不是文本，不能在这里编辑。"),
        ["editor.failed"] = ("The code editor could not start: {0}", "代码编辑器无法启动：{0}"),
        ["editor.discard.title"] = ("Discard unsaved changes?", "放弃未保存的修改？"),
        ["editor.discard.detail"] = ("Your changes to this file have not been saved.", "这个文件的修改还没有保存。"),
        ["editor.discard.confirm"] = ("Discard", "放弃"),
        ["editor.newFile.title"] = ("New file", "新建文件"),
        ["editor.newFile.hint"] = ("For example helper.js or data/items.json", "例如 helper.js 或 data/items.json"),

        ["size.small"] = ("Small", "小"),
        ["size.medium"] = ("Medium", "中"),
        ["size.large"] = ("Large", "大"),
        ["size.extraLarge"] = ("Extra large", "特大"),

        ["dialog.new.title"] = ("New widget", "新建小组件"),
        ["dialog.new.hint"] = ("Name", "名称"),
        ["dialog.new.default"] = ("My Widget", "我的小组件"),
        ["dialog.rename.title"] = ("Rename widget", "重命名小组件"),
        ["dialog.delete.title"] = ("Delete “{0}”?", "删除“{0}”？"),
        ["dialog.delete.detail"] = ("The widget and its files are removed from this computer. Widgets of it on the desktop are removed too.", "这个小组件和它的文件会从这台电脑上删除，桌面上用到它的小组件也会一并移除。"),
        ["dialog.import.title"] = ("Import this widget?", "导入这个小组件？"),
        ["dialog.import.detail"] = ("“{0}” will be added to your widgets. Widget code can fetch data from the Internet hosts it declares. Only import widgets from people you trust.", "“{0}”会加入你的小组件。小组件的代码可以访问它声明的网络地址，请只导入你信任的来源。"),
        ["dialog.import.confirm"] = ("Import", "导入"),
        ["dialog.error.title"] = ("That did not work", "操作没有成功"),

        ["toast.added"] = ("Added to the desktop", "已添加到桌面"),
        ["toast.exported"] = ("Exported to {0}", "已导出到 {0}"),
        ["toast.hostMissing"] = ("The desktop host is not running, so the widget could not be placed.", "桌面常驻程序没有运行，无法放置小组件。"),

        ["settings.title"] = ("Settings", "设置"),
        ["settings.refresh"] = ("Refresh interval", "刷新间隔"),
        ["settings.refresh.detail"] = ("How often widgets without a schedule of their own run again.", "没有自己时间表的小组件多久重新运行一次。"),
        ["settings.minutes"] = ("{0} minutes", "{0} 分钟"),
        ["settings.hours"] = ("{0} hours", "{0} 小时"),
        ["settings.hour"] = ("1 hour", "1 小时"),
        ["settings.lock"] = ("Lock positions", "锁定位置"),
        ["settings.lock.detail"] = ("Widgets cannot be dragged while this is on.", "打开后桌面上的小组件不能拖动。"),
        ["settings.pause"] = ("Pause for full-screen programs", "全屏程序运行时暂停"),
        ["settings.pause.detail"] = ("Hold refreshes while a game or a presentation is in front.", "游戏或演示在前台时暂不刷新。"),
        ["settings.startup"] = ("Start when I sign in", "登录时启动"),
        ["settings.startup.detail"] = ("Show your widgets as soon as Windows starts.", "Windows 启动后立即显示小组件。"),
        ["settings.data"] = ("Data folder", "数据文件夹"),
        ["settings.data.detail"] = ("Your widgets, their saved values and the log.", "你的小组件、它们保存的数据和日志。"),
        ["settings.about"] = ("About", "关于"),
        ["settings.version"] = ("ScriptWidget for Windows {0} (preview)", "ScriptWidget Windows 版 {0}（预览）"),
        ["settings.website"] = ("Website", "官方网站"),
        ["settings.docs"] = ("Documentation", "文档"),
    };

    public static string T(string key) => Text.TryGetValue(key, out var value) ? (Chinese ? value.Chinese : value.English) : key;

    public static string T(string key, params object[] arguments) => string.Format(CultureInfo.CurrentCulture, T(key), arguments);

    public static string Family(string family) => T("size." + family);
}

/// <summary><c>{s:T Key=nav.library}</c> in XAML.</summary>
[MarkupExtensionReturnType(ReturnType = typeof(string))]
public sealed class T : MarkupExtension
{
    public string Key { get; set; } = "";
    protected override object ProvideValue() => Loc.T(Key);
}
