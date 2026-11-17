using ScriptWidget.App.Interop;

namespace ScriptWidget.App.Windowing;

/// <summary>
/// One desktop widget: a layered window with per-pixel transparency that
/// shows a bitmap and reports clicks. It never takes focus, stays out of the
/// taskbar and Alt-Tab, and its place in the window order is decided by
/// <see cref="DesktopLayer"/> alone. Fully transparent pixels let clicks
/// through to whatever is behind.
/// </summary>
internal sealed unsafe class WidgetWindow : NativeWindow
{
    public const string ClassName = "ScriptWidgetWidget";
    private const int DragThreshold = 4;

    private int x, y, width, height;
    private bool pressed, dragging, visible;
    private Win32.POINT pressCursor, pressOrigin;
    private bool allowOrder;

    /// <summary>When true the widget cannot be dragged.</summary>
    public bool Locked { get; set; }
    /// <summary>A click that was not a drag, in pixels from the window's top-left corner.</summary>
    public event Action<int, int>? Clicked;
    /// <summary>The user finished dragging the widget.</summary>
    public event Action? Moved;
    /// <summary>Right click, in screen pixels.</summary>
    public event Action<int, int>? MenuRequested;
    /// <summary>The window is now on a display with another scale.</summary>
    public event Action? ScaleChanged;
    /// <summary>True when the point (window pixels) is over something clickable.</summary>
    public Func<int, int, bool>? IsInteractive { get; set; }

    public WidgetWindow() => Create(ClassName, Win32.WS_EX_LAYERED | Win32.WS_EX_TOOLWINDOW | Win32.WS_EX_NOACTIVATE, Win32.WS_POPUP);

    public int X => x;
    public int Y => y;
    public int Width => width;
    public int Height => height;

    /// <summary>Scale of the display the window is on.</summary>
    public double Scale => Monitors.Describe(Win32.MonitorFromWindow(Handle, Win32.MONITOR_DEFAULTTONEAREST))?.Scale ?? 1.0;

    public void MoveTo(int newX, int newY)
    {
        x = newX;
        y = newY;
        if (Handle != 0) Win32.SetWindowPos(Handle, 0, x, y, 0, 0, Win32.SWP_NOSIZE | Win32.SWP_NOZORDER | Win32.SWP_NOACTIVATE);
    }

    /// <summary>Shows a premultiplied BGRA bitmap, resizing the window to it.</summary>
    public void SetBitmap(ReadOnlySpan<byte> bgra, int pixelWidth, int pixelHeight)
    {
        if (Handle == 0 || pixelWidth <= 0 || pixelHeight <= 0 || bgra.Length < pixelWidth * pixelHeight * 4) return;
        var screen = Win32.GetDC(0);
        var memory = Win32.CreateCompatibleDC(screen);
        var header = new Win32.BITMAPINFOHEADER
        {
            Size = (uint)sizeof(Win32.BITMAPINFOHEADER),
            Width = pixelWidth,
            Height = -pixelHeight, // top-down rows
            Planes = 1,
            BitCount = 32,
        };
        void* bits = null;
        var bitmap = Win32.CreateDIBSection(screen, &header, 0, &bits, 0, 0);
        try
        {
            if (bitmap == 0 || bits is null) return;
            bgra[..(pixelWidth * pixelHeight * 4)].CopyTo(new Span<byte>(bits, pixelWidth * pixelHeight * 4));
            var previous = Win32.SelectObject(memory, bitmap);
            var position = new Win32.POINT { X = x, Y = y };
            var size = new Win32.SIZE { Width = pixelWidth, Height = pixelHeight };
            var source = new Win32.POINT();
            var blend = new Win32.BLENDFUNCTION { BlendOp = Win32.AC_SRC_OVER, SourceConstantAlpha = 255, AlphaFormat = Win32.AC_SRC_ALPHA };
            allowOrder = true;
            try { Win32.UpdateLayeredWindow(Handle, screen, &position, &size, memory, &source, 0, &blend, Win32.ULW_ALPHA); }
            finally { allowOrder = false; }
            Win32.SelectObject(memory, previous);
            width = pixelWidth;
            height = pixelHeight;
        }
        finally
        {
            if (bitmap != 0) Win32.DeleteObject(bitmap);
            Win32.DeleteDC(memory);
            Win32.ReleaseDC(0, screen);
        }
        if (!visible)
        {
            visible = true;
            Win32.ShowWindow(Handle, Win32.SW_SHOWNOACTIVATE);
        }
    }

