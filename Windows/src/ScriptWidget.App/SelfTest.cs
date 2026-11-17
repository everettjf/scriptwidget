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

    /// <summary>
    /// <c>ScriptWidget.exe --selftest-showdesktop &lt;log&gt;</c>: acts out "show desktop" with a stand-in
    /// for the desktop window and checks that a widget is raised while the desktop is shown and
    /// returns to its place directly above the desktop afterwards. The real desktop window is not
    /// touched, so this also runs on a locked or unattended machine. Exit code 0 when every check passes.
    /// </summary>
    public static int RunShowDesktop(string[] arguments)
    {
        var logPath = arguments.Length > 1 ? arguments[1] : Path.Combine(Path.GetTempPath(), "scriptwidget-showdesktop-selftest.log");
        File.WriteAllText(logPath, "");
        var failures = 0;
        void Check(string what, bool ok)
        {
            if (!ok) failures++;
            File.AppendAllText(logPath, $"{(ok ? "PASS" : "FAIL")}  {what}{Environment.NewLine}");
        }
        // True when `upper` is in front of `lower` in the window order.
        static bool InFront(nint upper, nint lower)
        {
            for (var window = Win32.GetWindow(upper, 2 /* GW_HWNDNEXT */); window != 0; window = Win32.GetWindow(window, 2)) if (window == lower) return true;
            return false;
        }
        static bool IsTopmost(nint window) => (GetWindowLongPtrW(window, -20) & Win32.WS_EX_TOPMOST) != 0;

        using var desktop = new PlainWindow("ScriptWidgetSelfTestDesktop");
        using var other = new PlainWindow("ScriptWidgetSelfTestOther");
        // The stand-in desktop starts behind the stand-in for an ordinary window, like the real desktop.
        Win32.SetWindowPos(other.Handle, 0 /* HWND_TOP */, 60, 60, 200, 120, Win32.SWP_NOACTIVATE | Win32.SWP_SHOWWINDOW);
        Win32.SetWindowPos(desktop.Handle, other.Handle, 40, 40, 400, 300, Win32.SWP_NOACTIVATE | Win32.SWP_SHOWWINDOW);
        var foreground = other.Handle;
        DesktopLayer.HostOverride = desktop.Handle;
        DesktopLayer.ForegroundOverride = () => foreground;
        try
        {
            using var layer = new DesktopLayer();
            using var window = new WidgetWindow();
            window.MoveTo(80, 80);
            window.SetBitmap(Card(120, 80, 12), 120, 80);
            layer.Add(window);
            layer.Reassert();

            Check("normally: the widget is in front of the desktop", InFront(window.Handle, desktop.Handle));
            Check("normally: an ordinary window is in front of the widget", InFront(other.Handle, window.Handle));
            Check("normally: the widget is not topmost", !IsTopmost(window.Handle));

            // A click on the wallpaper: the desktop becomes the foreground window but is not raised.
            foreground = desktop.Handle;
            layer.Check();
            Check("wallpaper click: not treated as show desktop", !layer.DesktopShown);
            Check("wallpaper click: the widget stays behind the ordinary window", InFront(other.Handle, window.Handle) && !IsTopmost(window.Handle));

            // Show desktop: the desktop is raised above everything and is the foreground window.
            Win32.SetWindowPos(desktop.Handle, 0 /* HWND_TOP */, 0, 0, 0, 0, Win32.SWP_NOMOVE | Win32.SWP_NOSIZE | Win32.SWP_NOACTIVATE);
            layer.Check();
            Check("show desktop: detected", layer.DesktopShown);
            Check("show desktop: the widget is in front of the raised desktop", InFront(window.Handle, desktop.Handle));
            Check("show desktop: the widget is topmost", IsTopmost(window.Handle));

            // Leaving: an ordinary window is activated and the desktop goes back to the bottom.
            Win32.SetWindowPos(desktop.Handle, Win32.HWND_BOTTOM, 0, 0, 0, 0, Win32.SWP_NOMOVE | Win32.SWP_NOSIZE | Win32.SWP_NOACTIVATE);
            foreground = other.Handle;
            layer.Check();
            Check("afterwards: no longer shown", !layer.DesktopShown);
            Check("afterwards: the widget is not topmost", !IsTopmost(window.Handle));
            Check("afterwards: the widget is in front of the desktop", InFront(window.Handle, desktop.Handle));
            Check("afterwards: the ordinary window is in front of the widget", InFront(other.Handle, window.Handle));

            // A second round must work the same way.
            Win32.SetWindowPos(desktop.Handle, 0, 0, 0, 0, 0, Win32.SWP_NOMOVE | Win32.SWP_NOSIZE | Win32.SWP_NOACTIVATE);
            foreground = desktop.Handle;
            layer.Check();
            Check("second time: detected and raised", layer.DesktopShown && IsTopmost(window.Handle));
            Win32.SetWindowPos(desktop.Handle, Win32.HWND_BOTTOM, 0, 0, 0, 0, Win32.SWP_NOMOVE | Win32.SWP_NOSIZE | Win32.SWP_NOACTIVATE);
            foreground = other.Handle;
            layer.Check();
            Check("second time: back in place", !layer.DesktopShown && !IsTopmost(window.Handle) && InFront(window.Handle, desktop.Handle) && InFront(other.Handle, window.Handle));
        }
        finally
        {
            DesktopLayer.HostOverride = 0;
            DesktopLayer.ForegroundOverride = null;
        }
        File.AppendAllText(logPath, failures == 0 ? "all checks passed" + Environment.NewLine : $"{failures} check(s) failed{Environment.NewLine}");
        return failures == 0 ? 0 : 1;
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern nint GetWindowLongPtrW(nint window, int index);

    /// <summary>An empty tool window used as a stand-in in the self-tests.</summary>
    private sealed class PlainWindow : NativeWindow
    {
        public PlainWindow(string className) => Create(className, Win32.WS_EX_TOOLWINDOW | Win32.WS_EX_NOACTIVATE, Win32.WS_POPUP);
        protected override nint? OnMessage(uint message, nuint wParam, nint lParam) => message == Win32.WM_MOUSEACTIVATE ? Win32.MA_NOACTIVATE : null;
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
