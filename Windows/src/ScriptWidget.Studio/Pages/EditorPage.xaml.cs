using System.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using ScriptWidget.Core.Hosting;
using ScriptWidget.Core.Packages;
using ScriptWidget.Core.Runtime;
using ScriptWidget.Studio.Editor;
using ScriptWidget.Studio.Services;

namespace ScriptWidget.Studio.Pages;

/// <summary>
/// Edits one installed package: its files, the code of the selected file, and
/// a preview that is drawn by the same renderer as the desktop widget and
/// follows the code as it is typed.
/// </summary>
public sealed partial class EditorPage : Page
{
    private readonly DispatcherTimer poll = new() { Interval = TimeSpan.FromMilliseconds(700) };
    private StudioEditor? editor;
    private InstalledPackage? package;
    private string? path;
    /// <summary>Text of the open file as it is on disk.</summary>
    private string saved = "";
    /// <summary>Text of the open file as last read from the editor.</summary>
    private string current = "";
    private string previewed = "\0";
    private bool previewRunning, previewQueued, polling, switching;
    private int previewOptions;

    public EditorPage()
    {
        InitializeComponent();
        foreach (var family in WidgetFamilies.All) Family.Items.Add(new ComboBoxItem { Content = Loc.Family(family), Tag = family });
        Dark.IsChecked = Preview.SystemIsDark;
        Logs.Text = Loc.T("editor.noLogs");
        poll.Tick += async (_, _) => await PollAsync();
        ActualThemeChanged += (_, _) => editor?.SetTheme(ActualTheme == ElementTheme.Dark);
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        if (e.Parameter is not string name || AppServices.Library.Find(name) is not { } found) { MainWindow.Current.ShowLibrary(); return; }
        package = found;
        TitleText.Text = found.DisplayName;
        // Offer only the sizes the package says it supports.
        Family.Items.Clear();
        foreach (var family in found.Families) Family.Items.Add(new ComboBoxItem { Content = Loc.Family(family), Tag = family });
        Family.SelectedIndex = Math.Max(0, found.Families.ToList().IndexOf("medium"));
        var menu = new MenuFlyout();
        foreach (var family in found.Families)
        {
            var item = new MenuFlyoutItem { Text = Loc.Family(family) };
            item.Click += async (_, _) => { await SaveAsync(); await LibraryPage.AddToDesktopAsync(found, family); };
            menu.Items.Add(item);
        }
        AddButton.Flyout = menu;

        editor = new StudioEditor(Web) { Save = text => { _ = SaveTextAsync(text); return true; } };
        editor.Ready += () => editor.SetTheme(ActualTheme == ElementTheme.Dark);
        editor.Failed += message => { Web.Visibility = Visibility.Collapsed; EditorMessage.Text = Loc.T("editor.failed", message); EditorMessage.Visibility = Visibility.Visible; };
        LoadFiles(found.Manifest is { } manifest && ScriptWidget.Core.Json.OptString(manifest, "entry") is { Length: > 0 } entry ? entry : PackageManifests.LegacyEntry);
        poll.Start();
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        poll.Stop();
        SaveNow();
        Web.Close();
    }

    private string SelectedFamily => (Family.SelectedItem as ComboBoxItem)?.Tag as string ?? "medium";

    // MARK: - Files

    private void LoadFiles(string? select)
    {
        if (package is null) return;
        switching = true;
        Files.Items.Clear();
        foreach (var file in package.Files.Paths()) Files.Items.Add(file);
        switching = false;
        var index = select is null ? -1 : Files.Items.IndexOf(select);
        Files.SelectedIndex = index >= 0 ? index : Files.Items.Count > 0 ? 0 : -1;
    }

    private async void OnFileSelected(object sender, SelectionChangedEventArgs arguments)
    {
        if (switching || package is null || Files.SelectedItem is not string selected || selected == path) return;
        await SaveAsync();
        path = selected;
        var text = PackageCompiler.IsTextFile(selected) ? package.Files.ReadText(selected) : null;
        if (text is null)
        {
            Web.Visibility = Visibility.Collapsed;
            EditorMessage.Text = Loc.T("editor.binary");
            EditorMessage.Visibility = Visibility.Visible;
            saved = current = "";
            path = null;
        }
        else
        {
            EditorMessage.Visibility = Visibility.Collapsed;
            Web.Visibility = Visibility.Visible;
            saved = current = text;
            editor?.Open(package.Installation + "/" + selected, text);
        }
        UpdateStatus();
        QueuePreview();
    }

    private async void OnNewFile(object sender, RoutedEventArgs arguments)
    {
        if (package is null) return;
        if (await MainWindow.Current.PromptAsync(Loc.T("editor.newFile.title"), Loc.T("editor.newFile.hint")) is not { } name) return;
        try
        {
            await SaveAsync();
            var installed = package;
            await Task.Run(() => AppServices.Library.WriteFile(installed.Name, name.Replace('\\', '/'), []));
            LoadFiles(PackagePaths.Normalize(name.Replace('\\', '/')));
        }
        catch (Exception error) when (error is PackageException or IOException or UnauthorizedAccessException)
        {
            await MainWindow.Current.ShowErrorAsync(error.Message);
        }
    }

