using System.Text;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using ScriptWidget.Core;
using ScriptWidget.Core.Hosting;
using ScriptWidget.Core.Packages;
using ScriptWidget.Core.Runtime;
using ScriptWidget.Studio.Editor;
using ScriptWidget.Studio.Services;

namespace ScriptWidget.Studio.Pages;

/// <summary>
/// One bundled template or example, opened from the grid: what it draws, its
/// code (read only), which hosts it contacts, and the one action that copies
/// it into the user's widgets. Nothing is installed until that action.
/// </summary>
public sealed partial class TemplateDetailPage : Page
{
    private BundledPackage? bundled;
    private StudioEditor? editor;
    private Dictionary<string, string> texts = new(StringComparer.Ordinal);
    private bool loading, previewRunning, previewQueued, busy;

    public TemplateDetailPage()
    {
        InitializeComponent();
        Dark.IsChecked = Preview.SystemIsDark;
        ActualThemeChanged += (_, _) => editor?.SetTheme(ActualTheme == ElementTheme.Dark);
    }

    private bool IsExample => bundled?.Group != "template";

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        if (e.Parameter is not BundledPackage package) { MainWindow.Current.BackFromDetail(); return; }
        bundled = package;
        TitleText.Text = package.Name;
        UseButton.Content = Loc.T(IsExample ? "action.openCopy" : "action.use");
        CopyButton.Visibility = IsExample ? Visibility.Visible : Visibility.Collapsed;
        Logs.Text = Loc.T("editor.noLogs");

        IReadOnlyDictionary<string, byte[]> files;
        try { files = await Task.Run(() => AppServices.Library.BundledFiles(package)); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { await MainWindow.Current.ShowErrorAsync(error.Message); MainWindow.Current.BackFromDetail(); return; }
        if (bundled != package) return;

        // The manifest the copy will get: the template's own, or the one made for a template without one.
        var manifest = files.TryGetValue(PackageManifests.FileName, out var manifestBytes) ? PackageManifests.Parse(Encoding.UTF8.GetString(manifestBytes)) : null;
        manifest ??= Library.BundledManifest(package.Name, files);
        var hosts = manifest.OptArray("networkDomains")?.Select(item => item?.AsText() ?? "").Where(host => host.Length > 0).ToList() ?? [];
        var network = hosts.Count > 0 ? Loc.T("detail.network", string.Join(", ", hosts)) : Loc.T("detail.noNetwork");
        InfoText.Text = manifest.OptString("description") is { Length: > 0 } description ? description + "  ·  " + network : network;

        var declared = manifest.OptArray("supportedFamilies")?.Select(item => WidgetFamilies.FromManifest(item?.AsText() ?? "")).OfType<string>().Distinct().ToList();
        var families = declared is { Count: > 0 } ? WidgetFamilies.All.Where(declared.Contains).ToList() : WidgetFamilies.All.ToList();
        loading = true;
        Family.Items.Clear();
        foreach (var family in families) Family.Items.Add(new ComboBoxItem { Content = Loc.Family(family), Tag = family });
        Family.SelectedIndex = Math.Max(0, families.IndexOf("medium"));

        // The code: the entry first, then the other text files. meta.json is not code.
        var entry = manifest.OptString("entry") is { Length: > 0 } declaredEntry && files.ContainsKey(declaredEntry) ? declaredEntry : PackageManifests.LegacyEntry;
        texts = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var path in files.Keys.OrderBy(path => path == entry ? 0 : 1).ThenBy(path => path, StringComparer.Ordinal))
        {
            if (path == PackageManifests.LegacyMetadata || !PackageCompiler.IsTextFile(path)) continue;
            try { texts[path] = new UTF8Encoding(false, true).GetString(files[path]); }
            catch (DecoderFallbackException) { }
        }
        Files.Items.Clear();
        foreach (var path in texts.Keys) Files.Items.Add(path);
        Files.Visibility = texts.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
        loading = false;

