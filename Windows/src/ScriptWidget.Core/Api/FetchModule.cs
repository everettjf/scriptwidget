using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json.Nodes;
using ScriptWidget.Core.Runtime;

namespace ScriptWidget.Core.Api;

/// <summary>
/// <c>fetch</c> and <c>$http</c>. Mirrors ScriptWidgetRuntimeFetch: public HTTP(S)
/// only, the package's declared hosts only, bounded request and response
/// sizes, a per-execution request budget, and every redirect re-validated.
/// Beyond the Swift host-name rule, the resolved addresses are checked so a
/// public name cannot point at a private or loopback address. On Windows the
/// connection is opened to the very address that was checked, so a DNS answer
/// that changes between the check and the connect cannot be used.
/// </summary>
public sealed class FetchModule : INativeModule
{
    public const int MaximumResponseBytes = 2 * 1024 * 1024;
    public const int MaximumRequestBodyBytes = 1024 * 1024;
    public const int MaximumRequests = 32;
    public const int MaximumConcurrent = 8;
    public const int MaximumRedirects = 5;
    public const long MaximumTotalMilliseconds = 10_000L;
    public static readonly IReadOnlyList<string> ExposedHeaders = ["content-type", "cache-control", "expires", "last-modified", "date", "retry-after"];

    internal const string BlockedMessage = "Local and private network hosts are not allowed";
    private const string TimedOutMessage = "The request timed out.";
    private static readonly HashSet<string> Methods = new(StringComparer.Ordinal) { "OPTIONS", "GET", "HEAD", "POST", "PUT", "DELETE", "PATCH", "TRACE" };
    private static readonly HashSet<string> ContentHeaders = new(StringComparer.OrdinalIgnoreCase)
    {
        "Allow", "Content-Disposition", "Content-Encoding", "Content-Language", "Content-Location", "Content-MD5", "Content-Range", "Content-Type", "Expires", "Last-Modified",
    };

    public sealed class Response(int status, byte[] body, IReadOnlyDictionary<string, string> headers)
    {
        public int Status { get; } = status;
        public byte[] Body { get; } = body;
        /// <summary>Response headers by lower-case name; the last value wins.</summary>
        public IReadOnlyDictionary<string, string> Headers { get; } = headers;
    }

    public sealed class FetchException(string message) : Exception(message);

    private readonly Func<string, IReadOnlyList<IPAddress>> resolver;
    private readonly HttpMessageInvoker client;
    private readonly BoundedExecutor pool = new(MaximumConcurrent);

    /// <param name="resolver">Turns a host name (or address literal) into addresses; tests replace it to stay offline.</param>
    /// <param name="handler">
    /// Sends the request. The default connects only to addresses the resolver returned and
    /// <see cref="RuntimePolicy.BlockedAddress"/> accepted. A replacement must not follow redirects itself.
    /// </param>
    public FetchModule(Func<string, IReadOnlyList<IPAddress>>? resolver = null, HttpMessageHandler? handler = null)
    {
        this.resolver = resolver ?? SystemResolver;
        client = new HttpMessageInvoker(handler ?? CreateHandler(this.resolver), disposeHandler: true);
    }

    /// <summary>The operating system's resolver. An address literal is returned as is.</summary>
    public static IReadOnlyList<IPAddress> SystemResolver(string host) => IPAddress.TryParse(host, out var literal) ? [literal] : Dns.GetHostAddresses(host);

    /// <summary>
    /// The production transport: no automatic redirects, cookies, credentials or proxy, and a
    /// connect step that resolves the host itself and connects to a vetted address only. A proxy
    /// is not used because the address it would reach cannot be checked here.
    /// </summary>
    public static SocketsHttpHandler CreateHandler(Func<string, IReadOnlyList<IPAddress>> resolver) => new()
    {
        AllowAutoRedirect = false,
        UseCookies = false,
        UseProxy = false,
        Proxy = null,
        DefaultProxyCredentials = null,
        Credentials = null,
        PreAuthenticate = false,
        AutomaticDecompression = DecompressionMethods.All,
        ConnectTimeout = TimeSpan.FromMilliseconds(MaximumTotalMilliseconds),
        PooledConnectionIdleTimeout = TimeSpan.FromSeconds(30),
        PooledConnectionLifetime = TimeSpan.FromMinutes(2),
        MaxConnectionsPerServer = MaximumConcurrent,
        MaxResponseHeadersLength = 64,
        ConnectCallback = (context, cancellation) => ConnectAsync(resolver, context.DnsEndPoint, cancellation),
    };

