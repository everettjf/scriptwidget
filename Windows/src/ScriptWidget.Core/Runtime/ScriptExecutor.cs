using System.Collections.Concurrent;
using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.Json.Nodes;
using ScriptWidget.Core.Js;

namespace ScriptWidget.Core.Runtime;

/// <summary>Everything one execution may touch.</summary>
public sealed class ExecutionRequest
{
    public required PreparedPackage Prepared { get; init; }
    public required IPackageFiles Files { get; init; }
    public IReadOnlyDictionary<string, string> Environments { get; init; } = new Dictionary<string, string> { ["widget-size"] = "medium", ["widget-param"] = "" };
    public bool DarkMode { get; init; }
    public JsonObject? Device { get; init; }
    public JsonObject? System { get; init; }
    /// <summary>Preview simulations for the shared kernel; production executions leave this empty.</summary>
    public JsonObject Fixtures { get; init; } = new();
    public IReadOnlyList<INativeModule> Modules { get; init; } = [];
    public long TimeoutMilliseconds { get; init; } = 5000;
    /// <summary>Package identity for storage namespaces and diagnostics.</summary>
    public string PackageID { get; init; } = "";

    /// <summary>Budgets and cancellation shared by every native call of this execution.</summary>
    public ExecutionSession Session { get; } = new();
}

public sealed class ExecutionSession
{
    private int networkRequests;
    private int dataQueries;

    /// <summary>Counts one more network request and returns the new total.</summary>
    public int AddNetworkRequest() => Interlocked.Increment(ref networkRequests);
    public int NetworkRequests => Volatile.Read(ref networkRequests);
    public int AddDataQuery() => Interlocked.Increment(ref dataQueries);
    public int DataQueries => Volatile.Read(ref dataQueries);

    /// <summary>True once the script asked whether dark mode is on: its output may differ between themes.</summary>
    public volatile bool ReadAppearance;
    /// <summary>Set when the execution ended; in-flight native work should stop.</summary>
    public volatile bool Finished;
    /// <summary>Cancelled when the execution ends.</summary>
    public CancellationTokenSource Cancellation { get; } = new();
}

public sealed record ExecutionError(string Kind, string Message);

public sealed record LogEntry(string Level, string Message);

public sealed class ExecutionResult
{
    /// <summary>Canonical tree JSON (see <c>encodeElement</c> in the shared kernel), or null on error.</summary>
    public string? Tree { get; init; }
    public ExecutionError? Error { get; init; }
    public IReadOnlyList<LogEntry> Logs { get; init; } = [];
    public JsonArray Diagnostics { get; init; } = new();
    public long ElapsedMilliseconds { get; init; }
}

/// <summary>Completes an asynchronous native operation. Call exactly once, from any thread.</summary>
public delegate void NativeCompletion(bool ok, string? json);

/// <summary>
/// A group of native operations exposed to package code through the host
/// bridge. Policy (manifest permissions, budgets) is enforced here and in the
/// JavaScript installers, never by trusting package code.
/// </summary>
public interface INativeModule
{
    bool Handles(string operation);
    /// <summary>Script globals this module implements, such as <c>$weather</c>; others report "not supported on Windows".</summary>
    IReadOnlySet<string> Apis => EmptyApis;
    /// <summary>Synchronous operation. Returns JSON text or null.</summary>
    string? Call(ExecutionRequest request, string operation, string? payload) => throw new ArgumentException($"Unsupported operation {operation}");
    /// <summary>Asynchronous operation. Call <paramref name="done"/> exactly once from any thread.</summary>
    void Start(ExecutionRequest request, string operation, JsonObject? payload, NativeCompletion done) => done(false, Json.Quote($"Unsupported operation {operation}"));

    private static readonly IReadOnlySet<string> EmptyApis = new HashSet<string>();
}

/// <summary>Runs one prepared package in a fresh QuickJS context and returns its element tree.</summary>
public sealed class ScriptExecutor(SharedScripts scripts)
{
    private const long InterruptGraceMilliseconds = 400;
    /// <summary>Name the "not supported" messages use for this host.</summary>
    public const string PlatformName = "Windows";

