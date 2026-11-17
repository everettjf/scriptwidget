namespace ScriptWidget.Core.Hosting;

/// <summary>
/// Where ScriptWidget keeps its data. Installed from the Microsoft Store, the
/// system redirects this folder into the package's private storage, so the
/// same code serves the packaged and the unpackaged program.
/// </summary>
public sealed class DataPaths
{
    public DataPaths(string? root = null)
    {
        Root = root ?? Environment.GetEnvironmentVariable("SCRIPTWIDGET_DATA") ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ScriptWidget");
        Directory.CreateDirectory(Root);
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