    /// <summary>
    /// Opens the TCP connection for one request. The host is refused by name first; then every
    /// address it resolves to must be public, and the socket connects to one of exactly those
    /// addresses. The name is never resolved a second time by the socket layer.
    /// </summary>
    internal static async ValueTask<Stream> ConnectAsync(Func<string, IReadOnlyList<IPAddress>> resolver, DnsEndPoint endPoint, CancellationToken cancellation)
    {
        var host = Unbracket(endPoint.Host);
        if (host.Length == 0 || RuntimePolicy.BlockedHostName(host)) throw new FetchException(BlockedMessage);
        IReadOnlyList<IPAddress> addresses;
        try { addresses = resolver(host); }
        catch (Exception) { throw new FetchException($"Could not resolve {endPoint.Host}"); }
        if (addresses.Count == 0 || addresses.Any(RuntimePolicy.BlockedAddress)) throw new FetchException(BlockedMessage);
        Exception? last = null;
        foreach (var address in addresses)
        {
            var socket = new Socket(address.AddressFamily, SocketType.Stream, ProtocolType.Tcp) { NoDelay = true };
            try
            {
                await socket.ConnectAsync(new IPEndPoint(address, endPoint.Port), cancellation).ConfigureAwait(false);
                return new NetworkStream(socket, ownsSocket: true);
            }
            catch (SocketException error)
            {
                socket.Dispose();
                last = error;
            }
            catch
            {
                socket.Dispose();
                throw;
            }
        }
        throw last!;
    }

    public bool Handles(string operation) => operation == "http.request";

    public void Start(ExecutionRequest request, string operation, JsonObject? payload, NativeCompletion done)
    {
        var job = payload ?? new JsonObject();
        void Fail(string message) => done(false, Json.Quote(message));
        if (RuntimePolicy.IsLiveActivity(request)) { Fail("[live_activity_unavailable] Live Activity presentations cannot request network data; update their state from the app"); return; }
        if (RuntimePolicy.IsTimelineProjection(request)) { Fail("[timeline_read_only] Future entries cannot make live network requests; read a saved snapshot"); return; }
        var url = job.OptString("url");
        if (!Uri.TryCreate(url, UriKind.RelativeOrAbsolute, out var uri)) { Fail($"{url} is not url"); return; }
        if (ValidationError(uri) is { } invalid) { Fail(invalid); return; }
        if (!RuntimePolicy.PackageAllowsHost(request, uri.Host)) { Fail("Network host is not declared in widget.json"); return; }
        if (request.Session.AddNetworkRequest() > MaximumRequests) { Fail("Network request budget exceeded"); return; }

        pool.Execute(() =>
        {
            try
            {
                var headers = new Dictionary<string, string>(StringComparer.Ordinal);
                if (job.OptObject("headers") is { } map) foreach (var (name, _) in map) headers[name] = map.OptString(name);
                var body = job.Has("body") ? Encoding.UTF8.GetBytes(job.OptString("body")) : null;
                if (body is not null && job.OptBoolean("jsonBody") && !headers.Keys.Any(name => name.Equals("Content-Type", StringComparison.OrdinalIgnoreCase))) headers["Content-Type"] = "application/json";
                if (body is not null && body.Length > MaximumRequestBodyBytes) throw new FetchException($"Request body exceeds the {MaximumRequestBodyBytes}-byte limit");
                var timeout = NormalizedTimeout(job.Has("timeout") ? job.OptDouble("timeout") : null);
                var response = Perform(job.OptString("method", "GET"), uri, headers, body, timeout,
                    redirected => !request.Session.Finished && ValidationError(redirected) is null && RuntimePolicy.PackageAllowsHost(request, redirected.Host),
                    request.Session.Cancellation.Token);
                if (request.Session.Finished) return;
                var base64 = job.OptBoolean("base64");
                var text = base64 ? Convert.ToBase64String(response.Body) : DecodeUtf8(response.Body);
                if (job.OptBoolean("metadata"))
                {
                    if (text is null) throw new FetchException("Response is not HTTP or has invalid UTF-8");
                    var allowed = new JsonObject();
                    foreach (var name in ExposedHeaders)
                    {
                        if (response.Headers.TryGetValue(name, out var value) && Encoding.UTF8.GetByteCount(value) <= 2048) allowed[name] = value;
                    }
                    done(true, Json.Stringify(new JsonObject { ["status"] = response.Status, ["body"] = text, ["headers"] = allowed }));
                }
                else if (text is null) throw new FetchException($"{url} is empty");
                else done(true, Json.Quote(text));
            }
            catch (FetchException error)
            {
                Fail(error.Message);
            }
            catch (Exception error)
            {
                Fail(string.IsNullOrEmpty(error.Message) ? error.GetType().Name : error.Message);
            }
        });
    }

