using System.Collections.Concurrent;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using ScriptWidget.App.Interop;

namespace ScriptWidget.App.Windowing;

/// <summary>A Win32 window whose messages are handled by a C# object. Windows are created and used on the UI thread.</summary>
internal abstract unsafe class NativeWindow : IDisposable
{
    private static readonly Dictionary<nint, NativeWindow> Windows = new();
    private static readonly HashSet<string> Classes = new();
    [ThreadStatic] private static NativeWindow? creating;

    public nint Handle { get; private set; }

    protected void Create(string className, uint exStyle, uint style, nint parent = 0)
    {
        var instance = Win32.GetModuleHandleW(null);
        fixed (char* name = className)
        {
            if (Classes.Add(className))
            {
                var windowClass = new Win32.WNDCLASSEXW
                {
                    Size = (uint)sizeof(Win32.WNDCLASSEXW),
                    Style = 0x0008 /* CS_DBLCLKS */,
                    WindowProcedure = &WindowProcedure,
                    Instance = instance,
                    Cursor = Win32.LoadCursorW(0, Win32.IDC_ARROW),
                    ClassName = name,
                };
                if (Win32.RegisterClassExW(&windowClass) == 0) throw new InvalidOperationException($"Could not register window class {className} (error {Marshal.GetLastPInvokeError()})");
            }
            creating = this;
            try
            {
                Handle = Win32.CreateWindowExW(exStyle, name, name, style, 0, 0, 0, 0, parent, 0, instance, 0);
            }
            finally { creating = null; }
        }
        if (Handle == 0) throw new InvalidOperationException($"Could not create window {className} (error {Marshal.GetLastPInvokeError()})");
        Windows[Handle] = this;
    }

    /// <summary>Handles one message. Return null to let Windows handle it.</summary>
    protected abstract nint? OnMessage(uint message, nuint wParam, nint lParam);

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvStdcall)])]
    private static nint WindowProcedure(nint window, uint message, nuint wParam, nint lParam)
    {
        try
        {
            var target = Windows.TryGetValue(window, out var known) ? known : creating;
            if (target is not null)
            {
                if (target.Handle == 0) target.Handle = window;
                if (target.OnMessage(message, wParam, lParam) is { } result) return result;
            }
        }
        catch (Exception error)
        {
            // An exception must not unwind into the window manager.
            Log.Write($"window message {message:X}: {error}");
        }
        return Win32.DefWindowProcW(window, message, wParam, lParam);
    }

    public virtual void Dispose()
    {
        if (Handle == 0) return;
        var handle = Handle;
        Handle = 0;
        Win32.DestroyWindow(handle);
        Windows.Remove(handle);
    }
}

/// <summary>Runs work on the UI thread from any thread.</summary>
internal sealed unsafe class UiDispatcher : NativeWindow
{
    private const uint Wake = Win32.WM_APP + 1;
    private readonly ConcurrentQueue<Action> queue = new();
    private readonly int thread = Environment.CurrentManagedThreadId;

    public UiDispatcher() => Create("ScriptWidgetDispatcher", 0, 0, Win32.HWND_MESSAGE);

    public bool OnUiThread => Environment.CurrentManagedThreadId == thread;

    public void Post(Action work)
    {
        queue.Enqueue(work);
        var handle = Handle;
        if (handle != 0) Win32.PostMessageW(handle, Wake, 0, 0);
    }

    protected override nint? OnMessage(uint message, nuint wParam, nint lParam)
    {
        if (message != Wake) return null;
        while (queue.TryDequeue(out var work))
        {
            try { work(); }
            catch (Exception error) { Log.Write($"dispatched work failed: {error}"); }
        }
        return 0;
    }
}

/// <summary>A small rolling log in the data folder. Never receives package output, tokens or response bodies.</summary>
internal static class Log
{
    private static readonly object Gate = new();
    public static string? File { get; set; }
    /// <summary>Extra detail for diagnosing input on a real desktop; set SCRIPTWIDGET_VERBOSE=1.</summary>
    public static bool Verbose { get; } = Environment.GetEnvironmentVariable("SCRIPTWIDGET_VERBOSE") == "1";

    public static void Write(string message)
    {
        var line = $"{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss.fff} {message}";
        System.Diagnostics.Debug.WriteLine(line);
        if (File is not { } path) return;
        lock (Gate)
        {
            try
            {
                var info = new FileInfo(path);
                if (info.Exists && info.Length > 512 * 1024) System.IO.File.Move(path, path + ".1", overwrite: true);
                System.IO.File.AppendAllText(path, line + Environment.NewLine);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
    }
}