    /// <summary>Places the window in the window order; every other attempt to reorder it is refused.</summary>
    public void SetOrder(nint insertAfter)
    {
        if (Handle == 0) return;
        allowOrder = true;
        try { Win32.SetWindowPos(Handle, insertAfter, 0, 0, 0, 0, Win32.SWP_NOMOVE | Win32.SWP_NOSIZE | Win32.SWP_NOACTIVATE | Win32.SWP_NOOWNERZORDER); }
        finally { allowOrder = false; }
    }

    protected override nint? OnMessage(uint message, nuint wParam, nint lParam)
    {
        switch (message)
        {
            case Win32.WM_MOUSEACTIVATE:
                return Win32.MA_NOACTIVATE;

            case Win32.WM_WINDOWPOSCHANGING:
                // Clicking or another program must not bring a desktop widget forward.
                if (!allowOrder) ((Win32.WINDOWPOS*)lParam)->Flags |= Win32.SWP_NOZORDER;
                return null;

            case Win32.WM_LBUTTONDOWN or Win32.WM_LBUTTONDBLCLK:
            {
                pressed = true;
                dragging = false;
                // The pointer position comes from the message, not from the cursor at this instant.
                pressCursor = new Win32.POINT { X = x + Win32.LowWord(lParam), Y = y + Win32.HighWord(lParam) };
                pressOrigin = new Win32.POINT { X = x, Y = y };
                Win32.SetCapture(Handle);
                return 0;
            }

            case Win32.WM_MOUSEMOVE:
            {
                if (!pressed) return null;
                var cursor = new Win32.POINT { X = x + Win32.LowWord(lParam), Y = y + Win32.HighWord(lParam) };
                var deltaX = cursor.X - pressCursor.X;
                var deltaY = cursor.Y - pressCursor.Y;
                if (!dragging && !Locked && (Math.Abs(deltaX) > DragThreshold || Math.Abs(deltaY) > DragThreshold)) dragging = true;
                if (dragging)
                {
                    var (snappedX, snappedY) = Snap(pressOrigin.X + deltaX, pressOrigin.Y + deltaY);
                    MoveTo(snappedX, snappedY);
                }
                return 0;
            }

            case Win32.WM_LBUTTONUP:
            {
                if (Log.Verbose) Log.Write($"button up: pressed={pressed} dragging={dragging} at {Win32.LowWord(lParam)},{Win32.HighWord(lParam)}");
                if (!pressed) return null;
                var wasDragging = dragging;
                pressed = false;
                dragging = false;
                Win32.ReleaseCapture();
                if (wasDragging) Moved?.Invoke();
                else Clicked?.Invoke(Win32.LowWord(lParam), Win32.HighWord(lParam));
                return 0;
            }

            case Win32.WM_CAPTURECHANGED:
                // Capture also ends when the button is released; only a drag in progress is finished here,
                // so a click still arrives with the button-up message.
                if (pressed && dragging) { pressed = false; dragging = false; Moved?.Invoke(); }
                return 0;

            case Win32.WM_RBUTTONUP:
            {
                Win32.POINT cursor;
                Win32.GetCursorPos(&cursor);
                MenuRequested?.Invoke(cursor.X, cursor.Y);
                return 0;
            }

            case Win32.WM_SETCURSOR:
            {
                if (Win32.LowWord(lParam) != Win32.HTCLIENT) return null;
                Win32.POINT cursor;
                Win32.GetCursorPos(&cursor);
                var interactive = IsInteractive?.Invoke(cursor.X - x, cursor.Y - y) ?? false;
                Win32.SetCursor(Win32.LoadCursorW(0, dragging ? Win32.IDC_SIZEALL : interactive ? Win32.IDC_HAND : Win32.IDC_ARROW));
                return 1;
            }

            case Win32.WM_DPICHANGED:
                ScaleChanged?.Invoke();
                return 0;
        }
        return null;
    }

    /// <summary>Snaps the window's edges to the edges of the work area when they come close.</summary>
    private (int X, int Y) Snap(int proposedX, int proposedY)
    {
        var monitor = Monitors.Containing(proposedX + width / 2, proposedY + height / 2);
        var distance = (int)Math.Round(10 * monitor.Scale);
        var work = monitor.Work;
        if (Math.Abs(proposedX - work.Left) < distance) proposedX = work.Left;
        else if (Math.Abs(proposedX + width - work.Right) < distance) proposedX = work.Right - width;
        if (Math.Abs(proposedY - work.Top) < distance) proposedY = work.Top;
        else if (Math.Abs(proposedY + height - work.Bottom) < distance) proposedY = work.Bottom - height;
        return (proposedX, proposedY);
    }
}
