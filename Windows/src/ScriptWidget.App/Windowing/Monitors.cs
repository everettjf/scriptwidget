using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using ScriptWidget.App.Interop;

namespace ScriptWidget.App.Windowing;

/// <summary>One display. Rectangles are in physical pixels of the virtual screen.</summary>
internal sealed record Monitor(nint Handle, string Device, Win32.RECT Bounds, Win32.RECT Work, double Scale, bool Primary);

internal static unsafe class Monitors
{
    [ThreadStatic] private static List<Monitor>? collecting;

    public static IReadOnlyList<Monitor> All()
    {
        var result = new List<Monitor>();
        collecting = result;
        try { Win32.EnumDisplayMonitors(0, null, &Collect, 0); }
        finally { collecting = null; }
        return result;
    }

    public static Monitor? Describe(nint handle)
    {
        if (handle == 0) return null;
        var info = new Win32.MONITORINFOEXW { Size = (uint)sizeof(Win32.MONITORINFOEXW) };
        if (Win32.GetMonitorInfoW(handle, &info) == 0) return null;
        uint dpiX = 96, dpiY = 96;
        if (Win32.GetDpiForMonitor(handle, 0, &dpiX, &dpiY) != 0 || dpiX == 0) dpiX = 96;
        var device = new string(info.Device).TrimEnd('\0');
        var end = device.IndexOf('\0');
        if (end >= 0) device = device[..end];
        return new Monitor(handle, device, info.Monitor, info.Work, dpiX / 96.0, (info.Flags & Win32.MONITORINFOF_PRIMARY) != 0);
    }

    public static Monitor Primary() => Describe(Win32.MonitorFromPoint(default, Win32.MONITOR_DEFAULTTOPRIMARY)) ?? throw new InvalidOperationException("No display is attached");

    public static Monitor Containing(int x, int y) => Describe(Win32.MonitorFromPoint(new Win32.POINT { X = x, Y = y }, Win32.MONITOR_DEFAULTTONEAREST)) ?? Primary();

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvStdcall)])]
    private static int Collect(nint monitor, nint context, Win32.RECT* rectangle, nint data)
    {
        if (Describe(monitor) is { } described) collecting?.Add(described);
        return 1;
    }
}
