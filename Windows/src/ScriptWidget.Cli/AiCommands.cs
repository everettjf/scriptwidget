using System.Text.Json.Nodes;
using ScriptWidget.Core;
using ScriptWidget.Core.AI;
using ScriptWidget.Core.Hosting;
using ScriptWidget.Core.Skills;

namespace ScriptWidget.Cli;

internal static partial class Program
{
    private static async Task<int> Ai(Options options)
    {
        var paths = new DataPaths(options.Value("data"));
        var profiles = new AiProfileStore(paths.AiProfiles);
        var settings = profiles.Load();
        var credentials = new WindowsAiCredentials();
        var command = options.Positional(0, "AI command");
        if (command == "configure")
        {
            var provider = options.Value("provider") switch { "anthropic" => AiProvider.Anthropic, "openai" => AiProvider.OpenAi, "ollama" => AiProvider.Ollama, "lmstudio" => AiProvider.LmStudio, "custom" or null => AiProvider.Compatible, _ => throw new ArgumentException("Unknown AI provider. Use anthropic, openai, custom, ollama or lmstudio.") };
            var profile = AiProfile.Create(provider);
            profile = profile with { Name = options.Value("name") ?? profile.Name, BaseUrl = options.Value("base-url") ?? profile.BaseUrl, Model = options.Value("model") ?? profile.Model };
            if (profile.ValidationError(requireModel: false) is { } error) throw new AiException("invalid_profile", error);
            profiles.Save(new AiProfileSettings([.. settings.Profiles, profile], profile.Id));
            Print(new JsonObject { ["ok"] = true, ["id"] = profile.Id, ["name"] = profile.Name, ["baseUrl"] = profile.NormalizedBaseUrl, ["model"] = profile.Model });
            return 0;
        }
        var active = options.Value("profile") is { } id ? settings.Profiles.FirstOrDefault(profile => profile.Id == id) : settings.Active;
        if (command == "profiles")
        {
            var rows = new JsonArray();
            foreach (var profile in settings.Profiles) rows.Append(new JsonObject { ["id"] = profile.Id, ["name"] = profile.Name, ["provider"] = profile.Provider.ToString(), ["baseUrl"] = profile.NormalizedBaseUrl, ["model"] = profile.Model, ["temperature"] = profile.Temperature, ["active"] = settings.ActiveId == profile.Id });
            Print(new JsonObject { ["profiles"] = rows });
            return 0;
        }
        if (command is "list" or "show" or "fork" or "select" or "apply") return await LocalAi(options, paths, command);
        if (active is null) throw new AiException("invalid_profile", "Configure an AI provider first.");
        if (command == "key")
        {
            var action = options.Positional(1, "key action");
            if (action == "set")
            {
                if (!options.Flag("stdin")) throw new ArgumentException("Use swcli ai key set --stdin; keys are never accepted as command-line arguments.");
                string text;
                if (Console.IsInputRedirected) text = Console.ReadLine() ?? "";
                else
                {
                    var characters = new System.Text.StringBuilder();
                    while (true)
                    {
                        var character = Console.ReadKey(intercept: true);
                        if (character.Key == ConsoleKey.Enter) break;
                        if (character.Key == ConsoleKey.Backspace) { if (characters.Length > 0) characters.Length--; continue; }
                        if (characters.Length >= 4096) throw new AiException("missing_api_key", "The API key is too long.");
                        characters.Append(character.KeyChar);
                    }
                    text = characters.ToString();
                }
                credentials.Set(active.Id, new AiApiKey(text));
                Print(new JsonObject { ["ok"] = true, ["storedIn"] = "Windows Credential Locker" });
            }
            else if (action == "remove") { credentials.Remove(active.Id); Print(new JsonObject { ["ok"] = true }); }
            else if (action == "status") Print(new JsonObject { ["configured"] = credentials.Get(active.Id) is not null });
            else throw new ArgumentException("Usage: swcli ai key set --stdin|remove|status [--profile <id>]");
            return 0;
        }
        if (command == "models")
        {
            var key = active.ReadKey(credentials);
            using var client = new AiClient();
            var models = await client.ListModelsAsync(active, key);
            Print(new JsonObject { ["ok"] = true, ["models"] = ScriptWidget.Core.Json.Array(models) });
            return 0;
        }
        if (command is "new" or "continue" or "retry")
        {
            var conversations = new AiConversationStore(paths.AiConversations);
            var library = new Library(paths);
            var skills = new SkillStore(paths.Skills);
            var conversation = command == "new" ? new AiConversation { Family = options.Value("family") ?? "medium" } :
                conversations.Load(options.Positional(1, "conversation id")) ?? throw new AiException("not_found", "Conversation not found.");
            if (!WidgetFamilies.IsKnown(conversation.Family)) throw new ArgumentException("Unknown widget family.");
            string request;
            if (command == "retry")
            {
                if (conversation.PackageId is { } packageId && library.FindByInstallation(packageId) is { } retryPackage &&
                    !conversation.CanApplyToSource(retryPackage.Files.ReadText(AiCandidates.Entry(retryPackage)) ?? ""))
                    throw new AiException("package_changed", "The widget changed. Continue the conversation to include the latest code before retrying.");
                var failed = options.Value("turn") ?? conversation.Turns.LastOrDefault(turn => turn.Status != AiTurnStatus.Succeeded)?.Id ?? throw new AiException("not_found", "No failed turn to retry.");
                request = conversation.RetryRequest(failed);
            }
            else request = options.Positional(command == "new" ? 1 : 2, "widget request");
            if (command == "new" && options.Value("package") is { } name)
            {
                var package = library.Find(name) ?? throw new AiException("not_found", "Widget not found.");
                conversation.PackageId = package.Installation;
                conversation.AddVersion(package.Files.ReadText(AiCandidates.Entry(package)) ?? throw new AiException("invalid_package", "Widget entry cannot be read."), AiCandidates.AllowedHosts(package));
                conversation.RecordAppliedSource(conversation.CurrentVersion!.Source);
            }
            if (options.Value("skills") is { } chosen) conversation.ChooseSkills(chosen.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries));
            if (options.Value("version") is { } version)
            {
                if (conversation.PackageId is { } packageId && library.FindByInstallation(packageId) is { } selectedPackage)
                    conversation.ReconcileInstalledSource(selectedPackage.Files.ReadText(AiCandidates.Entry(selectedPackage)) ?? "", AiCandidates.AllowedHosts(selectedPackage));
                if (!conversation.SelectVersion(version)) throw new AiException("not_found", "Version not found.");
            }
            var key = active.ReadKey(credentials);
            using var client = new AiClient();
            using var cancellation = new CancellationTokenSource();
            ConsoleCancelEventHandler cancel = (_, e) => { e.Cancel = true; cancellation.Cancel(); };
            Console.CancelKeyPress += cancel;
            AiTurn turn;
            try
            {
                turn = await new AiRunner(paths, library, skills, conversations).RunAsync(conversation, request, client.Bind(active, key), progress =>
                {
                    if (!options.Flag("stream") && progress.State == "partial") return;
                    var value = new JsonObject { ["state"] = progress.State, ["attempt"] = progress.Attempt };
                    if (options.Flag("stream")) value["text"] = progress.Text;
                    Console.Error.WriteLine(ScriptWidget.Core.Json.Stringify(value));
                }, cancellation: cancellation.Token);
            }
            finally { Console.CancelKeyPress -= cancel; }
            if (turn.Status == AiTurnStatus.Succeeded && options.Value("output") is { } output)
            {
                using var file = new FileStream(output, FileMode.CreateNew, FileAccess.Write);
                file.Write(System.Text.Encoding.UTF8.GetBytes(conversation.CurrentVersion!.Source));
            }
            Print(new JsonObject
            {
                ["ok"] = turn.Status == AiTurnStatus.Succeeded, ["id"] = conversation.Id, ["status"] = turn.Status.ToString().ToLowerInvariant(),
                ["title"] = conversation.Title, ["versionId"] = conversation.CurrentVersionId, ["versions"] = conversation.Versions.Count,
                ["repairs"] = turn.Repairs, ["note"] = turn.Note, ["error"] = turn.ErrorSummary,
                ["promptTokens"] = turn.Usage.PromptTokens, ["completionTokens"] = turn.Usage.CompletionTokens, ["totalTokens"] = turn.Usage.TotalTokens,
            });
            return turn.Status == AiTurnStatus.Succeeded ? 0 : 1;
        }
        throw new ArgumentException("Usage: swcli ai configure|profiles|key|models|new|continue|retry|list|show|fork|select|apply");
    }

    private static Task<int> LocalAi(Options options, DataPaths paths, string command)
    {
        var store = new AiConversationStore(paths.AiConversations);
        if (command == "list")
        {
            var entries = new JsonArray();
            foreach (var item in store.List()) entries.Append(new JsonObject { ["id"] = item.Id, ["title"] = item.Title, ["packageId"] = item.PackageId, ["versions"] = item.Versions.Count, ["updatedAt"] = item.UpdatedAt });
            Print(new JsonObject { ["conversations"] = entries });
            return Task.FromResult(0);
        }
        var conversation = store.Load(options.Positional(1, "conversation id")) ?? throw new AiException("not_found", "Conversation not found.");
        if (command == "show") { Print(conversation.ToJson()); return Task.FromResult(0); }
        if (command == "fork")
        {
            var fork = conversation.Fork();
            store.Save(fork);
            Print(new JsonObject { ["ok"] = true, ["id"] = fork.Id });
            return Task.FromResult(0);
        }
        if (command == "select")
        {
            if (!conversation.SelectVersion(options.Positional(2, "version id"))) throw new AiException("not_found", "Version not found.");
            store.Save(conversation);
            Print(new JsonObject { ["ok"] = true });
            return Task.FromResult(0);
        }
        if (command == "apply")
        {
            var version = conversation.CurrentVersion ?? throw new AiException("not_found", "This conversation has no successful version.");
            var library = new Library(paths);
            using var runtime = new ScriptWidget.Core.WidgetRuntime(paths);
            var installed = conversation.PackageId is { } id ? library.FindByInstallation(id) ?? throw new AiException("not_found", "Widget not found.") : null;
            if (installed is not null && !conversation.CanApplyToSource(installed.Files.ReadText(AiCandidates.Entry(installed)) ?? ""))
                throw new AiException("package_changed", "The widget changed since this version was prepared. Continue the conversation to include the latest code before applying.");
            var saved = installed is null ? AiCandidates.SaveNew(library, options.Value("name") ?? conversation.Title, version, options.Flag("allow-network"), runtime.ValidatePackage) :
                AiCandidates.Apply(library, installed, version, runtime.ValidatePackage, options.Flag("allow-network"));
            var receipt = AiPublication.Complete(conversation, version, saved, store.Save, _ =>
            {
                if (options.Value("data") is null) HostPipe.Send(new JsonObject { ["command"] = "library-changed" }, 300, 3000);
            });
            Print(new JsonObject { ["ok"] = true, ["name"] = saved.Name, ["installation"] = saved.Installation,
                ["conversationSaved"] = receipt.ConversationSaved,
                ["warning"] = receipt.ConversationSaved ? null : "Widget applied, but its conversation could not be saved. The installed widget is available in your library." });
            return Task.FromResult(0);
        }
        throw new ArgumentException("Unknown local AI command.");
    }
}
