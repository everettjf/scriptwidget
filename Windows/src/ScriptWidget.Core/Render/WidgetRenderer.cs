using System.Buffers.Binary;
using System.Globalization;
using System.IO.Compression;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Microsoft.Graphics.Canvas;
using ScriptWidget.Core.Js;
using ScriptWidget.Core.Runtime;

namespace ScriptWidget.Core.Render;

/// <summary>What to draw and at what size. Lengths are in points (device-independent pixels).</summary>
public sealed class RenderRequest
{
    public required string Tree { get; init; }
    public required float Width { get; init; }
    public required float Height { get; init; }
    /// <summary>Pixels per point.</summary>
    public required float Density { get; init; }
    public string Family { get; init; } = "medium";
    public bool DarkMode { get; init; }
    public IPackageFiles? Files { get; init; }
    /// <summary>Remote image URLs that were fetched under the package's network policy, with the paths of their files.</summary>
    public IReadOnlyDictionary<string, string> RemoteImages { get; init; } = new Dictionary<string, string>();
    /// <summary>Fixed clock for deterministic output; null uses the real clock.</summary>
    public long? NowMilliseconds { get; init; }
    /// <summary>Bitmap budget in bytes for this render; the output is scaled down to fit.</summary>
    public long MaximumBitmapBytes { get; init; } = long.MaxValue;
    /// <summary><c>&lt;date&gt;</c> styles left out of the bitmap because the host shows them with self-updating views.</summary>
    public IReadOnlySet<string> LiveDateStyles { get; init; } = new HashSet<string>();
    /// <summary>Leave <c>&lt;gif&gt;</c> out of the bitmap; the host plays it (see <see cref="RenderOutput.GifSlots"/>).</summary>
    public bool LiveGifs { get; init; }
    /// <summary>Leave clock and swing animations out of the bitmap; the host moves them (see <see cref="RenderOutput.MotionSlots"/>).</summary>
    public bool LiveMotion { get; init; }
    /// <summary>Leave the rows of the first <c>&lt;list&gt;</c> out of the bitmap; the host scrolls them (see <see cref="RenderOutput.ListSlots"/>). Android only; Windows hosts leave it off.</summary>
    public bool LiveLists { get; init; }
    /// <summary>System theme colors behind the <c>material.&lt;role&gt;</c> names; null leaves them unknown. Android only; Windows hosts leave it off.</summary>
    public JsonObject? Colors { get; init; }
}

public sealed class RenderOutput
{
    /// <summary>Premultiplied BGRA pixels, <see cref="PixelWidth"/> x <see cref="PixelHeight"/>, rows from the top, no padding.</summary>
    public required byte[] Pixels { get; init; }
    public required int PixelWidth { get; init; }
    public required int PixelHeight { get; init; }
    /// <summary>Pixels per point actually used (lower than requested when the budget forced a smaller bitmap).</summary>
    public required float Scale { get; init; }
    public required IReadOnlyList<HitRegion> HitRegions { get; init; }
    public required IReadOnlyList<DateSlot> DateSlots { get; init; }
    public required IReadOnlyList<GifSlot> GifSlots { get; init; }
    public required IReadOnlyList<MotionSlot> MotionSlots { get; init; }
    public required IReadOnlyList<ListSlot> ListSlots { get; init; }
    public required JsonArray Diagnostics { get; init; }
    public required long LayoutMilliseconds { get; init; }
    public required long PaintMilliseconds { get; init; }

    /// <summary>The bitmap as PNG data.</summary>
    public byte[] EncodePng() => PngEncoder.Encode(Pixels, PixelWidth, PixelHeight);
}

/// <summary>Writes premultiplied BGRA pixels as an RGBA PNG, without a graphics device.</summary>
public static class PngEncoder
{
    private static readonly uint[] CrcTable = MakeCrcTable();

