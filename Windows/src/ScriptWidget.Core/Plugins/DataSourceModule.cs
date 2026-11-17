using System.Text.Json.Nodes;
using ScriptWidget.Core.Api;
using ScriptWidget.Core.Runtime;

namespace ScriptWidget.Core.Plugins;

/// <summary>
/// Performs one HTTP exchange for a plugin request. Production uses <see cref="FetchModule.Perform"/>, which
/// resolves every hop and refuses private addresses; tests inject a fake so they stay offline.
/// <paramref name="allowRedirect"/> must be consulted for every redirect target before it is followed, and
/// work must stop when <paramref name="cancellation"/> is cancelled.
/// </summary>
public delegate FetchModule.Response DataSourceTransport(string method, Uri uri, IReadOnlyDictionary<string, string> headers, byte[]? body, int timeoutMilliseconds, Func<Uri, bool> allowRedirect, CancellationToken cancellation);

/// <summary>
/// The rules of <c>$dataSource.request</c>, as pure functions of the execution and the plugin. Each
/// returns the rejection message (the Swift wording) or null when the rule is satisfied. They are
/// evaluated natively for every request; the JavaScript installer is not a security boundary.
/// </summary>
public static class DataSourcePolicy
{
    public const string SessionEnded = "Execution session is no longer active";
    public const string LiveActivity = "[live_activity_unavailable] Live Activity presentations cannot request service data; update their state from the app";
    public const string Timeline = "[timeline_read_only] Future entries cannot make live service requests";
    public const string NetworkPermission = "Plugin requests require the network permission";
    public const string HttpsOnly = "Data source requests require HTTPS";
    public const string PluginHost = "Plugin request escaped its declared hosts.";
    public const string PackageHost = "Data source host is not declared in widget.json networkDomains.";
    public const string Budget = "Network request budget exceeded";

    /// <summary>
    /// Presentation rules: a finished execution gets nothing; Live Activity presentations and
    /// future timeline entries are rendered ahead of time and must not make live requests.
    /// </summary>
    public static string? PresentationError(ExecutionRequest request)
    {
        if (request.Session.Finished) return SessionEnded;
        if (RuntimePolicy.IsLiveActivity(request)) return LiveActivity;
        if (RuntimePolicy.IsTimelineProjection(request)) return Timeline;
        return null;
    }

    /// <summary>
    /// Declaration rules: the package's validated <c>widget.json</c> must list <paramref name="pluginID"/> in <c>plugins</c>
    /// and hold the <c>network</c> permission. A package without a manifest declares nothing, so it is
    /// refused: installing a plugin never grants a widget anything by itself.
    /// </summary>
    public static string? DeclarationError(ExecutionRequest request, string pluginID)
    {
        var manifest = request.Prepared.HasManifest ? request.Prepared.Manifest : null;
        var plugins = manifest.OptArray("plugins");
        var declared = plugins is not null && plugins.Any(item => item.IsString() && item!.GetValue<string>() == pluginID);
        if (!declared) return $"Plugin {pluginID} is not declared in widget.json";
        return RuntimePolicy.HasPermission(request, "network") ? null : NetworkPermission;
    }

    /// <summary>
    /// Destination rules for the initial URL and for every redirect target: HTTPS only, a public
    /// host name without credentials, a host the plugin declares, and a host the package allows
    /// through <c>network</c> + <c>networkDomains</c>. A plugin therefore never enlarges what the package
    /// may reach, and a package never reaches a host the plugin did not declare.
    /// </summary>
    public static string? DestinationError(ExecutionRequest request, PluginManifest plugin, Uri uri)
    {
        if (!uri.IsAbsoluteUri || uri.Scheme.ToLowerInvariant() != "https") return HttpsOnly;
        if (ValidationError(uri) is { } invalid) return invalid;
        var host = uri.Host.ToLowerInvariant();
        if (!RuntimePolicy.HostMatches(host, plugin.Hosts)) return PluginHost;
        if (!request.Prepared.HasManifest || !RuntimePolicy.PackageAllowsHost(request, host)) return PackageHost;
        return null;
    }

    /// <summary>True when a redirect to <paramref name="uri"/> may be followed; the execution must still be running.</summary>
    public static bool AllowsRedirect(ExecutionRequest request, PluginManifest plugin, Uri uri) =>
        !request.Session.Finished && DestinationError(request, plugin, uri) is null;

    /// <summary>Same textual rule as <c>FetchModule.ValidationError</c>: HTTP(S), a host, no credentials, not local or private.</summary>
    private static string? ValidationError(Uri uri)
    {
        var host = PluginUrl.Unbracket(uri.Host.ToLowerInvariant());
        if (host.Length == 0) return "URL host is required";
        if (uri.UserInfo.Length > 0) return "URL credentials are not allowed";
        return RuntimePolicy.BlockedHostName(host) ? "Local and private network hosts are not allowed" : null;
    }
}

