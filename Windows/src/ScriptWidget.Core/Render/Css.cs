using System.Globalization;
using System.Numerics;
using System.Text.RegularExpressions;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Brushes;
using Windows.Graphics.DirectX;
using Windows.UI;

namespace ScriptWidget.Core.Render;

/// <summary>A gradient brush together with the bitmap it may be drawn from.</summary>
public sealed class GradientBrush(ICanvasBrush brush, CanvasBitmap? bitmap = null) : IDisposable
{
    public ICanvasBrush Brush { get; } = brush;

    public void Dispose()
    {
        (Brush as IDisposable)?.Dispose();
        bitmap?.Dispose();
    }
}

/// <summary>Parsers for the small CSS subset the shared renderer writes.</summary>
public static partial class Css
{
    public static readonly Color Black = Windows.UI.Color.FromArgb(255, 0, 0, 0);
    public static readonly Color White = Windows.UI.Color.FromArgb(255, 255, 255, 255);
    public static readonly Color Transparent = Windows.UI.Color.FromArgb(0, 0, 0, 0);
    public static readonly Color Gray = Windows.UI.Color.FromArgb(255, 136, 136, 136);

    private static readonly Dictionary<string, Color> Named = new()
    {
        ["white"] = White, ["black"] = Black, ["transparent"] = Transparent, ["none"] = Transparent,
        ["red"] = Windows.UI.Color.FromArgb(255, 255, 0, 0), ["green"] = Windows.UI.Color.FromArgb(255, 0, 128, 0), ["blue"] = Windows.UI.Color.FromArgb(255, 0, 0, 255), ["gray"] = Gray, ["grey"] = Gray,
    };

