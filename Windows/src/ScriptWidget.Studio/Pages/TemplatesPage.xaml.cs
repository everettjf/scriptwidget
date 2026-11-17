using System.Collections.ObjectModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using ScriptWidget.Studio.Services;

namespace ScriptWidget.Studio.Pages;

/// <summary>
/// The packages shipped with the app that can run on Windows. The sidebar
/// shows this page twice: "Templates" lists the ready-made widgets as cards
/// the size of a widget, "Components" lists one example per component as
/// small tiles. An entry opens <see cref="TemplateDetailPage"/>. The page is
/// kept while an entry is open, so going back returns to the same place.
/// The APIs have their own page, <see cref="ApisPage"/>.
/// </summary>
public sealed partial class TemplatesPage : Page
{
    public const string Templates = "templates";
    public const string Components = "components";
    public const string Apis = "apis";

    private readonly ObservableCollection<PackageCard> cards = new();
    private List<PackageCard> all = new();
    private string? mode;

    public TemplatesPage()
    {
        InitializeComponent();
        Cards.ItemsSource = cards;
        Tiles.ItemsSource = cards;
    }

    /// <summary>The page mode a group of bundled packages is listed under.</summary>
    public static string ModeOf(string group) => group switch { "component" => Components, "api" => Apis, _ => Templates };

    private static string GroupOf(string mode) => mode switch { Components => "component", Apis => "api", _ => "template" };

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        var requested = e.Parameter as string == Components ? Components : Templates;
        // Coming back from an entry: the list, the search text and the scroll position stay.
        if (requested == mode && all.Count > 0) return;
        mode = requested;
        TitleText.Text = Loc.T(mode + ".title");
        DetailText.Text = Loc.T(mode + ".detail");
        var search = Loc.T(mode + ".search");
        Search.PlaceholderText = search;
        AutomationProperties.SetName(Search, search);
        Search.Text = "";
        cards.Clear();
        Cards.Visibility = mode == Components ? Visibility.Collapsed : Visibility.Visible;
        Tiles.Visibility = mode == Components ? Visibility.Visible : Visibility.Collapsed;
        if (all.Count == 0)
        {
            var bundled = await Task.Run(() => AppServices.Library.Bundled());
            all = bundled.Where(item => item.Group != "api").Select(item => new PackageCard { Title = item.Name, Bundled = item }).ToList();
        }
        Filter();
    }

    private void Filter()
    {
        if (mode is null) return;
        var group = GroupOf(mode);
        var query = Search.Text.Trim();
        cards.Clear();
        foreach (var card in all)
        {
            if (card.Bundled!.Group != group) continue;
            if (query.Length > 0 && !card.Title.Contains(query, StringComparison.CurrentCultureIgnoreCase)) continue;
            cards.Add(card);
        }
    }

    private void OnSearchChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs arguments) => Filter();

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
