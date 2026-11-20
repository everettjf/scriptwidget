using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace ScriptWidget.Studio.Pages;

public sealed partial class AiPage : Page
{
    public AiPage() => InitializeComponent();
    protected override void OnNavigatedTo(NavigationEventArgs e) => Assistant.Open();
}
