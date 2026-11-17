using System.Collections.ObjectModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using ScriptWidget.Core.Packages;
using ScriptWidget.Studio.Services;

namespace ScriptWidget.Studio.Pages;

/// <summary>The templates shipped with the app that can run on Windows.</summary>
public sealed partial class TemplatesPage : Page
{
    private readonly ObservableCollection<PackageCard> cards = new();
    private List<PackageCard> all = new();
    private string group = "template";

    public TemplatesPage()
    {
        InitializeComponent();
        GroupTemplate.Text = Loc.T("templates.group.template");
        GroupComponent.Text = Loc.T("templates.group.component");
        GroupApi.Text = Loc.T("templates.group.api");
        Cards.ItemsSource = cards;
    }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        var bundled = await Task.Run(() => AppServices.Library.Bundled());
        all = bundled.Select(item => new PackageCard { Title = item.Name, Bundled = item }).ToList();
        Filter();
    }

    private void Filter()
    {
        var query = Search.Text.Trim();
        cards.Clear();
        foreach (var card in all)
        {
            if (card.Bundled!.Group != group) continue;
            if (query.Length > 0 && !card.Title.Contains(query, StringComparison.CurrentCultureIgnoreCase)) continue;
            cards.Add(card);
        }
    }

    private void OnGroupChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs arguments)
    {
        if (sender.SelectedItem?.Tag is string tag && tag != group) { group = tag; Filter(); }
    }

    private void OnSearchChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs arguments) => Filter();

    private void OnContainerChanging(ListViewBase sender, ContainerContentChangingEventArgs arguments)
    {
        if (!arguments.InRecycleQueue && arguments.Item is PackageCard card) _ = card.RenderAsync(MainWindow.Current.RasterizationScale);
    }

    private async void OnUse(object sender, RoutedEventArgs arguments)
    {
        if ((sender as FrameworkElement)?.DataContext is not PackageCard { Bundled: { } bundled }) return;
        try
        {
            var installed = await Task.Run(() => AppServices.Library.InstallBundled(bundled));
            await LibraryPage.AddToDesktopAsync(installed, installed.Families.Contains("medium") ? "medium" : installed.Families[0]);
            MainWindow.Current.OpenEditor(installed.Name);
        }
        catch (Exception error) when (error is PackageException or IOException or UnauthorizedAccessException)
        {
            await MainWindow.Current.ShowErrorAsync(error.Message);
        }
    }
}
