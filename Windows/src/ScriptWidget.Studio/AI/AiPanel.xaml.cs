using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using ScriptWidget.Core.AI;
using ScriptWidget.Core.Hosting;
using ScriptWidget.Core.Packages;
using ScriptWidget.Studio.Services;

namespace ScriptWidget.Studio.AI;

/// <summary>The same versioned assistant is available for drafts and beside an installed widget's editor.</summary>
public sealed partial class AiPanel : UserControl
{
    private readonly AiConversationStore store = new(AppServices.Paths.AiConversations);
    private AiConversation conversation = new();
    private InstalledPackage? package;
    private CancellationTokenSource? cancellation;
    private bool updating;
    private int previewGeneration;
    public Func<Task<InstalledPackage?>>? ReadEditor { get; set; }
    public Action<InstalledPackage>? Applied { get; set; }

    public AiPanel()
    {
        InitializeComponent();
        foreach (var family in WidgetFamilies.All) Family.Items.Add(new ComboBoxItem { Content = Loc.Family(family), Tag = family });
        Family.SelectedIndex = WidgetFamilies.All.ToList().IndexOf("medium");
        Unloaded += (_, _) => cancellation?.Cancel();
    }

    public void Open(InstalledPackage? installed = null)
    {
        package = installed;
        try
        {
            conversation = store.List().FirstOrDefault(item => item.PackageId == installed?.Installation) ?? Create();
            ObservePackage();
            Reload();
        }
        catch (Exception error) when (error is not OutOfMemoryException)
        {
            conversation = new AiConversation { PackageId = installed?.Installation };
            Reload();
            Error(error);
        }
    }

    private void ObservePackage()
    {
        if (package is null) return;
        var source = package.Files.ReadText(AiCandidates.Entry(package)) ?? throw new AiException("invalid_package", Loc.T("ai.widgetChanged"));
        conversation.ReconcileInstalledSource(source, AiCandidates.AllowedHosts(package));
        store.Save(conversation);
    }

    private AiConversation Create()
    {
        var result = new AiConversation { PackageId = package?.Installation };
        if (package is not null)
        {
            var source = package.Files.ReadText(AiCandidates.Entry(package)) ?? "";
            result.AddVersion(source, AiCandidates.AllowedHosts(package));
            result.RecordAppliedSource(source);
        }
        result.ChooseSkills(AppServices.Skills.EnabledIds());
        return result;
    }

    private void Reload()
    {
        updating = true;
        var saved = store.List().Where(item => ReadEditor is null || item.PackageId == package?.Installation).ToList();
        if (!saved.Any(item => item.Id == conversation.Id)) saved.Insert(0, conversation);
        UpdateChoices(Conversations, saved.Select(item => (item.Id, item.Title.Length == 0 ? Loc.T("ai.draft") : item.Title)), conversation.Id);
        UpdateChoices(Versions, conversation.Versions.OrderByDescending(item => item.Number).Select(item => (item.Id, Loc.T("ai.version", item.Number))), conversation.CurrentVersionId);
        Family.SelectedItem = Family.Items.OfType<ComboBoxItem>().FirstOrDefault(item => (string)item.Tag == conversation.Family);
        History.Text = conversation.Turns.Count == 0 ? Loc.T("ai.welcome") : string.Join("\n\n", conversation.Turns.TakeLast(12).Select(turn =>
            turn.IsManualEdit ? Loc.T("ai.manual") : turn.Request + "\n" + Loc.T("ai.status." + turn.Status.ToString().ToLowerInvariant()) +
            (turn.IsAbandoned ? " · " + Loc.T("ai.abandoned") : "") + "\n" + (turn.ErrorSummary ?? turn.Note ?? "")));
        var versionNow = conversation.CurrentVersion;
        var before = conversation.Version(versionNow?.ParentId)?.Source ?? "";
        var diff = versionNow is null ? [] : AiSourceDiff.Lines(before, versionNow.Source);
        Changes.Text = diff is null ? versionNow?.Source ?? "" : string.Join("\n", diff.Select(line => line.Kind switch
        {
            AiDiffKind.Added => "+ " + line.Text, AiDiffKind.Removed => "− " + line.Text,
            AiDiffKind.Skipped => Loc.T("ai.skipped", line.Skipped), _ => "  " + line.Text,
        }));
        if (Changes.Text.Length == 0) Changes.Text = Loc.T("ai.noChanges");
        Status.Text = Loc.T("ai.tokens", conversation.TotalUsage.TotalTokens);
        updating = false;
        SetBusy(false);
        _ = RenderPreviewAsync();
    }

