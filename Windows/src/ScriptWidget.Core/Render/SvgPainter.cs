using System.Numerics;
using System.Text.RegularExpressions;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Effects;
using Microsoft.Graphics.Canvas.Geometry;
using Windows.UI;

namespace ScriptWidget.Core.Render;

/// <summary>
/// Paints the inline SVG the shared renderer emits: icons, rings, gauges,
/// charts and shape strokes. Presentation attributes inherit from ancestors
/// as in SVG; <c>currentColor</c> resolves to the element's CSS color.
/// </summary>
public sealed partial class SvgPainter(TextEngine text)
{
    private sealed record Attributes(
        string Fill = "black", string Stroke = "none", float StrokeWidth = 1f,
        string LineCap = "butt", string LineJoin = "miter", string FillRule = "nonzero",
        float FontSize = 16f, string FontFamily = "sans-serif", int FontWeight = 400, string TextAnchor = "start")
    {
        public Attributes Merged(DomNode node)
        {
            var attributes = node.Attributes;
            if (attributes.Count == 0) return this;
            return new Attributes(
                Fill: Get(attributes, "fill") ?? Fill,
                Stroke: Get(attributes, "stroke") ?? Stroke,
                StrokeWidth: Css.Number(Get(attributes, "stroke-width")) ?? StrokeWidth,
                LineCap: Get(attributes, "stroke-linecap") ?? LineCap,
                LineJoin: Get(attributes, "stroke-linejoin") ?? LineJoin,
                FillRule: Get(attributes, "fill-rule") ?? FillRule,
                FontSize: Css.Pixels(Get(attributes, "font-size")) ?? FontSize,
                FontFamily: Get(attributes, "font-family") ?? FontFamily,
                FontWeight: int.TryParse(Get(attributes, "font-weight"), out var weight) ? weight : FontWeight,
                TextAnchor: Get(attributes, "text-anchor") ?? TextAnchor);
        }
    }

    private Color currentColor = Css.Black;
    private Dictionary<string, DomNode> masks = new();

    private static string? Get(IReadOnlyDictionary<string, string> map, string key) => map.TryGetValue(key, out var value) ? value : null;

    private static List<float> Numbers(string? value) =>
        value is null ? [] : Css.Whitespace().Replace(value.Trim(), " ").Split([' ', ','], StringSplitOptions.RemoveEmptyEntries).Select(Css.Number).OfType<float>().ToList();

    /// <summary>Paints an <c>&lt;svg&gt;</c> element with its top-left corner at the canvas origin.</summary>
    public void Paint(PaintCanvas canvas, DomNode root, Color cssColor)
    {
        currentColor = cssColor;
        masks = new Dictionary<string, DomNode>();
        CollectMasks(root, masks);
        if (Css.Number(Get(root.Attributes, "width")) is not { } width) return;
        if (Css.Number(Get(root.Attributes, "height")) is not { } height) return;
        canvas.Save();
        if (Get(root.Style, "transform") is { } value && RootRotation().Match(value) is { Success: true } rotation && Css.Number(rotation.Groups[1].Value) is { } degrees)
            canvas.Rotate(degrees, width / 2f, height / 2f);
        var viewBox = Get(root.Attributes, "viewBox") is { } box ? Numbers(box) : null;
        if (viewBox is { Count: 4 } && viewBox[2] > 0f && viewBox[3] > 0f)
        {
            var scale = Math.Min(width / viewBox[2], height / viewBox[3]);
            canvas.Translate((width - viewBox[2] * scale) / 2f, (height - viewBox[3] * scale) / 2f);
            canvas.Scale(scale, scale);
            canvas.Translate(-viewBox[0], -viewBox[1]);
        }
        var attributes = new Attributes().Merged(root);
        foreach (var child in root.Children) Draw(canvas, child, attributes);
        canvas.Restore();
    }

    private static void CollectMasks(DomNode node, Dictionary<string, DomNode> into)
    {
        if (node.Tag == "mask" && Get(node.Attributes, "id") is { } id) into[id] = node;
        foreach (var child in node.Children) CollectMasks(child, into);
    }