    public static byte[] Encode(byte[] premultipliedBgra, int width, int height)
    {
        if (width <= 0 || height <= 0 || premultipliedBgra.Length < (long)width * height * 4) throw new ArgumentException("Pixel data does not match the size");
        var stride = width * 4 + 1;
        var raw = new byte[stride * height];
        for (var row = 0; row < height; row++)
        {
            var from = row * width * 4;
            var into = row * stride + 1;
            for (var column = 0; column < width; column++, from += 4, into += 4)
            {
                var alpha = premultipliedBgra[from + 3];
                if (alpha == 0) continue;
                if (alpha == 255)
                {
                    raw[into] = premultipliedBgra[from + 2]; raw[into + 1] = premultipliedBgra[from + 1]; raw[into + 2] = premultipliedBgra[from];
                }
                else
                {
                    raw[into] = Straight(premultipliedBgra[from + 2], alpha); raw[into + 1] = Straight(premultipliedBgra[from + 1], alpha); raw[into + 2] = Straight(premultipliedBgra[from], alpha);
                }
                raw[into + 3] = alpha;
            }
        }
        using var output = new MemoryStream(raw.Length / 4 + 128);
        output.Write([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
        Span<byte> header = stackalloc byte[13];
        BinaryPrimitives.WriteInt32BigEndian(header, width);
        BinaryPrimitives.WriteInt32BigEndian(header[4..], height);
        header[8] = 8; header[9] = 6; header[10] = 0; header[11] = 0; header[12] = 0;
        Chunk(output, "IHDR", header);
        using (var compressed = new MemoryStream(raw.Length / 4 + 64))
        {
            using (var zlib = new ZLibStream(compressed, CompressionLevel.Optimal, leaveOpen: true)) zlib.Write(raw);
            Chunk(output, "IDAT", compressed.GetBuffer().AsSpan(0, (int)compressed.Length));
        }
        Chunk(output, "IEND", []);
        return output.ToArray();
    }

    private static byte Straight(byte value, byte alpha) => (byte)Math.Min(255, (value * 255 + alpha / 2) / alpha);

    private static void Chunk(Stream output, string type, ReadOnlySpan<byte> data)
    {
        Span<byte> word = stackalloc byte[4];
        BinaryPrimitives.WriteInt32BigEndian(word, data.Length);
        output.Write(word);
        Span<byte> name = [(byte)type[0], (byte)type[1], (byte)type[2], (byte)type[3]];
        output.Write(name);
        output.Write(data);
        BinaryPrimitives.WriteUInt32BigEndian(word, ~Crc(data, Crc(name, 0xFFFFFFFF)));
        output.Write(word);
    }

    private static uint Crc(ReadOnlySpan<byte> data, uint crc)
    {
        foreach (var item in data) crc = CrcTable[(crc ^ item) & 0xFF] ^ (crc >> 8);
        return crc;
    }

    private static uint[] MakeCrcTable()
    {
        var table = new uint[256];
        for (uint index = 0; index < 256; index++)
        {
            var value = index;
            for (var bit = 0; bit < 8; bit++) value = (value & 1) != 0 ? 0xEDB88320 ^ (value >> 1) : value >> 1;
            table[index] = value;
        }
        return table;
    }
}

/// <summary>Decodes package, inline and fetched images for one render. Use it on the render thread only.</summary>
public sealed class PackageImageSource(IPackageFiles? files, IReadOnlyDictionary<string, string> remote, CanvasDevice device) : IImageSource, IDisposable
{
    private readonly Dictionary<string, CanvasBitmap?> decoded = new();
    private readonly Dictionary<string, CanvasBitmap?> cache = new();

    private byte[]? Bytes(string source)
    {
        if (source.StartsWith("res:", StringComparison.Ordinal)) return files?.ReadBytes(source["res:".Length..]);
        if (source.StartsWith("data:", StringComparison.Ordinal))
        {
            var marker = source.IndexOf("base64,", StringComparison.Ordinal);
            try { return Convert.FromBase64String(marker < 0 ? source : source[(marker + "base64,".Length)..]); }
            catch (FormatException) { return null; }
        }
        if (!remote.TryGetValue(source, out var path)) return null;
        try
        {
            var file = new FileInfo(path);
            return file.Exists && file.Length <= MaximumImageBytes ? File.ReadAllBytes(path) : null;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return null; }
    }

    /// <summary>The whole image, decoded once per render; null when the source cannot be decoded.</summary>
    private CanvasBitmap? Decode(string source)
    {
        if (decoded.TryGetValue(source, out var existing)) return existing;
        CanvasBitmap? bitmap = null;
        var data = Bytes(source);
        if (data is { Length: > 0 })
        {
            try
            {
                using var stream = new MemoryStream(data, false).AsRandomAccessStream();
                // 96 DPI: one unit of the bitmap is one pixel.
                bitmap = CanvasBitmap.LoadAsync(device, stream, 96f).AsTask().GetAwaiter().GetResult();
                var size = bitmap.SizeInPixels;
                if (size.Width == 0 || size.Height == 0) { bitmap.Dispose(); bitmap = null; }
            }
            catch (Exception)
            {
                // Not an image the system can decode.
                bitmap = null;
            }
        }
        decoded[source] = bitmap;
        return bitmap;
    }

    /// <summary>Natural size in pixels, or null when the source cannot be decoded.</summary>
    public int[]? Size(string source)
    {
        var bitmap = Decode(source);
        if (bitmap is null) return null;
        var size = bitmap.SizeInPixels;
        return [(int)size.Width, (int)size.Height];
    }

    public CanvasBitmap? Bitmap(string source, int maximumPixels)
    {
        var key = $"{source}@{maximumPixels}";
        if (cache.TryGetValue(key, out var existing)) return existing;
        var result = Reduce(Decode(source), maximumPixels);
        cache[key] = result;
        return result;
    }

    private CanvasBitmap? Reduce(CanvasBitmap? bitmap, int maximumPixels)
    {
        if (bitmap is null) return null;
        var size = bitmap.SizeInPixels;
        var sample = 1;
        // Keep no more than about four times the pixels that will be shown.
        while ((size.Width / (sample * 2)) * (long)(size.Height / (sample * 2)) >= maximumPixels) sample *= 2;
        if (sample == 1) return bitmap;
        try
        {
            var width = Math.Max(1u, (uint)(size.Width / sample));
            var height = Math.Max(1u, (uint)(size.Height / sample));
            var target = new CanvasRenderTarget(device, width, height, 96f);
            using (var session = target.CreateDrawingSession())
            {
                session.Clear(Css.Transparent);
                session.DrawImage(bitmap, new Windows.Foundation.Rect(0, 0, width, height), new Windows.Foundation.Rect(0, 0, size.Width, size.Height), 1f, CanvasImageInterpolation.HighQualityCubic);
            }
            return target;
        }
        catch (Exception)
        {
            return bitmap;
        }
    }

    public void Dispose()
    {
        foreach (var bitmap in cache.Values.Concat(decoded.Values).Distinct()) bitmap?.Dispose();
        cache.Clear();
        decoded.Clear();
    }

    private const long MaximumImageBytes = 16L * 1024 * 1024;
}

/// <summary>
/// Turns a canonical element tree into a bitmap. Layout runs in the shared
/// web renderer inside a long-lived QuickJS context (trusted code only); the
/// recorded elements are painted with <see cref="DomPainter"/>. Layout,
/// text measurement and painting all happen on one thread with a large stack.
/// </summary>
public sealed partial class WidgetRenderer : IDisposable
{
    private readonly SharedScripts scripts;
    private readonly TextEngine text;
    private readonly JsWorker worker = new("scriptwidget-render", 8 * 1024 * 1024);
    private QuickJs? engine;
    private PackageImageSource? images;

    public WidgetRenderer(SharedScripts scripts, FontRegistry? fonts = null)
    {
        this.scripts = scripts;
        Fonts = fonts ?? new FontRegistry();
        text = new TextEngine(Fonts);
    }

    public FontRegistry Fonts { get; }

    private string? Host(string operation, string? payload) => operation switch
    {
        "text.measure" => Measure(Json.ParseObject(payload!)),
        "text.baseline" => Number(text.Baseline(Style(Json.ParseObject(payload!)))),
        "image.size" => images?.Size(payload ?? "") is { } size ? $"[{size[0]},{size[1]}]" : "null",
        _ => IntlBridge.Call(operation, payload),
    };

    private static string Number(float value) => float.IsFinite(value) ? value.ToString("R", CultureInfo.InvariantCulture) : "0";

    private static TextStyle Style(JsonObject json) => new(json.OptString("family"), (float)json.OptDouble("size", 17.0), json.OptInt("weight", 400), (float)json.OptDouble("leading", 20.0));

    private string Measure(JsonObject json)
    {
        float? width = json.IsNull("width") ? null : (float)json.OptDouble("width");
        var lines = text.Lines(json.OptString("text"), Style(json), width);
        return $"{{\"width\":{Number(lines.Count == 0 ? 0f : lines.Max(line => line.Width))},\"lines\":{Math.Max(1, lines.Count)}}}";
    }

    private QuickJs Engine()
    {
        if (engine is not null) return engine;
        var created = new QuickJs(Host, memoryLimitBytes: 96L * 1024 * 1024, stackBytes: 6L * 1024 * 1024);
        try
        {
            // Keep the native entry point for the trusted render bundle before the host file removes it.
            created.Evaluate("globalThis.__swRenderNative = globalThis.__swNative;", "render-prelude.js");
            created.Evaluate(scripts.Text("host.js"), "host.js");
            created.Evaluate(scripts.Text("render.js"), "render.js");
            created.Evaluate(
                "globalThis.__swRenderStart = function (request) { globalThis.__swRenderResult = null; globalThis.__swRenderError = null;" +
                " __swRenderBundle.render(globalThis.__swRenderNative, request).then(function (value) { globalThis.__swRenderResult = value; }," +
                " function (error) { globalThis.__swRenderError = (error && error.stack ? String(error.message || error) + '\\n' + error.stack : String(error)); }); };" +
                " globalThis.__swRenderTake = function (name) { var value = globalThis[name]; globalThis[name] = null; return value; };",
                "render-driver.js");
            engine = created;
            return created;
        }
        catch
        {
            created.Dispose();
            throw;
        }
    }

    public RenderOutput Render(RenderRequest request) => worker.Run(() =>
    {
        try { return RenderOnThread(request); }
        // A lost graphics device (driver update, remote session) is replaced by Win2D; draw once more on the new one.
        catch (Exception error) when (DeviceWasLost(error)) { return RenderOnThread(request); }
    });

    private static bool DeviceWasLost(Exception error)
    {
        try
        {
            var device = CanvasDevice.GetSharedDevice();
            if (!device.IsDeviceLost(error.HResult)) return false;
            device.RaiseDeviceLost();
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    /// <summary>The element tree the layout records for a request, as JSON text; for tests and diagnosis.</summary>
    internal string Layout(RenderRequest request) => worker.Run(() =>
    {
        using var source = new PackageImageSource(request.Files, request.RemoteImages, CanvasDevice.GetSharedDevice());
        images = source;
        try { return Json.Stringify(LayoutOnThread(request)); }
        finally { images = null; }
    });

    /// <summary>Runs the shared layout; <see cref="images"/> must be set.</summary>
    private JsonObject LayoutOnThread(RenderRequest request)
    {
        var resources = new JsonObject();
        if (request.Files is not null)
            foreach (var path in request.Files.Paths())
                if (ImageFile().IsMatch(path)) resources[path] = "res:" + path;
        var job = new JsonObject
        {
            ["tree"] = request.Tree, ["width"] = (double)request.Width, ["height"] = (double)request.Height,
            ["family"] = request.Family, ["dark"] = request.DarkMode, ["resources"] = resources,
            ["images"] = Json.Array(request.RemoteImages.Keys),
        };
        if (request.NowMilliseconds is { } now) job["now"] = now;
        if (request.Colors is not null) job["colors"] = request.Colors.Copy();

        var js = Engine();
        try
        {
            js.SetDeadline(LayoutTimeoutMilliseconds);
            js.Call("__swRenderStart", Json.Stringify(job));
            js.RunJobs();
            var failure = js.Call("__swRenderTake", "__swRenderError");
            if (failure is not null) throw new InvalidOperationException($"Layout failed: {failure}");
            return Json.ParseObject(js.Call("__swRenderTake", "__swRenderResult") ?? throw new InvalidOperationException("Layout did not finish"));
        }
        catch
        {
            // A failed or interrupted context may hold partial state; start fresh next time.
            engine?.Dispose();
            engine = null;
            throw;
        }
        finally
        {
            engine?.SetDeadline(0);
        }
    }

    private RenderOutput RenderOnThread(RenderRequest request)
    {
        var layoutStart = System.Diagnostics.Stopwatch.GetTimestamp();
        var device = CanvasDevice.GetSharedDevice();
        using var source = new PackageImageSource(request.Files, request.RemoteImages, device);
        images = source;
        try
        {
            var rendered = LayoutOnThread(request);
            var layoutMilliseconds = (long)System.Diagnostics.Stopwatch.GetElapsedTime(layoutStart).TotalMilliseconds;

            var paintStart = System.Diagnostics.Stopwatch.GetTimestamp();
            var scale = request.Density;
            var bytesAtRequestedScale = (long)MathF.Ceiling(request.Width * scale) * (long)MathF.Ceiling(request.Height * scale) * 4L;
            if (bytesAtRequestedScale > request.MaximumBitmapBytes) scale *= (float)Math.Sqrt((double)request.MaximumBitmapBytes / bytesAtRequestedScale);
            var pixelWidth = Math.Clamp((int)MathF.Ceiling(request.Width * scale), 1, MaximumBitmapSide);
            var pixelHeight = Math.Clamp((int)MathF.Ceiling(request.Height * scale), 1, MaximumBitmapSide);
            var root = new DomNode(rendered.OptObject("root") ?? throw new InvalidOperationException("Layout returned no element tree"));
            var painter = new DomPainter(text, source, request.LiveDateStyles, request.LiveGifs) { LiveMotion = request.LiveMotion, LiveLists = request.LiveLists };
            byte[] pixels;
            using (var target = new CanvasRenderTarget(device, pixelWidth, pixelHeight, 96f))
            {
                var session = target.CreateDrawingSession();
                session.Clear(Css.Transparent);
                using (var canvas = new PaintCanvas(device, session)) painter.Paint(canvas, root, scale);
                pixels = target.GetPixelBytes();
            }
            return new RenderOutput
            {
                Pixels = pixels, PixelWidth = pixelWidth, PixelHeight = pixelHeight, Scale = scale,
                HitRegions = painter.HitRegions.ToList(), DateSlots = painter.DateSlots.ToList(), GifSlots = painter.GifSlots.ToList(),
                MotionSlots = painter.MotionSlots.ToList(), ListSlots = painter.ListSlots.ToList(),
                Diagnostics = rendered.OptArray("diagnostics") ?? new JsonArray(),
                LayoutMilliseconds = layoutMilliseconds,
                PaintMilliseconds = (long)System.Diagnostics.Stopwatch.GetElapsedTime(paintStart).TotalMilliseconds,
            };
        }
        finally
        {
            images = null;
        }
    }

    /// <summary>Frees the layout context; the next render recreates it.</summary>
    public void Release() => worker.Post(() => { engine?.Dispose(); engine = null; });

    public void Dispose()
    {
        try { worker.Run(() => { engine?.Dispose(); engine = null; return true; }); }
        catch (InvalidOperationException) { /* already disposed */ }
        worker.Dispose();
    }

    private const long LayoutTimeoutMilliseconds = 8000L;
    /// <summary>The largest texture Direct3D feature level 11 can hold.</summary>
    private const int MaximumBitmapSide = 16384;

    [GeneratedRegex(@"\.(png|jpe?g|webp|gif|heic|bmp)$", RegexOptions.IgnoreCase)]
    private static partial Regex ImageFile();
}
