using System.Numerics;
using System.Security.Cryptography;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Effects;
using Microsoft.Graphics.Canvas.Geometry;
using Windows.Foundation;
using Windows.UI;

namespace ScriptWidget.Core.Render;

/// <summary>A rectangle in points, like Android's RectF.</summary>
public readonly record struct RectF(float Left, float Top, float Right, float Bottom)
{
    public float Width => Right - Left;
    public float Height => Bottom - Top;
    public float CenterX => (Left + Right) / 2f;
    public float CenterY => (Top + Bottom) / 2f;

    /// <summary>The part shared with <paramref name="other"/>, or null when the two do not overlap.</summary>
    public RectF? Intersect(RectF other)
    {
        if (!(Left < other.Right && other.Left < Right && Top < other.Bottom && other.Top < Bottom)) return null;
        return new RectF(Math.Max(Left, other.Left), Math.Max(Top, other.Top), Math.Min(Right, other.Right), Math.Min(Bottom, other.Bottom));
    }

    internal Rect ToRect() => new(Left, Top, Math.Max(0f, Width), Math.Max(0f, Height));
}

public readonly record struct PointF(float X, float Y);

/// <summary>
/// A 3x3 matrix with the conventions of Android's Matrix: points are columns,
/// and <c>PreConcat(m)</c> applies <c>m</c> before this matrix.
/// </summary>
public sealed class Matrix
{
    private readonly float[] values = [1f, 0f, 0f, 0f, 1f, 0f, 0f, 0f, 1f];

    public Matrix() { }

    public Matrix(Matrix other) { other.values.CopyTo(values, 0); }

    private Matrix(float a, float b, float c, float d, float e, float f, float g, float h, float i) { values = [a, b, c, d, e, f, g, h, i]; }

    public static Matrix Translation(float x, float y) => new(1f, 0f, x, 0f, 1f, y, 0f, 0f, 1f);

    public static Matrix Scaling(float x, float y) => new(x, 0f, 0f, 0f, y, 0f, 0f, 0f, 1f);

    /// <summary>Clockwise on screen for positive degrees, as in CSS and SVG.</summary>
    public static Matrix Rotation(float degrees)
    {
        var radians = degrees * MathF.PI / 180f;
        var cos = MathF.Cos(radians);
        var sin = MathF.Sin(radians);
        return new Matrix(cos, -sin, 0f, sin, cos, 0f, 0f, 0f, 1f);
    }

    public static Matrix Rotation(float degrees, float centerX, float centerY)
    {
        var matrix = Translation(centerX, centerY);
        matrix.PreConcat(Rotation(degrees));
        matrix.PreTranslate(-centerX, -centerY);
        return matrix;
    }

    /// <summary>Rows: x, y and w of the mapped point.</summary>
    public static Matrix Projective(float a, float b, float c, float d, float e, float f, float g, float h, float i) => new(a, b, c, d, e, f, g, h, i);

    private static void Multiply(float[] left, float[] right, float[] into)
    {
        Span<float> result = stackalloc float[9];
        for (var row = 0; row < 3; row++)
            for (var column = 0; column < 3; column++)
                result[row * 3 + column] = left[row * 3] * right[column] + left[row * 3 + 1] * right[3 + column] + left[row * 3 + 2] * right[6 + column];
        result.CopyTo(into);
    }

    public void PreConcat(Matrix other) => Multiply(values, other.values, values);

    public void PostConcat(Matrix other) => Multiply(other.values, values, values);

    public void PreTranslate(float x, float y) => PreConcat(Translation(x, y));

    public void PostTranslate(float x, float y) => PostConcat(Translation(x, y));

    public PointF MapPoint(float x, float y)
    {
        var mappedX = values[0] * x + values[1] * y + values[2];
        var mappedY = values[3] * x + values[4] * y + values[5];
        var w = values[6] * x + values[7] * y + values[8];
        if (w != 1f && w != 0f) { mappedX /= w; mappedY /= w; }
        return new PointF(mappedX, mappedY);
    }

    /// <summary>The bounding box of the mapped corners.</summary>
    public RectF MapRect(RectF rect)
    {
        Span<PointF> corners = [MapPoint(rect.Left, rect.Top), MapPoint(rect.Right, rect.Top), MapPoint(rect.Right, rect.Bottom), MapPoint(rect.Left, rect.Bottom)];
        float left = corners[0].X, right = corners[0].X, top = corners[0].Y, bottom = corners[0].Y;
        foreach (var corner in corners)
        {
            left = Math.Min(left, corner.X); right = Math.Max(right, corner.X);
            top = Math.Min(top, corner.Y); bottom = Math.Max(bottom, corner.Y);
        }
        return new RectF(left, top, right, bottom);
    }

    public bool IsAffine => values[6] == 0f && values[7] == 0f && values[8] == 1f;

    /// <summary>True when the matrix only moves things.</summary>
    public bool IsTranslation => values[0] == 1f && values[4] == 1f && values[1] == 0f && values[3] == 0f && values[6] == 0f && values[7] == 0f;

    internal Matrix3x2 ToMatrix3x2() => new(values[0], values[3], values[1], values[4], values[2], values[5]);

    internal Matrix4x4 ToMatrix4x4() => new(
        values[0], values[3], 0f, values[6],
        values[1], values[4], 0f, values[7],
        0f, 0f, 1f, 0f,
        values[2], values[5], 0f, values[8]);
}

/// <summary>
/// The part of android.graphics.Canvas the painters use, over a Win2D drawing
/// session: a save/restore stack of transforms, clips and opacity layers,
/// plus offscreen recordings for shadows, masks and perspective.
/// Lengths are in pixels of the target unless a transform says otherwise.
/// </summary>
public sealed class PaintCanvas : IDisposable
{
    private sealed class Perspective(CanvasCommandList list, Matrix4x4 matrix, Matrix3x2 outer)
    {
        public CanvasCommandList List { get; } = list;
        public Matrix4x4 Matrix { get; } = matrix;
        public Matrix3x2 Outer { get; } = outer;
    }

    private sealed class SaveEntry(Matrix3x2 transform, int layers)
    {
        public Matrix3x2 Transform { get; } = transform;
        public int Layers { get; } = layers;
        public Perspective? Perspective { get; set; }
    }

