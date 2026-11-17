using ScriptWidget.App.Interop;
using ScriptWidget.App.Windowing;

namespace ScriptWidget.App;

/// <summary>
/// <c>ScriptWidget.exe --selftest-window &lt;seconds&gt; &lt;log&gt;</c>: shows one widget window with a
/// drawn test card and writes its state to a log once a second, so the window
/// order can be checked on a real desktop while windows are opened and the
/// desktop is shown. Used for the checks recorded in docs/windows/testing.md.
/// </summary>
internal static unsafe class SelfTest
{
    public static int Run(string[] arguments)
    {
        var seconds = arguments.Length > 1 && int.TryParse(arguments[1], out var parsed) ? parsed : 20;
        var logPath = arguments.Length > 2 ? arguments[2] : Path.Combine(Path.GetTempPath(), "scriptwidget-window-selftest.log");
        File.WriteAllText(logPath, "");
        void Note(string line) => File.AppendAllText(logPath, $"{DateTimeOffset.Now:HH:mm:ss.fff} {line}{Environment.NewLine}");

        using var layer = new DesktopLayer();
        using var window = new WidgetWindow();
        var monitor = Monitors.Primary();
        var scale = monitor.Scale;
        int width = (int)Math.Round(329 * scale), height = (int)Math.Round(170 * scale);
        window.MoveTo(monitor.Work.Right - width - (int)(40 * scale), monitor.Work.Top + (int)(40 * scale));
        window.SetBitmap(Card(width, height, (int)Math.Round(22 * scale)), width, height);
        layer.Add(window);
        window.Clicked += (x, y) => Note($"clicked {x},{y}");
        window.Moved += () => Note($"moved to {window.X},{window.Y}");
        Note($"monitors: {string.Join("; ", Monitors.All().Select(item => $"{item.Device} {item.Bounds.Width}x{item.Bounds.Height} scale {item.Scale} primary {item.Primary}"))}");
        Note($"window {window.Handle:X} at {window.X},{window.Y} size {width}x{height}");

        var started = Environment.TickCount64;
        using var timer = new TimerWindow(1000, () =>
        {
            var centre = new Win32.POINT { X = window.X + width / 2, Y = window.Y + height / 2 };
            var top = Win32.WindowFromPoint(centre);
            var foreground = Win32.GetForegroundWindow();
            Note($"desktopShown={layer.DesktopShown} windowAtCentre={(top == window.Handle ? "widget" : Win32.ClassName(top))} foreground={Win32.ClassName(foreground)} visible={Win32.IsWindowVisible(window.Handle) != 0}");
            if (Environment.TickCount64 - started > seconds * 1000L) Win32.PostQuitMessage(0);
        });

        Win32.MSG message;
        while (Win32.GetMessageW(&message, 0, 0, 0) > 0)
        {
            Win32.TranslateMessage(&message);
            Win32.DispatchMessageW(&message);
        }
        Note("done");
        return 0;
    }

    /// <summary>A rounded card with a gradient, as premultiplied BGRA.</summary>
    private static byte[] Card(int width, int height, int radius)
    {
        var pixels = new byte[width * height * 4];
        for (var row = 0; row < height; row++)
        {
            for (var column = 0; column < width; column++)
            {
                var dx = column < radius ? radius - column : column >= width - radius ? column - (width - radius - 1) : 0;
                var dy = row < radius ? radius - row : row >= height - radius ? row - (height - radius - 1) : 0;
                if (dx * dx + dy * dy > radius * radius) continue;
                var t = (double)(column + row) / (width + height);
                var index = (row * width + column) * 4;
                pixels[index] = (byte)(0xe5 + (0xd4 - 0xe5) * t);
                pixels[index + 1] = (byte)(0x46 + (0xb6 - 0x46) * t);
                pixels[index + 2] = (byte)(0x4f + (0x06 - 0x4f) * t);
                pixels[index + 3] = 255;
            }
        }
        return pixels;
    }

    private sealed class TimerWindow : NativeWindow
    {
        private readonly Action tick;
        public TimerWindow(uint milliseconds, Action tick)
        {
            this.tick = tick;
            Create("ScriptWidgetSelfTestTimer", 0, 0, Win32.HWND_MESSAGE);
            Win32.SetTimer(Handle, 1, milliseconds, 0);
        }
        protected override nint? OnMessage(uint message, nuint wParam, nint lParam)
        {
            if (message != Win32.WM_TIMER) return null;
            tick();
            return 0;
        }
    }
}
