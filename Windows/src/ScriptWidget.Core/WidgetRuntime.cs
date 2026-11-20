using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using ScriptWidget.Core.Api;
using ScriptWidget.Core.Hosting;
using ScriptWidget.Core.Plugins;
using ScriptWidget.Core.Render;
using ScriptWidget.Core.Runtime;

namespace ScriptWidget.Core;

/// <summary>Everything needed to run one package once.</summary>
public sealed class RunRequest
{
    public required IPackageFiles Files { get; init; }
    /// <summary>Stable identity of the installed package; namespaces storage and caches.</summary>
    public required string PackageID { get; init; }
    public string Family { get; init; } = "medium";
    public string Parameter { get; init; } = "";
    public bool DarkMode { get; init; }
    /// <summary>Declared action to run (<c>actions[].id</c>), or null to render.</summary>
    public string? ActionID { get; init; }
    /// <summary>Legacy <c>onClick="name"</c> function to call after the entry.</summary>
    public string? CallFunction { get; init; }
    public IReadOnlyDictionary<string, string> ExtraEnvironments { get; init; } = new Dictionary<string, string>();
    /// <summary>Directory for the compiled-artifact cache; null disables caching.</summary>
    public string? BuildDirectory { get; init; }
}

public sealed class RunResult(ExecutionResult execution, PreparedPackage? prepared, ExecutionRequest? request, long? nextTimelineTransition = null)
{
    public ExecutionResult Execution { get; } = execution;
    public PreparedPackage? Prepared { get; } = prepared;
    public ExecutionRequest? Request { get; } = request;
    /// <summary>When the package's daily schedule next changes slot; the host should run the package again then.</summary>
    public long? NextTimelineTransition { get; } = nextTimelineTransition;
    /// <summary>True when the script's output may depend on the light/dark theme it ran under.</summary>
    public bool DependsOnAppearance => Request?.Session.ReadAppearance == true;
}

/// <summary>
/// The Windows runtime: compiles a package, executes it, and renders its
/// tree. One instance per process; all methods are safe to call from any
/// background thread.
/// </summary>
public sealed class WidgetRuntime : IDisposable
{
    private const int MaximumCachedArtifacts = 6;
    private const int MaximumRemoteImages = 8;
    private const long ImageBudgetMilliseconds = 6000;
    private const long ImageCacheMilliseconds = 15 * 60 * 1000;

    private readonly IReadOnlyList<INativeModule> modules;
    private readonly string imageCache;

    public SharedScripts Scripts { get; }
    public PackageCompiler Compiler { get; }
    public ScriptExecutor Executor { get; }
    public WidgetRenderer Renderer { get; }
    public TimelinePlanner Timeline { get; }
    public StorageModule Storage { get; }
    public FetchModule Fetch { get; }
    public PluginStore Plugins { get; }

    public WidgetRuntime(DataPaths paths, IEnumerable<INativeModule>? extraModules = null, string? assetsDirectory = null)
    {
        Scripts = new SharedScripts(assetsDirectory);
        Compiler = new PackageCompiler(Scripts);
        Executor = new ScriptExecutor(Scripts);
        Renderer = new WidgetRenderer(Scripts);
        Timeline = new TimelinePlanner(Scripts);
        Storage = new StorageModule(paths.Storage);
        Fetch = new FetchModule();
        Plugins = new PluginStore(paths.Plugins);
        var version = typeof(WidgetRuntime).Assembly.GetName().Version;
        var weather = new WeatherModule(new FetchWeatherTransport(Fetch), Path.Combine(paths.Cache, "weather"), WeatherModule.UserAgent(version is null ? "" : $"{version.Major}.{version.Minor}.{version.Build}"));
        modules = [Storage, Fetch, new DataSourceModule(Plugins), weather, .. extraModules ?? []];
        imageCache = Path.Combine(paths.Cache, "remote-images");
    }

