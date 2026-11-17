namespace ScriptWidget.Core.Render;

/// <summary>
/// Rounds the corners of a rendered widget. The renderer draws the widget as
/// a full rectangle, as on Android, where the launcher clips it; on Windows
/// the host owns the window, so it cuts the corners itself.
/// </summary>
public static class RoundedCorners
{
    /// <summary>Corner radius of a desktop widget, in points.</summary>
    public const float DefaultRadius = 20;

    /// <summary>
    /// Makes the corners of a premultiplied BGRA bitmap transparent, with an
    /// antialiased edge. The bitmap is changed in place.
    /// </summary>
    /// <param name="radius">Corner radius in pixels.</param>
    public static void Apply(byte[] pixels, int width, int height, float radius)
    {
        if (radius <= 0 || width <= 0 || height <= 0 || pixels.Length < width * height * 4) return;
        radius = Math.Min(radius, Math.Min(width, height) / 2f);
        var reach = (int)Math.Ceiling(radius);
        for (var row = 0; row < reach; row++)
        {
            for (var column = 0; column < reach; column++)
            {
                // Distance of the pixel centre from the corner circle's centre.
                var dx = radius - (column + 0.5f);
                var dy = radius - (row + 0.5f);
                if (dx <= 0 || dy <= 0) continue;
                var distance = MathF.Sqrt(dx * dx + dy * dy);
                var coverage = Math.Clamp(radius - distance + 0.5f, 0f, 1f);
                if (coverage >= 1f) continue;
                var right = width - 1 - column;
                var bottom = height - 1 - row;
                Scale(pixels, (row * width + column) * 4, coverage);
                if (right != column) Scale(pixels, (row * width + right) * 4, coverage);
                if (bottom == row) continue;
                Scale(pixels, (bottom * width + column) * 4, coverage);
                if (right != column) Scale(pixels, (bottom * width + right) * 4, coverage);
            }
        }
    }

    private static void Scale(byte[] pixels, int index, float coverage)
    {
        // Premultiplied color: every channel scales with the coverage.
        pixels[index] = (byte)(pixels[index] * coverage + 0.5f);
        pixels[index + 1] = (byte)(pixels[index + 1] * coverage + 0.5f);
        pixels[index + 2] = (byte)(pixels[index + 2] * coverage + 0.5f);
        pixels[index + 3] = (byte)(pixels[index + 3] * coverage + 0.5f);
    }
}