    private void Draw(PaintCanvas canvas, DomNode node, Attributes inherited)
    {
        if (node.Tag == "defs" || node.Tag == "mask" || node.Tag.Length == 0) return;
        var attributes = inherited.Merged(node);
        DomNode? mask = null;
        if (Get(node.Attributes, "mask") is { } reference && MaskReference().Match(reference) is { Success: true } found) masks.TryGetValue(found.Groups[1].Value, out mask);
        var opacity = Css.Number(Get(node.Attributes, "opacity")) is { } value ? Math.Clamp(value, 0f, 1f) : 1f;

        canvas.Save();
        if (Get(node.Attributes, "transform") is { } transform) canvas.Concat(Transform(transform));
        // A masked drawing is recorded so the mask can be applied to all of it at once.
        if (mask is not null) canvas.BeginRecord();
        else if (opacity < 1f) canvas.SaveLayerAlpha(opacity);

        try
        {
            if (node.Tag == "g") foreach (var child in node.Children) Draw(canvas, child, attributes);
            else if (node.Tag == "text") DrawText(canvas, node, attributes);
            else DrawPath(canvas, node, attributes);
        }
        catch when (mask is not null)
        {
            canvas.EndRecord().Dispose();
            throw;
        }

        if (mask is not null)
        {
            // An SVG mask keeps the drawing where the mask is light: the mask's
            // luminance becomes the alpha of the drawing.
            using var drawing = canvas.EndRecord();
            canvas.BeginRecord();
            CanvasCommandList shape;
            try
            {
                var maskAttributes = new Attributes().Merged(mask);
                foreach (var child in mask.Children) Draw(canvas, child, maskAttributes);
            }
            finally { shape = canvas.EndRecord(); }
            using (shape)
            using (var luminance = new LuminanceToAlphaEffect { Source = shape })
            using (var masked = new AlphaMaskEffect { Source = drawing, AlphaMask = luminance })
            {
                if (opacity < 1f)
                {
                    using var faded = new OpacityEffect { Source = masked, Opacity = opacity };
                    canvas.DrawDeviceImage(faded);
                }
                else canvas.DrawDeviceImage(masked);
            }
        }
        else if (opacity < 1f) canvas.Restore();
        canvas.Restore();
    }

    private static float Number(DomNode node, string name, float fallback = 0f) => Css.Number(Get(node.Attributes, name)) ?? fallback;

    private static CanvasFilledRegionDetermination Winding(Attributes attributes) =>
        attributes.FillRule == "evenodd" ? CanvasFilledRegionDetermination.Alternate : CanvasFilledRegionDetermination.Winding;

    private static CanvasGeometry? Shape(ICanvasResourceCreator device, DomNode node, Attributes attributes)
    {
        switch (node.Tag)
        {
            case "path":
                if (Get(node.Attributes, "d") is not { } data) return null;
                try { return SvgPath.Parse(device, data, Winding(attributes)); }
                catch (Exception error) when (error is FormatException or ArgumentException) { return null; }
            case "rect":
            {
                var x = Number(node, "x"); var y = Number(node, "y");
                var width = Number(node, "width"); var height = Number(node, "height");
                var rx = Math.Min(Css.Number(Get(node.Attributes, "rx")) ?? Css.Number(Get(node.Attributes, "ry")) ?? 0f, width / 2f);
                var ry = Math.Min(Css.Number(Get(node.Attributes, "ry")) ?? rx, height / 2f);
                return width <= 0f || height <= 0f ? null : RoundedRect(device, x, y, width, height, rx, ry);
            }
            case "circle":
            {
                var r = Number(node, "r");
                return Oval(device, Number(node, "cx"), Number(node, "cy"), r, r);
            }
            case "ellipse": return Oval(device, Number(node, "cx"), Number(node, "cy"), Number(node, "rx"), Number(node, "ry"));
            case "line":
            {
                using var builder = new CanvasPathBuilder(device);
                builder.BeginFigure(Number(node, "x1"), Number(node, "y1"));
                builder.AddLine(Number(node, "x2"), Number(node, "y2"));
                builder.EndFigure(CanvasFigureLoop.Open);
                return CanvasGeometry.CreatePath(builder);
            }
            case "polyline" or "polygon":
            {
                var values = Numbers(Get(node.Attributes, "points"));
                if (values.Count < 4) return null;
                using var builder = new CanvasPathBuilder(device);
                builder.SetFilledRegionDetermination(Winding(attributes));
                builder.BeginFigure(values[0], values[1]);
                for (var index = 2; index < values.Count - 1; index += 2) builder.AddLine(values[index], values[index + 1]);
                builder.EndFigure(node.Tag == "polygon" ? CanvasFigureLoop.Closed : CanvasFigureLoop.Open);
                return CanvasGeometry.CreatePath(builder);
            }
            default: return null;
        }
    }

