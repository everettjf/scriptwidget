using ScriptWidget.Core.AI;
using ScriptWidget.Core.Hosting;
using ScriptWidget.Core.Tests.Packages;

namespace ScriptWidget.Core.Tests.AI;

public sealed class AiRecoveryTests
{
    private static AiProfile Profile => AiProfile.Create(AiProvider.OpenAi);
    private static readonly AiApiKey OldKey = new("synthetic-old-key"), NewKey = new("synthetic-new-key");

    private sealed class Settings(AiProfile? initial = null) : IAiProfileSettingsStore
    {
        public AiProfileSettings Value = initial is null ? new([], null) : new([initial], initial.Id);
        public bool Fail;
        public AiProfileSettings Load() => Value;
        public void Save(AiProfileSettings value)
        {
            if (Fail) throw new AiException("storage_unavailable", "Injected metadata write failure.");
            Value = value;
        }
    }
    private sealed class Credentials : IAiCredentials
    {
        public readonly Dictionary<string, AiApiKey> Values = [];
        public int Reads, Writes, FailSets;
        public bool FailEverySet, FailRemoveAfterMutation;
        public string? RefuseRemove;
        public AiApiKey? Get(string id) { Reads++; return Values.GetValueOrDefault(id); }
        public void Set(string id, AiApiKey key)
        {
            Writes++;
            Values[id] = key;
            if (FailEverySet || FailSets-- > 0) throw new AiException("credentials_unavailable", "Injected vault write failure.");
        }
        public void Remove(string id)
        {
            Writes++;
            if (id == RefuseRemove) throw new AiException("credentials_unavailable", "Injected vault cleanup failure.");
            Values.Remove(id);
            if (FailRemoveAfterMutation) { FailRemoveAfterMutation = false; throw new AiException("credentials_unavailable", "Injected partial delete."); }
        }
    }

    [Fact]
    public void SwitchingToALocalServerDoesNotReuseTheRemoteKey()
    {
        var remote = Profile;
        var settings = new Settings(remote);
        var keys = new Credentials(); keys.Values[remote.Id] = OldKey;
        var local = remote with { Provider = AiProvider.LmStudio, BaseUrl = "http://localhost:1234", Model = "" };
        var saved = new AiProfileManager(settings, keys).Save(remote, local);
        Assert.NotEqual(remote.Id, saved.Profile.Id);
        Assert.Null(saved.Profile.ReadKey(keys));
        Assert.Empty(keys.Values);
        Assert.Equal(saved.Profile, settings.Value.Active);
    }

    [Fact]
    public void FailedLocalEndpointChangesLeaveTheRemoteKeyAndProfileIntact()
    {
        var remote = Profile;
        var settings = new Settings(remote) { Fail = true };
        var keys = new Credentials(); keys.Values[remote.Id] = OldKey;
        var local = remote with { Provider = AiProvider.Ollama, BaseUrl = "http://127.0.0.1:11434", Model = "" };
        Assert.Throws<AiException>(() => new AiProfileManager(settings, keys).Save(remote, local));
        Assert.Same(OldKey, keys.Values[remote.Id]);
        Assert.Equal(remote, settings.Value.Active);
        Assert.Equal(0, keys.Writes);
    }

    [Fact]
    public void LeavingLocalForRemoteRequiresAnExplicitNewKey()
    {
        var local = AiProfile.Create(AiProvider.Ollama) with { Model = "local-chat" };
        var keys = new Credentials(); keys.Values[local.Id] = OldKey;
        var remote = local with { Provider = AiProvider.Compatible, BaseUrl = "https://api.example.com" };
        Assert.Throws<AiException>(() => new AiProfileManager(new Settings(local), keys).Save(local, remote));
        Assert.Equal(0, keys.Reads + keys.Writes);
    }

    [Fact]
    public void ReplacingAKeyRestoresItWhenMetadataCannotBeSaved()
    {
        var profile = Profile;
        var settings = new Settings(profile) { Fail = true };
        var keys = new Credentials(); keys.Values[profile.Id] = OldKey;
        Assert.Throws<AiException>(() => new AiProfileManager(settings, keys).Save(profile, profile with { Model = "new-model" }, NewKey));
        Assert.Same(OldKey, keys.Values[profile.Id]);
        Assert.Equal(profile, settings.Value.Active);
    }

