using Windows.Graphics.Imaging;

namespace ScriptWidget.Core.Render;

/// <summary>
/// Evenly spaced frames of a GIF and the delay between them. Each frame is
/// <see cref="Width"/> x <see cref="Height"/> premultiplied BGRA pixels.
/// </summary>
public sealed record GifFrames(IReadOnlyList<byte[]> Frames, int Width, int Height, int IntervalMilliseconds);

/// <summary>
/// Samples a GIF into a bounded set of bitmaps for a widget. A widget cannot
/// run a decoder, so the host flips through prepared frames; their total
/// size counts against the widget bitmap budget and is capped here.
/// </summary>
public static class GifSampler
{
    public const int MaximumInputBytes = 8 * 1024 * 1024;
    public const int MaximumFrames = 24;
    private const int MinimumInterval = 80;

    private sealed record Frame(byte[] Pixels, int Left, int Top, int Width, int Height, int Delay, int Disposal);

    /// <summary>
    /// Returns null when the data is not an animated GIF or cannot be decoded.
    /// <paramref name="width"/> and <paramref name="height"/> are the box in pixels the GIF is fitted into;
    /// <paramref name="maximumBytes"/> bounds all frames together.
    /// </summary>
    public static GifFrames? Sample(byte[] data, int width, int height, long maximumBytes)
    {
        if (data.Length > MaximumInputBytes || width <= 0 || height <= 0 || maximumBytes < 8) return null;
        try { return Decode(data, width, height, maximumBytes); }
        catch (Exception) { return null; }
    }

    private static T Wait<T>(Windows.Foundation.IAsyncOperation<T> operation) => operation.AsTask().GetAwaiter().GetResult();

    private static int Property(BitmapPropertySet properties, string name) =>
        properties.TryGetValue(name, out var value) && value.Value is { } item ? Convert.ToInt32(item, System.Globalization.CultureInfo.InvariantCulture) : 0;

    private static GifFrames? Decode(byte[] data, int width, int height, long maximumBytes)
    {
        using var stream = new MemoryStream(data, false).AsRandomAccessStream();
        var decoder = Wait(BitmapDecoder.CreateAsync(BitmapDecoder.GifDecoderId, stream));
        var total = (int)decoder.FrameCount;
        if (total < 2 || total > 256) return null;
        var movieWidth = 0;
        var movieHeight = 0;
        try
        {
            var screen = Wait(decoder.BitmapContainerProperties.GetPropertiesAsync(new List<string> { "/logscr/Width", "/logscr/Height" }));
            movieWidth = Property(screen, "/logscr/Width");
            movieHeight = Property(screen, "/logscr/Height");
        }
        catch (Exception)
        {
            // Some decoders do not report the logical screen; the frames below give its size.
        }

        var frames = new List<Frame>(total);
        var duration = 0;
        long decodedBytes = 0;
        for (var index = 0; index < total; index++)
        {
            var frame = Wait(decoder.GetFrameAsync((uint)index));
            var frameBytes = (long)frame.PixelWidth * frame.PixelHeight * 4;
            decodedBytes += frameBytes;
            if (frameBytes > 16 * 1024 * 1024 || decodedBytes > 32 * 1024 * 1024) return null;
            var properties = Wait(frame.BitmapProperties.GetPropertiesAsync(new List<string> { "/grctlext/Delay", "/grctlext/Disposal", "/imgdesc/Left", "/imgdesc/Top" }));
            var pixels = Wait(frame.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, new BitmapTransform(), ExifOrientationMode.IgnoreExifOrientation, ColorManagementMode.DoNotColorManage)).DetachPixelData();
            // GIF delays are hundredths of a second.
            var delay = Property(properties, "/grctlext/Delay") * 10;
            frames.Add(new Frame(pixels, Property(properties, "/imgdesc/Left"), Property(properties, "/imgdesc/Top"), (int)frame.PixelWidth, (int)frame.PixelHeight, delay, Property(properties, "/grctlext/Disposal")));
            duration += delay;
        }
        if (duration <= 0) return null;
        if (movieWidth <= 0) movieWidth = frames.Max(frame => frame.Left + frame.Width);
        if (movieHeight <= 0) movieHeight = frames.Max(frame => frame.Top + frame.Height);
        if (movieWidth <= 0 || movieHeight <= 0 || (long)movieWidth * movieHeight > 16L * 1024 * 1024) return null;

