using System.Collections.ObjectModel;
using System.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using ScriptWidget.Core.Hosting;
using ScriptWidget.Studio.Services;

namespace ScriptWidget.Studio.Pages;

/// <summary>
/// The packages shipped with the app that can run on Windows. The sidebar
/// shows this page three times: "Templates" (ready-made widgets) and
/// "Components" (one example per component) as a grid of previews, "APIs"
/// (one example per API) as a list to look a name up in. An entry opens
/// <see cref="TemplateDetailPage"/>. The page is kept while an entry is open,
/// so going back returns to the same place.
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
        Rows.ItemsSource = cards;
    }

    /// <summary>The page mode a group of bundled packages is listed under.</summary>
    public static string ModeOf(string group) => group switch { "component" => Components, "api" => Apis, _ => Templates };

    private static string GroupOf(string mode) => mode switch { Components => "component", Apis => "api", _ => "template" };

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        var requested = e.Parameter as string is Components or Apis ? (string)e.Parameter : Templates;
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
        Cards.Visibility = mode == Apis ? Visibility.Collapsed : Visibility.Visible;
        Rows.Visibility = mode == Apis ? Visibility.Visible : Visibility.Collapsed;
        if (all.Count == 0)
        {
            var bundled = await Task.Run(() => AppServices.Library.Bundled().Select(item => (item, snippet: item.Group == "api" ? FirstCodeLine(item) : "")).ToList());
            all = bundled.Select(entry => new PackageCard { Title = entry.item.Name, Bundled = entry.item, Snippet = entry.snippet }).ToList();
        }
        Filter();
    }

    /// <summary>
    /// The line of an example to show beside its name: the first line of code that mentions the API
    /// (<c>$storage.setString(…)</c> for "storage"), or else the first line of code. Comments are skipped.
    /// </summary>
    private static string FirstCodeLine(BundledPackage bundled)
    {
        string? first = null;
        try
        {
            var inComment = false;
            foreach (var line in File.ReadLines(Path.Combine(bundled.Directory, "main.jsx"), Encoding.UTF8))
            {
                var text = line.Trim();
                if (inComment) { if (text.Contains("*/", StringComparison.Ordinal)) inComment = false; continue; }
                if (text.StartsWith("/*", StringComparison.Ordinal)) { inComment = !text.Contains("*/", StringComparison.Ordinal); continue; }
                if (text.Length == 0 || text.StartsWith("//", StringComparison.Ordinal)) continue;
                if (text.Length > 160) text = text[..160];
                first ??= text;
                if (text.Contains(bundled.Name, StringComparison.OrdinalIgnoreCase)) return text;
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        return first ?? "";
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
            // An API is also found by what its example calls, such as "$storage" for the storage example.
            if (query.Length > 0 && !card.Title.Contains(query, StringComparison.CurrentCultureIgnoreCase) && !card.Snippet.Contains(query, StringComparison.CurrentCultureIgnoreCase)) continue;
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

    private void OnRowChanging(ListViewBase sender, ContainerContentChangingEventArgs arguments)
    {
        if (!arguments.InRecycleQueue && arguments.Item is PackageCard card) AutomationProperties.SetName(arguments.ItemContainer, card.Title);
    }

    private void OnOpen(object sender, ItemClickEventArgs arguments)
    {
        if (arguments.ClickedItem is PackageCard { Bundled: { } bundled }) MainWindow.Current.ShowDetail(bundled);
    }
}
