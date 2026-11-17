using ScriptWidget.App.Interop;

namespace ScriptWidget.App;

internal static class Program
{
    [STAThread]
    private static int Main(string[] arguments)
    {
        Win32.SetProcessDpiAwarenessContext(Win32.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        if (arguments.Length > 0 && arguments[0] == "--selftest-window") return SelfTest.Run(arguments);
        return 0;
    }
}
