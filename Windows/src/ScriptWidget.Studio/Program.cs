using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;
using ScriptWidget.Studio.Services;

namespace ScriptWidget.Studio;

public static class Program
{
    [STAThread]
    private static void Main(string[] arguments)
    {
        // The editor's browser profile must be in a folder the program can write to, also when installed from the Store.
        Environment.SetEnvironmentVariable("WEBVIEW2_USER_DATA_FOLDER", Path.Combine(AppServices.Paths.Cache, "WebView2"));
        WinRT.ComWrappersSupport.InitializeComWrappers();

        // One management window: a second start hands its request to the first and exits.
        var instance = AppInstance.FindOrRegisterForKey("ScriptWidgetStudio");
        if (!instance.IsCurrent)
        {
            instance.RedirectActivationToAsync(AppInstance.GetCurrent().GetActivatedEventArgs()).AsTask().Wait(5000);
            return;
        }
        Application.Start(parameters =>
        {
            SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            var app = new App(Request.From(AppInstance.GetCurrent().GetActivatedEventArgs(), arguments));
            instance.Activated += (_, activation) => app.OnRedirected(Request.From(activation, null));
        });
    }
}

/// <summary>What a start of the program asked for: nothing, a package to edit, or an archive to import.</summary>
public sealed record Request(string? OpenPackage, string? ImportFile)
{
    /// <summary>Development aid: save a picture of the window to this file after it loaded, then exit.</summary>
    public string? Screenshot { get; init; }
    /// <summary>Page to show for <see cref="Screenshot"/>: library, templates or settings.</summary>
    public string? Page { get; init; }

    public static Request From(AppActivationArguments activation, string[]? commandLine)
    {
        if (activation.Kind == ExtendedActivationKind.File && activation.Data is Windows.ApplicationModel.Activation.IFileActivatedEventArgs files && files.Files.Count > 0)
            return new Request(null, files.Files[0].Path);
        var arguments = commandLine ?? (activation.Data is Windows.ApplicationModel.Activation.ILaunchActivatedEventArgs launch ? Split(launch.Arguments) : []);
        string? screenshot = null, page = null;
        for (var index = 0; index + 1 < arguments.Length; index++)
        {
            if (arguments[index] == "--screenshot") screenshot = Path.GetFullPath(arguments[index + 1]);
            if (arguments[index] == "--page") page = arguments[index + 1];
        }
        for (var index = 0; index < arguments.Length; index++)
        {
            if (arguments[index] == "--open" && index + 1 < arguments.Length) return new Request(arguments[index + 1], null) { Screenshot = screenshot, Page = page };
            if (arguments[index].EndsWith(".swt", StringComparison.OrdinalIgnoreCase) && File.Exists(arguments[index])) return new Request(null, Path.GetFullPath(arguments[index]));
        }
        return new Request(null, null) { Screenshot = screenshot, Page = page };
    }

    /// <summary>Splits a command line on spaces, keeping quoted parts together. The program name, when present, is dropped by the caller's search.</summary>
    private static string[] Split(string commandLine)
    {
        var result = new List<string>();
        var current = new System.Text.StringBuilder();
        var quoted = false;
        foreach (var character in commandLine)
        {
            if (character == '"') { quoted = !quoted; continue; }
            if (character == ' ' && !quoted) { if (current.Length > 0) { result.Add(current.ToString()); current.Clear(); } continue; }
            current.Append(character);
        }
        if (current.Length > 0) result.Add(current.ToString());
        return [.. result];
    }
}
