using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using ScriptWidget.App.Interop;

namespace ScriptWidget.App.Windowing;

/// <summary>
/// Keeps the widget windows on the desktop: below every ordinary window, and
/// still visible when the user asks Windows to show the desktop.
///
/// The widgets are top-level windows held directly above the desktop window
/// in the window order (the approach Rainmeter uses) rather than children of
/// the shell's desktop window, which broke for other programs when Windows
/// 11 24H2 rearranged that window.
///
/// "Show desktop" (Win+D, the taskbar corner) raises the window that hosts
/// the desktop icons above everything and makes it the foreground window,
/// which would cover the widgets, so while that state lasts the widgets are
/// raised too. Since Windows 11 24H2 that window is Progman itself; before,
/// it is a WorkerW that takes over the icons (Rainmeter's System.cpp
/// documents both layouts). The state is detected with a hidden probe window
/// kept directly above the desktop like the widgets: the desktop is being
/// shown when the icons window is the foreground window and has moved above
/// the probe. Both conditions must hold, so a click on the wallpaper, which
/// makes the desktop the foreground window without raising it, never lifts
/// widgets over ordinary windows. If a Windows version shows the desktop
/// another way, the widgets are covered until the desktop is left.
/// </summary>
internal sealed unsafe class DesktopLayer : NativeWindow
{
    private const string ProbeClass = "ScriptWidgetDesktopProbe";
    private const nuint RecheckTimer = 1;
    private const nuint SettleTimer = 2;
    private int settleAttempts;
    private static DesktopLayer? current;

    private const uint GW_HWNDPREV = 3;
    private readonly List<WidgetWindow> windows = new();
    private nint hook;
    private bool placingProbe;
    private readonly uint taskbarCreated;

    /// <summary>For the self-test: a stand-in for the desktop window, so "show desktop" can be acted out without touching the real one.</summary>
    internal static nint HostOverride;
    /// <summary>For the self-test: which window counts as the foreground window.</summary>
    internal static Func<nint>? ForegroundOverride;

    /// <summary>True while Windows is showing the desktop and the widgets are raised above it.</summary>
    public bool DesktopShown { get; private set; }

    public DesktopLayer()
    {
        Create(ProbeClass, Win32.WS_EX_TOOLWINDOW | Win32.WS_EX_NOACTIVATE, Win32.WS_POPUP);
        PlaceProbe();
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
        PlaceProbe();
        Check();
        foreach (var window in windows) Place(window);
    }

    private void Place(WidgetWindow window)
    {
        if (DesktopShown) window.SetOrder(Win32.HWND_TOPMOST);
        else
        {
            window.SetOrder(Win32.HWND_NOTOPMOST);
            window.SetOrder(AboveDesktop(window.Handle));
        }
    }

    private void PlaceProbe()
    {
        placingProbe = true;
        try { Win32.SetWindowPos(Handle, AboveDesktop(Handle), 0, 0, 0, 0, Win32.SWP_NOMOVE | Win32.SWP_NOSIZE | Win32.SWP_NOACTIVATE | Win32.SWP_NOOWNERZORDER); }
        finally { placingProbe = false; }
    }

    /// <summary>
    /// The window to insert <paramref name="window"/> after so that it lands directly above the
    /// desktop: below every ordinary window, above the window that draws the wallpaper and icons.
    /// HWND_BOTTOM is not it. On Windows 11 that puts a window underneath the desktop window, where
    /// it is neither seen nor clicked.
    /// </summary>
    private static nint AboveDesktop(nint window)
    {
        var desktop = IconsHost();
        if (desktop == 0) return Win32.HWND_BOTTOM;
        // The nearest window above the desktop that is not the one being placed.
        var previous = Win32.GetWindow(desktop, GW_HWNDPREV);
        if (previous == window) previous = Win32.GetWindow(previous, GW_HWNDPREV);
        return previous != 0 ? previous : Win32.HWND_BOTTOM;
    }

    /// <summary>The top-level window that hosts the desktop icons: Progman, or a WorkerW on some configurations.</summary>
    private static nint IconsHost()
    {
        if (HostOverride != 0) return HostOverride;
        var worker = IconsWorker();
        return worker != 0 ? worker : Win32.GetShellWindow();
    }

    /// <summary>A WorkerW window that hosts the desktop icons, or 0 when the icons live in Progman.</summary>
    private static nint IconsWorker()
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
        return 0;
    }

    /// <summary>Compares the desktop window with the probe and raises or lowers the widgets when the state changed.</summary>
    public void Check()
    {
        var host = IconsHost();
        var shown = false;
        var foreground = ForegroundOverride?.Invoke() ?? Win32.GetForegroundWindow();
        if (host != 0 && Win32.IsWindowVisible(host) != 0 && foreground == host)
        {
            // FindWindowEx searches the windows below `host` in the window order: the probe is
            // there only after the desktop window was raised above it.
            fixed (char* probe = ProbeClass) shown = Win32.FindWindowExW(0, host, probe, null) == Handle;
            // The foreground change can arrive a moment before the window order changes.
            if (!shown && !DesktopShown && settleAttempts == 0) { settleAttempts = 6; Win32.SetTimer(Handle, SettleTimer, 40, 0); }
        }
        if (shown == DesktopShown) return;
        DesktopShown = shown;
        foreach (var window in windows) Place(window);
        if (!shown) PlaceProbe();
        if (shown) Win32.SetTimer(Handle, RecheckTimer, 500, 0);
        else Win32.KillTimer(Handle, RecheckTimer);
    }

    protected override nint? OnMessage(uint message, nuint wParam, nint lParam)
    {
        if (message == Win32.WM_TIMER && wParam == RecheckTimer) { Check(); return 0; }
        if (message == Win32.WM_TIMER && wParam == SettleTimer)
        {
            settleAttempts -= 1;
            var remaining = settleAttempts;
            settleAttempts = -1; // keeps Check from starting another round
            Check();
            settleAttempts = DesktopShown ? 0 : Math.Max(remaining, 0);
            if (settleAttempts == 0) Win32.KillTimer(Handle, SettleTimer);
            return 0;
        }
        if (message == Win32.WM_WINDOWPOSCHANGING)
        {
            // Only this class moves the probe in the window order.
            if (!placingProbe) ((Win32.WINDOWPOS*)lParam)->Flags |= Win32.SWP_NOZORDER;
            return null;
        }
        if (taskbarCreated != 0 && message == taskbarCreated) { if (Log.Verbose) Log.Write("taskbar created"); Reassert(); TaskbarCreated?.Invoke(); return 0; }
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
