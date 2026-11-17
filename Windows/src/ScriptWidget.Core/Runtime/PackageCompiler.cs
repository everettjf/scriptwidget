using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using ScriptWidget.Core.Js;

namespace ScriptWidget.Core.Runtime;

public sealed class RuntimeError(string kind, string message) : Exception(message)
{
    public string Kind { get; } = kind;
}

/// <summary>Output of preparing a package: transpiled entry, transpiled imports and the validated manifest.</summary>
public sealed class PreparedPackage
{
    public required string Code { get; init; }
    public IReadOnlyDictionary<string, string> Imports { get; init; } = new Dictionary<string, string>();
    public JsonObject? Manifest { get; init; }
    public bool HasManifest { get; init; }
    public string? ActionID { get; init; }
    public IReadOnlyDictionary<string, string> TimelineEnvironment { get; init; } = new Dictionary<string, string>();

    public JsonObject ToJson() => new()
    {
        ["code"] = Code,
        ["imports"] = Json.Object(Imports),
        ["manifest"] = Manifest?.DeepClone(),
        ["hasManifest"] = HasManifest,
        ["actionID"] = ActionID,
        ["timelineEnvironment"] = Json.Object(TimelineEnvironment),
    };

    public static PreparedPackage FromJson(JsonObject json)
    {
        var imports = new Dictionary<string, string>();
        if (json.OptObject("imports") is { } map) foreach (var (key, value) in map) imports[key] = value?.AsText() ?? "";
        var environment = new Dictionary<string, string>();
        if (json.OptObject("timelineEnvironment") is { } values) foreach (var (key, value) in values) environment[key] = value?.AsText() ?? "";
        return new PreparedPackage
        {
            Code = json.OptStringOrNull("code") ?? throw new RuntimeError("internalError", "Compiler returned no code"),
            Imports = imports,
            Manifest = json.OptObject("manifest")?.DeepClone() as JsonObject,
            HasManifest = json.OptBoolean("hasManifest"),
            ActionID = json.IsNull("actionID") ? null : json.OptString("actionID"),
            TimelineEnvironment = environment,
        };
    }
}

/// <summary>
/// Validates manifests and transpiles JSX with the same Babel bundle and
/// prepare code as the web preview engine. The Babel context is expensive, so
/// it lives on one dedicated thread and is released after a period of disuse.
/// Package code never executes in this context.
/// </summary>
public sealed partial class PackageCompiler : IDisposable
{
    private const int IdleSeconds = 45;
    private const long CompileTimeoutMilliseconds = 30_000;

    private readonly SharedScripts scripts;
    private readonly JsWorker worker = new("scriptwidget-compiler", 16 * 1024 * 1024);
    private readonly Timer release;
    private QuickJs? engine;

    public PackageCompiler(SharedScripts scripts)
    {
        this.scripts = scripts;
        release = new Timer(_ => worker.Post(() => { engine?.Dispose(); engine = null; }), null, Timeout.Infinite, Timeout.Infinite);
    }

    private T OnCompilerThread<T>(Func<QuickJs, T> block) => worker.Run(() =>
    {
        release.Change(Timeout.Infinite, Timeout.Infinite);
        var current = engine ??= CreateEngine();
        try { return block(current); }
        finally
        {
            current.SetDeadline(0);
            release.Change(TimeSpan.FromSeconds(IdleSeconds), Timeout.InfiniteTimeSpan);
        }
    });

    private QuickJs CreateEngine()
    {
        var created = new QuickJs((operation, payload) => operation == "url.parse" ? ParseURL(payload ?? "") : IntlBridge.Call(operation, payload), memoryLimitBytes: 384L * 1024 * 1024, stackBytes: 12L * 1024 * 1024);
        try
        {
            // The prelude captures the native entry point before the host file removes it.
            created.Evaluate(CompilerPrelude, "compiler-prelude.js");
            created.Evaluate(scripts.Text("host.js"), "host.js");
            foreach (var name in new[] { "core.js", "prepare.js", "compiler.js" }) created.Evaluate(scripts.Text(name), name);
        }
        catch
        {
            created.Dispose();
            throw;
        }
        return created;
    }

    /// <summary>Validates and transpiles a package. Throws <see cref="RuntimeError"/> with the engine's error kind.</summary>
    public PreparedPackage Prepare(IPackageFiles files, string? entry = null, string prelude = "", string? actionID = null, string? callFunction = null)
    {
        var text = new JsonObject();
        var binaries = new JsonArray();
        foreach (var path in files.Paths())
        {
            var content = IsTextFile(path) ? files.ReadText(path) : null;
            if (content is not null) text[path] = content; else binaries.Append(path);
        }
        var job = new JsonObject { ["files"] = text, ["binaries"] = binaries, ["prelude"] = prelude };
        if (entry is not null) job["entry"] = entry;
        if (actionID is not null) job["actionID"] = actionID;
        if (callFunction is not null) job["callFunction"] = callFunction;
        var jobText = Json.Stringify(job);
        string? output;
        try
        {
            output = OnCompilerThread(current => { current.SetDeadline(CompileTimeoutMilliseconds); return current.Call("__swPrepare", jobText); });
        }
        catch (JsException error)
        {
            throw new RuntimeError(error.Interrupted ? "resourceLimit" : "internalError", string.IsNullOrEmpty(error.Message) ? "Compiler failed" : error.Message);
        }
        var prepared = Json.ParseObject(output ?? throw new RuntimeError("internalError", "Compiler returned nothing"));
        if (!prepared.OptBoolean("ok"))
        {
            var error = prepared.OptObject("error");
            throw new RuntimeError(error?.OptStringOrNull("kind") ?? "internalError", error?.OptStringOrNull("message") ?? "Package could not be prepared");
        }
        return PreparedPackage.FromJson(prepared);
    }

