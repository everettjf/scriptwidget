using System.Collections.ObjectModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using ScriptWidget.Core.Hosting;
using ScriptWidget.Core.Packages;
using ScriptWidget.Studio.Services;
using Windows.Storage.Pickers;

namespace ScriptWidget.Studio.Pages;

/// <summary>The user's installed widgets.</summary>
public sealed partial class LibraryPage : Page
{
    private const string StarterSource = """
        // A widget is a script that returns JSX. Change the text and save to see it update.
        $render(
          <vstack frame="max" background="#1f2937" padding="16" spacing="6">
            <text font="title2" color="white">Hello, widget</text>
            <text font="caption" color="#9ca3af">Edit me in ScriptWidget</text>
          </vstack>
        );
        """;

    private readonly ObservableCollection<PackageCard> cards = new();

    public LibraryPage()
    {
        InitializeComponent();
        Cards.ItemsSource = cards;
    }

    protected override void OnNavigatedTo(NavigationEventArgs e) => _ = ReloadAsync();

    private async Task ReloadAsync()
    {
        var packages = await Task.Run(() => AppServices.Library.List());
        cards.Clear();
        foreach (var package in packages) cards.Add(new PackageCard { Title = package.DisplayName, Subtitle = package.Description, Installed = package });
        Empty.Visibility = cards.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        Cards.Visibility = cards.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        var counts = await DesktopHost.WidgetCountsAsync();
        foreach (var card in cards)
        {
            if (card.Installed is { } installed && counts.TryGetValue(installed.Installation, out var count)) card.Detail = Loc.T("library.onDesktop", count);
        }
    }

    private void OnContainerChanging(ListViewBase sender, ContainerContentChangingEventArgs arguments)
    {
        if (!arguments.InRecycleQueue && arguments.Item is PackageCard card) _ = card.RenderAsync(MainWindow.Current.RasterizationScale);
    }

    private static PackageCard? Card(object sender) => (sender as FrameworkElement)?.DataContext as PackageCard;

    private void OnCardClick(object sender, ItemClickEventArgs arguments)
    {
        if (arguments.ClickedItem is PackageCard { Installed: { } installed }) MainWindow.Current.OpenEditor(installed.Name);
    }

    private void OnEdit(object sender, RoutedEventArgs arguments)
    {
        if (Card(sender)?.Installed is { } installed) MainWindow.Current.OpenEditor(installed.Name);
    }

    private void OnAdd(object sender, RoutedEventArgs arguments)
    {
        if (Card(sender)?.Installed is not { } installed) return;
        var menu = new MenuFlyout();
        foreach (var family in installed.Families)
        {
            var item = new MenuFlyoutItem { Text = Loc.Family(family) };
            item.Click += async (_, _) => await AddToDesktopAsync(installed, family);
            menu.Items.Add(item);
        }
        menu.ShowAt((FrameworkElement)sender);
    }

    public static async Task AddToDesktopAsync(InstalledPackage installed, string family)
    {
        if (await DesktopHost.AddWidgetAsync(installed.Installation, family)) MainWindow.Current.Notify(Loc.T("toast.added"));
        else MainWindow.Current.Notify(Loc.T("toast.hostMissing"), InfoBarSeverity.Error);
    }

    private void OnMore(object sender, RoutedEventArgs arguments)
    {
        if (Card(sender)?.Installed is not { } installed) return;
        var menu = new MenuFlyout();
        void Add(string key, Func<Task> action)
        {
            var item = new MenuFlyoutItem { Text = Loc.T(key) };
            item.Click += async (_, _) => await Guarded(action);
            menu.Items.Add(item);
        }
        Add("action.duplicate", async () => { await Task.Run(() => AppServices.Library.Duplicate(installed.Name)); await ReloadAsync(); });
        Add("action.rename", async () =>
        {
            if (await MainWindow.Current.PromptAsync(Loc.T("dialog.rename.title"), Loc.T("dialog.new.hint"), installed.Name) is not { } name || name == installed.Name) return;
            await Task.Run(() => AppServices.Library.Rename(installed.Name, name));
            DesktopHost.LibraryChanged();
            await ReloadAsync();
        });
        Add("action.export", () => ExportAsync(installed));
        Add("action.openFolder", () => { OpenFolder(installed.Directory); return Task.CompletedTask; });
        menu.Items.Add(new MenuFlyoutSeparator());
        Add("action.delete", async () =>
        {
            if (!await MainWindow.Current.ConfirmAsync(Loc.T("dialog.delete.title", installed.DisplayName), Loc.T("dialog.delete.detail"), Loc.T("action.delete"))) return;
            await Task.Run(() => AppServices.Library.Delete(installed.Name));
            // The host shows a "not found" card for widgets of a removed package; take them off the desktop.
            var widgets = await DesktopHost.SendAsync(new System.Text.Json.Nodes.JsonObject { ["command"] = "list" });
            foreach (var widget in ScriptWidget.Core.Json.OptArray(widgets, "widgets") ?? new System.Text.Json.Nodes.JsonArray())
            {
                if (widget is System.Text.Json.Nodes.JsonObject item && ScriptWidget.Core.Json.OptString(item, "package") == installed.Installation)
                    await DesktopHost.SendAsync(new System.Text.Json.Nodes.JsonObject { ["command"] = "remove", ["id"] = ScriptWidget.Core.Json.OptString(item, "id") });
            }
            await ReloadAsync();
        });
        menu.ShowAt((FrameworkElement)sender);
    }

    public static void OpenFolder(string directory)
    {
        try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("explorer.exe") { ArgumentList = { directory }, UseShellExecute = false })?.Dispose(); }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException) { }
    }

    /// <summary>Runs an action and shows a dialog when the package store refuses it.</summary>
    private static async Task Guarded(Func<Task> action)
    {
        try { await action(); }
        catch (Exception error) when (error is PackageException or IOException or UnauthorizedAccessException) { await MainWindow.Current.ShowErrorAsync(error.Message); }
    }

    public static async Task ExportAsync(InstalledPackage installed)
    {
        var picker = new FileSavePicker { SuggestedFileName = installed.Name, SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        picker.FileTypeChoices.Add("ScriptWidget", [".swt"]);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, MainWindow.Current.WindowHandle);
        if (await picker.PickSaveFileAsync() is not { } file) return;
        await Task.Run(() =>
        {
            using var stream = File.Create(file.Path);
            AppServices.Library.ExportArchive(installed.Name, stream);
        });
        MainWindow.Current.Notify(Loc.T("toast.exported", file.Name));
    }

    private async void OnNew(object sender, RoutedEventArgs arguments) => await Guarded(async () =>
    {
        if (await MainWindow.Current.PromptAsync(Loc.T("dialog.new.title"), Loc.T("dialog.new.hint"), Loc.T("dialog.new.default")) is not { } name) return;
        var created = await Task.Run(() => AppServices.Library.Create(name, StarterSource));
        MainWindow.Current.OpenEditor(created.Name);
    });

    private async void OnImport(object sender, RoutedEventArgs arguments)
    {
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.Downloads };
        picker.FileTypeFilter.Add(".swt");
        picker.FileTypeFilter.Add(".zip");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, MainWindow.Current.WindowHandle);
        if (await picker.PickSingleFileAsync() is { } file) await MainWindow.Current.ImportArchiveAsync(file.Path);
    }

    private void OnBrowseTemplates(object sender, RoutedEventArgs arguments) => MainWindow.Current.ShowTemplates();
}