    [Fact]
    public void ANewProfileLeavesNoCredentialWhenMetadataFails()
    {
        var profile = Profile;
        var settings = new Settings { Fail = true };
        var keys = new Credentials();
        Assert.Throws<AiException>(() => new AiProfileManager(settings, keys).Save(profile, profile, NewKey));
        Assert.Empty(keys.Values);
        Assert.Empty(settings.Value.Profiles);
    }

    [Fact]
    public void EndpointChangesNeedAnExplicitKeyBeforeAnyVaultOperation()
    {
        var profile = Profile;
        var keys = new Credentials();
        Assert.Throws<AiException>(() => new AiProfileManager(new Settings(profile), keys).Save(profile, profile with { BaseUrl = "https://other.example.com" }));
        Assert.Equal(0, keys.Reads + keys.Writes);
    }

    [Fact]
    public void FailedEndpointChangesKeepTheOldEndpointAndKeyTogether()
    {
        var profile = Profile;
        var settings = new Settings(profile) { Fail = true };
        var keys = new Credentials(); keys.Values[profile.Id] = OldKey;
        Assert.Throws<AiException>(() => new AiProfileManager(settings, keys).Save(profile, profile with { BaseUrl = "https://other.example.com" }, NewKey));
        Assert.Equal(profile, settings.Value.Active);
        Assert.Single(keys.Values);
        Assert.Same(OldKey, keys.Values[profile.Id]);
    }

    [Fact]
    public void SuccessfulEndpointChangesUseANewVaultIdentity()
    {
        var profile = Profile;
        var settings = new Settings(profile);
        var keys = new Credentials(); keys.Values[profile.Id] = OldKey;
        var saved = new AiProfileManager(settings, keys).Save(profile, profile with { BaseUrl = "https://other.example.com/v1/" }, NewKey);
        Assert.NotEqual(profile.Id, saved.Profile.Id);
        Assert.Equal("https://other.example.com", settings.Value.Active!.BaseUrl);
        Assert.Same(NewKey, keys.Values[saved.Profile.Id]);
        Assert.False(keys.Values.ContainsKey(profile.Id));
        Assert.True(saved.PreviousKeyRemoved);
    }

    [Fact]
    public void CleanupFailureDoesNotMisreportACommittedEndpointChange()
    {
        var profile = Profile;
        var settings = new Settings(profile);
        var keys = new Credentials { RefuseRemove = profile.Id }; keys.Values[profile.Id] = OldKey;
        var saved = new AiProfileManager(settings, keys).Save(profile, profile with { BaseUrl = "https://other.example.com" }, NewKey);
        Assert.False(saved.PreviousKeyRemoved);
        Assert.Equal(saved.Profile, settings.Value.Active);
        Assert.Same(NewKey, keys.Values[saved.Profile.Id]);
        Assert.Same(OldKey, keys.Values[profile.Id]);
    }

    [Fact]
    public void APartiallyFailedVaultWriteIsCompensated()
    {
        var profile = Profile;
        var settings = new Settings(profile);
        var keys = new Credentials { FailSets = 1 }; keys.Values[profile.Id] = OldKey;
        Assert.Throws<AiException>(() => new AiProfileManager(settings, keys).Save(profile, profile, NewKey));
        Assert.Same(OldKey, keys.Values[profile.Id]);
        Assert.Equal(profile, settings.Value.Active);
    }

    [Fact]
    public void FailedCompensationIsExplicitAndNeverEchoesEitherKey()
    {
        var profile = Profile;
        var keys = new Credentials { FailEverySet = true }; keys.Values[profile.Id] = OldKey;
        var error = Assert.Throws<AiException>(() => new AiProfileManager(new Settings(profile), keys).Save(profile, profile, NewKey));
        Assert.Equal("credential_rollback_failed", error.Code);
        Assert.DoesNotContain(OldKey.Secret, error.Message);
        Assert.DoesNotContain(NewKey.Secret, error.Message);
    }

