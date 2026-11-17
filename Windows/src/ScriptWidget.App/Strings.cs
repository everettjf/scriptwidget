using System.Globalization;

namespace ScriptWidget.App;

/// <summary>The few words the tray and widget menus need, in Simplified Chinese and English.</summary>
internal static class Strings
{
    private static readonly bool Chinese = (Environment.GetEnvironmentVariable("SCRIPTWIDGET_LANGUAGE") ?? CultureInfo.CurrentUICulture.TwoLetterISOLanguageName).StartsWith("zh", StringComparison.OrdinalIgnoreCase);

    private static string Pick(string english, string chinese) => Chinese ? chinese : english;

    public static string OpenStudio => Pick("Open ScriptWidget", "打开 ScriptWidget");
    public static string AddWidget => Pick("Add widget", "添加小组件");
    public static string NoPackages => Pick("No widgets yet. Open ScriptWidget to create one.", "还没有小组件，打开 ScriptWidget 创建一个");
    public static string MorePackages => Pick("More in ScriptWidget…", "更多请打开 ScriptWidget…");
    public static string RefreshAll => Pick("Refresh all", "全部刷新");
    public static string LockPositions => Pick("Lock positions", "锁定位置");
    public static string StartAtLogin => Pick("Start when I sign in", "登录时启动");
    public static string Quit => Pick("Quit", "退出");
    public static string Refresh => Pick("Refresh", "刷新");
    public static string Size => Pick("Size", "尺寸");
    public static string Edit => Pick("Edit…", "编辑…");
    public static string Remove => Pick("Remove from desktop", "从桌面移除");
    public static string TrayTip => "ScriptWidget";

    public static string Family(string family) => family switch
    {
        "small" => Pick("Small", "小"),
        "large" => Pick("Large", "大"),
        "extraLarge" => Pick("Extra large", "特大"),
        _ => Pick("Medium", "中"),
    };

    public static string MissingTitle => Pick("Widget not found", "找不到这个小组件");
    public static string MissingDetail => Pick("Its package was removed. Right-click to take this widget off the desktop.", "它的包已被删除。右键可以把它从桌面移除。");
    public static string TooManyWidgets => Pick("The desktop already holds the maximum number of widgets.", "桌面上的小组件已达上限。");
}