    /// <summary>An oval that starts at 3 o'clock and runs clockwise, as SVG circles do; dash offsets depend on it.</summary>
    private static CanvasGeometry Oval(ICanvasResourceCreator device, float cx, float cy, float rx, float ry)
    {
        using var builder = new CanvasPathBuilder(device);
        builder.BeginFigure(cx + rx, cy);
        if (rx > 0f && ry > 0f)
        {
            builder.AddArc(new Vector2(cx - rx, cy), rx, ry, 0f, CanvasSweepDirection.Clockwise, CanvasArcSize.Small);
            builder.AddArc(new Vector2(cx + rx, cy), rx, ry, 0f, CanvasSweepDirection.Clockwise, CanvasArcSize.Small);
        }
        builder.EndFigure(CanvasFigureLoop.Closed);
        return CanvasGeometry.CreatePath(builder);
    }

    /// <summary>SVG rectangles start at (x + rx, y) and run clockwise; dash offsets depend on it.</summary>
    private static CanvasGeometry RoundedRect(ICanvasResourceCreator device, float x, float y, float width, float height, float rx, float ry)
    {
        using var builder = new CanvasPathBuilder(device);
        if (rx <= 0f || ry <= 0f)
        {
            builder.BeginFigure(x, y);
            builder.AddLine(x + width, y); builder.AddLine(x + width, y + height); builder.AddLine(x, y + height);
            builder.EndFigure(CanvasFigureLoop.Closed);
            return CanvasGeometry.CreatePath(builder);
        }
        void Corner(float toX, float toY) => builder.AddArc(new Vector2(toX, toY), rx, ry, 0f, CanvasSweepDirection.Clockwise, CanvasArcSize.Small);
        builder.BeginFigure(x + rx, y);
        builder.AddLine(x + width - rx, y);
        Corner(x + width, y + ry);
        builder.AddLine(x + width, y + height - ry);
        Corner(x + width - rx, y + height);
        builder.AddLine(x + rx, y + height);
        Corner(x, y + height - ry);
        builder.AddLine(x, y + ry);
        Corner(x + rx, y);
        builder.EndFigure(CanvasFigureLoop.Closed);
        return CanvasGeometry.CreatePath(builder);
    }

    private Color? ResolveColor(string value) => value == "currentColor" ? currentColor : Css.Color(value);

    private void DrawPath(PaintCanvas canvas, DomNode node, Attributes attributes)
    {
        using var path = Shape(canvas.Device, node, attributes);
        if (path is null) return;
        var fillOpacity = Css.Number(Get(node.Attributes, "fill-opacity")) is { } fillValue ? Math.Clamp(fillValue, 0f, 1f) : 1f;
        var strokeOpacity = Css.Number(Get(node.Attributes, "stroke-opacity")) is { } strokeValue ? Math.Clamp(strokeValue, 0f, 1f) : 1f;
        if (node.Tag != "line" && ResolveColor(attributes.Fill) is { A: not 0 } fill) canvas.Session.FillGeometry(path, WithOpacity(fill, fillOpacity));
        if (ResolveColor(attributes.Stroke) is { A: not 0 } stroke && attributes.StrokeWidth > 0f)
        {
            using var strokeStyle = new CanvasStrokeStyle
            {
                StartCap = Cap(attributes.LineCap), EndCap = Cap(attributes.LineCap), DashCap = Cap(attributes.LineCap),
                LineJoin = attributes.LineJoin switch { "round" => CanvasLineJoin.Round, "bevel" => CanvasLineJoin.Bevel, _ => CanvasLineJoin.MiterOrBevel },
                MiterLimit = 4f,
            };
            if (Get(node.Attributes, "stroke-dasharray") is { } dashes)
            {
                var values = Numbers(dashes);
                if (values.Count > 0 && values.Any(item => item > 0f))
                {
                    // pathLength rescales dash lengths to the real outline length.
                    var unit = Css.Number(Get(node.Attributes, "pathLength")) is { } pathLength and > 0f ? path.ComputePathLength() / pathLength : 1f;
                    var even = values.Count % 2 == 0 ? values : values.Concat(values).ToList();
                    var intervals = new float[even.Count];
                    for (var index = 0; index < intervals.Length; index++) intervals[index] = Math.Max(even[index] * unit, index % 2 == 0 ? 0.0001f : 0f);
                    var total = intervals.Sum();
                    var offset = (Css.Number(Get(node.Attributes, "stroke-dashoffset")) ?? 0f) * unit;
                    var phase = total > 0f ? (offset % total + total) % total : 0f;
                    // A zero-length dash with round caps would still draw a dot.
                    if (even[0] <= 0f) return;
                    // Direct2D measures dashes in stroke widths.
                    for (var index = 0; index < intervals.Length; index++) intervals[index] /= attributes.StrokeWidth;
                    strokeStyle.CustomDashStyle = intervals;
                    strokeStyle.DashOffset = phase / attributes.StrokeWidth;
                }
            }
            canvas.Session.DrawGeometry(path, WithOpacity(stroke, strokeOpacity), attributes.StrokeWidth, strokeStyle);
        }
    }

