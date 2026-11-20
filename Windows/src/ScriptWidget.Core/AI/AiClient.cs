using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json.Nodes;

namespace ScriptWidget.Core.AI;

public sealed record AiMessage(string Role, string Content);
public sealed record AiUsage(long PromptTokens = 0, long CompletionTokens = 0, long TotalTokens = 0)
{
    public static AiUsage operator +(AiUsage first, AiUsage second) => new(first.PromptTokens + second.PromptTokens, first.CompletionTokens + second.CompletionTokens, first.TotalTokens + second.TotalTokens);
}
public sealed record AiChatResult(string Content, AiUsage Usage, bool Truncated = false);
public interface IAiChat
{
    Task<AiChatResult> ChatAsync(IReadOnlyList<AiMessage> messages, Action<string>? onText, CancellationToken cancellation);
}

/// <summary>Bounded Anthropic Messages and OpenAI-compatible chat, with no redirected credentials.</summary>
public sealed class AiClient : IDisposable
{
    public const int MaximumResponseBytes = 4 * 1024 * 1024;
    private readonly HttpClient client;
    private readonly HttpClient localClient;
    public AiClient(HttpMessageHandler? handler = null)
    {
        client = new HttpClient(handler ?? CreateHandler()) { Timeout = Timeout.InfiniteTimeSpan };
        var localHandler = handler is null ? CreateHandler() : null;
        if (localHandler is not null)
        {
            localHandler.UseProxy = false;
            localHandler.ConnectCallback = ConnectLoopbackAsync;
        }
        localClient = localHandler is null ? client : new HttpClient(localHandler) { Timeout = Timeout.InfiniteTimeSpan };
    }

    private static SocketsHttpHandler CreateHandler() => new()
    {
        AllowAutoRedirect = false, UseCookies = false, Credentials = null,
        ConnectTimeout = TimeSpan.FromSeconds(15), AutomaticDecompression = DecompressionMethods.All,
    };

    private static async ValueTask<Stream> ConnectLoopbackAsync(SocketsHttpConnectionContext context, CancellationToken cancellation)
    {
        var host = context.DnsEndPoint.Host;
        if (!AiProfile.IsLoopbackHost(host)) throw new HttpRequestException("Local AI connections must stay on loopback.");
        // Resolve localhost ourselves: neither DNS/hosts-file overrides nor system proxies may
        // move a local prompt or credential off this computer. Try IPv6 if IPv4 is unavailable.
        var addresses = host.Equals("localhost", StringComparison.OrdinalIgnoreCase) ? new[] { IPAddress.Loopback, IPAddress.IPv6Loopback } :
            new[] { host is "::1" or "[::1]" ? IPAddress.IPv6Loopback : IPAddress.Loopback };
        foreach (var address in addresses)
        {
            var socket = new Socket(address.AddressFamily, SocketType.Stream, ProtocolType.Tcp) { NoDelay = true };
            try
            {
                await socket.ConnectAsync(new IPEndPoint(address, context.DnsEndPoint.Port), cancellation).ConfigureAwait(false);
                return new NetworkStream(socket, ownsSocket: true);
            }
            catch (SocketException) when (address.Equals(IPAddress.Loopback) && addresses.Length > 1) { socket.Dispose(); }
            catch { socket.Dispose(); throw; }
        }
        throw new HttpRequestException("The local AI server could not be reached.");
    }

    private sealed class Bound(AiClient client, AiProfile profile, AiApiKey? key) : IAiChat
    {
        public Task<AiChatResult> ChatAsync(IReadOnlyList<AiMessage> messages, Action<string>? onText, CancellationToken cancellation) => client.ChatAsync(profile, key, messages, onText, cancellation);
    }
    public IAiChat Bind(AiProfile profile, AiApiKey? key) => new Bound(this, profile, key);

