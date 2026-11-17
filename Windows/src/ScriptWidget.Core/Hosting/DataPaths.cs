namespace ScriptWidget.Core.Hosting;

/// <summary>
/// Where ScriptWidget keeps its data: <c>%LOCALAPPDATA%\ScriptWidget</c>, or
/// the package's own local folder when the program is installed from the
/// Microsoft Store, which Windows removes on uninstall.
/// </summary>
public sealed class DataPaths
{
    public DataPaths(string? root = null)
    {
        Root = root ?? Environment.GetEnvironmentVariable("SCRIPTWIDGET_DATA") ?? DefaultRoot();
        Directory.CreateDirectory(Root);
    }

    private static string DefaultRoot()
    {
        if (StartupRegistration.IsPackaged)
        {
            // The real folder, not %LOCALAPPDATA%: Windows would redirect that for a packaged program,
            // and the redirection does not support moving a directory, which a transactional
            // package install does.
            try { return Path.Combine(Windows.Storage.ApplicationData.Current.LocalFolder.Path, "ScriptWidget"); }
            catch (Exception error) when (error is not OutOfMemoryException) { }
        }
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ScriptWidget");
    }

    public string Root { get; }
    /// <summary>Installed packages, one folder each.</summary>
    public string Packages => Path.Combine(Root, "Packages");
    /// <summary>Package-scoped <c>$storage</c> files.</summary>
    public string Storage => Path.Combine(Root, "Storage");
    /// <summary>Compiled artifacts, remote images and other data that can be rebuilt.</summary>
    public string Cache => Path.Combine(Root, "Cache");
    public string Plugins => Path.Combine(Root, "Plugins");
    /// <summary>The widgets placed on the desktop.</summary>
    public string Widgets => Path.Combine(Root, "widgets.json");
    public string Settings => Path.Combine(Root, "settings.json");
    public string Log => Path.Combine(Root, "host.log");
}
