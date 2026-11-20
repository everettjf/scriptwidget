using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using ScriptWidget.Core.Gallery;
using ScriptWidget.Core.Packages;
using ScriptWidget.Core.Skills;
using ScriptWidget.Studio.Services;

namespace ScriptWidget.Studio.Pages;

public sealed partial class GalleryPage : Page
{
    private CancellationTokenSource cancellation = new();
    private bool installing;
    public GalleryPage() => InitializeComponent();
    private GalleryItem? Selected => (Items.SelectedItem as ListViewItem)?.Tag as GalleryItem;
    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        cancellation.Dispose();
        cancellation = new CancellationTokenSource();
        _ = ReloadAsync();
    }
    protected override void OnNavigatedFrom(NavigationEventArgs e) => cancellation.Cancel();

    private async Task ReloadAsync()
    {
        ReloadButton.IsEnabled = false;
        Busy.IsActive = true;
        Status.IsOpen = true;
        Status.Severity = InfoBarSeverity.Informational;
        Status.Message = Loc.T("gallery.loading");
        try
        {
            var loaded = await AppServices.Gallery.LoadAsync(cancellation.Token);
            if (cancellation.IsCancellationRequested) return;
            Items.Items.Clear();
            foreach (var item in loaded.Index.Items.OrderByDescending(item => item.Featured).ThenBy(item => item.Name, StringComparer.OrdinalIgnoreCase))
            {
                var row = new StackPanel { Spacing = 4, Padding = new Thickness(8) };
                row.Children.Add(new TextBlock { Text = item.Name, TextWrapping = TextWrapping.Wrap, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
                row.Children.Add(new TextBlock { Text = $"{Loc.T("gallery." + item.Kind)} · {item.Version}", TextWrapping = TextWrapping.Wrap });
                var entry = new ListViewItem { Tag = item, Content = row, HorizontalContentAlignment = HorizontalAlignment.Stretch };
                AutomationProperties.SetName(entry, item.Name);
                Items.Items.Add(entry);
            }
            Status.IsOpen = loaded.Warning is not null;
            Status.Severity = InfoBarSeverity.Warning;
            Status.Message = loaded.Warning ?? "";
        }
        catch (OperationCanceledException) { }
        catch (Exception error) when (error is GalleryException or IOException or UnauthorizedAccessException) { ShowError(error.Message); }
        finally { Busy.IsActive = false; ReloadButton.IsEnabled = !installing; }
    }

    private void ShowError(string message)
    {
        Status.IsOpen = true;
        Status.Severity = InfoBarSeverity.Error;
        Status.Message = message;
    }

    private void OnSelectionChanged(object sender, SelectionChangedEventArgs e) => Describe();
    private void Describe()
    {
        var item = Selected;
        NameText.Text = item?.Name ?? Loc.T("gallery.choose");
        SummaryText.Text = item?.Summary ?? "";
        MetadataText.Text = item is null ? "" : Loc.T("gallery.metadata", item.Version, item.Author, item.License, item.Files.Count, item.Files.Sum(file => (long)file.Bytes), string.Join(", ", item.Tags));
        SourceLink.Visibility = item is null ? Visibility.Collapsed : Visibility.Visible;
        SourceLink.NavigateUri = item is null ? null : new Uri(item.SourceUrl);
        var state = item is null ? "" : AppServices.Gallery.State(item);
        InstallButton.Content = Loc.T(state == "installed" ? "gallery.installed" : state == "updateAvailable" ? "gallery.update" : "gallery.install");
        InstallButton.IsEnabled = item is not null && state != "installed" && !installing;
    }

    private async void OnReload(object sender, RoutedEventArgs e) => await ReloadAsync();
    private async void OnInstall(object sender, RoutedEventArgs e)
    {
        if (Selected is not { } item || installing) return;
        var update = AppServices.Gallery.Installation(item) is not null;
        if (!await MainWindow.Current.ConfirmAsync(Loc.T(update ? "gallery.update.title" : "gallery.confirm.title", item.Name), Loc.T(update ? "gallery.update.detail" : "gallery.confirm.detail"), Loc.T(update ? "gallery.update" : "gallery.install"))) return;
        installing = true;
        InstallButton.IsEnabled = false;
        ReloadButton.IsEnabled = false;
        Busy.IsActive = true;
        Status.IsOpen = true;
        Status.Severity = InfoBarSeverity.Informational;
        Status.Message = Loc.T("gallery.installing");
        try
        {
            await AppServices.Gallery.InstallAsync(item, AppServices.ValidatePackage, update, cancellation.Token);
            DesktopHost.LibraryChanged();
            Status.IsOpen = false;
        }
        catch (OperationCanceledException) { }
        catch (Exception error) when (error is GalleryException or SkillException or PackageException or IOException or UnauthorizedAccessException) { ShowError(error.Message); }
        finally { installing = false; Busy.IsActive = false; ReloadButton.IsEnabled = true; Describe(); }
    }
}