    internal static HttpRequestMessage BuildRequest(AiProfile profile, AiApiKey? key, IReadOnlyList<AiMessage> messages, bool stream)
    {
        if (profile.ValidationError() is { } error) throw new AiException("invalid_profile", error);
        if (messages.Count is 0 or > 64 || messages.Any(message => message.Role is not ("system" or "user" or "assistant"))) throw new AiException("invalid_request", "The AI conversation has invalid messages.");
        var body = new JsonObject { ["model"] = profile.Model.Trim() };
        var rows = new JsonArray();
        var anthropic = profile.Provider == AiProvider.Anthropic;
        foreach (var message in messages)
            if (!anthropic || message.Role != "system" && !string.IsNullOrWhiteSpace(message.Content)) rows.Append(new JsonObject { ["role"] = message.Role, ["content"] = message.Content });
        body["messages"] = rows;
        if (anthropic)
        {
            body["max_tokens"] = 16000;
            body["system"] = string.Join("\n\n", messages.Where(message => message.Role == "system").Select(message => message.Content));
        }
        else
        {
            body["temperature"] = profile.Temperature;
            if (stream) body["stream_options"] = new JsonObject { ["include_usage"] = true };
        }
        if (stream) body["stream"] = true;
        var text = Json.Stringify(body);
        if (Encoding.UTF8.GetByteCount(text) > MaximumResponseBytes) throw new AiException("request_too_large", "The AI request is too large. Continue in a new conversation.");
        var request = new HttpRequestMessage(HttpMethod.Post, profile.NormalizedBaseUrl + (anthropic ? "/v1/messages" : "/v1/chat/completions"))
        { Content = new StringContent(text, Encoding.UTF8, "application/json") };
        Authenticate(request, profile, key);
        request.Headers.TryAddWithoutValidation("Accept", stream ? "text/event-stream" : "application/json");
        return request;
    }

    private static void Authenticate(HttpRequestMessage request, AiProfile profile, AiApiKey? key)
    {
        if (key is null)
        {
            if (!profile.IsLoopback) throw new AiException("missing_api_key", "Configure this provider's API key first.");
            return;
        }
        if (profile.Provider == AiProvider.Anthropic)
        {
            request.Headers.TryAddWithoutValidation("x-api-key", key.Secret);
            request.Headers.TryAddWithoutValidation("anthropic-version", "2023-06-01");
        }
        else request.Headers.TryAddWithoutValidation("Authorization", "Bearer " + key.Secret);
    }

    public async Task<AiChatResult> ChatAsync(AiProfile profile, AiApiKey? key, IReadOnlyList<AiMessage> messages, Action<string>? onText = null, CancellationToken cancellation = default)
    {
        cancellation.ThrowIfCancellationRequested();
        var stream = onText is not null;
        var reader = new AiStreamReader(profile.Provider == AiProvider.Anthropic, text => onText?.Invoke(key?.Redact(text) ?? text));
        try
        {
            var result = await SendAsync(profile, key, messages, stream, reader, cancellation).ConfigureAwait(false);
            onText?.Invoke(key?.Redact(result.Content) ?? result.Content);
            return result with { Content = key?.Redact(result.Content) ?? result.Content };
        }
        catch (Exception error) when (stream && reader.Content.Length == 0 && !cancellation.IsCancellationRequested && error is HttpRequestException or IOException)
        {
            // No text arrived: one ordinary request, as on Android and Linux. Never retry a partial reply.
            var fallback = await ChatAsync(profile, key, messages, null, cancellation).ConfigureAwait(false);
            onText?.Invoke(fallback.Content);
            return fallback;
        }
        catch (OperationCanceledException) when (!cancellation.IsCancellationRequested) { throw new AiException("timeout", "The AI request timed out."); }
        catch (Exception error) when (error is HttpRequestException or IOException) { throw new AiException("network", "The AI request could not be completed."); }
        catch (DecoderFallbackException) { throw new AiException("malformed_response", "The AI server returned invalid UTF-8."); }
    }