/// <summary>
/// <c>$dataSource.request(pluginID, operationID, parameters)</c>, ported from
/// <c>ScriptWidgetRuntimeDataSource</c>. Handles the asynchronous operation <c>datasource.request</c> with
/// payload <c>{pluginID, operationID, parameters}</c> and resolves with the mapped response.
///
/// Every rule of <see cref="DataSourcePolicy"/> is checked here, in this order, with the Swift error strings:
/// execution still active, not a Live Activity, not a timeline projection, plugin declared in
/// <c>widget.json</c>, <c>network</c> permission, plugin installed and valid, request built only from
/// declared parameters, HTTPS destination inside both the plugin's hosts and the package's
/// <c>networkDomains</c>, and the per-execution network budget shared with <c>fetch</c>. Redirects are
/// re-validated against the same destination rules. Errors never contain response content,
/// header values or parameter values.
/// </summary>
public sealed class DataSourceModule : INativeModule
{
    public const string Operation = "datasource.request";
    /// <summary>The Swift fetch session's per-request timeout (5 s); the 10 s total is enforced by the transport.</summary>
    public const int TimeoutMilliseconds = 5_000;

    private static readonly Lazy<FetchModule> SharedFetch = new(() => new FetchModule());
    private static readonly Lazy<BoundedExecutor> SharedPool = new(() => new BoundedExecutor(FetchModule.MaximumConcurrent));
    private static readonly IReadOnlySet<string> SupportedApis = new HashSet<string> { "$dataSource" };

    private readonly PluginStore store;
    private readonly DataSourceTransport transport;
    private readonly Action<Action> executor;

    /// <param name="store">Installed and built-in plugins.</param>
    /// <param name="transport">The HTTP exchange; the bounded <c>fetch</c> transport by default.</param>
    /// <param name="executor">Runs the request off the JavaScript thread; a bounded worker pool by default.</param>
    public DataSourceModule(PluginStore store, DataSourceTransport? transport = null, Action<Action>? executor = null)
    {
        this.store = store;
        this.transport = transport ?? ((method, uri, headers, body, timeout, allowRedirect, cancellation) => SharedFetch.Value.Perform(method, uri, headers, body, timeout, allowRedirect, cancellation));
        this.executor = executor ?? (work => SharedPool.Value.Execute(work));
    }

    public IReadOnlySet<string> Apis => SupportedApis;

    public bool Handles(string operation) => operation == Operation;

    public void Start(ExecutionRequest request, string operation, JsonObject? payload, NativeCompletion done)
    {
        void Fail(string message) => done(false, Json.Quote(message));
        if (operation != Operation) { Fail($"Unsupported operation {operation}"); return; }
        if (DataSourcePolicy.PresentationError(request) is { } presentation) { Fail(presentation); return; }
        var job = payload ?? new JsonObject();
        var pluginID = job["pluginID"] is { } pluginNode && pluginNode.IsString() ? pluginNode.GetValue<string>() : null;
        var operationID = job["operationID"] is { } operationNode && operationNode.IsString() ? operationNode.GetValue<string>() : null;
        if (pluginID is null || operationID is null) { Fail("Data source requests need a plugin id and an operation id"); return; }
        if (DataSourcePolicy.DeclarationError(request, pluginID) is { } declaration) { Fail(declaration); return; }
        var values = new Dictionary<string, object?>(StringComparer.Ordinal);
        if (job.OptObject("parameters") is { } parameters) foreach (var (name, value) in parameters) values[name] = value;

        executor(() =>
        {
            try
            {
                var plugin = store.Manifest(pluginID) ?? throw new PluginException(PluginErrorKind.NotFound, $"Plugin {pluginID} is not installed");
                var prepared = DataSourceRequestBuilder.Prepare(plugin, operationID, values);
                if (DataSourcePolicy.DestinationError(request, plugin, prepared.Uri) is { } destination) throw new PluginException(PluginErrorKind.Permission, destination);
                if (request.Session.Finished || request.Session.AddNetworkRequest() > FetchModule.MaximumRequests)
                {
                    throw new PluginException(PluginErrorKind.Network, DataSourcePolicy.Budget);
                }
                var response = transport(prepared.Method, prepared.Uri, prepared.Headers, prepared.Body, TimeoutMilliseconds,
                    redirected => DataSourcePolicy.AllowsRedirect(request, plugin, redirected), request.Session.Cancellation.Token);
                if (request.Session.Finished) return;
                done(true, DataSourceResponseMapper.Map(prepared.Operation, response.Status, response.Body));
            }
            catch (PluginException error)
            {
                Fail(error.Message);
            }
            catch (FetchModule.FetchException error)
            {
                Fail(string.IsNullOrEmpty(error.Message) ? "Data source request failed" : error.Message);
            }
            catch (Exception)
            {
                // Exception text from the network stack can quote the URL, which may carry parameter values.
                Fail("Data source request failed");
            }
        });
    }
}
