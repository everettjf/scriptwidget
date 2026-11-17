using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using ScriptWidget.Core.Hosting;
using ScriptWidget.Core.Packages;
using ScriptWidget.Core.Runtime;
using ScriptWidget.Studio.Services;

namespace ScriptWidget.Studio.Pages;

/// <summary>One widget in a grid: an installed package or a bundled template, with its preview.</summary>
public sealed class PackageCard : INotifyPropertyChanged
{
    private ImageSource? image;
    private string detail = "";
    private string output = "";
    private bool rendering;

    public required string Title { get; init; }
    public string Subtitle { get; init; } = "";
    /// <summary>Set for an installed package.</summary>
    public InstalledPackage? Installed { get; init; }
    /// <summary>Set for a bundled template.</summary>
    public BundledPackage? Bundled { get; init; }

    public ImageSource? Image
    {
        get => image;
        private set { image = value; Changed(nameof(Image)); Changed(nameof(PlaceholderVisibility)); }
    }

    /// <summary>A line under the title, such as how many widgets of it are on the desktop.</summary>
    public string Detail
    {
        get => detail;
        set { detail = value; Changed(nameof(Detail)); Changed(nameof(DetailVisibility)); }
    }

    public Visibility DetailVisibility => detail.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    public Visibility SubtitleVisibility => Subtitle.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    /// <summary>What an example that draws nothing printed; shown in place of a picture.</summary>
    public string Output
    {
        get => output;
        private set { output = value; Changed(nameof(Output)); Changed(nameof(OutputVisibility)); Changed(nameof(PlaceholderVisibility)); }
    }

    public string OutputLabel => Loc.T("editor.logs");
    public Visibility OutputVisibility => output.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    public Visibility PlaceholderVisibility => image is null && output.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
    public Visibility InstalledVisibility => Installed is not null ? Visibility.Visible : Visibility.Collapsed;
    public Visibility BundledVisibility => Bundled is not null ? Visibility.Visible : Visibility.Collapsed;

    public string EditLabel => Loc.T("action.edit");
    public string AddLabel => Loc.T("action.addToDesktop");
    public string UseLabel => Loc.T("action.use");
    public string MoreLabel => Loc.T("action.more");

    public bool HasPreview => image is not null || output.Length > 0 || rendering;

    /// <summary>Draws the medium-size preview once. Safe to call again; later calls do nothing.</summary>
    public async Task RenderAsync(double scale)
    {
        if (HasPreview) return;
        rendering = true;
        try
        {
            IPackageFiles files;
            string id;
            string? build = null;
            if (Installed is { } installed) { files = installed.Files; id = installed.Installation; build = installed.BuildDirectory; }
            else if (Bundled is { } bundled) { files = new DiskPackageFiles(bundled.Directory); id = "template:" + bundled.Group + "/" + bundled.Name; }
            else return;
            var result = await Preview.RenderAsync(files, id, "medium", Preview.SystemIsDark, "", scale, build);
            if (Preview.DrawsNothing(result.Execution))
            {
                var lines = Preview.LogLines(result.Execution);
                Output = lines.Count > 0 ? string.Join("\n", lines) : Loc.T("detail.noOutput");
            }
            else Image = result.Image;
        }
        catch (Exception error) when (error is not OutOfMemoryException) { /* the placeholder stays */ }
        finally { rendering = false; }
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    private void Changed(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
