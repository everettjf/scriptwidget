using System.Runtime.InteropServices;

namespace ScriptWidget.App.Interop;

/// <summary>The Win32 calls the desktop host uses. Every signature is blittable, so it works under native AOT.</summary>
internal static unsafe class Win32
{
    // MARK: - Constants

    public const uint WS_POPUP = 0x80000000;
    public const uint WS_EX_LAYERED = 0x00080000;
    public const uint WS_EX_TOOLWINDOW = 0x00000080;
    public const uint WS_EX_NOACTIVATE = 0x08000000;
    public const uint WS_EX_TOPMOST = 0x00000008;

    public const uint WM_DESTROY = 0x0002;
    public const uint WM_CLOSE = 0x0010;
    public const uint WM_QUERYENDSESSION = 0x0011;
    public const uint WM_ENDSESSION = 0x0016;
    public const uint WM_SETTINGCHANGE = 0x001A;
    public const uint WM_TIMECHANGE = 0x001E;
    public const uint WM_SETCURSOR = 0x0020;
    public const uint WM_MOUSEACTIVATE = 0x0021;
    public const uint WM_WINDOWPOSCHANGING = 0x0046;
    public const uint WM_DISPLAYCHANGE = 0x007E;
    public const uint WM_CONTEXTMENU = 0x007B;
    public const uint WM_NCHITTEST = 0x0084;
    public const uint WM_COMMAND = 0x0111;
    public const uint WM_TIMER = 0x0113;
    public const uint WM_MOUSEMOVE = 0x0200;
    public const uint WM_LBUTTONDOWN = 0x0201;
    public const uint WM_LBUTTONUP = 0x0202;
    public const uint WM_LBUTTONDBLCLK = 0x0203;
    public const uint WM_RBUTTONUP = 0x0205;
    public const uint WM_CAPTURECHANGED = 0x0215;
    public const uint WM_POWERBROADCAST = 0x0218;
    public const uint WM_DPICHANGED = 0x02E0;
    public const uint WM_APP = 0x8000;
    public const uint WM_NULL = 0x0000;

    public const int PBT_APMRESUMEAUTOMATIC = 0x0012;
    public const int MA_NOACTIVATE = 3;
    public const int HTCLIENT = 1;
    public const int HTTRANSPARENT = -1;

    public static readonly nint HWND_BOTTOM = 1;
    public static readonly nint HWND_TOPMOST = -1;
    public static readonly nint HWND_NOTOPMOST = -2;
    public static readonly nint HWND_MESSAGE = -3;

    public const uint SWP_NOSIZE = 0x0001;
    public const uint SWP_NOMOVE = 0x0002;
    public const uint SWP_NOZORDER = 0x0004;
    public const uint SWP_NOACTIVATE = 0x0010;
    public const uint SWP_SHOWWINDOW = 0x0040;
    public const uint SWP_HIDEWINDOW = 0x0080;
    public const uint SWP_NOOWNERZORDER = 0x0200;
    public const uint SWP_NOSENDCHANGING = 0x0400;

    public const int SW_HIDE = 0;
    public const int SW_SHOWNOACTIVATE = 4;
    public const int SW_SHOWNORMAL = 1;

    public const uint ULW_ALPHA = 0x00000002;
    public const byte AC_SRC_OVER = 0;
    public const byte AC_SRC_ALPHA = 1;

    public const uint MONITOR_DEFAULTTONULL = 0;
    public const uint MONITOR_DEFAULTTOPRIMARY = 1;
    public const uint MONITOR_DEFAULTTONEAREST = 2;
    public const uint MONITORINFOF_PRIMARY = 1;

    public const uint MF_STRING = 0x0000;
    public const uint MF_GRAYED = 0x0001;
    public const uint MF_CHECKED = 0x0008;
    public const uint MF_POPUP = 0x0010;
    public const uint MF_SEPARATOR = 0x0800;
    public const uint TPM_RIGHTBUTTON = 0x0002;
    public const uint TPM_RETURNCMD = 0x0100;
    public const uint TPM_NONOTIFY = 0x0080;

    public const uint NIM_ADD = 0, NIM_MODIFY = 1, NIM_DELETE = 2, NIM_SETVERSION = 4;
    public const uint NIF_MESSAGE = 1, NIF_ICON = 2, NIF_TIP = 4, NIF_SHOWTIP = 0x80;
    public const uint NOTIFYICON_VERSION_4 = 4;
    public const uint NIN_SELECT = 0x0400;
    public const uint NIN_KEYSELECT = 0x0401;