    private readonly List<CanvasDrawingSession> sessions = [];
    private readonly List<(CanvasCommandList List, int Layers)> recordings = [];
    private readonly List<CanvasActiveLayer> layers = [];
    private readonly List<SaveEntry> saves = [];

    /// <summary>Takes ownership of <paramref name="session"/>.</summary>
    public PaintCanvas(ICanvasResourceCreator device, CanvasDrawingSession session)
    {
        Device = device;
        Configure(session);
        sessions.Add(session);
    }

    public ICanvasResourceCreator Device { get; }

    /// <summary>The session drawing goes to right now.</summary>
    public CanvasDrawingSession Session => sessions[^1];

    public Matrix3x2 Transform { get => Session.Transform; set => Session.Transform = value; }

    private static void Configure(CanvasDrawingSession session)
    {
        session.Antialiasing = CanvasAntialiasing.Antialiased;
        // ClearType needs an opaque background; a widget bitmap is transparent.
        session.TextAntialiasing = Microsoft.Graphics.Canvas.Text.CanvasTextAntialiasing.Grayscale;
        // Glyphs keep their measured shapes and positions at every scale: no fitting to the pixel grid.
        session.TextRenderingParameters = TextRendering;
    }

    private static readonly Microsoft.Graphics.Canvas.Text.CanvasTextRenderingParameters TextRendering =
        new(Microsoft.Graphics.Canvas.Text.CanvasTextRenderingMode.NaturalSymmetric, Microsoft.Graphics.Canvas.Text.CanvasTextGridFit.Disable);

    public void Save() => saves.Add(new SaveEntry(Transform, layers.Count));

    public void Restore()
    {
        if (saves.Count == 0) return;
        var entry = saves[^1];
        saves.RemoveAt(saves.Count - 1);
        if (entry.Perspective is { } perspective)
        {
            var list = EndRecord();
            using var effect = new Transform3DEffect { Source = list, TransformMatrix = perspective.Matrix, InterpolationMode = CanvasImageInterpolation.Cubic };
            Session.Transform = perspective.Outer;
            Session.DrawImage(effect);
            list.Dispose();
        }
        PopLayers(entry.Layers);
        Session.Transform = entry.Transform;
    }

    private void PopLayers(int count)
    {
        while (layers.Count > count)
        {
            layers[^1].Dispose();
            layers.RemoveAt(layers.Count - 1);
        }
    }

    public void Translate(float x, float y) => Transform = Matrix3x2.CreateTranslation(x, y) * Transform;

    public void Scale(float x, float y) => Transform = Matrix3x2.CreateScale(x, y) * Transform;

    public void Rotate(float degrees, float centerX, float centerY) => Transform = Matrix3x2.CreateRotation(degrees * MathF.PI / 180f, new Vector2(centerX, centerY)) * Transform;

    /// <summary>
    /// Applies <paramref name="matrix"/> before the current transform. A matrix with perspective cannot be a
    /// Direct2D transform: what is drawn until the matching <see cref="Restore"/> is recorded and
    /// drawn through a 3D transform effect.
    /// </summary>
    public void Concat(Matrix matrix)
    {
        if (matrix.IsAffine || saves.Count == 0 || saves[^1].Perspective is not null)
        {
            Transform = matrix.ToMatrix3x2() * Transform;
            return;
        }
        var outer = Transform;
        // Record at the resolution of the target so the effect does not enlarge a low-resolution image.
        var scale = DeviceScale();
        BeginRecord(Matrix3x2.CreateScale(scale));
        saves[^1].Perspective = new Perspective(recordings[^1].List, Matrix4x4.CreateScale(1f / scale, 1f / scale, 1f) * matrix.ToMatrix4x4(), outer);
    }

    /// <summary>Pixels per unit of the current transform, at least 1.</summary>
    public float DeviceScale()
    {
        var transform = Transform;
        return Math.Max(1f, Math.Max(MathF.Sqrt(transform.M11 * transform.M11 + transform.M12 * transform.M12), MathF.Sqrt(transform.M21 * transform.M21 + transform.M22 * transform.M22)));
    }

    /// <summary>Clips to <paramref name="geometry"/> until the enclosing <see cref="Save"/> is restored.</summary>
    public void ClipPath(CanvasGeometry geometry) => layers.Add(Session.CreateLayer(1f, geometry));

    public void ClipRect(RectF bounds) => layers.Add(Session.CreateLayer(1f, bounds.ToRect()));

    /// <summary>Like <c>saveLayerAlpha</c>: what is drawn until <see cref="Restore"/> is blended as one group.</summary>
    public void SaveLayerAlpha(float opacity)
    {
        Save();
        layers.Add(Session.CreateLayer(opacity));
    }

    /// <summary>Sends drawing to a command list with the given transform (the current one by default).</summary>
    public void BeginRecord(Matrix3x2? transform = null)
    {
        var start = transform ?? Transform;
        var list = new CanvasCommandList(Device);
        var session = list.CreateDrawingSession();
        Configure(session);
        session.Transform = start;
        recordings.Add((list, layers.Count));
        sessions.Add(session);
    }

    /// <summary>Ends the innermost recording; the caller owns the list.</summary>
    public CanvasCommandList EndRecord()
    {
        var (list, count) = recordings[^1];
        recordings.RemoveAt(recordings.Count - 1);
        PopLayers(count);
        sessions[^1].Dispose();
        sessions.RemoveAt(sessions.Count - 1);
        return list;
    }

    /// <summary>Draws an image that is already in the coordinates of the session, ignoring the transform.</summary>
    public void DrawDeviceImage(ICanvasImage image, Vector2 offset = default)
    {
        var saved = Transform;
        Session.Transform = Matrix3x2.Identity;
        Session.DrawImage(image, offset);
        Session.Transform = saved;
    }

    public void Dispose()
    {
        while (recordings.Count > 0) EndRecord().Dispose();
        PopLayers(0);
        saves.Clear();
        foreach (var session in sessions) session.Dispose();
        sessions.Clear();
    }
}

/// <summary>One element recorded by the shared renderer (see render/entry.mjs <c>serialize</c>).</summary>
public sealed class DomNode
{
    private static readonly IReadOnlyDictionary<string, string> Empty = new Dictionary<string, string>();

