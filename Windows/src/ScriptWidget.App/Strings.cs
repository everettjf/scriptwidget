namespace ScriptWidget.App;

/// <summary>The few words the tray and widget menus need.</summary>
internal static class Strings
{
    public static string OpenStudio => "Open ScriptWidget";
    public static string AddWidget => "Add widget";
    public static string NoPackages => "No widgets yet. Open ScriptWidget to create one.";
    public static string MorePackages => "More in ScriptWidget…";
    public static string RefreshAll => "Refresh all";
    public static string LockPositions => "Lock positions";
    public static string StartAtLogin => "Start when I sign in";
    public static string Quit => "Quit";
    public static string Refresh => "Refresh";
    public static string Size => "Size";
    public static string Edit => "Edit…";
    public static string Remove => "Remove from desktop";
    public static string TrayTip => "ScriptWidget";

    public static string Family(string family) => family switch
    {
        "small" => "Small",
        "large" => "Large",
        "extraLarge" => "Extra large",
        _ => "Medium",
    };

    public static string MissingTitle => "Widget not found";
    public static string MissingDetail => "Its package was removed. Right-click to take this widget off the desktop.";
    public static string TooManyWidgets => "The desktop already holds the maximum number of widgets.";
}