    private static CanvasCapStyle Cap(string name) => name switch { "round" => CanvasCapStyle.Round, "square" => CanvasCapStyle.Square, _ => CanvasCapStyle.Flat };

    private static Color WithOpacity(Color color, float opacity) =>
        opacity >= 1f ? color : Windows.UI.Color.FromArgb((byte)(color.A * opacity + 0.5f), color.R, color.G, color.B);

    private void DrawText(PaintCanvas canvas, DomNode node, Attributes attributes)
    {
        if (node.Text is not { } content) return;
        if (ResolveColor(attributes.Fill) is not { } fill) return;
        var style = new TextStyle(attributes.FontFamily, attributes.FontSize, attributes.FontWeight, attributes.FontSize * 1.2f);
        var x = Number(node, "x");
        if (attributes.TextAnchor == "middle") x -= text.Measure(content, style) / 2f;
        else if (attributes.TextAnchor == "end") x -= text.Measure(content, style);
        using var brush = new Microsoft.Graphics.Canvas.Brushes.CanvasSolidColorBrush(canvas.Device, fill);
        text.Draw(canvas.Session, content, style, x, Number(node, "y"), brush);
    }

    /// <summary>SVG transform list: translate, scale, rotate.</summary>
    private static Matrix Transform(string value)
    {
        var matrix = new Matrix();
        foreach (Match match in TransformFunction().Matches(value))
        {
            var arguments = Numbers(match.Groups[2].Value);
            float Argument(int index, float fallback) => index < arguments.Count ? arguments[index] : fallback;
            Matrix step;
            switch (match.Groups[1].Value)
            {
                case "translate": step = Matrix.Translation(Argument(0, 0f), Argument(1, 0f)); break;
                case "scale": step = Matrix.Scaling(Argument(0, 1f), Argument(1, Argument(0, 1f))); break;
                case "rotate": step = arguments.Count >= 3 ? Matrix.Rotation(arguments[0], arguments[1], arguments[2]) : Matrix.Rotation(Argument(0, 0f)); break;
                default: continue;
            }
            matrix.PreConcat(step);
        }
        return matrix;
    }

    [GeneratedRegex(@"rotate\((-?[0-9.]+)deg\)")]
    private static partial Regex RootRotation();

    [GeneratedRegex(@"url\(#(.+?)\)")]
    private static partial Regex MaskReference();

    [GeneratedRegex(@"([a-zA-Z]+)\(([^)]*)\)")]
    private static partial Regex TransformFunction();
}

