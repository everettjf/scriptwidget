using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using ScriptWidget.Core.Packages;
using ScriptWidget.Core.Skills;
using ScriptWidget.Studio.Services;
using Windows.Storage.Pickers;

namespace ScriptWidget.Studio.Pages;

public sealed partial class SkillsPage : Page
{
    public SkillsPage() => InitializeComponent();
    protected override void OnNavigatedTo(NavigationEventArgs e) => _ = ReloadAsync();
    private WidgetSkill? Selected => (Skills.SelectedItem as ListViewItem)?.Tag as WidgetSkill;

    private async Task ReloadAsync(string? selected = null)
    {
        var entries = await Task.Run(AppServices.Skills.List);
        var enabled = AppServices.Skills.EnabledIds();
        Skills.Items.Clear();
        foreach (var skill in entries)
        {
            var toggle = new ToggleSwitch { Header = Loc.T("skills.enabled"), IsOn = enabled.Contains(skill.Id) };
            var reverting = false;
            AutomationProperties.SetName(toggle, $"{skill.Name}: {Loc.T("skills.enabled")}");
            toggle.Toggled += async (_, _) => await Guarded(async () =>
            {
                if (reverting) return;
                var desired = toggle.IsOn;
                var previous = AppServices.Skills.EnabledIds().Contains(skill.Id);
                try { await Task.Run(() => AppServices.Skills.SetEnabled(skill.Id, desired)); }
                catch { reverting = true; toggle.IsOn = previous; reverting = false; throw; }
            });
            var row = new StackPanel { Spacing = 6, Padding = new Thickness(8) };
            row.Children.Add(new TextBlock { Text = skill.Name, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
            row.Children.Add(new TextBlock { Text = $"{skill.Version} · {Loc.T(skill.IsBuiltIn ? "skills.builtIn" : "skills.imported")}", TextWrapping = TextWrapping.Wrap });
            row.Children.Add(toggle);
            var item = new ListViewItem { Content = row, Tag = skill, HorizontalContentAlignment = HorizontalAlignment.Stretch };
            AutomationProperties.SetName(item, skill.Name);
            Skills.Items.Add(item);
            if (skill.Id == selected) Skills.SelectedItem = item;
        }
    }

    private void OnSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        var skill = Selected;
        NameText.Text = skill?.Name ?? Loc.T("skills.choose");
        SummaryText.Text = skill?.Summary ?? "";
        Instructions.Text = skill?.Instruction ?? "";
        ExportButton.IsEnabled = skill is not null;
        RemoveButton.IsEnabled = skill is { IsBuiltIn: false };
    }

    private static async Task Guarded(Func<Task> work)
    {
        try { await work(); }
        catch (Exception error) when (error is SkillException or PackageException or IOException or UnauthorizedAccessException)
        { await MainWindow.Current.ShowErrorAsync(error.Message); }
    }

    private async void OnImport(object sender, RoutedEventArgs e) => await Guarded(async () =>
    {
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.Downloads };
        picker.FileTypeFilter.Add(".swskill");
        picker.FileTypeFilter.Add(".zip");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, MainWindow.Current.WindowHandle);
        if (await picker.PickSingleFileAsync() is not { } file) return;
        var imported = await Task.Run(() => { using var stream = File.OpenRead(file.Path); return AppServices.Skills.ImportArchive(stream); });
        await ReloadAsync(imported.Id);
    });

    private async void OnExport(object sender, RoutedEventArgs e) => await Guarded(async () =>
    {
        if (Selected is not { } skill) return;
        var picker = new FileSavePicker { SuggestedFileName = skill.Name, SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        picker.FileTypeChoices.Add(Loc.T("skills.archive"), [".swskill"]);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, MainWindow.Current.WindowHandle);
        if (await picker.PickSaveFileAsync() is not { } file) return;
        // Prepare the complete archive before replacing the chosen file.
        using var archive = new MemoryStream();
        await Task.Run(() => AppServices.Skills.Export(skill.Id, archive));
        await File.WriteAllBytesAsync(file.Path, archive.ToArray());
    });

    private async void OnRemove(object sender, RoutedEventArgs e) => await Guarded(async () =>
    {
        if (Selected is not { IsBuiltIn: false } skill || !await MainWindow.Current.ConfirmAsync(Loc.T("skills.remove.title", skill.Name), Loc.T("skills.remove.detail"), Loc.T("skills.remove"))) return;
        await Task.Run(() => AppServices.Skills.Delete(skill.Id));
        await ReloadAsync();
    });
}
