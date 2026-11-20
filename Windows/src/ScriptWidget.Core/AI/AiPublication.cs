using ScriptWidget.Core.Hosting;

namespace ScriptWidget.Core.AI;

public sealed record AiPublicationResult(InstalledPackage Package, bool ConversationSaved);

/// <summary>Publication already happened: a conversation-file failure cannot undo or hide that fact.</summary>
public static class AiPublication
{
    public static AiPublicationResult Complete(AiConversation conversation, AiVersion version, InstalledPackage package,
        Action<AiConversation> persist, Action<InstalledPackage> published)
    {
        conversation.PackageId = package.Installation;
        conversation.RecordAppliedSource(version.Source);
        var saved = false;
        try { persist(conversation); saved = true; }
        catch (Exception error) when (error is AiException or IOException or UnauthorizedAccessException) { }
        finally { published(package); }
        return new(package, saved);
    }
}