/// <summary>
/// SVG path data to a Direct2D geometry: the Windows counterpart of
/// androidx PathParser. All commands are supported, absolute and relative.
/// </summary>
internal static class SvgPath
{
    public static CanvasGeometry Parse(ICanvasResourceCreator device, string data, CanvasFilledRegionDetermination winding)
    {
        using var builder = new CanvasPathBuilder(device);
        builder.SetFilledRegionDetermination(winding);
        var at = 0;
        var open = false;
        float x = 0f, y = 0f, startX = 0f, startY = 0f, controlX = 0f, controlY = 0f;
        var previous = ' ';
        var command = ' ';

        void SkipSeparators()
        {
            while (at < data.Length && (char.IsWhiteSpace(data[at]) || data[at] == ',')) at += 1;
        }
        bool MoreNumbers()
        {
            SkipSeparators();
            return at < data.Length && (char.IsDigit(data[at]) || data[at] is '-' or '+' or '.');
        }
        float Next()
        {
            SkipSeparators();
            var start = at;
            if (at < data.Length && data[at] is '-' or '+') at += 1;
            var dot = false;
            while (at < data.Length && (char.IsDigit(data[at]) || (data[at] == '.' && !dot))) { if (data[at] == '.') dot = true; at += 1; }
            if (at < data.Length && data[at] is 'e' or 'E')
            {
                var exponent = at + 1;
                if (exponent < data.Length && data[exponent] is '-' or '+') exponent += 1;
                if (exponent < data.Length && char.IsDigit(data[exponent]))
                {
                    at = exponent;
                    while (at < data.Length && char.IsDigit(data[at])) at += 1;
                }
            }
            return Css.Number(data[start..at]) ?? throw new FormatException("Malformed SVG path number");
        }
        // Arc flags are single digits that may be written without separators.
        bool Flag()
        {
            SkipSeparators();
            if (at >= data.Length || data[at] is not ('0' or '1')) throw new FormatException("Malformed SVG arc flag");
            return data[at++] == '1';
        }
        void Begin()
        {
            if (open) return;
            builder.BeginFigure(x, y);
            startX = x; startY = y;
            open = true;
        }
        void End(CanvasFigureLoop loop)
        {
            if (!open) return;
            builder.EndFigure(loop);
            open = false;
        }

        while (true)
        {
            SkipSeparators();
            if (at >= data.Length) break;
            if (char.IsLetter(data[at])) command = data[at++];
            else if (command == ' ') throw new FormatException("SVG path data must start with a command");
            // More coordinates after a move are lines.
            else if (command == 'M') command = 'L';
            else if (command == 'm') command = 'l';
            var relative = char.IsLower(command);
            var baseX = relative ? x : 0f;
            var baseY = relative ? y : 0f;
            switch (char.ToUpperInvariant(command))
            {
                case 'M':
                    End(CanvasFigureLoop.Open);
                    x = baseX + Next(); y = baseY + Next();
                    Begin();
                    break;
                case 'Z':
                    End(CanvasFigureLoop.Closed);
                    x = startX; y = startY;
                    break;
                case 'L':
                    Begin();
                    x = baseX + Next(); y = baseY + Next();
                    builder.AddLine(x, y);
                    break;
                case 'H':
                    Begin();
                    x = baseX + Next();
                    builder.AddLine(x, y);
                    break;
                case 'V':
                    Begin();
                    y = baseY + Next();
                    builder.AddLine(x, y);
                    break;
                case 'C':
                {
                    Begin();
                    float x1 = baseX + Next(), y1 = baseY + Next(), x2 = baseX + Next(), y2 = baseY + Next();
                    x = baseX + Next(); y = baseY + Next();
                    builder.AddCubicBezier(new Vector2(x1, y1), new Vector2(x2, y2), new Vector2(x, y));
                    controlX = x2; controlY = y2;
                    break;
                }
                case 'S':
                {
                    Begin();
                    var smooth = previous is 'C' or 'S';
                    float x1 = smooth ? 2f * x - controlX : x, y1 = smooth ? 2f * y - controlY : y;
                    float x2 = baseX + Next(), y2 = baseY + Next();
                    x = baseX + Next(); y = baseY + Next();
                    builder.AddCubicBezier(new Vector2(x1, y1), new Vector2(x2, y2), new Vector2(x, y));
                    controlX = x2; controlY = y2;
                    break;
                }
                case 'Q':
                {
                    Begin();
                    controlX = baseX + Next(); controlY = baseY + Next();
                    x = baseX + Next(); y = baseY + Next();
                    builder.AddQuadraticBezier(new Vector2(controlX, controlY), new Vector2(x, y));
                    break;
                }
                case 'T':
                {
                    Begin();
                    var smooth = previous is 'Q' or 'T';
                    controlX = smooth ? 2f * x - controlX : x; controlY = smooth ? 2f * y - controlY : y;
                    x = baseX + Next(); y = baseY + Next();
                    builder.AddQuadraticBezier(new Vector2(controlX, controlY), new Vector2(x, y));
                    break;
                }
                case 'A':
                {
                    Begin();
                    float rx = Math.Abs(Next()), ry = Math.Abs(Next()), rotation = Next();
                    var large = Flag();
                    var sweep = Flag();
                    var fromX = x; var fromY = y;
                    x = baseX + Next(); y = baseY + Next();
                    if (fromX == x && fromY == y) break;
                    if (rx == 0f || ry == 0f) { builder.AddLine(x, y); break; }
                    builder.AddArc(new Vector2(x, y), rx, ry, rotation * MathF.PI / 180f, sweep ? CanvasSweepDirection.Clockwise : CanvasSweepDirection.CounterClockwise, large ? CanvasArcSize.Large : CanvasArcSize.Small);
                    break;
                }
                default: throw new FormatException($"Unknown SVG path command {command}");
            }
            previous = char.ToUpperInvariant(command);
            if (previous == 'Z' && MoreNumbers()) throw new FormatException("Numbers after a close command");
        }
        End(CanvasFigureLoop.Open);
        return CanvasGeometry.CreatePath(builder);
    }
}
