using System.Net;
using System.Text;
using ScriptWidget.Core.Api;

namespace ScriptWidget.Core.Tests.Api;

internal static class SystemFixtures
{
    public const string Owner = "11111111-1111-4111-8111-111111111111";
    public const string OtherOwner = "22222222-2222-4222-8222-222222222222";

    public static string TemporaryDirectory(string name)
    {
        var path = Path.Combine(Path.GetTempPath(), "scriptwidget-tests", name + "-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(path);
        return path;
    }

    /// <summary>A call context with an adjustable query budget, defaulting to an installed Package 2.0 widget on Runtime 1.6.</summary>
    public static CallContext Context(
        string[]? permissions = null, string installation = Owner, bool hasManifest = true, string[]? domains = null,
        string? runtime = "1.6", bool action = false, bool projection = false, bool liveActivity = false,
        int queries = CallContext.MaximumDataQueries, int network = CallContext.MaximumNetworkRequests, Func<bool>? active = null)
    {
        var usedQueries = 0;
        var usedNetwork = 0;
        return new CallContext(installation, hasManifest, new HashSet<string>(permissions ?? []), domains ?? [], runtime, action, projection, liveActivity,
            dataQuery: () => ++usedQueries <= queries, networkRequest: () => ++usedNetwork <= network, active: active ?? (() => true));
    }

    /// <summary>Asserts that <paramref name="block"/> rejects with a message starting with <c>[code]</c>.</summary>
    public static void AssertRejects(string code, Action block)
    {
        var error = Assert.Throws<SystemReject>(block);
        Assert.Equal($"[{code}]", "[" + SystemLog.Code(error.Message) + "]");
    }
}

/// <summary>An HTTP exchange that never leaves the process: records each request and answers from a function.</summary>
internal sealed class FakeHandler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> respond) : HttpMessageHandler
{
    public FakeHandler(Func<HttpRequestMessage, HttpResponseMessage> respond) : this((message, _) => Task.FromResult(respond(message))) { }

    public sealed record Request(string Method, Uri Uri, IReadOnlyDictionary<string, string> Headers, byte[]? Body, string? Host);

    public List<Request> Requests { get; } = [];

    public static HttpResponseMessage Text(int status, string body, string contentType = "text/plain; charset=utf-8")
    {
        var response = new HttpResponseMessage((HttpStatusCode)status) { Content = new ByteArrayContent(Encoding.UTF8.GetBytes(body)) };
        response.Content.Headers.TryAddWithoutValidation("Content-Type", contentType);
        return response;
    }

    public static HttpResponseMessage Redirect(int status, string? location)
    {
        var response = new HttpResponseMessage((HttpStatusCode)status) { Content = new ByteArrayContent([]) };
        if (location is not null) response.Headers.TryAddWithoutValidation("Location", location);
        return response;
    }

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var (name, values) in request.Headers.NonValidated) headers[name] = values.ToString();
        byte[]? body = null;
        if (request.Content is { } content)
        {
            foreach (var (name, values) in content.Headers.NonValidated) headers[name] = values.ToString();
            body = await content.ReadAsByteArrayAsync(cancellationToken);
        }
        lock (Requests) Requests.Add(new Request(request.Method.Method, request.RequestUri!, headers, body, request.Headers.Host));
        return await respond(request, cancellationToken);
    }
}

/// <summary>A response body without a length: zeros for as long as it is read, or until a limit.</summary>
internal sealed class ZeroStream(long length = long.MaxValue, bool stall = false) : Stream
{
    public long BytesRead { get; private set; }

    public override bool CanRead => true;
    public override bool CanSeek => false;
    public override bool CanWrite => false;
    public override long Length => throw new NotSupportedException();
    public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }

    public override int Read(byte[] buffer, int offset, int count)
    {
        var take = (int)Math.Min(count, length - BytesRead);
        Array.Clear(buffer, offset, take);
        BytesRead += take;
        return take;
    }

    public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
    {
        // A stalled body sends its first bytes and then nothing, like a server that stops answering.
        if (stall && BytesRead > 0) await Task.Delay(Timeout.Infinite, cancellationToken);
        var take = (int)Math.Min(buffer.Length, length - BytesRead);
        buffer.Span[..take].Clear();
        BytesRead += take;
        return take;
    }

    public override void Flush() { }
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
}
