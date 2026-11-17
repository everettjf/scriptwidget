using System.Diagnostics;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using ScriptWidget.Core;
using ScriptWidget.Core.Api;
using ScriptWidget.Core.Hosting;
using ScriptWidget.Core.Render;
using ScriptWidget.Core.Runtime;

namespace ScriptWidget.Studio.Services;

/// <summary>The objects every page of the management window shares.</summary>
public static class AppServices
{
    public static DataPaths Paths { get; } = new();
    public static Library Library { get; } = new(Paths);
    public static HostSettings Settings { get; } = new(Paths.Settings);
    private static readonly Lazy<WidgetRuntime> LazyRuntime = new(() => new WidgetRuntime(Paths));
    /// <summary>Scripts and rendering run one at a time on this thread, never on the UI thread.</summary>
    private static readonly SemaphoreSlim RuntimeGate = new(1, 1);

    /// <summary>Runs work that uses the runtime on a background thread, one piece at a time.</summary>
    public static async Task<T> WithRuntime<T>(Func<WidgetRuntime, T> work)
    {
        await RuntimeGate.WaitAsync();
        try { return await Task.Run(() => work(LazyRuntime.Value)); }
        finally { RuntimeGate.Release(); }
    }

    /// <summary>Checks an imported package the way an installation would; throws when it is invalid.</summary>
    public static void ValidatePackage(IPackageFiles files)
    {
        try { LazyRuntime.Value.ValidatePackage(files); }
        catch (RuntimeError error) { throw new ScriptWidget.Core.Packages.PackageException(ScriptWidget.Core.Packages.PackageErrors.InvalidManifest, error.Message); }
    }

    public static string Version => typeof(AppServices).Assembly.GetName().Version is { } version ? $"{version.Major}.{version.Minor}.{version.Build}" : "";
}

/// <summary>Talks to the desktop host, starting it when it is not running.</summary>
public static class DesktopHost
{
    private static string? Executable()
    {
        var directory = AppContext.BaseDirectory;
        foreach (var candidate in new[]
        {
            Path.Combine(directory, "ScriptWidget.exe"),
            Path.Combine(directory, "..", "ScriptWidget.exe"),
            Environment.GetEnvironmentVariable("SCRIPTWIDGET_HOST") ?? "",
        })
        {
            if (candidate.Length > 0 && File.Exists(candidate)) return Path.GetFullPath(candidate);
        }
        return null;
    }

    /// <summary>Starts the host when no host answers. Returns true when one is running afterwards.</summary>
    public static async Task<bool> EnsureRunningAsync()
    {
        if (await Task.Run(HostPipe.IsHostRunning)) return true;
        if (Executable() is not { } executable) return false;
        try
        {
            var start = new ProcessStartInfo(executable) { UseShellExecute = false };
            start.ArgumentList.Add("--startup");
            Process.Start(start)?.Dispose();
        }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException) { return false; }
        for (var attempt = 0; attempt < 30; attempt++)
        {
            await Task.Delay(200);
            if (await Task.Run(HostPipe.IsHostRunning)) return true;
        }
        return false;
    }

    public static Task<JsonObject?> SendAsync(JsonObject request) => Task.Run(() => HostPipe.Send(request));

    /// <summary>Tells the host that packages were added, edited, renamed or deleted.</summary>
    public static void LibraryChanged() => _ = SendAsync(new JsonObject { ["command"] = "library-changed" });

    public static void SettingsChanged() => _ = SendAsync(new JsonObject { ["command"] = "settings-changed" });

    /// <summary>Puts a package on the desktop. Returns false when the host could not be reached or refused.</summary>
    public static async Task<bool> AddWidgetAsync(string installation, string family)
    {
        if (!await EnsureRunningAsync()) return false;
        var response = await SendAsync(new JsonObject { ["command"] = "add", ["package"] = installation, ["family"] = family });
        return response is not null && response.OptBoolean("ok");
    }

    /// <summary>How many desktop widgets show each installed package, by installation identifier.</summary>
    public static async Task<IReadOnlyDictionary<string, int>> WidgetCountsAsync()
    {
        var counts = new Dictionary<string, int>();
        var response = await SendAsync(new JsonObject { ["command"] = "list" });
        foreach (var item in response.OptArray("widgets") ?? new JsonArray())
        {
            var package = (item as JsonObject).OptString("package");
            if (package.Length > 0) counts[package] = counts.GetValueOrDefault(package) + 1;
        }
        return counts;
    }
}

/// <summary>What one preview run produced.</summary>
public sealed record PreviewResult(ImageSource? Image, double Width, double Height, ExecutionResult Execution);

/// <summary>Runs a package and draws it with the renderer the desktop host uses.</summary>
public static class Preview
{
    /// <param name="scale">Pixels per point of the display the preview is shown on.</param>
    public static async Task<PreviewResult> RenderAsync(IPackageFiles files, string packageID, string family, bool dark, string parameter, double scale, string? buildDirectory = null)
    {
        var (width, height) = WidgetFamilies.Size(family);
        var (output, execution) = await AppServices.WithRuntime(runtime =>
        {
            var request = new RunRequest { Files = files, PackageID = packageID, Family = family, Parameter = parameter, DarkMode = dark, BuildDirectory = buildDirectory };
            var result = runtime.Run(request);
            return (runtime.Render(request, result, (float)width, (float)height, (float)Math.Clamp(scale, 1, 4)), result.Execution);
        });
        return new PreviewResult(ToImage(output), width, height, execution);
    }

    /// <summary>Must be called on the UI thread.</summary>
    private static ImageSource? ToImage(RenderOutput output)
    {
        if (output.PixelWidth <= 0 || output.PixelHeight <= 0) return null;
        var bitmap = new WriteableBitmap(output.PixelWidth, output.PixelHeight);
        using (var stream = bitmap.PixelBuffer.AsStream()) stream.Write(output.Pixels, 0, output.PixelWidth * output.PixelHeight * 4);
        bitmap.Invalidate();
        return bitmap;
    }

    public static bool SystemIsDark => DeviceInfo.IsDarkMode();
}