    public const uint EVENT_SYSTEM_FOREGROUND = 0x0003;
    public const uint WINEVENT_OUTOFCONTEXT = 0;
    public const uint WINEVENT_SKIPOWNPROCESS = 2;

    public const uint IMAGE_ICON = 1;
    public const uint LR_LOADFROMFILE = 0x0010;
    public const uint LR_DEFAULTSIZE = 0x0040;
    public const uint LR_SHARED = 0x8000;
    public static readonly nint IDC_ARROW = 32512;
    public static readonly nint IDC_HAND = 32649;
    public static readonly nint IDC_SIZEALL = 32646;
    public static readonly nint IDI_APPLICATION = 32512;

    public static readonly nint DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4;

    // MARK: - Structures

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct SIZE { public int Width, Height; }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left, Top, Right, Bottom;
        public readonly int Width => Right - Left;
        public readonly int Height => Bottom - Top;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MSG { public nint Window; public uint Message; public nuint WParam; public nint LParam; public uint Time; public POINT Point; public uint Private; }

    [StructLayout(LayoutKind.Sequential)]
    public struct WNDCLASSEXW
    {
        public uint Size, Style;
        public delegate* unmanaged[Stdcall]<nint, uint, nuint, nint, nint> WindowProcedure;
        public int ClassExtra, WindowExtra;
        public nint Instance, Icon, Cursor, Background;
        public char* MenuName, ClassName;
        public nint SmallIcon;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct WINDOWPOS { public nint Window, InsertAfter; public int X, Y, Width, Height; public uint Flags; }

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    public struct BLENDFUNCTION { public byte BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat; }