    private static void UpdateChoices(ComboBox box, IEnumerable<(string Id, string Title)> choices, string? selectedId)
    {
        // Keep existing containers alive while the ComboBox closes its popup. Clearing a
        // selected item during SelectionChanged can fail fast inside WinUI's popup teardown.
        var desired = choices.ToList();
        var ids = desired.Select(item => item.Id).ToHashSet(StringComparer.Ordinal);
        foreach (var obsolete in box.Items.OfType<ComboBoxItem>().Where(item => !ids.Contains((string)item.Tag)).ToList())
            box.Items.Remove(obsolete);
        foreach (var (id, title) in desired)
        {
            var item = box.Items.OfType<ComboBoxItem>().FirstOrDefault(item => (string)item.Tag == id);
            if (item is null) box.Items.Insert(desired.FindIndex(choice => choice.Id == id), new ComboBoxItem { Content = title, Tag = id });
            else item.Content = title;
        }
        box.SelectedItem = box.Items.OfType<ComboBoxItem>().FirstOrDefault(item => (string)item.Tag == selectedId);
    }

    private void SetBusy(bool busy)
    {
        Conversations.IsEnabled = Versions.IsEnabled = Family.IsEnabled = NewButton.IsEnabled = SkillsButton.IsEnabled = !busy;
        SendButton.IsEnabled = Request.IsEnabled = !busy;
        ApplyButton.IsEnabled = ForkButton.IsEnabled = !busy && conversation.CurrentVersion is not null;
        RetryButton.IsEnabled = !busy && conversation.Turns.Any(turn => !turn.IsManualEdit && turn.Status != AiTurnStatus.Succeeded);
        CancelButton.IsEnabled = busy && cancellation is not null;
    }

    private void Error(Exception error)
    {
        Message.Severity = InfoBarSeverity.Error;
        Message.Message = error is AiException or PackageException or IOException or UnauthorizedAccessException ? error.Message : Loc.T("ai.failed");
        Message.IsOpen = true;
    }

    private async Task RefreshPackageAsync(bool adopt)
    {
        var fresh = ReadEditor is null ? package is null ? null : AppServices.Library.FindByInstallation(package.Installation) : await ReadEditor();
        if (package is not null && fresh is null) throw new AiException("package_changed", Loc.T("ai.widgetChanged"));
        if (fresh is not null)
        {
            var source = fresh.Files.ReadText(AiCandidates.Entry(fresh)) ?? throw new AiException("invalid_package", Loc.T("ai.widgetChanged"));
            if (adopt) conversation.ReconcileInstalledSource(source, AiCandidates.AllowedHosts(fresh));
            else if (!conversation.CanApplyToSource(source)) throw new AiException("package_changed", Loc.T("ai.widgetChanged"));
            package = fresh;
        }
    }