    private async Task<AiChatResult> SendAsync(AiProfile profile, AiApiKey? key, IReadOnlyList<AiMessage> messages, bool stream, AiStreamReader reader, CancellationToken cancellation)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        timeout.CancelAfter(TimeSpan.FromMinutes(5));
        using var request = BuildRequest(profile, key, messages, stream);
        using var response = await (profile.IsLoopback ? localClient : client).SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false);
        var status = (int)response.StatusCode;
        if (status is >= 300 and < 400) throw new AiException("redirect_refused", "The AI server redirected the request. Enter its final HTTPS base URL in Settings.");
        if (status is 401 or 403 or 429 || !stream && !response.IsSuccessStatusCode) throw HttpError(status);
        if (!response.IsSuccessStatusCode) return await ChatAsync(profile, key, messages, null, cancellation).ConfigureAwait(false);
        if (response.Content.Headers.ContentLength is > MaximumResponseBytes) throw TooLarge();
        await using var input = await response.Content.ReadAsStreamAsync(timeout.Token).ConfigureAwait(false);
        using var raw = new MemoryStream();
        var chunk = new byte[8192];
        while (true)
        {
            var count = await input.ReadAsync(chunk, timeout.Token).ConfigureAwait(false);
            if (count == 0) break;
            if (raw.Length + count > MaximumResponseBytes) throw TooLarge();
            raw.Write(chunk, 0, count);
            if (stream) reader.Feed(chunk.AsSpan(0, count));
        }
        if (stream)
        {
            reader.Finish();
            if (reader.SawEvent)
            {
                if (reader.Refused) throw new AiException("refused", "The model declined this request. Rephrase it and try again.");
                if (string.IsNullOrWhiteSpace(reader.Content)) throw Empty();
                if (!reader.Terminal) throw new AiException("network", "The AI stream ended before its reply was complete.");
                return new AiChatResult(reader.Content, reader.Usage, reader.Truncated);
            }
        }
        return ParseResponse(profile.Provider, raw.ToArray());
    }

    public async Task<IReadOnlyList<string>> ListModelsAsync(AiProfile profile, AiApiKey? key, CancellationToken cancellation = default)
    {
        cancellation.ThrowIfCancellationRequested();
        if (profile.ValidationError(requireModel: false) is { } error) throw new AiException("invalid_profile", error);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        timeout.CancelAfter(TimeSpan.FromSeconds(15));
        using var request = new HttpRequestMessage(HttpMethod.Get, profile.NormalizedBaseUrl + "/v1/models" + (profile.Provider == AiProvider.Anthropic ? "?limit=1000" : ""));
        Authenticate(request, profile, key);
        try
        {
            using var response = await (profile.IsLoopback ? localClient : client).SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false);
            if ((int)response.StatusCode is >= 300 and < 400) throw new AiException("redirect_refused", "The models endpoint redirected the request.");
            if (!response.IsSuccessStatusCode) throw HttpError((int)response.StatusCode);
            await using var stream = await response.Content.ReadAsStreamAsync(timeout.Token).ConfigureAwait(false);
            using var bytes = new MemoryStream();
            var chunk = new byte[8192];
            while (true)
            {
                var count = await stream.ReadAsync(chunk, timeout.Token).ConfigureAwait(false);
                if (count == 0) break;
                if (bytes.Length + count > 1024 * 1024) throw TooLarge();
                bytes.Write(chunk, 0, count);
            }
            var json = ParseObject(bytes.ToArray());
            if (json.OptArray("data") is not { } models) throw Malformed();
            return models.OfType<JsonObject>().Select(model => key?.Redact(model.OptString("id")) ?? model.OptString("id")).Where(model => model.Length is > 0 and <= 200 && !model.Any(char.IsControl)).Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToList();
        }
        catch (OperationCanceledException) when (!cancellation.IsCancellationRequested) { throw new AiException("timeout", "The AI connection test timed out."); }
        catch (Exception exception) when (exception is HttpRequestException or IOException) { throw new AiException("network", "The AI server could not be reached."); }
    }

    internal static AiChatResult ParseResponse(AiProvider provider, byte[] bytes)
    {
        if (bytes.Length > MaximumResponseBytes) throw TooLarge();
        var json = ParseObject(bytes);
        if (json.Has("error") && !json.IsNull("error")) throw new AiException("http", "The AI server reported an error.");
        if (provider == AiProvider.Anthropic)
        {
            var stop = json.OptString("stop_reason");
            if (stop == "refusal") throw new AiException("refused", "The model declined this request.");
            if (json.OptArray("content") is not { } blocks) throw Malformed();
            var text = string.Concat(blocks.OfType<JsonObject>().Where(block => block.OptString("type") == "text").Select(block => block.OptString("text")));
            if (string.IsNullOrWhiteSpace(text)) throw Empty();
            return new(text, AnthropicUsage(json.OptObject("usage")), stop == "max_tokens");
        }
        var choice = json.OptArray("choices")?.OfType<JsonObject>().FirstOrDefault() ?? throw Malformed();
        var message = choice.OptObject("message") ?? throw Malformed();
        if (message.OptString("refusal").Length > 0 || choice.OptString("finish_reason") == "content_filter") throw new AiException("refused", "The model declined this request.");
        var content = message.OptString("content");
        if (string.IsNullOrWhiteSpace(content)) throw Empty();
        return new(content, OpenAiUsage(json.OptObject("usage")), choice.OptString("finish_reason") == "length");
    }
    internal static long Count(JsonObject? json, string name) => Math.Clamp(json.OptLong(name), 0, 1000000000);
    internal static AiUsage OpenAiUsage(JsonObject? json)
    {
        var input = Count(json, "prompt_tokens");
        var output = Count(json, "completion_tokens");
        var total = Count(json, "total_tokens");
        return new(input, output, total > 0 ? total : input + output);
    }
    internal static AiUsage AnthropicUsage(JsonObject? json)
    {
        var input = Count(json, "input_tokens") + Count(json, "cache_creation_input_tokens") + Count(json, "cache_read_input_tokens");
        var output = Count(json, "output_tokens");
        return new(input, output, input + output);
    }
    private static JsonObject ParseObject(byte[] bytes)
    {
        try { return Json.ParseObject(new UTF8Encoding(false, true).GetString(bytes)); }
        catch (Exception error) when (error is System.Text.Json.JsonException or DecoderFallbackException) { throw Malformed(); }
    }
    internal static AiException TooLarge() => new("response_too_large", "The AI response exceeded the size limit.");
    private static AiException Empty() => new("empty_response", "The model returned an empty response.");
    private static AiException Malformed() => new("malformed_response", "The AI server returned a response that could not be read. Check the API base URL.");
    private static AiException HttpError(int status) => new("http", status is 401 or 403 ? "The AI server rejected the API key or its permissions." : status == 429 ? "The AI server's rate or credit limit was reached." : $"The AI server returned HTTP {status}.");
    public void Dispose() { if (!ReferenceEquals(localClient, client)) localClient.Dispose(); client.Dispose(); }
}