    public DomNode(JsonObject json)
    {
        Tag = json.OptString("t");
        Svg = json.OptInt("g") == 1;
        Style = StringMap(json.OptObject("s"));
        Attributes = StringMap(json.OptObject("a"));
        Dataset = StringMap(json.OptObject("d"));
        Text = json.Has("x") ? json.OptString("x") : null;
        var children = json.OptArray("c");
        if (children is null) Children = [];
        else
        {
            var list = new List<DomNode>(children.Count);
            foreach (var child in children) list.Add(new DomNode(child as JsonObject ?? throw new FormatException("A recorded element is not an object")));
            Children = list;
        }
    }

    public string Tag { get; }
    public bool Svg { get; }
    public IReadOnlyDictionary<string, string> Style { get; }
    public IReadOnlyDictionary<string, string> Attributes { get; }
    public IReadOnlyDictionary<string, string> Dataset { get; }
    public string? Text { get; }
    public IReadOnlyList<DomNode> Children { get; }

    private static IReadOnlyDictionary<string, string> StringMap(JsonObject? json)
    {
        if (json is null) return Empty;
        var result = new Dictionary<string, string>(json.Count);
        foreach (var (key, _) in json) result[key] = json.OptString(key);
        return result;
    }
}

/// <summary>A tappable area of the widget, in points from the widget's top-left corner.</summary>
public sealed record HitRegion(RectF Bounds, JsonObject Interaction);

/// <summary>A <c>&lt;date&gt;</c> text the host may replace with a self-updating view.</summary>
public sealed record DateSlot(RectF Bounds, JsonObject Description, TextStyle? Style, Color Color, string Align);

/// <summary>A package GIF the host plays with its own views; it is left out of the bitmap.</summary>
public sealed record GifSlot(RectF Bounds, string Source);

/// <summary>
/// A view with a clock or swing animation, drawn at rest into its own bitmap
/// so the host can move it. <see cref="Anchor"/> is the rotation centre (clock) or the
/// resting centre (swing) in widget points; the bitmap is centred on it.
/// <see cref="Pixels"/> are premultiplied BGRA, <see cref="PixelSize"/> on a side.
/// </summary>
public sealed record MotionSlot(JsonObject Description, PointF Anchor, byte[] Pixels, int PixelSize, float SizePoints);

/// <summary>
/// A stretch of a scrolling list as one image: one or more whole rows, drawn at
/// the list's width. <see cref="HitRegions"/> are in points from the piece's top-left corner.
/// </summary>
public sealed record ListPiece(byte[] Png, float HeightPoints, IReadOnlyList<HitRegion> HitRegions);

/// <summary>
/// A <c>&lt;list&gt;</c> the host scrolls with its own views. <see cref="Bounds"/> is the visible
/// area in widget points; the rows are left out of the widget bitmap.
/// <see cref="Truncated"/> is true when rows were dropped to stay inside the image budget.
/// </summary>
public sealed record ListSlot(RectF Bounds, IReadOnlyList<ListPiece> Pieces, bool Truncated);

internal sealed record PendingPiece(Task<byte[]> Png, float Height, IReadOnlyList<HitRegion> HitRegions);

/// <summary>
/// Turns list pieces into PNG data. Encoding is the slow part of drawing a
/// long list, so it runs on several threads, and a piece whose pixels did not
/// change since an earlier drawing reuses the data made then.
/// </summary>
internal static class PieceEncoder
{
    private static readonly int Threads = Math.Clamp(Environment.ProcessorCount, 2, 4);
    /// <summary>Pieces waiting to be encoded hold their pixels; the painter waits rather than queue more than this.</summary>
    private static readonly SemaphoreSlim Waiting = new(Threads * 2);
    private const int MaximumCacheBytes = 12 * 1024 * 1024;
    private static readonly Dictionary<string, LinkedListNode<(string Key, byte[] Png)>> Cache = new();
    private static readonly LinkedList<(string Key, byte[] Png)> Recent = new();
    private static int cacheBytes;

    /// <summary><paramref name="pixels"/> are premultiplied BGRA.</summary>
    public static Task<byte[]> Encode(byte[] pixels, int width, int height)
    {
        Waiting.Wait();
        return Task.Run(() =>
        {
            try
            {
                var key = $"{width}x{height}:" + Convert.ToHexStringLower(SHA256.HashData(pixels));
                lock (Cache)
                {
                    if (Cache.TryGetValue(key, out var found))
                    {
                        Recent.Remove(found);
                        Recent.AddFirst(found);
                        return found.Value.Png;
                    }
                }
                var png = PngEncoder.Encode(pixels, width, height);
                lock (Cache)
                {
                    if (!Cache.ContainsKey(key) && png.Length <= MaximumCacheBytes)
                    {
                        Cache[key] = Recent.AddFirst((key, png));
                        cacheBytes += png.Length;
                        while (cacheBytes > MaximumCacheBytes && Recent.Last is { } oldest)
                        {
                            Recent.RemoveLast();
                            Cache.Remove(oldest.Value.Key);
                            cacheBytes -= oldest.Value.Png.Length;
                        }
                    }
                }
                return png;
            }
            finally
            {
                Waiting.Release();
            }
        });
    }
}

/// <summary>Supplies decoded images for <c>src</c> values: <c>res:&lt;path&gt;</c>, data URLs and fetched remote URLs.</summary>
public interface IImageSource
{
    CanvasBitmap? Bitmap(string source, int maximumPixels);
}

/// <summary>
/// Paints a recorded element tree on a canvas. It implements exactly the
/// HTML/CSS and SVG subset that Web/preview-engine/src/render/renderer.js
/// writes: absolutely positioned boxes, text, images and inline SVG.
/// </summary>
public sealed partial class DomPainter
{
    private readonly TextEngine text;
    private readonly IImageSource images;
    /// <summary><c>&lt;date&gt;</c> styles the host draws itself with self-updating views; their text is left out of the bitmap.</summary>
    private readonly IReadOnlySet<string> liveDateStyles;
    /// <summary>When true, GIF images are recorded as <see cref="GifSlots"/> instead of being drawn as a still frame.</summary>
    private readonly bool liveGifs;
    private readonly SvgPainter svg;