    private async Task RunAsync(string request, bool retry = false)
    {
        if (cancellation is not null) return;
        try
        {
            var profile = new AiProfileStore(AppServices.Paths.AiProfiles).Load().Active ?? throw new AiException("invalid_profile", Loc.T("ai.configureFirst"));
            var key = profile.ReadKey(new WindowsAiCredentials());
            await RefreshPackageAsync(adopt: !retry);
            if (retry)
            {
                var failed = conversation.Turns.Last(turn => !turn.IsManualEdit && turn.Status != AiTurnStatus.Succeeded);
                request = conversation.RetryRequest(failed.Id);
            }
            if (string.IsNullOrWhiteSpace(request)) return;
            using var cancel = new CancellationTokenSource();
            cancellation = cancel;
            SetBusy(true);
            Streaming.Text = "";
            Message.IsOpen = false;
            var runner = new AiRunner(AppServices.Paths, AppServices.Library, AppServices.Skills, store);
            using var client = new AiClient();
            var turn = await Task.Run(() => runner.RunAsync(conversation, request, client.Bind(profile, key), progress => DispatcherQueue.TryEnqueue(() =>
            {
                Status.Text = Loc.T("ai.progress", Loc.T("ai.state." + progress.State), progress.Attempt);
                if (progress.State == "partial") Streaming.Text = AiConversation.Clip(progress.Text ?? "", 6000);
            }), cancellation: cancel.Token));
            Request.Text = "";
            Streaming.Text = "";
            if (turn.Status == AiTurnStatus.Succeeded) Tabs.SelectedIndex = 1;
            else if (turn.ErrorSummary is { } error) Error(new AiException("request_failed", error));
        }
        catch (Exception error) when (error is not OutOfMemoryException) { Error(error); }
        finally { cancellation = null; Reload(); }
    }

