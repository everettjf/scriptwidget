using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using ScriptWidget.Studio.Services;

namespace ScriptWidget.Studio.Pages;

/// <summary>
/// The API reference: the globals a widget's code can use on the left, the
/// functions of the chosen one on the right, each with its arguments, what it
/// returns and one sentence about it. A global with a bundled example offers
/// "View example", which opens the example's code and output. The search
/// looks through every function of every global.
/// </summary>
public sealed partial class ApisPage : Page
{
    private IReadOnlyList<ApiGroup> all = [];
    private bool updating;

    public ApisPage() => InitializeComponent();

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        // Coming back from an example: the chosen global and the search text stay.
        if (all.Count > 0) return;
        all = await Task.Run(() => ApiReference.Groups(AppServices.Library.Bundled()));
        Refresh();
    }

    private static bool Matches(ApiFunction function, string query) =>
        function.Signature.Contains(query, StringComparison.CurrentCultureIgnoreCase) || function.Documentation.Contains(query, StringComparison.CurrentCultureIgnoreCase);

    /// <summary>Fills the list of globals for the current search text and shows one of them, or every match.</summary>
    private void Refresh()
    {
        var query = Search.Text.Trim();
        var groups = query.Length == 0 ? all : all.Where(group => group.Name.Contains(query, StringComparison.CurrentCultureIgnoreCase) || group.Functions.Any(function => Matches(function, query))).ToList();
        var previous = (Groups.SelectedItem as ApiGroup)?.Name;
        updating = true;
        Groups.ItemsSource = groups;
        // With search text nothing is chosen at first: the right side lists every match.
        Groups.SelectedItem = query.Length == 0 ? groups.FirstOrDefault(group => group.Name == previous) ?? groups.FirstOrDefault() : null;
        updating = false;
        Show();
    }

    private void Show()
    {
        var query = Search.Text.Trim();
        var group = Groups.SelectedItem as ApiGroup;
        IReadOnlyList<ApiFunction> functions;
        if (group is not null)
        {
            // A global chosen while searching shows its matches; when its name is the match, all of it.
            functions = query.Length == 0 || group.Name.Contains(query, StringComparison.CurrentCultureIgnoreCase) ? group.Functions : group.Functions.Where(function => Matches(function, query)).ToList();
            GroupTitle.Text = group.Name;
            var note = !group.Supported ? Loc.T("apis.notOnWindows.detail") : group.Functions.Count == 0 ? Loc.T("apis.noReference") : "";
            GroupNote.Text = note;
            GroupNote.Visibility = note.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
            ExampleButton.Visibility = group.Example is not null ? Visibility.Visible : Visibility.Collapsed;
        }
        else
        {
            var groups = Groups.ItemsSource as IReadOnlyList<ApiGroup> ?? [];
            functions = groups.SelectMany(item => item.Functions.Where(function => Matches(function, query))).ToList();
            GroupTitle.Text = functions.Count == 0 ? Loc.T("apis.noResults") : functions.Count == 1 ? Loc.T("apis.result") : Loc.T("apis.results", functions.Count);
            GroupNote.Visibility = Visibility.Collapsed;
            ExampleButton.Visibility = Visibility.Collapsed;
        }
        Functions.ItemsSource = functions;
    }

    private void OnGroupSelected(object sender, SelectionChangedEventArgs arguments)
    {
        if (!updating) Show();
    }

    private void OnSearchChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs arguments)
    {
        if (all.Count > 0) Refresh();
    }

    private void OnExample(object sender, RoutedEventArgs arguments)
    {
        if (Groups.SelectedItem is ApiGroup { Example: { } example }) MainWindow.Current.ShowDetail(example);
    }

    private void OnGroupContainerChanging(ListViewBase sender, ContainerContentChangingEventArgs arguments)
    {
        if (!arguments.InRecycleQueue && arguments.Item is ApiGroup group) AutomationProperties.SetName(arguments.ItemContainer, group.Name);
    }

    private void OnFunctionContainerChanging(ListViewBase sender, ContainerContentChangingEventArgs arguments)
    {
        if (!arguments.InRecycleQueue && arguments.Item is ApiFunction function) AutomationProperties.SetName(arguments.ItemContainer, function.Signature);
    }
}