    public DomPainter(TextEngine text, IImageSource images, IReadOnlySet<string>? liveDateStyles = null, bool liveGifs = false)
    {
        this.text = text;
        this.images = images;
        this.liveDateStyles = liveDateStyles ?? new HashSet<string>();
        this.liveGifs = liveGifs;
        svg = new SvgPainter(text);
    }

    public List<GifSlot> GifSlots { get; } = [];
    /// <summary>Filled when <see cref="LiveMotion"/> is on.</summary>
    public List<MotionSlot> MotionSlots { get; } = [];
    /// <summary>Draw animated views into <see cref="MotionSlots"/> instead of the widget bitmap.</summary>
    public bool LiveMotion { get; set; }
    /// <summary>Filled when <see cref="LiveLists"/> is on.</summary>
    public List<ListSlot> ListSlots { get; } = [];
    /// <summary>Draw the rows of the first <c>&lt;list&gt;</c> into <see cref="ListSlots"/> instead of the widget bitmap.</summary>
    public bool LiveLists { get; set; }
    public List<HitRegion> HitRegions { get; } = [];
    public List<DateSlot> DateSlots { get; } = [];

    /// <summary>Inside a list row or a moving view everything is drawn into the bitmap; nothing is handed to the host.</summary>
    private int staticDepth;
    private float pixelScale = 1f;
    private JsonObject? activeDate;

    private sealed record TextContext(
        string Family = "sans-serif", float Size = 17f, int Weight = 400, float? LineHeight = null,
        string Align = "left", bool Wrap = true, Color Color = default)
    {
        public TextStyle Style() => new(Family, Size, Weight, LineHeight ?? Size * 1.2f);
    }

    private static string? Get(IReadOnlyDictionary<string, string> map, string key) => map.TryGetValue(key, out var value) ? value : null;

    private static JsonObject? ParseObject(string? text) => Json.TryParse(text) as JsonObject;

    private static float Opacity(IReadOnlyDictionary<string, string> style) => Css.Number(Get(style, "opacity")) is { } value ? Math.Clamp(value, 0f, 1f) : 1f;

    /// <summary>Paints <paramref name="root"/> (the widget element). <paramref name="scale"/> converts points to pixels.</summary>
    public void Paint(PaintCanvas canvas, DomNode root, float scale)
    {
        HitRegions.Clear();
        DateSlots.Clear();
        GifSlots.Clear();
        MotionSlots.Clear();
        ListSlots.Clear();
        staticDepth = 0;
        pixelScale = scale;
        canvas.Save();
        canvas.Scale(scale, scale);
        var width = Css.Pixels(Get(root.Style, "width")) ?? 0f;
        var height = Css.Pixels(Get(root.Style, "height")) ?? 0f;
        Element(canvas, root, width, height, new TextContext(Color: Css.Black), new Matrix());
        canvas.Restore();
    }

    private void Element(PaintCanvas canvas, DomNode node, float parentWidth, float parentHeight, TextContext inherited, Matrix toWidget)
    {
        if (node.Tag == "style" || node.Tag.Length == 0) return;
        var style = node.Style;
        if (node.Svg)
        {
            var left = Css.Pixels(Get(style, "left")) ?? 0f;
            var top = Css.Pixels(Get(style, "top")) ?? 0f;
            canvas.Save();
            canvas.Translate(left, top);
            svg.Paint(canvas, node, (Get(style, "color") is { } color ? Css.Color(color) : null) ?? inherited.Color);
            canvas.Restore();
            return;
        }

        if (LiveMotion && staticDepth == 0 && MotionSlots.Count < MaximumMotionSlots)
        {
            var motion = ParseObject(Get(node.Dataset, "swAnimation"));
            if (motion is not null && IsSupportedMotion(motion) && RecordMotion(canvas, node, motion, parentWidth, parentHeight, inherited, toWidget)) return;
        }
        var absolute = Get(style, "position") == "absolute";
        var x = absolute ? Css.Length(Get(style, "left"), parentWidth) ?? 0f : 0f;
        var y = (absolute ? Css.Length(Get(style, "top"), parentHeight) ?? 0f : 0f) + (Css.Pixels(Get(style, "marginTop")) ?? 0f);
        var width = Css.Length(Get(style, "width"), parentWidth) ?? parentWidth;
        var height = Css.Length(Get(style, "height"), parentHeight) ?? parentHeight;
        var bounds = new RectF(0f, 0f, width, height);

        var local = new Matrix(toWidget);
        local.PreTranslate(x, y);
        canvas.Save();
        canvas.Translate(x, y);

        if (Transform(style, width, height) is { } matrix) { canvas.Concat(matrix); local.PreConcat(matrix); }

        var shadow = Css.DropShadow(Get(style, "filter"));
        var opacity = Opacity(style);
        if (shadow is not null)
        {
            PaintWithDropShadow(canvas, node, width, height, inherited, local, shadow, opacity);
            canvas.Restore();
            return;
        }
        var layered = opacity < 1f;
        if (layered) canvas.SaveLayerAlpha(opacity);
        Content(canvas, node, bounds, inherited, local);
        if (layered) canvas.Restore();
        canvas.Restore();
    }

    /// <summary>
    /// The standard deviation, in the units of the radius, of Android's BlurMaskFilter,
    /// so shadows are as soft as in the Android bitmap.
    /// </summary>
    private static float BlurSigma(float radius) => radius > 0f ? 0.57735f * radius + 0.5f : 0f;

    /// <summary>Records the element offscreen so its silhouette can cast a blurred shadow.</summary>
    private void PaintWithDropShadow(PaintCanvas canvas, DomNode node, float width, float height, TextContext inherited, Matrix local, Css.Shadow shadow, float opacity)
    {
        var deviceScale = canvas.DeviceScale();
        canvas.BeginRecord();
        CanvasCommandList layer;
        // Hit regions inside are collected in widget coordinates through `local`.
        try { Content(canvas, node, new RectF(0f, 0f, width, height), inherited, local); }
        finally { layer = canvas.EndRecord(); }

        using (layer)
        using (var blurred = new ShadowEffect { Source = layer, BlurAmount = Math.Min(250f, shadow.Blur > 0f ? Math.Max(0.1f, BlurSigma(shadow.Blur * deviceScale)) : 0f), ShadowColor = shadow.Color })
        {
            var layered = opacity < 1f;
            if (layered) canvas.SaveLayerAlpha(opacity);
            // The offset is given in the element's own units; the recording is in pixels.
            var offset = Vector2.TransformNormal(new Vector2(shadow.Dx, shadow.Dy), canvas.Transform);
            canvas.DrawDeviceImage(blurred, offset);
            canvas.DrawDeviceImage(layer);
            if (layered) canvas.Restore();
        }
    }