    private async void OnSend(object sender, RoutedEventArgs e) => await RunAsync(Request.Text);
    private async void OnRetry(object sender, RoutedEventArgs e) => await RunAsync("", retry: true);
    private void OnCancel(object sender, RoutedEventArgs e) => cancellation?.Cancel();
    private void OnNew(object sender, RoutedEventArgs e)
    {
        try
        {
            if (ReadEditor is null) package = null;
            conversation = Create();
            Request.Text = "";
            Reload();
        }
        catch (Exception error) when (error is not OutOfMemoryException) { Error(error); }
    }
    private void OnFork(object sender, RoutedEventArgs e)
    {
        try { conversation = conversation.Fork(); store.Save(conversation); Reload(); }
        catch (Exception error) when (error is not OutOfMemoryException) { Error(error); }
    }
    private void OnConversation(object sender, SelectionChangedEventArgs e)
    {
        if (updating || Conversations.SelectedItem is not ComboBoxItem { Tag: string id }) return;
        // Let the popup finish committing its selection before Reload replaces its items.
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
        {
            if (updating || Conversations.SelectedItem is not ComboBoxItem { Tag: string selected } || selected != id) return;
            try
            {
                if (store.Load(id) is not { } loaded || loaded.Id == conversation.Id) return;
                conversation = loaded;
                package = loaded.PackageId is null ? null : AppServices.Library.FindByInstallation(loaded.PackageId);
                ObservePackage();
                Reload();
            }
            catch (Exception error) when (error is not OutOfMemoryException) { Error(error); }
        });
    }
    private void OnVersion(object sender, SelectionChangedEventArgs e)
    {
        if (updating || Versions.SelectedItem is not ComboBoxItem { Tag: string id }) return;
        var conversationId = conversation.Id;
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, async () =>
        {
            if (updating || conversation.Id != conversationId || Versions.SelectedItem is not ComboBoxItem { Tag: string selected } || selected != id) return;
            SetBusy(true);
            try
            {
                // Record disk changes before intentionally returning to an older branch.
                await RefreshPackageAsync(adopt: true);
                if (conversation.SelectVersion(id)) { store.Save(conversation); Reload(); }
            }
            catch (Exception error) when (error is not OutOfMemoryException) { Error(error); }
            finally { SetBusy(false); }
        });
    }
    private void OnFamily(object sender, SelectionChangedEventArgs e)
    {
        if (updating || Family.SelectedItem is not ComboBoxItem { Tag: string family }) return;
        conversation.Family = family;
        _ = RenderPreviewAsync();
    }
    private void OnTab(object sender, SelectionChangedEventArgs e) { if (Tabs.SelectedIndex == 1) _ = RenderPreviewAsync(); }

    private async Task RenderPreviewAsync()
    {
        var generation = ++previewGeneration;
        if (conversation.CurrentVersion is not { } version) { Picture.Source = null; return; }
        try
        {
            var result = await Preview.RenderAsync(AiCandidates.Files(package, version.Source, version.NetworkDomains, conversation.Title), "ai-preview-" + conversation.Id,
                conversation.Family, Preview.SystemIsDark, "", MainWindow.Current.RasterizationScale);
            if (generation != previewGeneration) return;
            Picture.Source = result.Image;
            Picture.Width = result.Width;
            Picture.Height = result.Height;
            PreviewError.Text = result.Execution.Error?.Message ?? "";
        }
        catch (Exception error) when (error is not OutOfMemoryException) { if (generation == previewGeneration) PreviewError.Text = error.Message; }
    }

    private async void OnSkills(object sender, RoutedEventArgs e)
    {
        IEnumerable<string> selected = conversation.SkillIds is { } chosen ? chosen : AppServices.Skills.EnabledIds();
        var boxes = AppServices.Skills.List().Select(skill => new CheckBox { Content = skill.Name, Tag = skill.Id, IsChecked = selected.Contains(skill.Id) }).ToList();
        var panel = new StackPanel { Spacing = 8 };
        foreach (var box in boxes) panel.Children.Add(box);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = Loc.T("ai.skills"), Content = new ScrollViewer { Content = panel, MaxHeight = 350 }, PrimaryButtonText = Loc.T("action.save"), CloseButtonText = Loc.T("action.cancel") };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        try { conversation.ChooseSkills(boxes.Where(box => box.IsChecked == true).Select(box => (string)box.Tag)); store.Save(conversation); }
        catch (Exception error) when (error is not OutOfMemoryException) { Error(error); }
    }

    private async void OnApply(object sender, RoutedEventArgs e)
    {
        if (conversation.CurrentVersion is not { } version) return;
        try
        {
            await RefreshPackageAsync(adopt: false);
            var hosts = AiCandidates.NewHosts(package, version);
            if (hosts.Count > 0 && !await MainWindow.Current.ConfirmAsync(Loc.T("ai.network.title"), Loc.T("ai.network.detail", string.Join("\n", hosts)), Loc.T("ai.network.allow"))) return;
            var name = package?.Name ?? await MainWindow.Current.PromptAsync(Loc.T("ai.save.title"), Loc.T("ai.save.name"), conversation.Title);
            if (name is null) return;
            SetBusy(true);
            var saved = await AppServices.WithRuntime(runtime =>
            {
                // A name/network dialog or a queued preview may have allowed an external edit.
                if (package is not null && !conversation.CanApplyToSource(package.Files.ReadText(AiCandidates.Entry(package)) ?? ""))
                    throw new AiException("package_changed", Loc.T("ai.widgetChanged"));
                return package is null
                    ? AiCandidates.SaveNew(AppServices.Library, name, version, hosts.Count > 0, runtime.ValidatePackage)
                    : AiCandidates.Apply(AppServices.Library, package, version, runtime.ValidatePackage, hosts.Count > 0);
            });
            package = saved;
            var receipt = AiPublication.Complete(conversation, version, saved, store.Save, updated =>
            {
                Applied?.Invoke(updated);
                DesktopHost.LibraryChanged();
            });
            if (receipt.ConversationSaved) MainWindow.Current.Notify(Loc.T("ai.applied"));
            else
            {
                Message.Severity = InfoBarSeverity.Warning;
                Message.Message = Loc.T("ai.applied.unsavedConversation");
                Message.IsOpen = true;
            }
            Reload();
        }
        catch (Exception error) when (error is not OutOfMemoryException) { Error(error); }
        finally { SetBusy(false); }
    }
}