    /// <summary>A number as Kotlin's <c>toFloatOrNull</c> reads it: null when the text is not one.</summary>
    public static float? Number(string? text)
    {
        if (string.IsNullOrEmpty(text)) return null;
        return float.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var value) ? value : null;
    }

    private static string RemoveSuffix(string text, string suffix) => text.EndsWith(suffix, StringComparison.Ordinal) ? text[..^suffix.Length] : text;

    /// <summary>Parses rgba()/rgb()/#hex/named colors. Returns null for <c>none</c>, empty or unknown values.</summary>
    public static Color? Color(string? value)
    {
        var text = value?.Trim().ToLowerInvariant();
        if (text is null) return null;
        if (text.Length == 0 || text == "none") return null;
        if (Named.TryGetValue(text, out var named)) return named;
        if (text.StartsWith("rgb", StringComparison.Ordinal))
        {
            var open = text.IndexOf('(');
            var inner = open < 0 ? text : text[(open + 1)..];
            var close = inner.IndexOf(')');
            if (close >= 0) inner = inner[..close];
            var parts = inner.Split(',', '/').Select(part => part.Trim()).ToArray();
            if (parts.Length < 3) return null;
            if (Number(parts[0]) is not { } red || Number(parts[1]) is not { } green || Number(parts[2]) is not { } blue) return null;
            var alpha = (parts.Length > 3 ? Number(parts[3]) : null) ?? 1f;
            return Windows.UI.Color.FromArgb((byte)(Math.Clamp(alpha, 0f, 1f) * 255f + 0.5f), Channel(red), Channel(green), Channel(blue));
        }
        if (text.StartsWith('#'))
        {
            var hex = text[1..];
            if (!hex.All(Uri.IsHexDigit)) return null;
            switch (hex.Length)
            {
                case 3:
                    return Windows.UI.Color.FromArgb(255, (byte)(Convert.ToInt32(hex[..1], 16) * 17), (byte)(Convert.ToInt32(hex[1..2], 16) * 17), (byte)(Convert.ToInt32(hex[2..3], 16) * 17));
                case 6:
                {
                    var rgb = Convert.ToUInt32(hex, 16);
                    return Windows.UI.Color.FromArgb(255, (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb);
                }
                case 8:
                {
                    var rgba = Convert.ToUInt32(hex, 16);
                    return Windows.UI.Color.FromArgb((byte)rgba, (byte)(rgba >> 24), (byte)(rgba >> 16), (byte)(rgba >> 8));
                }
                default: return null;
            }
        }
        return null;
    }

    private static byte Channel(float value) => (byte)Math.Clamp((int)value, 0, 255);

    /// <summary><c>12px</c>, <c>12</c> or a bare number. Returns null for auto, percentages and keywords.</summary>
    public static float? Pixels(string? value)
    {
        var text = value?.Trim();
        if (text is null) return null;
        if (text.Length == 0 || text.EndsWith('%')) return null;
        return Number(RemoveSuffix(text, "px"));
    }

    /// <summary>A length that may be a percentage of <paramref name="basis"/>.</summary>
    public static float? Length(string? value, float basis)
    {
        var text = value?.Trim();
        if (text is null) return null;
        if (text.EndsWith('%')) return Number(text[..^1]) is { } percent ? percent / 100f * basis : null;
        return Pixels(text);
    }

    /// <summary>Splits on commas that are not inside parentheses.</summary>
    public static List<string> SplitTopLevel(string value, char separator = ',')
    {
        var parts = new List<string>();
        var depth = 0;
        var start = 0;
        for (var index = 0; index < value.Length; index++)
        {
            var character = value[index];
            if (character == '(') depth += 1;
            else if (character == ')') depth -= 1;
            else if (character == separator && depth == 0) { parts.Add(value[start..index].Trim()); start = index + 1; }
        }
        parts.Add(value[start..].Trim());
        return parts.Where(part => part.Length > 0).ToList();
    }

    private sealed record Stop(Color Color, float Position);

    /// <summary><c>&lt;color&gt; &lt;position&gt;</c> where position is in px or deg.</summary>
    private static Stop? ParseStop(string text)
    {
        text = text.Trim();
        var split = text.LastIndexOf(' ');
        if (split <= 0) return null;
        if (Color(text[..split]) is not { } color) return null;
        if (Number(RemoveSuffix(RemoveSuffix(text[(split + 1)..], "px"), "deg")) is not { } position) return null;
        return new Stop(color, position);
    }

    /// <summary>
    /// Brush for a CSS gradient painted in a <paramref name="width"/> x <paramref name="height"/> box, or null
    /// when <paramref name="value"/> is not a gradient this renderer emits. <paramref name="offset"/> moves the
    /// box; <paramref name="pixelScale"/> is the resolution a conic gradient is drawn at.
    /// </summary>
    public static GradientBrush? Gradient(ICanvasResourceCreator device, string? value, float width, float height, Vector2 offset = default, float pixelScale = 1f)
    {
        var text = value?.Trim();
        if (text is null) return null;
        var open = text.IndexOf('(');
        if (open < 0 || !text.EndsWith(')')) return null;
        var kind = text[..open];
        var arguments = SplitTopLevel(text[(open + 1)..^1]);
        if (arguments.Count == 0) return null;
        var move = Matrix3x2.CreateTranslation(offset);
        switch (kind)
        {
            case "linear-gradient":
            {
                var angled = arguments[0].EndsWith("deg", StringComparison.Ordinal);
                var degrees = angled ? Number(RemoveSuffix(arguments[0], "deg")) ?? 180f : 180f;
                var stopTexts = angled ? arguments.Skip(1).ToList() : arguments;
                var parsed = stopTexts.Select(ParseStop).ToList();
                var radians = degrees * Math.PI / 180.0;
                var directionX = (float)Math.Sin(radians);
                var directionY = -(float)Math.Cos(radians);
                var lineLength = Math.Abs(width * directionX) + Math.Abs(height * directionY);
                // Stops without positions (a solid two-stop fallback) span the gradient line.
                List<Stop> stops;
                if (parsed.All(stop => stop is not null)) stops = parsed.OfType<Stop>().ToList();
                else
                {
                    stops = [];
                    for (var index = 0; index < stopTexts.Count; index++)
                        if (Color(stopTexts[index]) is { } color) stops.Add(new Stop(color, lineLength * index / Math.Max(1, stopTexts.Count - 1)));
                }
                if (stops.Count < 2) return null;
                var first = stops[0].Position;
                var last = stops[^1].Position;
                if (last - first <= 0f) return null;
                Vector2 Point(float distance) => new(width / 2f + (distance - lineLength / 2f) * directionX, height / 2f + (distance - lineLength / 2f) * directionY);
                return new GradientBrush(new CanvasLinearGradientBrush(device, GradientStops(stops, Monotonic(stops.Select(stop => (stop.Position - first) / (last - first)))))
                {
                    StartPoint = Point(first), EndPoint = Point(last), Transform = move,
                });
            }
            case "radial-gradient":
            {
                if (CenterOf(arguments[0]) is not { } center) return null;
                var stops = arguments.Skip(1).Select(ParseStop).OfType<Stop>().ToList();
                if (stops.Count < 2) return null;
                var radius = stops[^1].Position;
                if (radius <= 0f) return null;
                return new GradientBrush(new CanvasRadialGradientBrush(device, GradientStops(stops, Monotonic(stops.Select(stop => Math.Clamp(stop.Position / radius, 0f, 1f)))))
                {
                    Center = center, RadiusX = radius, RadiusY = radius, Transform = move,
                });
            }
            case "conic-gradient":
            {
                if (CenterOf(arguments[0]) is not { } center) return null;
                var match = ConicFrom().Match(arguments[0]);
                var from = (match.Success ? Number(match.Groups[1].Value) : null) ?? 0f;
                var stops = arguments.Skip(1).Select(ParseStop).OfType<Stop>().ToList();
                if (stops.Count < 2) return null;
                return Conic(device, center, from, stops, Monotonic(stops.Select(stop => Math.Clamp(stop.Position / 360f, 0f, 1f))), width, height, move, pixelScale);
            }
        }
        return null;
    }

    private static CanvasGradientStop[] GradientStops(List<Stop> stops, float[] positions)
    {
        var result = new CanvasGradientStop[stops.Count];
        for (var index = 0; index < result.Length; index++) result[index] = new CanvasGradientStop { Color = stops[index].Color, Position = positions[index] };
        return result;
    }

    /// <summary>
    /// Direct2D has no sweep gradient, so the box is filled pixel by pixel and used as an image brush.
    /// CSS measures conic angles clockwise from 12 o'clock.
    /// </summary>
    private static GradientBrush? Conic(ICanvasResourceCreator device, Vector2 center, float from, List<Stop> stops, float[] positions, float width, float height, Matrix3x2 move, float pixelScale)
    {
        if (!(width > 0f) || !(height > 0f)) return null;
        var scale = Math.Max(0.01f, pixelScale);
        // Bounded like every other image this renderer makes.
        var largest = Math.Max(width, height) * scale;
        if (largest > MaximumConicPixels) scale *= MaximumConicPixels / largest;
        var pixelWidth = Math.Max(1, (int)Math.Ceiling(width * scale));
        var pixelHeight = Math.Max(1, (int)Math.Ceiling(height * scale));
        var pixels = new byte[pixelWidth * pixelHeight * 4];
        var at = 0;
        for (var row = 0; row < pixelHeight; row++)
        {
            var dy = (row + 0.5f) / scale - center.Y;
            for (var column = 0; column < pixelWidth; column++)
            {
                var dx = (column + 0.5f) / scale - center.X;
                var degrees = MathF.Atan2(dx, -dy) * 180f / MathF.PI - from;
                degrees %= 360f;
                if (degrees < 0f) degrees += 360f;
                var position = degrees / 360f;
                var index = 0;
                while (index + 1 < positions.Length && positions[index + 1] <= position) index += 1;
                float alpha, red, green, blue;
                var low = stops[index].Color;
                if (position <= positions[0] || index + 1 >= positions.Length) { low = position <= positions[0] ? stops[0].Color : stops[^1].Color; alpha = low.A; red = low.R; green = low.G; blue = low.B; }
                else
                {
                    var high = stops[index + 1].Color;
                    var span = positions[index + 1] - positions[index];
                    var amount = span <= 0f ? 0f : (position - positions[index]) / span;
                    alpha = low.A + (high.A - low.A) * amount;
                    red = low.R + (high.R - low.R) * amount;
                    green = low.G + (high.G - low.G) * amount;
                    blue = low.B + (high.B - low.B) * amount;
                }
                var coverage = alpha / 255f;
                pixels[at++] = (byte)(blue * coverage + 0.5f);
                pixels[at++] = (byte)(green * coverage + 0.5f);
                pixels[at++] = (byte)(red * coverage + 0.5f);
                pixels[at++] = (byte)(alpha + 0.5f);
            }
        }
        var bitmap = CanvasBitmap.CreateFromBytes(device, pixels, pixelWidth, pixelHeight, DirectXPixelFormat.B8G8R8A8UIntNormalized, 96f, CanvasAlphaMode.Premultiplied);
        var brush = new CanvasImageBrush(device, bitmap)
        {
            Transform = Matrix3x2.CreateScale(1f / scale) * move,
            ExtendX = CanvasEdgeBehavior.Clamp, ExtendY = CanvasEdgeBehavior.Clamp, Interpolation = CanvasImageInterpolation.Linear,
        };
        return new GradientBrush(brush, bitmap);
    }

    private const float MaximumConicPixels = 1024f;

    private static Vector2? CenterOf(string argument)
    {
        var match = GradientCenter().Match(argument);
        if (!match.Success) return null;
        if (Number(match.Groups[1].Value) is not { } x || Number(match.Groups[2].Value) is not { } y) return null;
        return new Vector2(x, y);
    }

    /// <summary>Direct2D, like Android, wants non-decreasing positions.</summary>
    private static float[] Monotonic(IEnumerable<float> positions)
    {
        var result = positions.ToArray();
        var previous = 0f;
        for (var index = 0; index < result.Length; index++)
        {
            var current = float.IsNaN(result[index]) ? previous : Math.Max(previous, result[index]);
            result[index] = current;
            previous = current;
        }
        return result;
    }

    public sealed record Shadow(float Dx, float Dy, float Blur, Color Color);

    /// <summary><c>drop-shadow(Xpx Ypx Rpx color)</c> from a filter list.</summary>
    public static Shadow? DropShadow(string? filter)
    {
        if (filter is null) return null;
        var match = DropShadowPattern().Match(filter);
        if (!match.Success) return null;
        if (Color(match.Groups[4].Value) is not { } color) return null;
        if (Number(match.Groups[1].Value) is not { } dx || Number(match.Groups[2].Value) is not { } dy || Number(match.Groups[3].Value) is not { } blur) return null;
        return new Shadow(dx, dy, blur, color);
    }

    public sealed record BoxShadowValue(bool Inset, float Dx, float Dy, float Blur, float Spread, Color Color);

    /// <summary><c>[inset] X Y blur [spread] color</c>.</summary>
    public static BoxShadowValue? BoxShadow(string? value)
    {
        var text = value?.Trim();
        if (text is null) return null;
        var inset = text.StartsWith("inset", StringComparison.Ordinal);
        if (inset) text = text["inset".Length..].Trim();
        var colorStart = -1;
        for (var index = 0; index < text.Length; index++)
            if (char.IsLetter(text[index]) && text[index] != 'p' && text[index] != 'x') { colorStart = index; break; }
        if (colorStart < 0) return null;
        var numbers = Whitespace().Split(text[..colorStart].Trim()).Select(Pixels).OfType<float>().ToList();
        if (Color(text[colorStart..]) is not { } color) return null;
        if (numbers.Count < 2) return null;
        return new BoxShadowValue(inset, numbers[0], numbers[1], numbers.Count > 2 ? numbers[2] : 0f, numbers.Count > 3 ? numbers[3] : 0f, color);
    }

    [GeneratedRegex(@"from\s+(-?[0-9.]+)deg")]
    private static partial Regex ConicFrom();

    [GeneratedRegex(@"at\s+(-?[0-9.eE+-]+)px\s+(-?[0-9.eE+-]+)px")]
    private static partial Regex GradientCenter();

    [GeneratedRegex(@"drop-shadow\(\s*(-?[0-9.]+)px\s+(-?[0-9.]+)px\s+(-?[0-9.]+)px\s+(.+?\))\s*\)")]
    private static partial Regex DropShadowPattern();

    [GeneratedRegex(@"\s+")]
    internal static partial Regex Whitespace();
}