    /// <summary>Compiles a package, reusing the cached artifact when no source changed.</summary>
    public PreparedPackage Prepare(RunRequest request)
    {
        var cacheFile = request.BuildDirectory is null ? null : Path.Combine(request.BuildDirectory, $"prepared-{CacheKey(request)}.json");
        if (cacheFile is not null && File.Exists(cacheFile))
        {
            try { return PreparedPackage.FromJson(Json.ParseObject(File.ReadAllText(cacheFile, Encoding.UTF8))); }
            catch (Exception error) when (error is JsonException or IOException or UnauthorizedAccessException or RuntimeError) { }
        }
        var prepared = Compiler.Prepare(request.Files, actionID: request.ActionID, callFunction: request.CallFunction);
        if (cacheFile is not null)
        {
            try
            {
                var directory = new DirectoryInfo(request.BuildDirectory!);
                directory.Create();
                // Keep the cache small: one artifact per (source, action) pair, older ones removed.
                foreach (var old in directory.EnumerateFiles("prepared-*.json").OrderByDescending(file => file.LastWriteTimeUtc).Skip(MaximumCachedArtifacts - 1)) old.Delete();
                var temporary = cacheFile + ".tmp";
                File.WriteAllText(temporary, Json.Stringify(prepared.ToJson()), new UTF8Encoding(false));
                File.Move(temporary, cacheFile, overwrite: true);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
        return prepared;
    }

    private string CacheKey(RunRequest request)
    {
        using var digest = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        void Add(string text) { digest.AppendData(Encoding.UTF8.GetBytes(text)); digest.AppendData([0]); }
        digest.AppendData(Encoding.UTF8.GetBytes(Scripts.Contract.OptString("compilerFingerprint")));
        Add(request.ActionID ?? "");
        Add(request.CallFunction ?? "");
        foreach (var path in request.Files.Paths())
        {
            Add(path);
            Add(PackageCompiler.IsTextFile(path) ? request.Files.ReadText(path) ?? "" : "");
        }
        return Convert.ToHexStringLower(digest.GetHashAndReset())[..32];
    }

    /// <summary>Compiles the package the way an installation would; throws <see cref="RuntimeError"/> when it is invalid.</summary>
    public void ValidatePackage(IPackageFiles files) => Compiler.Prepare(files);

    /// <summary>Compiles and executes. Compile failures are returned as an execution error, never thrown.</summary>
    public RunResult Run(RunRequest request)
    {
        PreparedPackage prepared;
        try { prepared = Prepare(request); }
        catch (RuntimeError error)
        {
            return new RunResult(new ExecutionResult { Error = new ExecutionError(error.Kind, error.Message) }, null, null);
        }
        var environments = new Dictionary<string, string>
        {
            ["widget-size"] = request.Family,
            ["widget-param"] = request.Parameter,
            ["widget-rendering-mode"] = "fullColor",
        };
        // The cached artifact carries the slot of the moment it was compiled; use the slot of now.
        var schedule = Timeline.State(prepared.Manifest);
        if (schedule is not null) foreach (var (key, value) in schedule.Environments) environments[key] = value;
        foreach (var (key, value) in request.ExtraEnvironments) environments[key] = value;
        var execution = new ExecutionRequest
        {
            Prepared = prepared,
            Files = request.Files,
            Environments = environments,
            DarkMode = request.DarkMode,
            Device = DeviceInfo.Device(),
            System = DeviceInfo.System(),
            Modules = modules,
            PackageID = request.PackageID,
        };
        return new RunResult(Executor.Execute(execution), prepared, execution, schedule?.NextTransitionMilliseconds);
    }

    /// <summary>
    /// Renders the result of <see cref="Run"/>. Errors become a visible card so
    /// a widget is never blank. Remote images are fetched first, under the
    /// same network policy as <c>fetch</c>.
    /// </summary>
    /// <param name="width">Width in points.</param>
    /// <param name="density">Pixels per point of the display the widget is on.</param>
    /// <param name="cornerRadius">Corner radius in points; 0 leaves the widget square.</param>
    public RenderOutput Render(RunRequest request, RunResult result, float width, float height, float density, bool? darkMode = null, long? nowMilliseconds = null, long maximumBitmapBytes = long.MaxValue, float cornerRadius = RoundedCorners.DefaultRadius, bool liveAnimation = false)
    {
        var output = RenderSquare(request, result, width, height, density, darkMode, nowMilliseconds, maximumBitmapBytes, liveAnimation);
        RoundedCorners.Apply(output.Pixels, output.PixelWidth, output.PixelHeight, cornerRadius * output.Scale);
        return output;
    }

    private RenderOutput RenderSquare(RunRequest request, RunResult result, float width, float height, float density, bool? darkMode, long? nowMilliseconds, long maximumBitmapBytes, bool liveAnimation)
    {
        var dark = darkMode ?? request.DarkMode;
        var tree = result.Execution.Tree ?? ErrorTree(result.Execution.Error);
        var remote = result.Execution.Tree is not null && result.Request is not null ? FetchRemoteImages(tree, result.Request) : new Dictionary<string, string>();
        try
        {
            return Renderer.Render(new RenderRequest
            {
                Tree = tree, Width = width, Height = height, Density = density, Family = request.Family, DarkMode = dark,
                Files = request.Files, RemoteImages = remote, NowMilliseconds = nowMilliseconds, MaximumBitmapBytes = maximumBitmapBytes,
                DesktopAnimation = liveAnimation,
            });
        }
        catch (Exception error) when (error is not OutOfMemoryException)
        {
            return Renderer.Render(new RenderRequest
            {
                Tree = ErrorTree(new ExecutionError("internalError", string.IsNullOrEmpty(error.Message) ? "Rendering failed" : error.Message)),
                Width = width, Height = height, Density = density, Family = request.Family, DarkMode = dark, MaximumBitmapBytes = maximumBitmapBytes,
            });
        }
    }

    /// <summary>Renders a canonical tree that is not the output of a package, such as a message card.</summary>
    public RenderOutput RenderTree(string tree, string family, float width, float height, float density, bool darkMode, float cornerRadius = RoundedCorners.DefaultRadius)
    {
        var output = Renderer.Render(new RenderRequest { Tree = tree, Width = width, Height = height, Density = density, Family = family, DarkMode = darkMode });
        RoundedCorners.Apply(output.Pixels, output.PixelWidth, output.PixelHeight, cornerRadius * output.Scale);
        return output;
    }

    /// <summary>A canonical tree that explains <paramref name="error"/> with its category and recovery hint.</summary>
    public string ErrorTree(ExecutionError? error)
    {
        var kind = error?.Kind ?? "internalError";
        var category = Scripts.ErrorCategories.OptObject(kind) ?? Scripts.ErrorCategories.OptObject("internalError");
        var title = category?.OptStringOrNull("category") ?? "Internal";
        var recovery = category.OptString("recovery");
        var message = error?.Message ?? "Unknown error";
        if (message.Length > 400) message = message[..400];
        // Fixed colors: the card keeps its light background in dark mode.
        return MessageTree(
            ($"{title} error", """{"color":"#b91c1c","font":"caption","fontWeight":"bold"}"""),
            (message, """{"color":"#1f2937","font":"caption"}"""),
            (recovery, """{"color":"#6b7280","font":"caption2"}"""));
    }

    /// <summary>A card with a title and a line of explanation, for widgets that have nothing to run.</summary>
    public static string NoticeTree(string title, string detail) => MessageTree(
        (title, """{"color":"#1f2937","font":"caption","fontWeight":"bold"}"""),
        (detail, """{"color":"#6b7280","font":"caption2"}"""));

    private static string MessageTree(params (string Text, string Props)[] lines)
    {
        var children = string.Join(",", lines.Select(line => $$"""{"$element":"text","props":{{line.Props}},"children":[{{Json.Quote(line.Text)}}]}"""));
        return $$"""{"$element":"vstack","props":{"alignment":"leading","background":"#fef2f2","frame":"max,topLeading","padding":"12","spacing":4},"children":[{{children}}]}""";
    }

    /// <summary>Downloads http(s) <c>&lt;image url&gt;</c> sources referenced by the tree, bounded in count, size and time.</summary>
    private Dictionary<string, string> FetchRemoteImages(string tree, ExecutionRequest execution)
    {
        var result = new Dictionary<string, string>();
        if (RuntimePolicy.IsTimelineProjection(execution) || RuntimePolicy.IsLiveActivity(execution)) return result;
        var urls = new List<string>();
        void Visit(JsonNode? node)
        {
            switch (node)
            {
                case JsonObject item:
                    if (item.OptString("$element") == "image")
                    {
                        var props = item.OptObject("props");
                        var url = props.OptString("url") is { Length: > 0 } direct ? direct : props.OptString("src");
                        if (url.Length > 0 && (url.StartsWith("http://", StringComparison.Ordinal) || url.StartsWith("https://", StringComparison.Ordinal)) && !urls.Contains(url)) urls.Add(url);
                    }
                    Visit(item.OptArray("children"));
                    break;
                case JsonArray array:
                    foreach (var child in array) Visit(child);
                    break;
            }
        }
        try { Visit(Json.Parse(tree)); } catch (JsonException) { return result; }
        if (urls.Count == 0) return result;
        try { Directory.CreateDirectory(imageCache); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return result; }
        var deadline = Environment.TickCount64 + ImageBudgetMilliseconds;
        foreach (var url in urls.Take(MaximumRemoteImages))
        {
            if (!Uri.TryCreate(url, UriKind.Absolute, out var uri)) continue;
            if (Fetch.ValidationError(uri) is not null || !RuntimePolicy.PackageAllowsHost(execution, uri.Host)) continue;
            var name = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(execution.PackageID + "\n" + url)));
            var file = Path.Combine(imageCache, name);
            var fresh = File.Exists(file) && (DateTime.UtcNow - File.GetLastWriteTimeUtc(file)).TotalMilliseconds < ImageCacheMilliseconds;
            if (!fresh && Environment.TickCount64 < deadline && execution.Session.AddNetworkRequest() <= FetchModule.MaximumRequests)
            {
                try
                {
                    var response = Fetch.Perform("GET", uri, new Dictionary<string, string>(), null, 4000,
                        next => Fetch.ValidationError(next) is null && RuntimePolicy.PackageAllowsHost(execution, next.Host));
                    if (response.Status is >= 200 and <= 299 && response.Body.Length > 0)
                    {
                        var temporary = file + ".tmp";
                        File.WriteAllBytes(temporary, response.Body);
                        File.Move(temporary, file, overwrite: true);
                    }
                }
                catch (Exception error) when (error is not OutOfMemoryException) { /* a stale copy or the placeholder is shown */ }
            }
            // A stale copy is better than a placeholder when the network is unavailable.
            if (File.Exists(file)) result[url] = file;
        }
        return result;
    }

    public void Dispose()
    {
        Compiler.Dispose();
        Renderer.Dispose();
    }
}