        var count = (int)Math.Min(Math.Clamp(duration / MinimumInterval, 2, MaximumFrames), maximumBytes / 4);
        // Fit inside the box, then shrink further until every frame together fits the budget.
        var scale = Math.Min((float)width / movieWidth, (float)height / movieHeight);
        long Bytes(float s) => (long)(movieWidth * s) * (long)(movieHeight * s) * 4L * count;
        if (Bytes(scale) > maximumBytes) scale *= (float)Math.Sqrt((double)maximumBytes / Bytes(scale));
        var frameWidth = Math.Max(1, (int)(movieWidth * scale));
        var frameHeight = Math.Max(1, (int)(movieHeight * scale));
        if ((long)frameWidth * frameHeight * 4 * count > maximumBytes) return null;

        // Compose the frames in order; a sample shows the frame on screen at its time.
        var canvas = new byte[movieWidth * movieHeight * 4];
        byte[]? beforeFrame = null;
        var result = new List<byte[]>(count);
        var composed = -1;
        var frameEnd = 0;
        for (var sample = 0; sample < count; sample++)
        {
            var time = (int)((long)duration * sample / count);
            while (composed < 0 || (time >= frameEnd && composed + 1 < frames.Count))
            {
                if (composed >= 0) Dispose(canvas, frames[composed], beforeFrame, movieWidth, movieHeight);
                composed += 1;
                var next = frames[composed];
                beforeFrame = next.Disposal == 3 ? (byte[])canvas.Clone() : null;
                Compose(canvas, next, movieWidth, movieHeight);
                frameEnd += next.Delay;
            }
            result.Add(Resize(canvas, movieWidth, movieHeight, frameWidth, frameHeight));
        }
        return new GifFrames(result, frameWidth, frameHeight, Math.Max(MinimumInterval, duration / count));
    }

    /// <summary>What a frame leaves behind: 2 clears its area, 3 puts back what was there before it.</summary>
    private static void Dispose(byte[] canvas, Frame frame, byte[]? before, int width, int height)
    {
        if (frame.Disposal == 3 && before is not null) { before.CopyTo(canvas, 0); return; }
        if (frame.Disposal != 2) return;
        for (var row = Math.Max(0, frame.Top); row < Math.Min(height, frame.Top + frame.Height); row++)
        {
            var from = Math.Max(0, frame.Left);
            var to = Math.Min(width, frame.Left + frame.Width);
            if (to > from) Array.Clear(canvas, (row * width + from) * 4, (to - from) * 4);
        }
    }

    private static void Compose(byte[] canvas, Frame frame, int width, int height)
    {
        for (var row = 0; row < frame.Height; row++)
        {
            var targetRow = frame.Top + row;
            if (targetRow < 0 || targetRow >= height) continue;
            for (var column = 0; column < frame.Width; column++)
            {
                var targetColumn = frame.Left + column;
                if (targetColumn < 0 || targetColumn >= width) continue;
                var source = (row * frame.Width + column) * 4;
                // GIF pixels are opaque or fully transparent.
                if (source + 3 >= frame.Pixels.Length || frame.Pixels[source + 3] == 0) continue;
                Buffer.BlockCopy(frame.Pixels, source, canvas, (targetRow * width + targetColumn) * 4, 4);
            }
        }
    }

    /// <summary>Averages the source pixels each target pixel covers.</summary>
    private static byte[] Resize(byte[] source, int width, int height, int targetWidth, int targetHeight)
    {
        if (width == targetWidth && height == targetHeight) return (byte[])source.Clone();
        var result = new byte[targetWidth * targetHeight * 4];
        Span<int> sums = stackalloc int[4];
        for (var row = 0; row < targetHeight; row++)
        {
            var top = (int)((long)row * height / targetHeight);
            var bottom = Math.Max(top + 1, (int)((long)(row + 1) * height / targetHeight));
            for (var column = 0; column < targetWidth; column++)
            {
                var left = (int)((long)column * width / targetWidth);
                var right = Math.Max(left + 1, (int)((long)(column + 1) * width / targetWidth));
                sums.Clear();
                var samples = 0;
                for (var y = top; y < bottom && y < height; y++)
                    for (var x = left; x < right && x < width; x++)
                    {
                        var at = (y * width + x) * 4;
                        sums[0] += source[at]; sums[1] += source[at + 1]; sums[2] += source[at + 2]; sums[3] += source[at + 3];
                        samples += 1;
                    }
                if (samples == 0) continue;
                var into = (row * targetWidth + column) * 4;
                for (var channel = 0; channel < 4; channel++) result[into + channel] = (byte)((sums[channel] + samples / 2) / samples);
            }
        }
        return result;
    }
}
