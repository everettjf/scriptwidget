using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace ScriptWidget.Core.Hosting;

/// <summary>
/// The local channel between the always-running desktop host and the
/// programs that drive it (the management window, the command line). One
/// JSON object per line in each direction. The pipe is created for the
/// current user only, so other accounts on the machine cannot connect.
/// Requests name packages and widgets by identifier; nothing sent over the
/// pipe is ever executed as code.
/// </summary>
public static class HostPipe
{
    public const string Name = "ScriptWidget.Host.v1";
    private const int MaximumLineBytes = 1024 * 1024;

    /// <summary>Serves requests until <paramref name="cancellation"/> is cancelled. <paramref name="handle"/> runs on a thread-pool thread.</summary>
    public static async Task ServeAsync(Func<JsonObject, JsonObject> handle, CancellationToken cancellation)
    {
        while (!cancellation.IsCancellationRequested)
        {
            NamedPipeServerStream server;
            try
            {
                server = new NamedPipeServerStream(Name, PipeDirection.InOut, NamedPipeServerStream.MaxAllowedServerInstances, PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
            }
            catch (IOException) { await Task.Delay(1000, cancellation).ConfigureAwait(false); continue; }
            try { await server.WaitForConnectionAsync(cancellation).ConfigureAwait(false); }
            catch (OperationCanceledException) { await server.DisposeAsync().ConfigureAwait(false); return; }
            catch (IOException) { await server.DisposeAsync().ConfigureAwait(false); continue; }
            _ = Task.Run(() => ServeConnectionAsync(server, handle, cancellation), cancellation);
        }
    }

    private static async Task ServeConnectionAsync(NamedPipeServerStream server, Func<JsonObject, JsonObject> handle, CancellationToken cancellation)
    {
        await using (server.ConfigureAwait(false))
        {
            try
            {
                while (server.IsConnected && !cancellation.IsCancellationRequested)
                {
                    if (await ReadLineAsync(server, cancellation).ConfigureAwait(false) is not { } line) return;
                    JsonObject response;
                    try { response = handle(Json.ParseObject(line)); }
                    catch (Exception error) when (error is JsonException or InvalidOperationException or ArgumentException)
                    {
                        response = new JsonObject { ["ok"] = false, ["error"] = error.Message };
                    }
                    await WriteLineAsync(server, Json.Stringify(response), cancellation).ConfigureAwait(false);
                }
            }
            catch (Exception error) when (error is IOException or OperationCanceledException or ObjectDisposedException) { }
        }
    }

    /// <summary>Sends one request to the running host. Returns null when no host is running.</summary>
    public static JsonObject? Send(JsonObject request, int connectTimeoutMilliseconds = 1500, int responseTimeoutMilliseconds = 30_000)
    {
        try
        {
            using var client = new NamedPipeClientStream(".", Name, PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
            client.Connect(connectTimeoutMilliseconds);
            using var timeout = new CancellationTokenSource(responseTimeoutMilliseconds);
            WriteLineAsync(client, Json.Stringify(request), timeout.Token).GetAwaiter().GetResult();
            var line = ReadLineAsync(client, timeout.Token).GetAwaiter().GetResult();
            return line is null ? null : Json.TryParse(line) as JsonObject;
        }
        catch (Exception error) when (error is IOException or TimeoutException or OperationCanceledException or UnauthorizedAccessException) { return null; }
    }

    /// <summary>True when a host is listening.</summary>
    public static bool IsHostRunning() => Send(new JsonObject { ["command"] = "ping" }, 300, 3000) is { } response && response.OptBoolean("ok");

    private static async Task<string?> ReadLineAsync(Stream stream, CancellationToken cancellation)
    {
        var bytes = new MemoryStream();
        var buffer = new byte[4096];
        while (true)
        {
            var read = await stream.ReadAsync(buffer, cancellation).ConfigureAwait(false);
            if (read == 0) return bytes.Length == 0 ? null : Encoding.UTF8.GetString(bytes.GetBuffer(), 0, (int)bytes.Length);
            var end = Array.IndexOf(buffer, (byte)'\n', 0, read);
            if (end >= 0)
            {
                bytes.Write(buffer, 0, end);
                return Encoding.UTF8.GetString(bytes.GetBuffer(), 0, (int)bytes.Length);
            }
            bytes.Write(buffer, 0, read);
            if (bytes.Length > MaximumLineBytes) throw new IOException("Request is too large");
        }
    }

    private static async Task WriteLineAsync(Stream stream, string line, CancellationToken cancellation)
    {
        var bytes = Encoding.UTF8.GetBytes(line.Replace("\n", "") + "\n");
        await stream.WriteAsync(bytes, cancellation).ConfigureAwait(false);
        await stream.FlushAsync(cancellation).ConfigureAwait(false);
    }
}
