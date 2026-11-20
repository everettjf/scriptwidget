using System.Globalization;
using Microsoft.UI.Xaml.Markup;

namespace ScriptWidget.Studio.Services;

/// <summary>The management window's text, by key. The interface is English only.</summary>
public static class Loc
{
    private static readonly Dictionary<string, string> Text = new()
    {
        ["nav.library"] = "My widgets",
        ["nav.templates"] = "Templates",
        ["nav.components"] = "Components",
        ["nav.apis"] = "APIs",
        ["nav.settings"] = "Settings",

        ["library.title"] = "My widgets",
        ["library.new"] = "New widget",
        ["library.import"] = "Import…",
        ["library.empty.title"] = "No widgets yet",
        ["library.empty.detail"] = "Start from a template, or create an empty widget and write your own.",
        ["library.empty.templates"] = "Browse templates",
        ["library.onDesktop"] = "On desktop: {0}",

        ["action.edit"] = "Edit",
        ["action.addToDesktop"] = "Add to desktop",
        ["action.duplicate"] = "Duplicate",
        ["action.rename"] = "Rename…",
        ["action.export"] = "Export…",
        ["action.delete"] = "Delete",
        ["action.more"] = "More actions",
        ["action.use"] = "Use this template",
        ["action.openCopy"] = "Open a copy in the editor",
        ["action.copyCode"] = "Copy code",
        ["action.save"] = "Save",
        ["action.format"] = "Format",
        ["action.back"] = "Back",
        ["action.cancel"] = "Cancel",
        ["action.ok"] = "OK",
        ["action.newFile"] = "New file…",
        ["action.deleteFile"] = "Delete file",
        ["action.openFolder"] = "Open folder",

        ["templates.title"] = "Templates",
        ["templates.detail"] = "Ready-made widgets. Open one to see what it shows and how it is written, then put it on the desktop.",
        ["components.title"] = "Components",
        ["components.detail"] = "What a widget is built from. Open one to see its properties and an example.",
        ["components.search"] = "Search components",
        ["apis.title"] = "APIs",
        ["apis.detail"] = "What a widget's code can call: choose one on the left to see its functions.",
        ["apis.functions"] = "{0} functions",
        ["apis.function"] = "1 function",
        ["apis.exampleOnly"] = "Example",
        ["apis.notOnWindows"] = "Not on Windows",
        ["apis.notOnWindows.detail"] = "Not available on Windows in this release. A widget that calls it gets an [unsupported_platform] error.",
        ["apis.noReference"] = "This one has no reference entry. Its example shows how it is used.",
        ["apis.viewExample"] = "View example",
        ["apis.results"] = "{0} matches",
        ["apis.result"] = "1 match",
        ["apis.noResults"] = "No matches",
        ["detail.properties"] = "Properties",
        ["detail.required"] = "required",
        ["detail.common"] = "Every component also takes: {0}",
        ["apis.search"] = "Search APIs",
        ["detail.code"] = "Code",
        ["detail.readOnly"] = "Read only",
        ["detail.network"] = "Connects to {0}",
        ["detail.noNetwork"] = "Does not use the network",
        ["detail.noUI"] = "This example draws nothing. What it prints is under Output.",
        ["detail.noOutput"] = "Draws nothing and prints nothing.",
        ["templates.search"] = "Search templates",

        ["editor.files"] = "Files",
        ["editor.preview"] = "Preview",
        ["editor.size"] = "Size",
        ["editor.dark"] = "Dark",
        ["editor.parameter"] = "Parameter",
        ["editor.parameter.hint"] = "Value of $getenv(\"widget-param\")",
        ["editor.unsaved"] = "Unsaved changes",
        ["editor.saved"] = "Saved",
        ["editor.saveFailed"] = "Could not save: {0}",
        ["editor.running"] = "Running…",
        ["editor.ok"] = "Ran in {0} ms",
        ["editor.logs"] = "Output",
        ["editor.noLogs"] = "console.log output appears here.",
        ["editor.binary"] = "This file is not text and cannot be edited here.",
        ["editor.failed"] = "The code editor could not start: {0}",
        ["editor.discard.title"] = "Discard unsaved changes?",
        ["editor.discard.detail"] = "Your changes to this file have not been saved.",
        ["editor.discard.confirm"] = "Discard",
        ["editor.newFile.title"] = "New file",
        ["editor.newFile.hint"] = "For example helper.js or data/items.json",

        ["size.small"] = "Small",
        ["size.medium"] = "Medium",
        ["size.large"] = "Large",
        ["size.extraLarge"] = "Extra large",

        ["dialog.new.title"] = "New widget",
        ["dialog.new.hint"] = "Name",
        ["dialog.new.default"] = "My Widget",
        ["dialog.rename.title"] = "Rename widget",
        ["dialog.delete.title"] = "Delete “{0}”?",
        ["dialog.delete.detail"] = "The widget and its files are removed from this computer. Widgets of it on the desktop are removed too.",
        ["dialog.import.title"] = "Import this widget?",
        ["dialog.import.detail"] = "“{0}” will be added to your widgets. Widget code can fetch data from the Internet hosts it declares. Only import widgets from people you trust.",
        ["dialog.import.confirm"] = "Import",
        ["dialog.error.title"] = "That did not work",

        ["toast.added"] = "Added to the desktop",
        ["toast.copied"] = "Code copied",
        ["toast.exported"] = "Exported to {0}",
        ["toast.hostMissing"] = "The desktop host is not running, so the widget could not be placed.",

        ["settings.title"] = "Settings",
        ["settings.refresh"] = "Refresh interval",
        ["settings.refresh.detail"] = "How often widgets without a schedule of their own run again.",
        ["settings.minutes"] = "{0} minutes",
        ["settings.hours"] = "{0} hours",
        ["settings.hour"] = "1 hour",
        ["settings.lock"] = "Lock positions",
        ["settings.lock.detail"] = "Widgets cannot be dragged while this is on.",
        ["settings.pause"] = "Pause for full-screen programs",
        ["settings.pause.detail"] = "Hold refreshes while a game or a presentation is in front.",
        ["settings.startup"] = "Start when I sign in",
        ["settings.startup.detail"] = "Show your widgets as soon as Windows starts.",
        ["settings.data"] = "Data folder",
        ["settings.data.detail"] = "Your widgets, their saved values and the log.",
        ["settings.about"] = "About",
        ["settings.version"] = "ScriptWidget for Windows {0} (preview)",
        ["settings.website"] = "Website",
        ["settings.docs"] = "Documentation",
    };

    public static string T(string key) => Text.TryGetValue(key, out var value) ? value : key;

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