    /// <summary>Standard clock hands map to a system clock view; a custom interval is played as rotated frames.</summary>
    private static bool IsSupportedMotion(JsonObject motion) => motion.OptString("kind") switch
    {
        "swing" => true,
        "clock" => motion.OptString("type") is "clockSecond" or "clockMinute" or "clockMiniute" or "clockHour" or "clock",
        _ => false,
    };

    /// <summary>Draws into a new transparent bitmap and returns its premultiplied BGRA pixels.</summary>
    private static byte[] DrawBitmap(ICanvasResourceCreator device, int pixelWidth, int pixelHeight, Action<PaintCanvas> draw)
    {
        using var target = new CanvasRenderTarget(device, pixelWidth, pixelHeight, 96f);
        var session = target.CreateDrawingSession();
        session.Clear(Css.Transparent);
        using (var layer = new PaintCanvas(device, session)) draw(layer);
        return target.GetPixelBytes();
    }

    /// <summary>Draws <paramref name="node"/> at rest (no animation transform) into a square bitmap centred on its anchor.</summary>
    private bool RecordMotion(PaintCanvas canvas, DomNode node, JsonObject motion, float parentWidth, float parentHeight, TextContext inherited, Matrix toWidget)
    {
        var style = node.Style;
        var x = Css.Length(Get(style, "left"), parentWidth) ?? 0f;
        var y = Css.Length(Get(style, "top"), parentHeight) ?? 0f;
        var width = Css.Length(Get(style, "width"), parentWidth) ?? parentWidth;
        var height = Css.Length(Get(style, "height"), parentHeight) ?? parentHeight;
        if (width <= 0f || height <= 0f) return false;
        var origin = Get(style, "transformOrigin")?.Split(' ');
        var clock = motion.OptString("kind") == "clock";
        var anchorX = clock ? Css.Length(origin?.ElementAtOrDefault(0), width) ?? width / 2f : width / 2f;
        var anchorY = clock ? Css.Length(origin?.ElementAtOrDefault(1), height) ?? height / 2f : height / 2f;
        // A rotating view needs room for every angle; a swinging one only for itself.
        (float X, float Y)[] corners = [(0f, 0f), (width, 0f), (0f, height), (width, height)];
        var reach = clock ? corners.Max(corner => MathF.Sqrt((corner.X - anchorX) * (corner.X - anchorX) + (corner.Y - anchorY) * (corner.Y - anchorY))) : Math.Max(width, height) / 2f;
        var side = reach * 2f + 4f;
        var pixels = (int)MathF.Ceiling(side * pixelScale);
        if (pixels <= 0 || pixels > 1024) return false;
        // Tap targets inside a moving view are not tracked; the view is drawn only.
        var saved = new List<HitRegion>(HitRegions);
        var opacity = Opacity(style);
        byte[] bitmap;
        staticDepth += 1;
        try
        {
            bitmap = DrawBitmap(canvas.Device, pixels, pixels, layer =>
            {
                layer.Scale(pixelScale, pixelScale);
                layer.Translate(side / 2f - anchorX, side / 2f - anchorY);
                if (opacity < 1f) layer.SaveLayerAlpha(opacity);
                Content(layer, node, new RectF(0f, 0f, width, height), inherited, new Matrix());
                if (opacity < 1f) layer.Restore();
            });
        }
        finally { staticDepth -= 1; }
        HitRegions.Clear(); HitRegions.AddRange(saved);
        var point = toWidget.MapPoint(x + anchorX, y + anchorY);
        MotionSlots.Add(new MotionSlot(motion, point, bitmap, pixels, side));
        return true;
    }