/// <summary>SSE reader with bounded UTF-8 lines, multi-line events and usage from both wire formats.</summary>
internal sealed class AiStreamReader(bool anthropic, Action<string> onText)
{
    private readonly List<byte> pending = [];
    private readonly StringBuilder data = new();
    private readonly StringBuilder content = new();
    private long lastSent;
    public bool SawEvent { get; private set; }
    public bool Terminal { get; private set; }
    public bool Truncated { get; private set; }
    public bool Refused { get; private set; }
    public string Content => content.ToString();
    public AiUsage Usage { get; private set; } = new();
    public void Feed(ReadOnlySpan<byte> bytes)
    {
        foreach (var value in bytes)
            if (value == (byte)'\n') { Line(new UTF8Encoding(false, true).GetString(pending.ToArray()).TrimEnd('\r')); pending.Clear(); }
            else { if (pending.Count >= 1024 * 1024) throw AiClient.TooLarge(); pending.Add(value); }
    }
    public void Finish()
    {
        if (pending.Count > 0) Line(new UTF8Encoding(false, true).GetString(pending.ToArray()).TrimEnd('\r'));
        pending.Clear();
        Dispatch();
    }
    private void Line(string line)
    {
        if (line.Length == 0) { Dispatch(); return; }
        if (!line.StartsWith("data:", StringComparison.Ordinal)) return;
        if (data.Length > 0) data.Append('\n');
        data.Append(line.AsSpan(5).TrimStart());
        if (data.Length > 1024 * 1024) throw AiClient.TooLarge();
    }
    private void Dispatch()
    {
        var payload = data.ToString().Trim();
        data.Clear();
        if (payload.Length == 0) return;
        if (payload == "[DONE]") { Terminal = true; return; }
        if (Json.TryParse(payload) is not JsonObject json) return;
        SawEvent = true;
        string? piece = null;
        if (anthropic)
        {
            switch (json.OptString("type"))
            {
                case "message_start": Usage = AiClient.AnthropicUsage(json.OptObject("message")?.OptObject("usage")); break;
                case "message_delta":
                    var output = AiClient.Count(json.OptObject("usage"), "output_tokens");
                    Usage = Usage with { CompletionTokens = output, TotalTokens = Usage.PromptTokens + output };
                    var reason = json.OptObject("delta").OptString("stop_reason");
                    Truncated |= reason == "max_tokens";
                    Refused |= reason == "refusal";
                    Terminal |= reason.Length > 0;
                    break;
                case "message_stop": Terminal = true; break;
                case "content_block_delta":
                    var delta = json.OptObject("delta");
                    if (delta.OptString("type") == "text_delta") piece = delta.OptString("text");
                    break;
                case "error": throw new AiException("http", "The AI server reported a streaming error.");
            }
        }
        else
        {
            if (json.OptObject("usage") is { } usage) Usage = AiClient.OpenAiUsage(usage);
            var choice = json.OptArray("choices")?.OfType<JsonObject>().FirstOrDefault();
            var reason = choice.OptString("finish_reason");
            Truncated |= reason == "length";
            Refused |= reason == "content_filter" || choice?.OptObject("delta").OptString("refusal").Length > 0;
            Terminal |= reason.Length > 0;
            piece = choice?.OptObject("delta").OptString("content");
            if (json.Has("error")) throw new AiException("http", "The AI server reported a streaming error.");
        }
        if (string.IsNullOrEmpty(piece)) return;
        if (content.Length + piece.Length > AiClient.MaximumResponseBytes) throw AiClient.TooLarge();
        content.Append(piece);
        var now = Environment.TickCount64;
        if (now - lastSent >= 80) { lastSent = now; onText(content.ToString()); }
    }
}