        editor = new StudioEditor(Web);
        editor.Ready += () => editor.SetTheme(ActualTheme == ElementTheme.Dark);
        // Without the WebView2 runtime the code is still readable, as plain text.
        editor.Failed += _ => { Web.Visibility = Visibility.Collapsed; PlainCode.Visibility = Visibility.Visible; };
        Files.SelectedIndex = texts.Count > 0 ? 0 : -1;
        if (texts.Count == 0) ShowFile(null);
        QueuePreview();
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        bundled = null;
        Web.Close();
    }

    private string? SelectedFile => Files.SelectedItem as string;

    private void OnFileSelected(object sender, SelectionChangedEventArgs arguments)
    {
        if (!loading) ShowFile(SelectedFile);
    }

    private void ShowFile(string? path)
    {
        var text = path is not null && texts.TryGetValue(path, out var found) ? found : "";
        PlainCodeText.Text = text;
        if (bundled is { } package) editor?.Open($"template:{package.Group}/{package.Name}/{path}", text, readOnly: true);
    }

    private void OnBack(object sender, RoutedEventArgs arguments) => MainWindow.Current.BackFromDetail();

    private void OnCopy(object sender, RoutedEventArgs arguments)
    {
        if (SelectedFile is not { } path || !texts.TryGetValue(path, out var text)) return;
        var data = new Windows.ApplicationModel.DataTransfer.DataPackage();
        data.SetText(text);
        Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(data);
        MainWindow.Current.Notify(Loc.T("toast.copied"));
    }

    private async void OnUse(object sender, RoutedEventArgs arguments)
    {
        if (bundled is not { } package || busy) return;
        busy = true;
        UseButton.IsEnabled = false;
        try
        {
            var installed = await Task.Run(() => AppServices.Library.InstallBundled(package));
            // A template is a widget: it goes on the desktop. An example is code to read and change.
            if (package.Group == "template") await LibraryPage.AddToDesktopAsync(installed, installed.Families.Contains("medium") ? "medium" : installed.Families[0]);
            else DesktopHost.LibraryChanged();
            MainWindow.Current.OpenEditor(installed.Name);
        }
        catch (Exception error) when (error is PackageException or IOException or UnauthorizedAccessException)
        {
            await MainWindow.Current.ShowErrorAsync(error.Message);
        }
        finally
        {
            busy = false;
            UseButton.IsEnabled = true;
        }
    }

    // MARK: - Preview

    private void OnPreviewOptionChanged(object sender, RoutedEventArgs arguments)
    {
        if (!loading) QueuePreview();
    }

    private void QueuePreview()
    {
        if (previewRunning) { previewQueued = true; return; }
        _ = RunPreviewAsync();
    }

    private async Task RunPreviewAsync()
    {
        if (bundled is not { } package) return;
        previewRunning = true;
        PreviewBusy.IsActive = true;
        try
        {
            var family = (Family.SelectedItem as ComboBoxItem)?.Tag as string ?? "medium";
            var result = await Preview.RenderAsync(new DiskPackageFiles(package.Directory), $"template:{package.Group}/{package.Name}", family, Dark.IsChecked == true, "", MainWindow.Current.RasterizationScale);
            if (bundled != package) return;
            var execution = result.Execution;
            var drawsNothing = Preview.DrawsNothing(execution);
            PreviewBox.Visibility = drawsNothing ? Visibility.Collapsed : Visibility.Visible;
            NoUIText.Visibility = drawsNothing ? Visibility.Visible : Visibility.Collapsed;
            PreviewImage.Source = result.Image;
            PreviewImage.Width = result.Width;
            PreviewImage.Height = result.Height;
            ErrorBar.IsOpen = execution.Error is not null;
            ErrorBar.Title = execution.Error?.Kind ?? "";
            ErrorBar.Message = execution.Error?.Message ?? "";
            var lines = Preview.LogLines(execution);
            Logs.Text = lines.Count > 0 ? string.Join("\n", lines) : execution.Error is null ? Loc.T("editor.ok", execution.ElapsedMilliseconds) : Loc.T("editor.noLogs");
        }
        catch (Exception error) when (error is not OutOfMemoryException)
        {
            ErrorBar.IsOpen = true;
            ErrorBar.Title = "";
            ErrorBar.Message = error.Message;
        }
        finally
        {
            previewRunning = false;
            PreviewBusy.IsActive = false;
            if (previewQueued) { previewQueued = false; _ = RunPreviewAsync(); }
        }
    }
}
