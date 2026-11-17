using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using ScriptWidget.Core.Hosting;
using ScriptWidget.Studio.Services;

namespace ScriptWidget.Studio.Pages;

/// <summary>Settings of the desktop host. The host reads the same file and is told when it changed.</summary>
public sealed partial class SettingsPage : Page
{
    private static readonly int[] Intervals = [5, 15, 30, 60, 120, 360];
    private bool loading = true;

    public SettingsPage()
    {
        InitializeComponent();
        AppServices.Settings.Reload();
        foreach (var minutes in Intervals)
        {
            Refresh.Items.Add(minutes < 60 ? Loc.T("settings.minutes", minutes) : minutes == 60 ? Loc.T("settings.hour") : Loc.T("settings.hours", minutes / 60));
        }
        var current = AppServices.Settings.RefreshMinutes;
        Refresh.SelectedIndex = Math.Max(0, Array.FindIndex(Intervals, minutes => minutes >= current));
        Lock.IsOn = AppServices.Settings.Locked;
        Pause.IsOn = AppServices.Settings.PauseWhenBusy;
        StartAtLogin.IsOn = StartupRegistration.IsEnabled();
        VersionText.Text = Loc.T("settings.version", AppServices.Version);
        loading = false;
    }

    private void OnRefreshChanged(object sender, SelectionChangedEventArgs arguments)
    {
        if (loading || Refresh.SelectedIndex < 0) return;
        AppServices.Settings.RefreshMinutes = Intervals[Refresh.SelectedIndex];
        DesktopHost.SettingsChanged();
    }

    private void OnLockToggled(object sender, RoutedEventArgs arguments)
    {
        if (loading) return;
        AppServices.Settings.Locked = Lock.IsOn;
        DesktopHost.SettingsChanged();
    }

    private void OnPauseToggled(object sender, RoutedEventArgs arguments)
    {
        if (loading) return;
        AppServices.Settings.PauseWhenBusy = Pause.IsOn;
        DesktopHost.SettingsChanged();
    }

    private void OnStartupToggled(object sender, RoutedEventArgs arguments)
    {
        if (loading) return;
        var host = Path.Combine(AppContext.BaseDirectory, "ScriptWidget.exe");
        var enabled = StartupRegistration.SetEnabled(StartAtLogin.IsOn, File.Exists(host) ? host : null);
        // Windows or the user's own choice in Task Manager can refuse; show what is true.
        if (enabled != StartAtLogin.IsOn) { loading = true; StartAtLogin.IsOn = enabled; loading = false; }
    }

    private void OnOpenData(object sender, RoutedEventArgs arguments) => LibraryPage.OpenFolder(AppServices.Paths.Root);
}