    private void Content(PaintCanvas canvas, DomNode node, RectF bounds, TextContext inherited, Matrix toWidget)
    {
        var style = node.Style;
        var width = bounds.Width;
        var height = bounds.Height;
        var radius = Radius(Get(style, "borderRadius"), width, height);
        using var outline = Outline(canvas.Device, style, bounds, radius);

        // An outer shadow lies under the box; an inset one is drawn over its background.
        var boxShadow = Css.BoxShadow(Get(style, "boxShadow"));
        if (boxShadow is not null && !boxShadow.Inset) BoxShadow(canvas, boxShadow, bounds, radius);
        Background(canvas, style, bounds, outline);
        if (boxShadow is not null && boxShadow.Inset) BoxShadow(canvas, boxShadow, bounds, radius);
        if (Get(style, "border") is { } border && border.Contains("dashed"))
        {
            var color = Css.Color(border[(border.IndexOf("dashed", StringComparison.Ordinal) + "dashed".Length)..].Trim()) ?? Css.Gray;
            using var dashes = new CanvasStrokeStyle { CustomDashStyle = [3f, 3f] };
            canvas.Session.DrawRectangle(new Rect(0.5f, 0.5f, Math.Max(0f, width - 1f), Math.Max(0f, height - 1f)), color, 1f, dashes);
        }

        if (ParseObject(Get(node.Dataset, "swInteraction")) is { } interaction) HitRegions.Add(new HitRegion(toWidget.MapRect(bounds), interaction));

        var clips = Get(style, "overflow") == "hidden" || Get(style, "clipPath") is not null;
        if (clips) { canvas.Save(); canvas.ClipPath(outline); }

        var context = MakeTextContext(style, inherited);
        var previousDate = activeDate;
        if (Get(node.Dataset, "swDate") is { } description)
        {
            var parsed = ParseObject(description);
            var dateStyle = parsed?.OptString("style");
            // A clock view shows the current time, so only a <date> of "now" may use it.
            if (parsed is not null && staticDepth == 0 && dateStyle is not null && liveDateStyles.Contains(dateStyle) && (dateStyle != "time" || parsed.OptBoolean("live"))) activeDate = parsed;
        }
        var date = activeDate;
        if (date is not null && style.ContainsKey("fontSize"))
        {
            // The text element of a live <date>: the host places a clock or timer here.
            var textChild = node.Children.FirstOrDefault(child => child.Text is not null);
            var color = (textChild is not null && Get(textChild.Style, "color") is { } childColor ? Css.Color(childColor) : null) ?? context.Color;
            DateSlots.Add(new DateSlot(toWidget.MapRect(bounds), date, context.Style(), color, context.Align));
            activeDate = previousDate;
            if (clips) canvas.Restore();
            return;
        }
        if (node.Tag == "img")
        {
            var source = Get(node.Attributes, "src") ?? "";
            if (liveGifs && staticDepth == 0 && source.StartsWith("res:", StringComparison.Ordinal) && source.EndsWith(".gif", StringComparison.OrdinalIgnoreCase) && Get(node.Style, "objectFit") == "contain")
                GifSlots.Add(new GifSlot(toWidget.MapRect(bounds), source));
            else Image(canvas, node, bounds);
        }
        else if (node.Text is not null && node.Children.Count == 0) DrawText(canvas, node.Text, style, bounds, context);
        var list = Get(node.Dataset, "swList");
        if (list is null)
        {
            foreach (var child in node.Children) Element(canvas, child, width, height, context, toWidget);
        }
        else if (LiveLists && staticDepth == 0 && ListSlots.Count == 0 && toWidget.IsTranslation && width >= 1f && height >= 1f)
        {
            RecordList(canvas, node, list, bounds, context, toWidget);
        }
        else
        {
            // Drawn in place: the rows that fit are visible, the rest are cut off, and so are their tap targets.
            var firstHit = HitRegions.Count;
            var visible = toWidget.MapRect(bounds);
            canvas.Save();
            canvas.ClipRect(bounds);
            foreach (var child in node.Children) Element(canvas, child, width, height, context, toWidget);
            canvas.Restore();
            var inside = new List<HitRegion>();
            for (var index = firstHit; index < HitRegions.Count; index++)
                if (HitRegions[index].Bounds.Intersect(visible) is { } shown) inside.Add(HitRegions[index] with { Bounds = shown });
            HitRegions.RemoveRange(firstHit, HitRegions.Count - firstHit);
            HitRegions.AddRange(inside);
        }
        activeDate = previousDate;
        if (clips) canvas.Restore();
    }

    /// <summary>
    /// Draws the rows of <paramref name="node"/> as a few images, each holding consecutive whole
    /// rows. A row reaches down to the top of the next one, so spacing is part
    /// of it. Several rows share an image because a widget update has room for
    /// a limited number of small images but passes larger ones by reference.
    /// </summary>
    private void RecordList(PaintCanvas canvas, DomNode node, string description, RectF bounds, TextContext context, Matrix toWidget)
    {
        var mapped = toWidget.MapRect(bounds);
        var rows = node.Children.Where(child => child.Dataset.ContainsKey("swListRow")).ToList();
        var tops = rows.Select(row => Css.Pixels(Get(row.Style, "top")) ?? 0f).ToList();
        var contentHeight = ParseObject(description) is { } parsed ? (float)parsed.OptDouble("contentHeight", 0.0) : 0f;
        var bottoms = new List<float>(rows.Count);
        for (var index = 0; index < rows.Count; index++)
            bottoms.Add(index + 1 < rows.Count ? tops[index + 1] : Math.Max(contentHeight, tops[index] + (Css.Pixels(Get(rows[index].Style, "height")) ?? 0f)));
        var width = bounds.Width;
        var pixelWidth = Math.Max(1, (int)MathF.Ceiling(width * pixelScale));
        var saved = new List<HitRegion>(HitRegions);
        var result = new List<ListPiece>();
        var pending = new List<PendingPiece>();
        var bytes = 0L;
        var truncated = false;
        staticDepth += 1;
        try
        {
            var first = 0;
            while (first < rows.Count)
            {
                // Take rows until the piece is tall enough, without passing the tallest image a view can show.
                var last = first;
                while (last + 1 < rows.Count && bottoms[last] - tops[first] < MinimumPiecePoints &&
                    MathF.Ceiling((bottoms[last + 1] - tops[first]) * pixelScale) <= MaximumPiecePixels) last += 1;
                var top = tops[first];
                var height = Math.Max(1f, bottoms[last] - top);
                var pixelHeight = (int)MathF.Ceiling(height * pixelScale);
                if (pixelHeight > MaximumPiecePixels) { truncated = true; break; }
                HitRegions.Clear();
                var from = first;
                var pixels = DrawBitmap(canvas.Device, pixelWidth, pixelHeight, layer =>
                {
                    layer.Scale(pixelScale, pixelScale);
                    layer.Translate(0f, -top);
                    for (var index = from; index <= last; index++) Element(layer, rows[index], width, Math.Max(contentHeight, bounds.Height), context, Matrix.Translation(0f, -top));
                });
                pending.Add(new PendingPiece(PieceEncoder.Encode(pixels, pixelWidth, pixelHeight), height, HitRegions.ToList()));
                first = last + 1;
            }
            foreach (var piece in pending)
            {
                var encoded = piece.Png.GetAwaiter().GetResult();
                if (truncated || bytes + encoded.Length > MaximumListBytes) { truncated = true; continue; }
                bytes += encoded.Length;
                result.Add(new ListPiece(encoded, piece.Height, piece.HitRegions));
            }
        }
        finally
        {
            staticDepth -= 1;
            HitRegions.Clear(); HitRegions.AddRange(saved);
        }
        ListSlots.Add(new ListSlot(mapped, result, truncated));
    }

