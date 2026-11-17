using System.Collections.ObjectModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using ScriptWidget.Studio.Services;

namespace ScriptWidget.Studio.Pages;

/// <summary>
/// The packages shipped with the app that can run on Windows, as a grid of
/// previews. It is shown in two places: "Templates" lists the ready-made
/// widgets, "Examples" lists the component and API examples. A card opens
/// <see cref="TemplateDetailPage"/>. The page is kept while a card is open,
/// so going back returns to the same place in the list.
/// </summary>
public sealed partial class TemplatesPage : Page
{
    public const string Templates = "templates";
    public const string Examples = "examples";

    private readonly ObservableCollection<PackageCard> cards = new();
    private List<PackageCard> all = new();
    private string? mode;
    private string group = "template";

    public TemplatesPage()
    {
        InitializeComponent();
        GroupComponent.Text = Loc.T("templates.group.component");
        GroupApi.Text = Loc.T("templates.group.api");
        Cards.ItemsSource = cards;
    }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        var requested = e.Parameter as string == Examples ? Examples : Templates;
        // Coming back from a card: the list, the search text and the scroll position stay.
        if (requested == mode && all.Count > 0) return;
        mode = requested;
        var examples = mode == Examples;
        TitleText.Text = Loc.T(examples ? "examples.title" : "templates.title");
        DetailText.Text = Loc.T(examples ? "examples.detail" : "templates.detail");
        var search = Loc.T(examples ? "examples.search" : "templates.search");
        Search.PlaceholderText = search;
        AutomationProperties.SetName(Search, search);
        Search.Text = "";
        Groups.Visibility = examples ? Visibility.Visible : Visibility.Collapsed;
        if (examples) Groups.SelectedItem = GroupComponent;
        group = examples ? "component" : "template";
        cards.Clear();
        if (all.Count == 0)
        {
            var bundled = await Task.Run(() => AppServices.Library.Bundled());
            all = bundled.Select(item => new PackageCard { Title = item.Name, Bundled = item }).ToList();
        }
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
        if (mode == Examples && sender.SelectedItem?.Tag is string tag && tag != group) { group = tag; Filter(); }
    }

    private void OnSearchChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs arguments)
    {
        if (mode is not null) Filter();
    }

    private void OnContainerChanging(ListViewBase sender, ContainerContentChangingEventArgs arguments)
    {
        if (arguments.InRecycleQueue || arguments.Item is not PackageCard card) return;
        // The card is the control: a screen reader hears the template's name.
        AutomationProperties.SetName(arguments.ItemContainer, card.Title);
        _ = card.RenderAsync(MainWindow.Current.RasterizationScale);
    }

    private void OnOpen(object sender, ItemClickEventArgs arguments)
    {
        if (arguments.ClickedItem is PackageCard { Bundled: { } bundled }) MainWindow.Current.ShowDetail(bundled);
    }
}
