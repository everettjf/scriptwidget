using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace ScriptWidget.Core.Hosting;

/// <summary>Starting the desktop host when the user signs in.</summary>
public static class StartupRegistration
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "ScriptWidget";
    /// <summary>Identifier of the startup task declared in the MSIX manifest.</summary>
    public const string TaskID = "ScriptWidgetStartup";

    [DllImport("kernel32.dll")] private static extern unsafe int GetCurrentPackageFullName(uint* length, char* name);

    /// <summary>True when the program was installed as an MSIX package (from the Microsoft Store).</summary>
    public static unsafe bool IsPackaged
    {
        get
        {
            uint length = 0;
            return GetCurrentPackageFullName(&length, null) != 15700 /* APPMODEL_ERROR_NO_PACKAGE */;
        }
    }

    public static bool IsEnabled()
    {
        try
        {
            if (IsPackaged)
            {
                var task = Windows.ApplicationModel.StartupTask.GetAsync(TaskID).AsTask().GetAwaiter().GetResult();
                return task.State is Windows.ApplicationModel.StartupTaskState.Enabled or Windows.ApplicationModel.StartupTaskState.EnabledByPolicy;
            }
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(ValueName) is string;
        }
        catch (Exception error) when (error is not OutOfMemoryException) { return false; }
    }

    /// <summary>Turns starting at sign-in on or off. Returns the state afterwards; Windows or the user's policy may refuse.</summary>
    /// <param name="hostExecutable">Full path of ScriptWidget.exe, used when the program is not packaged.</param>
    public static bool SetEnabled(bool enabled, string? hostExecutable)
    {
        try
        {
            if (IsPackaged)
            {
                var task = Windows.ApplicationModel.StartupTask.GetAsync(TaskID).AsTask().GetAwaiter().GetResult();
                if (enabled) task.RequestEnableAsync().AsTask().GetAwaiter().GetResult(); else task.Disable();
            }
            else
            {
                using var key = Registry.CurrentUser.CreateSubKey(RunKey);
                if (enabled && hostExecutable is not null) key.SetValue(ValueName, $"\"{hostExecutable}\" --startup");
                else key.DeleteValue(ValueName, throwOnMissingValue: false);
            }
        }
        catch (Exception error) when (error is not OutOfMemoryException) { }
        return IsEnabled();
    }
}