    [Fact]
    public void FailedProfileRemovalRestoresTheCredential()
    {
        var profile = Profile;
        var settings = new Settings(profile) { Fail = true };
        var keys = new Credentials(); keys.Values[profile.Id] = OldKey;
        Assert.Throws<AiException>(() => new AiProfileManager(settings, keys).Remove(profile.Id));
        Assert.Equal(profile, settings.Value.Active);
        Assert.Same(OldKey, keys.Values[profile.Id]);
    }

    [Fact]
    public void APartiallyFailedVaultRemovalAlsoRestoresTheCredential()
    {
        var profile = Profile;
        var settings = new Settings(profile);
        var keys = new Credentials { FailRemoveAfterMutation = true }; keys.Values[profile.Id] = OldKey;
        Assert.Throws<AiException>(() => new AiProfileManager(settings, keys).Remove(profile.Id));
        Assert.Equal(profile, settings.Value.Active);
        Assert.Same(OldKey, keys.Values[profile.Id]);
    }

    [Fact]
    public void StaleProfileEditsAreRefusedBeforeTouchingCredentials()
    {
        var profile = Profile;
        var keys = new Credentials();
        Assert.Throws<AiException>(() => new AiProfileManager(new Settings(profile with { Model = "changed-elsewhere" }), keys).Save(profile, profile, NewKey));
        Assert.Equal(0, keys.Reads + keys.Writes);
    }

    [Fact]
    public void RealWindowsVaultRestoresTheOldKeyAfterMetadataFailure()
    {
        var profile = Profile;
        var keys = new WindowsAiCredentials("ScriptWidget.RecoveryTests." + Guid.NewGuid().ToString("N"));
        try
        {
            keys.Set(profile.Id, OldKey);
            Assert.Throws<AiException>(() => new AiProfileManager(new Settings(profile) { Fail = true }, keys).Save(profile, profile, NewKey));
            Assert.Equal(OldKey.Secret, keys.Get(profile.Id)!.Secret);
        }
        finally { keys.Remove(profile.Id); }
    }

    [Fact]
    public void AppliedWidgetsStayObservableWhenTheirConversationCannotBeSaved()
    {
        using var temporary = new TemporaryFolder();
        var library = new Library(new DataPaths(temporary.Root));
        var conversation = new AiConversation();
        var version = conversation.AddVersion("$render(<vstack><text>Applied</text></vstack>);");
        var package = AiCandidates.SaveNew(library, "Recovery", version, false);
        var blocked = Path.Combine(temporary.Root, "blocked");
        File.WriteAllText(blocked, "not a directory");
        var brokenStore = new AiConversationStore(blocked);
        var notifications = 0;
        var result = AiPublication.Complete(conversation, version, package, brokenStore.Save, updated =>
        {
            notifications++;
            Assert.Equal(version.Source, updated.Files.ReadText("main.jsx"));
        });
        Assert.False(result.ConversationSaved);
        Assert.Equal(1, notifications);
        Assert.Equal(package.Installation, conversation.PackageId);
        Assert.True(conversation.CanApplyToSource(version.Source));
        var working = new AiConversationStore(Path.Combine(temporary.Root, "working"));
        Assert.True(AiPublication.Complete(conversation, version, package, working.Save, _ => notifications++).ConversationSaved);
        Assert.Single(working.Load(conversation.Id)!.Versions);
        Assert.Equal(2, notifications);
    }

    [Fact]
    public void UnexpectedPersistenceErrorsStillNotifyThePublishedWidget()
    {
        using var temporary = new TemporaryFolder();
        var conversation = new AiConversation();
        var version = conversation.AddVersion("$render(<text>Saved</text>);");
        var package = AiCandidates.SaveNew(new Library(new DataPaths(temporary.Root)), "Saved", version, false);
        var notified = false;
        Assert.Throws<InvalidOperationException>(() => AiPublication.Complete(conversation, version, package,
            _ => throw new InvalidOperationException("unexpected"), _ => notified = true));
        Assert.True(notified);
    }
}
