using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using ScriptWidget.Core.Packages;
using ScriptWidget.Studio.Pages;
using ScriptWidget.Studio.Services;

namespace ScriptWidget.Studio;

/// <summary>The management window: the user's widgets, the templates, the editor and the settings.</summary>
public sealed partial class MainWindow : Window
{
    public static MainWindow Current { get; private set; } = null!;
    private readonly DispatcherTimer toastTimer = new() { Interval = TimeSpan.FromSeconds(4) };

    public MainWindow()
    {
        InitializeComponent();
        Current = this;
        Title = "ScriptWidget";
        LibraryItem.Content = Loc.T("nav.library");
        TemplatesItem.Content = Loc.T("nav.templates");
        SettingsItem.Content = Loc.T("nav.settings");
        var icon = Path.Combine(AppContext.BaseDirectory, "ScriptWidget.ico");
        if (File.Exists(icon)) AppWindow.SetIcon(icon);
        AppWindow.Resize(new Windows.Graphics.SizeInt32(Scaled(1240), Scaled(820)));
        toastTimer.Tick += (_, _) => { toastTimer.Stop(); Toast.IsOpen = false; };
        Closed += (_, _) => (ContentFrame.Content as EditorPage)?.SaveNow();
        Navigation.SelectedItem = LibraryItem;
        // The widgets on the desktop belong to the host; start it when the window opens first.
        _ = DesktopHost.EnsureRunningAsync();
    }

    private int Scaled(int points)
    {
        var dpi = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this));
        return (int)Math.Round(points * (dpi == 0 ? 1.0 : dpi / 96.0));
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern uint GetDpiForWindow(nint window);

    public nint WindowHandle => WinRT.Interop.WindowNative.GetWindowHandle(this);

    public double RasterizationScale => Root.XamlRoot?.RasterizationScale ?? 1.0;

    private void OnSelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs arguments)
    {
        if (arguments.SelectedItem is not NavigationViewItem item) return;
        (ContentFrame.Content as EditorPage)?.SaveNow();
        switch (item.Tag as string)
        {
            case "library": ContentFrame.Navigate(typeof(LibraryPage)); break;
            case "templates": ContentFrame.Navigate(typeof(TemplatesPage)); break;
            case "settings": ContentFrame.Navigate(typeof(SettingsPage)); break;
        }
    }

    /// <summary>Opens the editor on an installed package.</summary>
    public void OpenEditor(string packageName)
    {
        Navigation.SelectedItem = null;
        ContentFrame.Navigate(typeof(EditorPage), packageName);
    }

    public void ShowLibrary()
    {
        if (Navigation.SelectedItem == LibraryItem) ContentFrame.Navigate(typeof(LibraryPage));
        else Navigation.SelectedItem = LibraryItem;
    }

    public void ShowTemplates() => Navigation.SelectedItem = TemplatesItem;

    /// <summary>A short message at the bottom of the window.</summary>
    public void Notify(string message, InfoBarSeverity severity = InfoBarSeverity.Success)
    {
        Toast.Severity = severity;
        Toast.Message = message;
        Toast.IsOpen = true;
        toastTimer.Stop();
        toastTimer.Start();
    }

    public async Task ShowErrorAsync(string message)
    {
        var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, Title = Loc.T("dialog.error.title"), Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap }, CloseButtonText = Loc.T("action.ok") };
        await dialog.ShowAsync();
    }

    /// <summary>Asks for one line of text. Returns null when cancelled.</summary>
    public async Task<string?> PromptAsync(string title, string placeholder, string initial = "")
    {
        var box = new TextBox { Text = initial, PlaceholderText = placeholder, MaxLength = 120 };
        box.SelectAll();
        var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, Title = title, Content = box, PrimaryButtonText = Loc.T("action.ok"), CloseButtonText = Loc.T("action.cancel"), DefaultButton = ContentDialogButton.Primary };
        return await dialog.ShowAsync() == ContentDialogResult.Primary && box.Text.Trim().Length > 0 ? box.Text.Trim() : null;
    }

    public async Task<bool> ConfirmAsync(string title, string detail, string confirm)
    {
        var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, Title = title, Content = new TextBlock { Text = detail, TextWrapping = TextWrapping.Wrap }, PrimaryButtonText = confirm, CloseButtonText = Loc.T("action.cancel"), DefaultButton = ContentDialogButton.Close };
        return await dialog.ShowAsync() == ContentDialogResult.Primary;
    }

    /// <summary>Imports a <c>.swt</c> archive after the user confirmed, then opens it in the editor.</summary>
    public async Task ImportArchiveAsync(string file)
    {
        try
        {
            var name = Path.GetFileNameWithoutExtension(file);
            if (!await ConfirmAsync(Loc.T("dialog.import.title"), Loc.T("dialog.import.detail", name), Loc.T("dialog.import.confirm"))) return;
            var installed = await Task.Run(() =>
            {
                using var stream = File.OpenRead(file);
                return AppServices.Library.ImportArchive(stream, name, AppServices.ValidatePackage);
            });
            DesktopHost.LibraryChanged();
            OpenEditor(installed.Name);
        }
        catch (Exception error) when (error is PackageException or IOException or UnauthorizedAccessException)
        {
            await ShowErrorAsync(error.Message);
        }
    }
}