    private sealed record Completion(int ID, bool OK, string? Json);

    public ExecutionResult Execute(ExecutionRequest request)
    {
        var started = Stopwatch.GetTimestamp();
        var result = JsThread.Run(() => Run(request));
        return new ExecutionResult { Tree = result.Tree, Error = result.Error, Logs = result.Logs, Diagnostics = result.Diagnostics, ElapsedMilliseconds = (long)Stopwatch.GetElapsedTime(started).TotalMilliseconds };
    }

    private ExecutionResult Run(ExecutionRequest request)
    {
        using var completions = new BlockingCollection<Completion>();
        var gate = new object();
        var nativeLogs = new List<LogEntry>();
        string? finished = null;
        var cancelled = false;

        string? Host(string operation, string? payload)
        {
            switch (operation)
            {
                case "finish": finished = payload; return null;
                case "package.import": return CompiledImport(request, payload);
                case "package.read": return PackagePaths.Normalize(payload) is { } readPath ? request.Files.ReadText(readPath) : null;
                case "package.exists": return PackagePaths.Normalize(payload) is { } existsPath && request.Files.Exists(existsPath) ? "1" : "0";
                case "support.script": return scripts.SupportScript(payload ?? "");
                case "xml.parse": return XmlBridge.Parse(payload ?? "");
                case "session.appearance": request.Session.ReadAppearance = true; return null;
                case "log.log" or "log.error":
                    if (nativeLogs.Count < 500) nativeLogs.Add(new LogEntry(operation["log.".Length..], payload ?? ""));
                    return null;
                case "async.start":
                {
                    var job = Json.ParseObject(payload!);
                    var id = job.OptInt("id");
                    var name = job.OptString("operation");
                    var module = request.Modules.FirstOrDefault(item => item.Handles(name));
                    if (module is null) completions.Add(new Completion(id, false, Json.Quote($"Unsupported operation {name}")));
                    else
                    {
                        var delivered = false;
                        module.Start(request, name, job.OptObject("payload"), (ok, json) =>
                        {
                            lock (gate)
                            {
                                if (delivered || cancelled) return;
                                delivered = true;
                                completions.Add(new Completion(id, ok, json));
                            }
                        });
                    }
                    return null;
                }
            }
            if (IntlBridge.Handles(operation)) return IntlBridge.Call(operation, payload);
            var handler = request.Modules.FirstOrDefault(item => item.Handles(operation)) ?? throw new ArgumentException($"Unsupported operation {operation}");
            return handler.Call(request, operation, payload);
        }

        var token = "__sw_" + Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(16));
        var deadline = Stopwatch.GetTimestamp() + request.TimeoutMilliseconds * Stopwatch.Frequency / 1000;
        var engine = new QuickJs(Host);
        try
        {
            // The interrupt deadline is a backstop for synchronous loops; the
            // kernel's own timeout reports unresolved asynchronous work first.
            engine.SetDeadline(request.TimeoutMilliseconds + InterruptGraceMilliseconds);
            foreach (var name in scripts.HostFiles) engine.Evaluate(scripts.Text(name), name);
            engine.Evaluate(scripts.Text("kernel.js"), "kernel.js");
            var job = new JsonObject
            {
                ["config"] = Json.Stringify(Configuration(request)),
                ["code"] = request.Prepared.Code,
                ["timeoutMilliseconds"] = request.TimeoutMilliseconds,
                ["supportedAPIs"] = Json.Array(request.Modules.SelectMany(module => module.Apis).Distinct()),
                ["platformName"] = PlatformName,
            };
            engine.Call("__swBoot", token, Json.Stringify(job));

            while (finished is null)
            {
                engine.RunJobs();
                if (finished is not null) break;
                if (engine.Call(token, "pump") == "1") continue;
                var remaining = Stopwatch.GetElapsedTime(Stopwatch.GetTimestamp(), deadline);
                Completion? completion = null;
                if (remaining > TimeSpan.Zero) completions.TryTake(out completion, remaining);
                if (completion is null)
                {
                    engine.Call(token, "timeout");
                    engine.RunJobs();
                    finished ??= Failure("resourceLimit", "Script exceeded the 5-second execution limit");
                }
                else engine.Call(token, "resolve", completion.ID.ToString(System.Globalization.CultureInfo.InvariantCulture), completion.OK ? "1" : "0", completion.Json);
            }
        }
        catch (JsException error)
        {
            finished ??= error.Interrupted ? Failure("resourceLimit", "Script exceeded the 5-second execution limit")
                : error.Message.Contains("out of memory", StringComparison.OrdinalIgnoreCase) ? Failure("resourceLimit", "Script exceeded the runtime memory budget")
                : Failure("internalError", string.IsNullOrEmpty(error.Message) ? "Execution failed" : error.Message);
        }
        finally
        {
            lock (gate) cancelled = true;
            request.Session.Finished = true;
            request.Session.Cancellation.Cancel();
            engine.Dispose();
        }
        return Decode(finished!, nativeLogs);
    }

    private static string? CompiledImport(ExecutionRequest request, string? relativePath)
    {
        if (PackagePaths.Normalize(relativePath) is not { } path) return null;
        if (!request.Files.Exists(path) || request.Files.ReadText(path) is null) return null;
        return request.Prepared.Imports.TryGetValue(path, out var code) ? code : """{"ok":false,"kind":"transformError","message":"Not a script file"}""";
    }

    private JsonObject Configuration(ExecutionRequest request)
    {
        var prepared = request.Prepared;
        var environments = new JsonObject();
        foreach (var (key, value) in prepared.TimelineEnvironment) environments[key] = value;
        foreach (var (key, value) in request.Environments) environments[key] = value;
        if (prepared.ActionID is not null)
        {
            if (!request.Environments.ContainsKey("action-id")) environments["action-id"] = prepared.ActionID;
            environments["widget-size"] = "action";
        }
        request.Environments.TryGetValue("widget-size", out var size);
        var config = new JsonObject
        {
            ["contract"] = scripts.Contract.DeepClone(),
            ["environments"] = environments,
            ["actionID"] = prepared.ActionID,
            ["liveActivityPresentation"] = size is "live-activity" or "dynamic-island",
            ["preview"] = new JsonObject { ["appearance"] = request.DarkMode ? "dark" : "light" },
            ["fixtures"] = request.Fixtures.DeepClone(),
            ["manifest"] = prepared.Manifest?.DeepClone(),
            ["hasManifest"] = prepared.HasManifest,
            ["packageID"] = request.PackageID,
        };
        if (request.Device is not null) config["device"] = request.Device.DeepClone();
        if (request.System is not null) config["system"] = request.System.DeepClone();
        return config;
    }

    private static string Failure(string kind, string message) => Json.Stringify(new JsonObject
    {
        ["tree"] = null,
        ["error"] = new JsonObject { ["kind"] = kind, ["message"] = message },
        ["logs"] = new JsonArray(),
        ["diagnostics"] = new JsonArray(),
    });

    private static ExecutionResult Decode(string resultText, List<LogEntry> nativeLogs)
    {
        var json = Json.ParseObject(resultText);
        var errorJson = json.OptObject("error");
        var error = errorJson is null ? null : new ExecutionError(errorJson.OptString("kind", "internalError"), errorJson.OptString("message"));
        var logs = json.OptArray("logs")?.OfType<JsonObject>().Select(item => new LogEntry(item.OptString("level"), item.OptString("message"))).ToList();
        return new ExecutionResult
        {
            Tree = json.IsNull("tree") ? null : json.OptString("tree"),
            Error = error,
            Logs = logs is { Count: > 0 } ? logs : nativeLogs,
            Diagnostics = (json.OptArray("diagnostics")?.DeepClone() as JsonArray) ?? new JsonArray(),
        };
    }
}