    private static TextContext MakeTextContext(IReadOnlyDictionary<string, string> style, TextContext inherited)
    {
        if (!style.ContainsKey("fontFamily") && !style.ContainsKey("fontSize") && !style.ContainsKey("fontWeight") && !style.ContainsKey("lineHeight") &&
            !style.ContainsKey("textAlign") && !style.ContainsKey("whiteSpace") && !style.ContainsKey("color")) return inherited;
        return new TextContext(
            Family: Get(style, "fontFamily") ?? inherited.Family,
            Size: Css.Pixels(Get(style, "fontSize")) ?? inherited.Size,
            Weight: int.TryParse(Get(style, "fontWeight"), out var weight) ? weight : inherited.Weight,
            LineHeight: Css.Pixels(Get(style, "lineHeight")) ?? inherited.LineHeight,
            Align: Get(style, "textAlign") ?? inherited.Align,
            Wrap: Get(style, "whiteSpace") is { } whiteSpace ? whiteSpace != "pre" : inherited.Wrap,
            Color: (Get(style, "color") is { } color ? color == "transparent" ? Css.Transparent : Css.Color(color) : null) ?? inherited.Color);
    }

    private void DrawText(PaintCanvas canvas, string content, IReadOnlyDictionary<string, string> style, RectF bounds, TextContext context)
    {
        if (content.Length == 0) return;
        var textStyle = context.Style();
        using var gradient = Get(style, "backgroundClip") == "text" || Get(style, "webkitBackgroundClip") == "text"
            ? Css.Gradient(canvas.Device, Get(style, "backgroundImage"), bounds.Width, bounds.Height, default, pixelScale) : null;
        if (gradient is null && context.Color.A == 0) return;
        using var solid = gradient is null ? new Microsoft.Graphics.Canvas.Brushes.CanvasSolidColorBrush(canvas.Device, context.Color) : null;
        var brush = gradient?.Brush ?? solid!;
        var lines = text.Lines(content, textStyle, context.Wrap ? bounds.Width : null);
        var baseline = text.Baseline(textStyle);
        for (var index = 0; index < lines.Count; index++)
        {
            var line = lines[index];
            var x = context.Align switch
            {
                "center" => (bounds.Width - line.Width) / 2f,
                "right" => bounds.Width - line.Width,
                _ => 0f,
            };
            text.Draw(canvas.Session, line.Text, textStyle, x, baseline + index * textStyle.Leading, brush);
        }
    }

    private void Image(PaintCanvas canvas, DomNode node, RectF bounds)
    {
        if (Get(node.Attributes, "src") is not { } source) return;
        var scale = canvas.Transform.M11 is > 0f and var value ? value : 1f;
        var pixels = Math.Max(1, (int)Math.Min(int.MaxValue, (double)bounds.Width * scale * bounds.Height * scale));
        var bitmap = images.Bitmap(source, pixels);
        if (bitmap is null) return;
        var destination = bounds;
        var fit = Get(node.Style, "objectFit") ?? "fill";
        var size = bitmap.SizeInPixels;
        if (fit is "contain" or "cover")
        {
            var ratio = (float)size.Width / Math.Max(1u, size.Height);
            var boxRatio = bounds.Width / Math.Max(0.0001f, bounds.Height);
            var fitWidth = (fit == "contain") == (ratio > boxRatio) ? bounds.Width : bounds.Height * ratio;
            var fitHeight = fitWidth / ratio;
            destination = new RectF((bounds.Width - fitWidth) / 2f, (bounds.Height - fitHeight) / 2f, (bounds.Width + fitWidth) / 2f, (bounds.Height + fitHeight) / 2f);
        }
        canvas.Save();
        canvas.ClipRect(bounds);
        canvas.Session.DrawImage(bitmap, destination.ToRect(), new Rect(0, 0, size.Width, size.Height), 1f, CanvasImageInterpolation.HighQualityCubic);
        canvas.Restore();
    }

    private void Background(PaintCanvas canvas, IReadOnlyDictionary<string, string> style, RectF bounds, CanvasGeometry outline)
    {
        var color = Css.Color(Get(style, "backgroundColor"));
        if (color is { A: not 0 } solidColor) canvas.Session.FillGeometry(outline, solidColor);
        var image = Get(style, "backgroundImage");
        if (image is not null && image != "none" && Get(style, "backgroundClip") != "text" && Get(style, "webkitBackgroundClip") != "text")
        {
            // Shapes paint a gradient sized for the whole view behind a smaller outline.
            var size = Get(style, "backgroundSize")?.Split(' ').Select(Css.Pixels).OfType<float>().ToList();
            var position = Get(style, "backgroundPosition")?.Split(' ').Select(Css.Pixels).OfType<float>().ToList();
            var width = size is { Count: > 0 } ? size[0] : bounds.Width;
            var height = size is { Count: > 1 } ? size[1] : bounds.Height;
            var offset = position is { Count: 2 } ? new Vector2(position[0], position[1]) : default;
            using var gradient = Css.Gradient(canvas.Device, image, width, height, offset, pixelScale);
            if (gradient is not null) canvas.Session.FillGeometry(outline, gradient.Brush);
            else if (Css.Color(image) is { } solid) canvas.Session.FillGeometry(outline, solid);
        }
    }

    private static void BoxShadow(PaintCanvas canvas, Css.BoxShadowValue shadow, RectF bounds, float radius)
    {
        if (shadow.Inset)
        {
            // `inset 0 0 0 <spread> color` is the renderer's one-point inner border.
            var width = shadow.Spread > 0f ? shadow.Spread : 1f;
            var inset = width / 2f;
            var corner = Math.Max(0f, radius - inset);
            canvas.Session.DrawRoundedRectangle(new Rect(inset, inset, Math.Max(0f, bounds.Width - width), Math.Max(0f, bounds.Height - width)), corner, corner, shadow.Color, width);
            return;
        }
        // Outer shadow under an opaque shape: draw the blurred shape first.
        canvas.Save();
        canvas.Translate(shadow.Dx, shadow.Dy);
        if (shadow.Blur > 0f)
        {
            var sigma = BlurSigma(shadow.Blur / 2f + 0.1f) * canvas.DeviceScale();
            canvas.BeginRecord();
            canvas.Session.FillRoundedRectangle(bounds.ToRect(), radius, radius, shadow.Color);
            using var shape = canvas.EndRecord();
            using var blurred = new GaussianBlurEffect { Source = shape, BlurAmount = Math.Min(250f, sigma), BorderMode = EffectBorderMode.Soft };
            canvas.DrawDeviceImage(blurred);
        }
        else canvas.Session.FillRoundedRectangle(bounds.ToRect(), radius, radius, shadow.Color);
        canvas.Restore();
    }