    [StructLayout(LayoutKind.Sequential)]
    public struct BITMAPINFOHEADER
    {
        public uint Size; public int Width, Height; public ushort Planes, BitCount; public uint Compression, SizeImage;
        public int XPelsPerMeter, YPelsPerMeter; public uint ColorsUsed, ColorsImportant;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MONITORINFOEXW
    {
        public uint Size; public RECT Monitor, Work; public uint Flags;
        public fixed char Device[32];
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct NOTIFYICONDATAW
    {
        public uint Size; public nint Window; public uint ID, Flags, CallbackMessage; public nint Icon;
        public fixed char Tip[128];
        public uint State, StateMask;
        public fixed char Info[256];
        public uint VersionOrTimeout;
        public fixed char InfoTitle[64];
        public uint InfoFlags; public Guid Item; public nint BalloonIcon;
    }

    // MARK: - user32

    private const string User = "user32.dll";

    [DllImport(User, SetLastError = true)] public static extern ushort RegisterClassExW(WNDCLASSEXW* windowClass);
    [DllImport(User, SetLastError = true)] public static extern nint CreateWindowExW(uint exStyle, char* className, char* title, uint style, int x, int y, int width, int height, nint parent, nint menu, nint instance, nint parameter);
    [DllImport(User)] public static extern nint DefWindowProcW(nint window, uint message, nuint wParam, nint lParam);
    [DllImport(User)] public static extern int DestroyWindow(nint window);
    [DllImport(User)] public static extern int ShowWindow(nint window, int command);
    [DllImport(User)] public static extern int IsWindowVisible(nint window);
    [DllImport(User)] public static extern int SetWindowPos(nint window, nint insertAfter, int x, int y, int width, int height, uint flags);
    [DllImport(User)] public static extern int GetWindowRect(nint window, RECT* rectangle);
    [DllImport(User)] public static extern int GetMessageW(MSG* message, nint window, uint filterMinimum, uint filterMaximum);
    [DllImport(User)] public static extern int TranslateMessage(MSG* message);
    [DllImport(User)] public static extern nint DispatchMessageW(MSG* message);
    [DllImport(User)] public static extern int PostMessageW(nint window, uint message, nuint wParam, nint lParam);
    [DllImport(User)] public static extern void PostQuitMessage(int exitCode);
    [DllImport(User)] public static extern int UpdateLayeredWindow(nint window, nint destination, POINT* position, SIZE* size, nint source, POINT* sourcePoint, uint colorKey, BLENDFUNCTION* blend, uint flags);
    [DllImport(User)] public static extern nint GetDC(nint window);
    [DllImport(User)] public static extern int ReleaseDC(nint window, nint context);
    [DllImport(User)] public static extern nint SetCapture(nint window);
    [DllImport(User)] public static extern int ReleaseCapture();
    [DllImport(User)] public static extern int GetCursorPos(POINT* point);
    [DllImport(User)] public static extern nint SetCursor(nint cursor);
    [DllImport(User)] public static extern nint LoadCursorW(nint instance, nint name);
    [DllImport(User)] public static extern nint LoadIconW(nint instance, nint name);
    [DllImport(User)] public static extern nint LoadImageW(nint instance, char* name, uint type, int width, int height, uint flags);
    [DllImport(User)] public static extern nint MonitorFromWindow(nint window, uint flags);
    [DllImport(User)] public static extern nint MonitorFromPoint(POINT point, uint flags);
    [DllImport(User)] public static extern int GetMonitorInfoW(nint monitor, MONITORINFOEXW* information);
    [DllImport(User)] public static extern int EnumDisplayMonitors(nint context, RECT* clip, delegate* unmanaged[Stdcall]<nint, nint, RECT*, nint, int> callback, nint data);
    [DllImport(User)] public static extern uint GetDpiForWindow(nint window);
    [DllImport(User)] public static extern int SetProcessDpiAwarenessContext(nint context);
    [DllImport(User)] public static extern uint RegisterWindowMessageW(char* name);
    [DllImport(User)] public static extern nint CreatePopupMenu();
    [DllImport(User)] public static extern int AppendMenuW(nint menu, uint flags, nuint item, char* text);
    [DllImport(User)] public static extern int TrackPopupMenuEx(nint menu, uint flags, int x, int y, nint window, void* parameters);
    [DllImport(User)] public static extern int DestroyMenu(nint menu);
    [DllImport(User)] public static extern int SetForegroundWindow(nint window);
    [DllImport(User)] public static extern nint GetForegroundWindow();
    [DllImport(User)] public static extern int GetClassNameW(nint window, char* name, int capacity);
    [DllImport(User)] public static extern nint SetWinEventHook(uint eventMinimum, uint eventMaximum, nint module, delegate* unmanaged[Stdcall]<nint, uint, nint, int, int, uint, uint, void> callback, uint process, uint thread, uint flags);
    [DllImport(User)] public static extern int UnhookWinEvent(nint hook);
    [DllImport(User)] public static extern nuint SetTimer(nint window, nuint id, uint milliseconds, nint callback);
    [DllImport(User)] public static extern int KillTimer(nint window, nuint id);
    [DllImport(User)] public static extern nint FindWindowExW(nint parent, nint after, char* className, char* title);
    [DllImport(User)] public static extern nint GetWindow(nint window, uint command);
    [DllImport(User)] public static extern nint WindowFromPoint(POINT point);
    [DllImport(User)] public static extern int MessageBoxW(nint window, char* text, char* caption, uint type);
    [DllImport(User)] public static extern nint GetShellWindow();

    // MARK: - gdi32, shcore, shell32, kernel32

    [DllImport("gdi32.dll")] public static extern nint CreateCompatibleDC(nint context);
    [DllImport("gdi32.dll")] public static extern int DeleteDC(nint context);
    [DllImport("gdi32.dll")] public static extern nint CreateDIBSection(nint context, BITMAPINFOHEADER* information, uint usage, void** bits, nint section, uint offset);
    [DllImport("gdi32.dll")] public static extern nint SelectObject(nint context, nint value);
    [DllImport("gdi32.dll")] public static extern int DeleteObject(nint value);

    [DllImport("shcore.dll")] public static extern int GetDpiForMonitor(nint monitor, int type, uint* dpiX, uint* dpiY);

    [DllImport("shell32.dll")] public static extern int Shell_NotifyIconW(uint message, NOTIFYICONDATAW* data);
    [DllImport("shell32.dll")] public static extern int SHQueryUserNotificationState(int* state);
    [DllImport("shell32.dll")] public static extern nint ShellExecuteW(nint window, char* operation, char* file, char* parameters, char* directory, int show);

    [DllImport("kernel32.dll")] public static extern nint GetModuleHandleW(char* name);

    // MARK: - Helpers

    public static int LowWord(nint value) => (short)(value & 0xFFFF);
    public static int HighWord(nint value) => (short)((value >> 16) & 0xFFFF);
    public static int LowWord(nuint value) => (int)(value & 0xFFFF);
    public static int HighWord(nuint value) => (int)((value >> 16) & 0xFFFF);

    public static string ClassName(nint window)
    {
        var buffer = stackalloc char[128];
        var length = GetClassNameW(window, buffer, 128);
        return length <= 0 ? "" : new string(buffer, 0, length);
    }
}
