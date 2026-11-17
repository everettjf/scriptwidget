using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using ScriptWidget.App.Interop;

namespace ScriptWidget.App.Windowing;

/// <summary>
/// Keeps the widget windows on the desktop: below every ordinary window, and
/// still visible when the user asks Windows to show the desktop.
///
/// The widgets are top-level windows held at the bottom of the window order
/// (the approach Rainmeter uses) rather than children of the shell's desktop
/// window, which broke for other programs when Windows 11 24H2 rearranged
/// that window. "Show desktop" (Win+D, the taskbar corner) raises the shell's
/// desktop window above everything, which would cover the widgets, so while
/// that state lasts the widgets are raised too. The state is detected with a
/// hidden probe window that always stays at the bottom: when the desktop
/// window sits above the probe, the desktop is being shown.
/// </summary>
internal sealed unsafe class DesktopLayer : NativeWindow
{
    private const string ProbeClass = "ScriptWidgetDesktopProbe";
    private const nuint RecheckTimer = 1;
    private static DesktopLayer? current;

    private readonly List<WidgetWindow> windows = new();
    private nint hook;
    private readonly uint taskbarCreated;

    /// <summary>True while Windows is showing the desktop and the widgets are raised above it.</summary>
    public bool DesktopShown { get; private set; }

    public DesktopLayer()
    {
        Create(ProbeClass, Win32.WS_EX_TOOLWINDOW | Win32.WS_EX_NOACTIVATE, Win32.WS_POPUP);
        Win32.SetWindowPos(Handle, Win32.HWND_BOTTOM, 0, 0, 0, 0, Win32.SWP_NOMOVE | Win32.SWP_NOSIZE | Win32.SWP_NOACTIVATE);
        current = this;
        hook = Win32.SetWinEventHook(Win32.EVENT_SYSTEM_FOREGROUND, Win32.EVENT_SYSTEM_FOREGROUND, 0, &ForegroundChanged, 0, 0, Win32.WINEVENT_OUTOFCONTEXT | Win32.WINEVENT_SKIPOWNPROCESS);
        fixed (char* name = "TaskbarCreated") taskbarCreated = Win32.RegisterWindowMessageW(name);
    }

    public void Add(WidgetWindow window)
    {
        windows.Add(window);
        Place(window);
    }

    public void Remove(WidgetWindow window) => windows.Remove(window);

    /// <summary>Re-applies the window order to every widget, for example after Explorer restarted.</summary>
    public void Reassert()
    {
        Win32.SetWindowPos(Handle, Win32.HWND_BOTTOM, 0, 0, 0, 0, Win32.SWP_NOMOVE | Win32.SWP_NOSIZE | Win32.SWP_NOACTIVATE);
        Check();
        foreach (var window in windows) Place(window);
    }

    private void Place(WidgetWindow window)
    {
        if (DesktopShown) window.SetOrder(Win32.HWND_TOPMOST);
        else
        {
            window.SetOrder(Win32.HWND_NOTOPMOST);
            window.SetOrder(Win32.HWND_BOTTOM);
        }
    }

    /// <summary>The top-level window that hosts the desktop icons: Progman, or a WorkerW on some configurations.</summary>
    private static nint DesktopHost()
    {
        fixed (char* workerClass = "WorkerW")
        fixed (char* viewClass = "SHELLDLL_DefView")
        {
            nint worker = 0;
            while ((worker = Win32.FindWindowExW(0, worker, workerClass, null)) != 0)
            {
                if (Win32.FindWindowExW(worker, 0, viewClass, null) != 0) return worker;
            }
        }
        return Win32.GetShellWindow();
    }

    /// <summary>Compares the desktop window with the probe and raises or lowers the widgets when the state changed.</summary>
    public void Check()
    {
        var host = DesktopHost();
        var shown = false;
        if (host != 0 && Win32.IsWindowVisible(host) != 0)
        {
            // FindWindowEx searches the windows below `host` in the window order.
            fixed (char* probe = ProbeClass) shown = Win32.FindWindowExW(0, host, probe, null) == Handle && IsDesktopForeground();
        }
        if (shown == DesktopShown) return;
        DesktopShown = shown;
        foreach (var window in windows) Place(window);
        if (shown) Win32.SetTimer(Handle, RecheckTimer, 500, 0);
        else Win32.KillTimer(Handle, RecheckTimer);
    }

    /// <summary>The probe is also below the desktop window when nothing was raised; only a foreground desktop means "show desktop".</summary>
    private static bool IsDesktopForeground()
    {
        var foreground = Win32.GetForegroundWindow();
        if (foreground == 0) return false;
        var name = Win32.ClassName(foreground);
        return name is "WorkerW" or "Progman";
    }

    protected override nint? OnMessage(uint message, nuint wParam, nint lParam)
    {
        if (message == Win32.WM_TIMER && wParam == RecheckTimer) { Check(); return 0; }
        if (message == Win32.WM_WINDOWPOSCHANGING)
        {
            // The probe stays at the bottom whatever happens.
            var position = (Win32.WINDOWPOS*)lParam;
            position->InsertAfter = Win32.HWND_BOTTOM;
            position->Flags &= ~Win32.SWP_NOZORDER;
            return null;
        }
        if (taskbarCreated != 0 && message == taskbarCreated) { Reassert(); TaskbarCreated?.Invoke(); return 0; }
        return null;
    }

    /// <summary>Explorer started (again): the tray icon must be added again.</summary>
    public event Action? TaskbarCreated;

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvStdcall)])]
    private static void ForegroundChanged(nint hook, uint eventID, nint window, int objectID, int childID, uint thread, uint time)
    {
        try { current?.Check(); }
        catch (Exception error) { Log.Write($"foreground check failed: {error.Message}"); }
    }

    public override void Dispose()
    {
        if (hook != 0) { Win32.UnhookWinEvent(hook); hook = 0; }
        if (current == this) current = null;
        base.Dispose();
    }
}
