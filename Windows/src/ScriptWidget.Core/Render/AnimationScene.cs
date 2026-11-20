using System.Text.Json.Nodes;
using Microsoft.Graphics.Canvas;
using ScriptWidget.Core.Runtime;
using Windows.Graphics.DirectX;

namespace ScriptWidget.Core.Render;

/// <summary>Display-only poses matching the shared renderer and the Apple runtime.</summary>
public readonly record struct AnimationPose(float Degrees, float X, float Y)
{
    public static AnimationPose At(JsonObject description, long milliseconds)
    {
        if (description.OptString("kind") == "swing")
        {
            var duration = description.OptDouble("duration", 1);
            duration = double.IsFinite(duration) && duration > 0 ? Math.Clamp(duration, .1, 86400) : 1;
            var distance = description.OptDouble("distance", 10);
            distance = double.IsFinite(distance) ? Math.Clamp(distance, -10000, 10000) : 10;
            var offset = (float)(Math.Sin(milliseconds / 1000.0 % (duration * 2) / duration * Math.PI) * distance);
            return description.OptString("axis") == "y" ? new(0, 0, offset) : new(0, offset, 0);
        }
        if (milliseconds is < -62135596800000 or > 253402300799000) return default;
        var date = DateTimeOffset.FromUnixTimeMilliseconds(milliseconds);
        var zoneName = description.OptString("timezone", "current");
        var zone = TimeZoneInfo.Local;
        if (zoneName is not ("current" or ""))
        {
            try { zone = TimeZoneInfo.FindSystemTimeZoneById(zoneName); }
            catch (Exception error) when (error is TimeZoneNotFoundException or InvalidTimeZoneException) { }
        }
        var local = TimeZoneInfo.ConvertTime(date, zone);
        var type = description.OptString("type");
        double degrees;
        if (type == "clock")
        {
            var interval = description.OptDouble("interval", 10);
            interval = !double.IsFinite(interval) ? 10 : Math.Abs(interval) < .25 ? (interval < 0 ? -.25 : .25) : interval;
            var seconds = (local.DateTime - new DateTime(2001, 1, 1)).TotalSeconds;
            degrees = seconds / interval % 2 * 180;
        }
        else
        {
            var cycle = type switch { "clockSecond" => 60, "clockMinute" or "clockMiniute" => 3600, "clockHour" => 43200, _ => 0 };
            degrees = cycle == 0 ? 0 : local.TimeOfDay.TotalSeconds % cycle / cycle * 360;
        }
        return new((float)degrees, 0, 0);
    }

    public static int IntervalMilliseconds(JsonObject description) => description.OptString("kind") == "swing" || description.OptString("type") == "clock" ? 50 :
        description.OptString("type") == "clockSecond" ? 1000 : 60000;
}

/// <summary>One native paint of the saved layout, including the current hit regions.</summary>
public sealed record AnimationFrame(byte[] Pixels, IReadOnlyList<HitRegion> HitRegions);

/// <summary>
/// A saved layout and bounded GIF frames. Ticks repaint this layout natively, preserving
/// drawing order, clipping, opacity and moving hit targets without running package code or layout.
/// No device resource survives a tick; removing a widget releases its frames normally.
/// </summary>
public sealed class AnimationScene
{
    public const long MaximumLayerBytes = 16 * 1024 * 1024;
    private readonly DomNode root;
    private readonly RenderRequest request;
    private readonly float scale;
    private readonly int width, height;
    private readonly Dictionary<string, GifFrames> movies = new(StringComparer.Ordinal);
    private readonly long epoch;
    public int IntervalMilliseconds { get; private set; } = 60000;
    public bool IsAnimated { get; private set; }

    internal AnimationScene(DomNode root, RenderRequest request, float scale, int width, int height)
    {
        this.root = root;
        this.request = request;
        this.scale = scale;
        this.width = width;
        this.height = height;
        epoch = request.NowMilliseconds ?? DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        long bytes = 0;
        var attempted = new HashSet<string>(StringComparer.Ordinal);
        void Visit(DomNode node)
        {
            if (node.Dataset.TryGetValue("swAnimation", out var text) && Json.TryParse(text) is JsonObject motion)
            {
                IsAnimated = true;
                IntervalMilliseconds = Math.Min(IntervalMilliseconds, AnimationPose.IntervalMilliseconds(motion));
            }
            if (node.Tag == "img" && node.Style.GetValueOrDefault("objectFit") == "contain" &&
                node.Attributes.GetValueOrDefault("src") is { } name && name.StartsWith("res:", StringComparison.Ordinal) &&
                name.EndsWith(".gif", StringComparison.OrdinalIgnoreCase) && attempted.Count < 16 && attempted.Add(name) &&
                request.Files?.ReadBytes(name[4..]) is { } data)
            {
                var w = Math.Clamp((int)MathF.Ceiling((Css.Pixels(node.Style.GetValueOrDefault("width")) ?? request.Width) * scale), 1, 1024);
                var h = Math.Clamp((int)MathF.Ceiling((Css.Pixels(node.Style.GetValueOrDefault("height")) ?? request.Height) * scale), 1, 1024);
                var frames = GifSampler.Sample(data, w, h, MaximumLayerBytes - bytes);
                if (frames is not null)
                {
                    movies[name] = frames;
                    bytes += frames.Frames.Sum(frame => (long)frame.Length);
                    IsAnimated = true;
                    IntervalMilliseconds = Math.Min(IntervalMilliseconds, frames.IntervalMilliseconds);
                }
            }
            foreach (var child in node.Children) Visit(child);
        }
        Visit(root);
    }

    private sealed class Images(PackageImageSource still, CanvasDevice device, Dictionary<string, GifFrames> movies, long elapsed) : IImageSource, IDisposable
    {
        private readonly Dictionary<string, CanvasBitmap> frames = new(StringComparer.Ordinal);
        public CanvasBitmap? Bitmap(string source, int maximumPixels)
        {
            if (!movies.TryGetValue(source, out var movie)) return still.Bitmap(source, maximumPixels);
            if (frames.TryGetValue(source, out var cached)) return cached;
            var index = (int)(Math.Max(0, elapsed) / movie.IntervalMilliseconds % movie.Frames.Count);
            return frames[source] = CanvasBitmap.CreateFromBytes(device, movie.Frames[index], movie.Width, movie.Height, DirectXPixelFormat.B8G8R8A8UIntNormalized);
        }
        public void Dispose() { foreach (var bitmap in frames.Values) bitmap.Dispose(); }
    }

    internal AnimationFrame Draw(TextEngine text, long milliseconds)
    {
        var device = CanvasDevice.GetSharedDevice();
        using var still = new PackageImageSource(request.Files, request.RemoteImages, device);
        using var images = new Images(still, device, movies, milliseconds - epoch);
        using var target = new CanvasRenderTarget(device, width, height, 96);
        var painter = new DomPainter(text, images) { AnimationMilliseconds = milliseconds };
        var session = target.CreateDrawingSession();
        session.Clear(Css.Transparent);
        using (var canvas = new PaintCanvas(device, session)) painter.Paint(canvas, root, scale);
        var pixels = target.GetPixelBytes();
        RoundedCorners.Apply(pixels, width, height, RoundedCorners.DefaultRadius * scale);
        return new AnimationFrame(pixels, painter.HitRegions.ToList());
    }
}