    /// <summary>Returns {ok, manifest?, error?, issues[]} from the shared manifest validator.</summary>
    public JsonObject ValidateManifest(string manifestText, IEnumerable<string> paths)
    {
        var pathsText = Json.Stringify(Json.Array(paths));
        return Json.ParseObject(OnCompilerThread(current => { current.SetDeadline(CompileTimeoutMilliseconds); return current.Call("__swValidateManifest", manifestText, pathsText); })!);
    }

    /// <summary>Timeline plan for a <c>timeline</c> manifest object: {entries:[{date, environments}], reloadDate}.</summary>
    public JsonObject TimelinePlan(JsonObject schedule, long nowMilliseconds, string systemTimeZone)
    {
        var scheduleText = Json.Stringify(schedule);
        return Json.ParseObject(OnCompilerThread(current => { current.SetDeadline(CompileTimeoutMilliseconds); return current.Call("__swTimeline", scheduleText, nowMilliseconds.ToString(System.Globalization.CultureInfo.InvariantCulture), systemTimeZone); })!);
    }

    /// <summary>WHATWG-style components for the absolute URLs the manifest validator inspects, or null.</summary>
    internal static string? ParseURL(string text)
    {
        if (!Uri.TryCreate(text.Trim(), UriKind.Absolute, out var uri)) return null;
        var scheme = uri.Scheme.ToLowerInvariant();
        if (string.IsNullOrEmpty(uri.Host) || scheme is "mailto" or "urn" or "data" or "javascript" or "file") return null;
        var userInfo = uri.UserInfo;
        var separator = userInfo.IndexOf(':');
        return Json.Stringify(new JsonObject
        {
            ["href"] = uri.OriginalString.Trim(),
            ["protocol"] = scheme + ":",
            ["hostname"] = uri.Host.ToLowerInvariant().TrimStart('[').TrimEnd(']'),
            ["port"] = uri.IsDefaultPort ? "" : uri.Port.ToString(System.Globalization.CultureInfo.InvariantCulture),
            ["pathname"] = string.IsNullOrEmpty(uri.AbsolutePath) ? "/" : uri.AbsolutePath,
            ["search"] = uri.Query,
            ["hash"] = uri.Fragment,
            ["username"] = separator < 0 ? userInfo : userInfo[..separator],
            ["password"] = separator < 0 ? "" : userInfo[(separator + 1)..],
        });
    }

    public void Dispose()
    {
        release.Dispose();
        worker.Post(() => { engine?.Dispose(); engine = null; });
        worker.Dispose();
    }

    /// <summary>
    /// Globals the trusted compiler code expects. JavaScriptCore contexts have
    /// a console object, and the shared manifest validator measures UTF-8
    /// lengths with TextEncoder. Package code never runs here.
    /// </summary>
    private const string CompilerPrelude = """
        globalThis.console = { log() {}, info() {}, warn() {}, error() {}, debug() {}, trace() {} };
        {
          const native = globalThis.__swNative;
          globalThis.URL = class URL {
            constructor(text) {
              const parsed = native("url.parse", String(text));
              if (parsed === null) throw new TypeError("Invalid URL");
              Object.assign(this, JSON.parse(parsed));
            }
            toString() { return this.href; }
          };
        }
        globalThis.TextEncoder = class TextEncoder {
          encode(text) {
            const bytes = [];
            for (const character of String(text ?? "")) {
              const code = character.codePointAt(0);
              if (code < 0x80) bytes.push(code);
              else if (code < 0x800) bytes.push(0xc0 | (code >> 6), 0x80 | (code & 63));
              else if (code < 0x10000) {
                const safe = code >= 0xd800 && code <= 0xdfff ? 0xfffd : code;
                bytes.push(0xe0 | (safe >> 12), 0x80 | ((safe >> 6) & 63), 0x80 | (safe & 63));
              } else bytes.push(0xf0 | (code >> 18), 0x80 | ((code >> 12) & 63), 0x80 | ((code >> 6) & 63), 0x80 | (code & 63));
            }
            return new Uint8Array(bytes);
          }
        };
        """;

    [GeneratedRegex(@"\.(jsx?|mjs|json|txt|md|csv|svg|xml|html?|css|ya?ml)$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex TextFile();

    public static bool IsTextFile(string path) => TextFile().IsMatch(path);
}