    private static float Radius(string? value, float width, float height)
    {
        var trimmed = value?.Trim();
        if (trimmed is null) return 0f;
        if (trimmed.EndsWith('%')) return Math.Min(width, height) * (Css.Number(trimmed[..^1]) ?? 0f) / 100f;
        return Math.Max(0f, Math.Min(Css.Pixels(trimmed) ?? 0f, Math.Min(width, height) / 2f));
    }

    private static CanvasGeometry Outline(ICanvasResourceCreator device, IReadOnlyDictionary<string, string> style, RectF bounds, float radius)
    {
        var clip = Get(style, "clipPath");
        var width = Math.Max(0f, bounds.Width);
        var height = Math.Max(0f, bounds.Height);
        if (clip is not null && clip.StartsWith("circle", StringComparison.Ordinal)) return CanvasGeometry.CreateCircle(device, bounds.CenterX, bounds.CenterY, Math.Min(width, height) / 2f);
        if (clip is not null && clip.StartsWith("ellipse", StringComparison.Ordinal)) return CanvasGeometry.CreateEllipse(device, bounds.CenterX, bounds.CenterY, width / 2f, height / 2f);
        if (clip is not null && clip.StartsWith("inset", StringComparison.Ordinal))
        {
            var round = Math.Min(width, height) / 2f;
            return CanvasGeometry.CreateRoundedRectangle(device, bounds.Left, bounds.Top, width, height, round, round);
        }
        if (Get(style, "borderRadius")?.Trim().EndsWith('%') == true) return CanvasGeometry.CreateEllipse(device, bounds.CenterX, bounds.CenterY, width / 2f, height / 2f);
        if (radius > 0f) return CanvasGeometry.CreateRoundedRectangle(device, bounds.Left, bounds.Top, width, height, radius, radius);
        return CanvasGeometry.CreateRectangle(device, bounds.Left, bounds.Top, width, height);
    }

    /// <summary>CSS transform list with its transform-origin, as a matrix in element coordinates.</summary>
    private static Matrix? Transform(IReadOnlyDictionary<string, string> style, float width, float height)
    {
        if (Get(style, "transform") is not { } value) return null;
        var origin = Get(style, "transformOrigin")?.Split(' ');
        var originX = Css.Length(origin?.ElementAtOrDefault(0), width) ?? width / 2f;
        var originY = Css.Length(origin?.ElementAtOrDefault(1), height) ?? height / 2f;
        var matrix = new Matrix();
        var perspective = 0f;
        foreach (Match match in TransformFunction().Matches(value))
        {
            var arguments = match.Groups[2].Value.Split(',').Select(argument => argument.Trim()).ToArray();
            Matrix step;
            switch (match.Groups[1].Value)
            {
                case "rotate": step = Matrix.Rotation(Css.Number(Degrees(arguments[0])) ?? 0f); break;
                case "translateX": step = Matrix.Translation(Css.Pixels(arguments[0]) ?? 0f, 0f); break;
                case "translateY": step = Matrix.Translation(0f, Css.Pixels(arguments[0]) ?? 0f); break;
                case "translate": step = Matrix.Translation(Css.Pixels(arguments[0]) ?? 0f, Css.Pixels(arguments.ElementAtOrDefault(1)) ?? 0f); break;
                case "scale":
                {
                    var sx = Css.Number(arguments[0]) ?? 1f;
                    step = Matrix.Scaling(sx, Css.Number(arguments.ElementAtOrDefault(1)) ?? sx);
                    break;
                }
                case "perspective": perspective = Css.Pixels(arguments[0]) ?? 0f; continue;
                case "rotate3d":
                {
                    if (arguments.Length < 4) continue;
                    var axisX = Css.Number(arguments[0]) ?? 0f;
                    var axisY = Css.Number(arguments[1]) ?? 0f;
                    var axisZ = Css.Number(arguments[2]) ?? 0f;
                    var degrees = Css.Number(Degrees(arguments[3])) ?? 0f;
                    var length = MathF.Sqrt(axisX * axisX + axisY * axisY + axisZ * axisZ);
                    if (length == 0f) continue;
                    // Android approximates this with a Camera turned about fixed axes. Here it is the
                    // CSS rotate3d() matrix itself, applied to the element's plane (z = 0) and
                    // followed by the perspective division w = 1 - z / distance.
                    float ux = axisX / length, uy = axisY / length, uz = axisZ / length;
                    var half = degrees * MathF.PI / 360f;
                    var sc = MathF.Sin(half) * MathF.Cos(half);
                    var sq = MathF.Sin(half) * MathF.Sin(half);
                    var r00 = 1f - 2f * (uy * uy + uz * uz) * sq;
                    var r01 = 2f * (ux * uy * sq - uz * sc);
                    var r10 = 2f * (ux * uy * sq + uz * sc);
                    var r11 = 1f - 2f * (ux * ux + uz * uz) * sq;
                    var r20 = 2f * (ux * uz * sq - uy * sc);
                    var r21 = 2f * (uy * uz * sq + ux * sc);
                    var depth = perspective > 0f ? 1f / perspective : 0f;
                    step = Matrix.Projective(r00, r01, 0f, r10, r11, 0f, -r20 * depth, -r21 * depth, 1f);
                    break;
                }
                default: continue;
            }
            matrix.PreConcat(step);
        }
        matrix.PreTranslate(-originX, -originY);
        matrix.PostTranslate(originX, originY);
        return matrix;
    }

    private static string Degrees(string text) => text.EndsWith("deg", StringComparison.Ordinal) ? text[..^3] : text;

    [GeneratedRegex(@"([a-zA-Z0-9]+)\(([^)]*)\)")]
    private static partial Regex TransformFunction();

    private const int MaximumMotionSlots = 8;
    /// <summary>A piece holds whole rows until it is at least this tall.</summary>
    private const float MinimumPiecePoints = 160f;
    /// <summary>One piece is one image; taller than this it could not be uploaded as a texture.</summary>
    private const int MaximumPiecePixels = 2048;
    /// <summary>All encoded pieces of one list together.</summary>
    private const long MaximumListBytes = 1536L * 1024;
}
