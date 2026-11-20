namespace ScriptWidget.Core.AI;

public sealed record AiProfileUpdate(AiProfile Profile, bool PreviousKeyRemoved = true);

/// <summary>Coordinates metadata with Credential Locker, including compensation when one write fails.</summary>
public sealed class AiProfileManager(IAiProfileSettingsStore store, IAiCredentials credentials)
{
    public AiProfileUpdate Save(AiProfile original, AiProfile edited, AiApiKey? replacement = null)
    {
        if (edited.Id != original.Id || edited.ValidationError(requireModel: false) is not null)
            throw new AiException("invalid_profile", edited.ValidationError(requireModel: false) ?? "The profile identity is invalid.");
        var settings = store.Load();
        var previous = settings.Profiles.FirstOrDefault(item => item.Id == original.Id);
        if (previous is not null && previous != original)
            throw new AiException("profile_changed", "This profile changed. Reload Settings before saving it.");
        var changedEndpoint = previous is not null && (edited.NormalizedBaseUrl != previous.NormalizedBaseUrl || edited.Provider != previous.Provider);
        if (changedEndpoint && replacement is null && !edited.IsLoopback)
            throw new AiException("key_required", "Enter a key for the new endpoint before saving it.");
        var saved = edited with { Id = changedEndpoint ? Guid.NewGuid().ToString("D") : edited.Id,
            Name = edited.Name.Trim(), BaseUrl = edited.NormalizedBaseUrl, Model = edited.Model.Trim() };
        var next = new AiProfileSettings([.. settings.Profiles.Where(item => item.Id != original.Id), saved], saved.Id);
        if (next.Profiles.Count > 20) throw new AiException("invalid_profile", "At most 20 AI provider profiles may be saved.");
        var oldKey = replacement is null ? null : credentials.Get(saved.Id);
        try
        {
            if (replacement is not null) credentials.Set(saved.Id, replacement);
            store.Save(next);
        }
        catch (Exception error) when (error is not OutOfMemoryException)
        {
            if (replacement is not null) RestoreKey(saved.Id, oldKey);
            throw;
        }
        if (changedEndpoint)
        {
            try { credentials.Remove(original.Id); }
            catch (Exception error) when (error is not OutOfMemoryException) { return new(saved, PreviousKeyRemoved: false); }
        }
        return new(saved);
    }

    public void Remove(string id)
    {
        var settings = store.Load();
        if (!settings.Profiles.Any(item => item.Id == id)) throw new AiException("not_found", "This provider profile no longer exists.");
        var oldKey = credentials.Get(id);
        var remaining = settings.Profiles.Where(item => item.Id != id).ToList();
        try
        {
            credentials.Remove(id);
            store.Save(new(remaining, settings.ActiveId == id ? remaining.FirstOrDefault()?.Id : settings.ActiveId));
        }
        catch (Exception error) when (error is not OutOfMemoryException)
        {
            RestoreKey(id, oldKey);
            throw;
        }
    }

    private void RestoreKey(string id, AiApiKey? oldKey)
    {
        try { if (oldKey is null) credentials.Remove(id); else credentials.Set(id, oldKey); }
        catch (Exception error) when (error is not OutOfMemoryException)
        {
            throw new AiException("credential_rollback_failed", "Provider settings were not saved, and Windows could not restore the previous credential. Re-enter the key before using this profile.");
        }
    }
}