    public string? ValidationError(Uri uri)
    {
        var scheme = uri.IsAbsoluteUri ? uri.Scheme.ToLowerInvariant() : null;
        if (scheme != "http" && scheme != "https") return "Only HTTP and HTTPS URLs are allowed";
        var host = Unbracket(uri.Host.ToLowerInvariant());
        if (host.Length == 0) return "URL host is required";
        if (uri.UserInfo.Length > 0) return "URL credentials are not allowed";
        return RuntimePolicy.BlockedHostName(host) ? BlockedMessage : null;
    }

    /// <summary>
    /// Performs one request, following up to five redirects that <paramref name="allowRedirect"/> accepts.
    /// Blocks the calling thread; call it from a worker.
    /// </summary>
    public Response Perform(string method, Uri start, IReadOnlyDictionary<string, string> headers, byte[]? body, int timeoutMilliseconds, Func<Uri, bool> allowRedirect, CancellationToken cancellation = default) =>
        PerformAsync(method, start, headers, body, timeoutMilliseconds, allowRedirect, cancellation).GetAwaiter().GetResult();

    /// <summary>
    /// Performs one request, following up to five redirects that <paramref name="allowRedirect"/> accepts.
    /// Every hop is resolved and its addresses checked before anything is sent. The response body is
    /// counted while it is read, never trusting <c>Content-Length</c>, and reading stops at the limit.
    /// </summary>
    public async Task<Response> PerformAsync(string method, Uri start, IReadOnlyDictionary<string, string> headers, byte[]? body, int timeoutMilliseconds, Func<Uri, bool> allowRedirect, CancellationToken cancellation = default)
    {
        var current = start;
        var currentMethod = method.ToUpperInvariant();
        var currentBody = body;
        if (!Methods.Contains(currentMethod)) throw new FetchException($"Unknown method '{currentMethod}'");
        var deadline = Stopwatch.GetTimestamp() + MaximumTotalMilliseconds * Stopwatch.Frequency / 1000;
        for (var hop = 0; hop <= MaximumRedirects; hop++)
        {
            cancellation.ThrowIfCancellationRequested();
            var host = Unbracket(current.Host);
            IReadOnlyList<IPAddress> addresses;
            try { addresses = resolver(host); }
            catch (Exception) { throw new FetchException($"Could not resolve {current.Host}"); }
            if (addresses.Count == 0 || addresses.Any(RuntimePolicy.BlockedAddress)) throw new FetchException(BlockedMessage);
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
            // Each wait (connect and response headers, then every read) gets the request timeout, inside the total deadline.
            void Arm()
            {
                var remaining = (int)Math.Min(int.MaxValue, (deadline - Stopwatch.GetTimestamp()) * 1000 / Stopwatch.Frequency);
                if (remaining <= 0) throw new FetchException(TimedOutMessage);
                timeout.CancelAfter(Math.Min(timeoutMilliseconds, remaining));
            }
            Arm();
            using var message = new HttpRequestMessage(new HttpMethod(currentMethod), current);
            HttpContent? content = currentBody is not null && currentMethod != "GET" ? new ByteArrayContent(currentBody) : null;
            var unique = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (var (name, value) in headers) unique[name] = value;
            foreach (var (name, value) in unique)
            {
                if (name.Equals("Host", StringComparison.OrdinalIgnoreCase) || name.Equals("Content-Length", StringComparison.OrdinalIgnoreCase)) continue;
                // A value can never start a new header line, whatever the transport would do with it.
                if (name.Length == 0 || name.Any(character => character <= ' ' || character >= '\u007F' || character == ':') || value.Any(character => character is '\r' or '\n' or '\0'))
                {
                    throw new FetchException($"Request header {Printable(name)} is not valid");
                }
                bool added;
                if (ContentHeaders.Contains(name))
                {
                    content ??= new ByteArrayContent([]);
                    added = content.Headers.TryAddWithoutValidation(name, value);
                }
                else added = message.Headers.TryAddWithoutValidation(name, value);
                // The name is the script's own; the value is not repeated.
                if (!added) throw new FetchException($"Request header {Printable(name)} is not valid");
            }
            message.Content = content;
            try
            {
                HttpResponseMessage response;
                try { response = await client.SendAsync(message, timeout.Token).ConfigureAwait(false); }
                catch (HttpRequestException error) when (Refusal(error) is { } refusal) { throw refusal; }
                using (response)
                {
                    var status = (int)response.StatusCode;
                    if (status is >= 300 and <= 399 && status != 304)
                    {
                        var location = Last(response.Headers.NonValidated, "Location") ?? throw new FetchException("Redirect without a location");
                        if (!Uri.TryCreate(current, location, out var next) || hop == MaximumRedirects || !allowRedirect(next)) throw new FetchException("Redirect target is not allowed");
                        if (status == 303 || ((status == 301 || status == 302) && currentMethod == "POST")) { currentMethod = "GET"; currentBody = null; }
                        current = next;
                        continue;
                    }
                    var tooLarge = $"Response exceeds the {MaximumResponseBytes}-byte limit";
                    if (response.Content.Headers.ContentLength is > MaximumResponseBytes) throw new FetchException(tooLarge);
                    using var buffer = new MemoryStream();
                    await using (var stream = await response.Content.ReadAsStreamAsync(timeout.Token).ConfigureAwait(false))
                    {
                        var chunk = new byte[16 * 1024];
                        while (true)
                        {
                            Arm();
                            var read = await stream.ReadAsync(chunk, timeout.Token).ConfigureAwait(false);
                            if (read <= 0) break;
                            if (buffer.Length + read > MaximumResponseBytes) throw new FetchException(tooLarge);
                            buffer.Write(chunk, 0, read);
                        }
                    }
                    var responseHeaders = new Dictionary<string, string>(StringComparer.Ordinal);
                    foreach (var (name, values) in response.Headers.NonValidated) if (values.Count > 0) responseHeaders[name.ToLowerInvariant()] = values.Last();
                    foreach (var (name, values) in response.Content.Headers.NonValidated) if (values.Count > 0) responseHeaders[name.ToLowerInvariant()] = values.Last();
                    return new Response(status, buffer.ToArray(), responseHeaders);
                }
            }
            catch (OperationCanceledException) when (!cancellation.IsCancellationRequested)
            {
                throw new FetchException(TimedOutMessage);
            }
        }
        throw new FetchException("Too many redirects");
    }