    // MARK: - Saving

    /// <summary>Reads the editor on a timer: marks unsaved changes and keeps the preview following the code.</summary>
    private async Task PollAsync()
    {
        if (polling || editor is null || path is null) return;
        polling = true;
        try
        {
            var openPath = path;
            if (await editor.ContentAsync() is { } text && openPath == path && text != current)
            {
                current = text;
                UpdateStatus();
                QueuePreview();
            }
        }
        finally { polling = false; }
    }

    private void UpdateStatus() => StatusText.Text = path is null ? "" : current != saved ? $"{path} · {Loc.T("editor.unsaved")}" : path;

    private async Task SaveAsync()
    {
        if (editor is null || path is null) return;
        if (await editor.ContentAsync() is { } text) current = text;
        await SaveTextAsync(current);
    }

    private async Task SaveTextAsync(string text)
    {
        if (package is null || path is null || text == saved) return;
        var installed = package;
        var file = path;
        try
        {
            await Task.Run(() => AppServices.Library.WriteFile(installed.Name, file, Encoding.UTF8.GetBytes(text)));
            if (file == path) { saved = text; current = text; UpdateStatus(); }
            // The widgets of this package on the desktop pick up the new code.
            DesktopHost.LibraryChanged();
        }
        catch (Exception error) when (error is PackageException or IOException or UnauthorizedAccessException)
        {
            MainWindow.Current.Notify(Loc.T("editor.saveFailed", error.Message), InfoBarSeverity.Error);
        }
    }

    /// <summary>Saves what was last read from the editor, without waiting for the editor. Used when the page or window closes.</summary>
    public void SaveNow()
    {
        if (package is null || path is null || current == saved) return;
        try
        {
            AppServices.Library.WriteFile(package.Name, path, Encoding.UTF8.GetBytes(current));
            saved = current;
            DesktopHost.LibraryChanged();
        }
        catch (Exception error) when (error is PackageException or IOException or UnauthorizedAccessException) { }
    }

    private async void OnSave(object sender, RoutedEventArgs arguments)
    {
        await SaveAsync();
        if (current == saved) MainWindow.Current.Notify(Loc.T("editor.saved"));
    }

    private void OnFormat(object sender, RoutedEventArgs arguments) => editor?.Format();

    private async void OnExport(object sender, RoutedEventArgs arguments)
    {
        if (package is null) return;
        await SaveAsync();
        try { await LibraryPage.ExportAsync(package); }
        catch (Exception error) when (error is PackageException or IOException or UnauthorizedAccessException) { await MainWindow.Current.ShowErrorAsync(error.Message); }
    }

    private void OnOpenFolder(object sender, RoutedEventArgs arguments)
    {
        if (package is not null) LibraryPage.OpenFolder(package.Directory);
    }

    private async void OnBack(object sender, RoutedEventArgs arguments)
    {
        await SaveAsync();
        MainWindow.Current.ShowLibrary();
    }

    // MARK: - Preview

    private void OnPreviewOptionChanged(object sender, RoutedEventArgs arguments)
    {
        previewOptions += 1;
        QueuePreview();
    }

    private void OnParameterChanged(object sender, TextChangedEventArgs arguments)
    {
        previewOptions += 1;
        QueuePreview();
    }

    private void QueuePreview()
    {
        if (previewRunning) { previewQueued = true; return; }
        _ = RunPreviewAsync();
    }

    private async Task RunPreviewAsync()
    {
        if (package is null) return;
        var key = $"{previewOptions}|{path}|{current}";
        if (key == previewed) return;
        previewed = key;
        previewRunning = true;
        PreviewBusy.IsActive = true;
        try
        {
            // The preview runs the files on disk with the text in the editor laid over the open file.
            IPackageFiles files = path is null ? package.Files : new OverlayPackageFiles(package.Files, path, current);
            var result = await Preview.RenderAsync(files, package.Installation, SelectedFamily, Dark.IsChecked == true, Parameter.Text, MainWindow.Current.RasterizationScale);
            PreviewImage.Source = result.Image;
            PreviewImage.Width = result.Width;
            PreviewImage.Height = result.Height;
            var execution = result.Execution;
            ErrorBar.IsOpen = execution.Error is not null;
            ErrorBar.Title = execution.Error?.Kind ?? "";
            ErrorBar.Message = execution.Error?.Message ?? "";
            editor?.PublishDiagnostics(execution.Error?.Message);
            var lines = execution.Logs.Select(entry => entry.Level == "error" ? "✕ " + entry.Message : entry.Message).ToList();
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

    /// <summary>A package's files with one text file replaced by the text being edited.</summary>
    private sealed class OverlayPackageFiles(IPackageFiles inner, string path, string text) : IPackageFiles
    {
        public IReadOnlyList<string> Paths() => inner.Paths().Contains(path) ? inner.Paths() : [.. inner.Paths(), path];
        public bool Exists(string file) => file == path || inner.Exists(file);
        public string? ReadText(string file) => file == path ? text : inner.ReadText(file);
        public byte[]? ReadBytes(string file) => file == path ? Encoding.UTF8.GetBytes(text) : inner.ReadBytes(file);
    }
}
