using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using ScriptWidget.Core.AI;
using ScriptWidget.Studio.Services;

namespace ScriptWidget.Studio.AI;

public sealed partial class AiSettingsControl : UserControl
{
    private readonly AiProfileStore store = new(AppServices.Paths.AiProfiles);
    private readonly WindowsAiCredentials credentials = new();
    private AiProfileSettings settings = new([], null);
    private AiProfile profile = AiProfile.Create(AiProvider.Compatible);
    private bool updating;
    private readonly CancellationTokenSource lifetime = new();

    public AiSettingsControl()
    {
        InitializeComponent();
        Provider.Items.Add(new ComboBoxItem { Content = "Anthropic", Tag = AiProvider.Anthropic });
        Provider.Items.Add(new ComboBoxItem { Content = "OpenAI", Tag = AiProvider.OpenAi });
        Provider.Items.Add(new ComboBoxItem { Content = Loc.T("ai.compatible"), Tag = AiProvider.Compatible });
        Provider.Items.Add(new ComboBoxItem { Content = "Ollama (local)", Tag = AiProvider.Ollama });
        Provider.Items.Add(new ComboBoxItem { Content = "LM Studio (local)", Tag = AiProvider.LmStudio });
        Loaded += (_, _) => Load();
        Unloaded += (_, _) => lifetime.Cancel();
    }

    private void Load(string? select = null)
    {
        settings = store.Load();
        updating = true;
        Profiles.Items.Clear();
        foreach (var item in settings.Profiles) Profiles.Items.Add(new ComboBoxItem { Content = item.Name + (item.Id == settings.ActiveId ? " · " + Loc.T("ai.active") : ""), Tag = item.Id });
        Profiles.SelectedItem = Profiles.Items.OfType<ComboBoxItem>().FirstOrDefault(item => (string)item.Tag == (select ?? settings.ActiveId));
        updating = false;
        Fill(settings.Profiles.FirstOrDefault(item => item.Id == ((Profiles.SelectedItem as ComboBoxItem)?.Tag as string)) ?? profile);
    }

    private void Fill(AiProfile value)
    {
        profile = value;
        ProfileName.Text = value.Name;
        BaseUrl.Text = value.BaseUrl;
        Model.Text = value.Model;
        updating = true;
        Provider.SelectedItem = Provider.Items.OfType<ComboBoxItem>().FirstOrDefault(item => (AiProvider)item.Tag == value.Provider);
        updating = false;
        Key.Password = "";
        Models.Visibility = Visibility.Collapsed;
        RemoveButton.IsEnabled = settings.Profiles.Any(item => item.Id == value.Id);
        try { KeyStatus.Text = Loc.T(credentials.Get(value.Id) is null ? value.IsLoopback ? "ai.key.optional" : "ai.key.absent" : "ai.key.stored"); }
        catch (Exception error) when (error is not OutOfMemoryException) { Show(error is AiException ? error.Message : Loc.T("ai.failed")); }
    }

    private AiProfile Edited() => profile with { Name = ProfileName.Text.Trim(), BaseUrl = BaseUrl.Text.Trim(), Model = Model.Text.Trim(), Provider = (AiProvider)((ComboBoxItem)Provider.SelectedItem).Tag };
    private AiApiKey? GetKey(AiProfile edited)
    {
        if (Key.Password.Length > 0) return new AiApiKey(Key.Password);
        if (edited.NormalizedBaseUrl != profile.NormalizedBaseUrl || edited.Provider != profile.Provider)
        {
            if (edited.IsLoopback) return null;
            throw new AiException("key_required", Loc.T("ai.key.changedEndpoint"));
        }
        return edited.ReadKey(credentials);
    }
    private void OnProvider(object sender, SelectionChangedEventArgs e)
    {
        if (updating || Provider.SelectedItem is not ComboBoxItem { Tag: AiProvider selected }) return;
        var defaults = AiProfile.Create(selected);
        ProfileName.Text = defaults.Name;
        BaseUrl.Text = defaults.BaseUrl;
        Model.Text = defaults.Model;
        // Never carry a newly typed remote key into another provider's test request.
        Key.Password = "";
        Models.Visibility = Visibility.Collapsed;
        KeyStatus.Text = Loc.T(defaults.IsLoopback ? "ai.key.optional" : "ai.key.absent");
    }
    private void Show(string text, bool success = false)
    {
        Message.Message = text;
        Message.Severity = success ? InfoBarSeverity.Success : InfoBarSeverity.Error;
        Message.IsOpen = true;
    }
    private void OnProfile(object sender, SelectionChangedEventArgs e)
    {
        if (!updating && Profiles.SelectedItem is ComboBoxItem { Tag: string id } && settings.Profiles.FirstOrDefault(item => item.Id == id) is { } value) Fill(value);
    }
    private void OnNew(object sender, RoutedEventArgs e)
    {
        updating = true; Profiles.SelectedIndex = -1; updating = false;
        Fill(AiProfile.Create((AiProvider)((ComboBoxItem)Provider.SelectedItem).Tag));
    }
    private void OnSave(object sender, RoutedEventArgs e)
    {
        try
        {
            var edited = Edited();
            var key = Key.Password.Length > 0 ? new AiApiKey(Key.Password) : null;
            var result = new AiProfileManager(store, credentials).Save(profile, edited, key);
            Load(result.Profile.Id);
            Show(Loc.T("ai.provider.saved"), true);
            if (!result.PreviousKeyRemoved)
            {
                Message.Severity = InfoBarSeverity.Warning;
                Message.Message = Loc.T("ai.provider.oldKeyRetained");
            }
        }
        catch (Exception error) when (error is not OutOfMemoryException) { Show(error is AiException ? error.Message : Loc.T("ai.failed")); }
    }
    private async void OnModels(object sender, RoutedEventArgs e)
    {
        TestButton.IsEnabled = false;
        try
        {
            var edited = Edited();
            if (edited.ValidationError(requireModel: false) is { } error) throw new AiException("invalid_profile", error);
            var key = GetKey(edited);
            using var client = new AiClient();
            var models = await client.ListModelsAsync(edited, key, lifetime.Token);
            Models.Items.Clear();
            foreach (var model in models) Models.Items.Add(model);
            Models.Visibility = Visibility.Visible;
            Show(Loc.T("ai.models.loaded", models.Count), true);
        }
        catch (OperationCanceledException) { }
        catch (Exception error) when (error is not OutOfMemoryException) { Show(error is AiException ? error.Message : Loc.T("ai.failed")); }
        finally { TestButton.IsEnabled = true; }
    }
    private void OnModel(object sender, SelectionChangedEventArgs e) { if (Models.SelectedItem is string model) Model.Text = model; }
    private async void OnRemove(object sender, RoutedEventArgs e)
    {
        if (!await MainWindow.Current.ConfirmAsync(Loc.T("ai.provider.remove"), Loc.T("ai.provider.remove.detail", profile.Name), Loc.T("action.remove"))) return;
        try
        {
            new AiProfileManager(store, credentials).Remove(profile.Id);
            profile = AiProfile.Create(AiProvider.Compatible);
            Load();
        }
        catch (Exception error) when (error is not OutOfMemoryException) { Show(error is AiException ? error.Message : Loc.T("ai.failed")); }
    }
}