    /// <summary>Seconds from the script, clamped to 1...10; 5 by default.</summary>
    public static int NormalizedTimeout(double? seconds)
    {
        var value = seconds is not { } given || double.IsNaN(given) || given <= 0 ? 5.0 : Math.Clamp(given, 1.0, 10.0);
        return (int)(value * 1000);
    }

    /// <summary>The policy refusal of the connect step, when that is why sending failed.</summary>
    private static FetchException? Refusal(Exception error)
    {
        for (var inner = error.InnerException; inner is not null; inner = inner.InnerException) if (inner is FetchException refusal) return refusal;
        return null;
    }

    private static string? Last(System.Net.Http.Headers.HttpHeadersNonValidated headers, string name) =>
        headers.TryGetValues(name, out var values) && values.Count > 0 ? values.Last() : null;

    private static string Printable(string name) => new(name.Where(character => character > ' ' && character < '\u007F').Take(64).ToArray());

    private static string Unbracket(string host) => host.StartsWith('[') && host.EndsWith(']') ? host[1..^1] : host;

    private static string? DecodeUtf8(byte[] bytes)
    {
        try { return new UTF8Encoding(false, true).GetString(bytes); }
        catch (DecoderFallbackException) { return null; }
    }
}

/// <summary>
/// Runs work on thread-pool threads, at most a fixed number at a time; the rest waits in order.
/// The counterpart of the fixed thread pools of the Android implementation.
/// </summary>
internal sealed class BoundedExecutor(int maximumConcurrent)
{
    private readonly Queue<Action> queue = new();
    private int running;

    public void Execute(Action work)
    {
        lock (queue)
        {
            if (running >= maximumConcurrent) { queue.Enqueue(work); return; }
            running += 1;
        }
        ThreadPool.UnsafeQueueUserWorkItem(static state => state.self.Drain(state.work), (self: this, work), preferLocal: false);
    }

    private void Drain(Action? work)
    {
        while (work is not null)
        {
            // Work reports its own failures; one that still throws must not end the worker.
            try { work(); } catch (Exception) { }
            lock (queue)
            {
                if (!queue.TryDequeue(out work)) { running -= 1; work = null; }
            }
        }
    }
}
