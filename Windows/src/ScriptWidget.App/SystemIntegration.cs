using System.Diagnostics;
using System.Runtime.InteropServices;
using ScriptWidget.App.Interop;
using ScriptWidget.App.Windowing;

namespace ScriptWidget.App;

/// <summary>Opens links a widget asks for. Package content is untrusted, so only a few schemes are handed to Windows.</summary>
internal static unsafe class Links
{
    /// <summary>
    /// Schemes that open a browser or a mail program. Everything else is
    /// refused: a file path or a <c>file:</c> URL would run programs, and
    /// many registered protocol handlers were never meant to take input from
    /// untrusted content.
    /// </summary>
    private static readonly HashSet<string> Allowed = new(StringComparer.OrdinalIgnoreCase) { "http", "https", "mailto" };

    /// <summary>Opens the link, or returns false when it is not one a widget may open.</summary>
    public static bool Open(string? url, Action<Uri>? openInApp = null)
    {
        if (string.IsNullOrWhiteSpace(url) || url.Length > 4096) return false;
        if (!Uri.TryCreate(url.Trim(), UriKind.Absolute, out var uri)) return false;
        if (uri.Scheme.Equals("scriptwidget", StringComparison.OrdinalIgnoreCase)) { openInApp?.Invoke(uri); return openInApp is not null; }
        if (!Allowed.Contains(uri.Scheme)) return false;
        if (uri.Scheme is "http" or "https" && string.IsNullOrEmpty(uri.Host)) return false;
        // The canonical form of the parsed URL, never the raw text.
        var target = uri.AbsoluteUri;
        fixed (char* operation = "open")
        fixed (char* file = target)
            return Win32.ShellExecuteW(0, operation, file, null, null, Win32.SW_SHOWNORMAL) > 32;
    }
}

/// <summary>Starting the host when the user signs in.</summary>
internal static class Startup
{
    public static bool IsPackaged => ScriptWidget.Core.Hosting.StartupRegistration.IsPackaged;
    public static bool IsEnabled() => ScriptWidget.Core.Hosting.StartupRegistration.IsEnabled();
    public static void SetEnabled(bool enabled) => ScriptWidget.Core.Hosting.StartupRegistration.SetEnabled(enabled, Environment.ProcessPath);
}

/// <summary>Starts the management window program.</summary>
internal static class Studio
{
    public static string? Path()
    {
        var directory = AppContext.BaseDirectory;
        foreach (var candidate in new[]
        {
            System.IO.Path.Combine(directory, "ScriptWidgetStudio.exe"),
            System.IO.Path.Combine(directory, "Studio", "ScriptWidgetStudio.exe"),
            Environment.GetEnvironmentVariable("SCRIPTWIDGET_STUDIO") ?? "",
        })
        {
            if (candidate.Length > 0 && File.Exists(candidate)) return candidate;
        }
        return null;
    }

    /// <summary>Opens the management window, optionally on a package.</summary>
    public static void Open(string? packageName = null)
    {
        if (Path() is not { } executable) { Log.Write("management window program not found"); return; }
        try
        {
            var start = new ProcessStartInfo(executable) { UseShellExecute = false };
            if (packageName is not null) { start.ArgumentList.Add("--open"); start.ArgumentList.Add(packageName); }
            Process.Start(start)?.Dispose();
        }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException) { Log.Write($"management window: {error.Message}"); }
    }
}
