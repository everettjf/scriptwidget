using System.Text;
using ScriptWidget.Core.Api;
using ScriptWidget.Core.Plugins;

namespace ScriptWidget.Core.Hosting;

/// <summary>Bounded private text, refusing links and publishing through an exclusively created temporary file.</summary>
internal sealed class SafeJsonFile(string path, int maximumBytes)
{
    public string Path { get; } = System.IO.Path.GetFullPath(path);
    public string? Read()
    {
        var parent = System.IO.Path.GetDirectoryName(Path)!;
        if (!PluginFiles.Occupied(parent)) return null;
        if (PluginFiles.RealDirectory(parent) is null) throw new PrivateFile.Unreadable();
        if (!PluginFiles.Occupied(Path)) return null;
        var file = PluginFiles.ExistingFile(parent, System.IO.Path.GetFileName(Path));
        if (file is null || PluginFiles.ReadBounded(file, maximumBytes) is not { } bytes) throw new PrivateFile.Unreadable();
        try { return new UTF8Encoding(false, true).GetString(bytes); }
        catch (DecoderFallbackException) { throw new PrivateFile.Unreadable(); }
    }

    public bool Write(string text)
    {
        var bytes = Encoding.UTF8.GetBytes(text);
        if (bytes.Length > maximumBytes) return false;
        var parent = System.IO.Path.GetDirectoryName(Path)!;
        var temporary = System.IO.Path.Combine(parent, ".write-" + Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(parent);
            if (PluginFiles.RealDirectory(parent) is null) return false;
            PluginFiles.WriteNew(temporary, bytes);
            File.Move(temporary, Path, overwrite: true);
            return true;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return false; }
        finally { PluginFiles.DeleteTree(temporary); }
    }
}
