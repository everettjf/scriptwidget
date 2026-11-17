using System.Collections.Concurrent;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;
using ScriptWidget.Core;

namespace ScriptWidget.Studio.Editor;

/// <summary>
/// The CodeMirror-based Studio editor (the same bundle the Apple and Android
/// apps embed) in a WebView2. The page is served only from the program's own
/// folder under a private host name; it cannot navigate elsewhere, open
/// windows or reach the network. This is the only web content in the
/// management window; widgets are never drawn by it.
/// </summary>
public sealed class StudioEditor
{
    private const string Host = "studio.scriptwidget.invalid";

    private readonly WebView2 view;
    private readonly ConcurrentDictionary<string, Action<JsonObject>> replies = new();
    private string documentID = "";
    private string sessionID = "";
    private (string ID, string Content, bool ReadOnly)? pendingDocument;
    private bool? pendingDark;

    public bool IsReady { get; private set; }
    /// <summary>The user asked to save (Ctrl+S). Return true when the text was saved.</summary>
    public Func<string, bool>? Save { get; set; }
    public event Action? Ready;
    /// <summary>The editor could not start (for example the WebView2 runtime is missing).</summary>
    public event Action<string>? Failed;

    public StudioEditor(WebView2 view)
    {
        this.view = view;
        _ = InitializeAsync();
    }

    private async Task InitializeAsync()
    {
        try
        {
            await view.EnsureCoreWebView2Async();
            var core = view.CoreWebView2;
            core.Settings.AreDevToolsEnabled = false;
            core.Settings.IsStatusBarEnabled = false;
            core.Settings.AreDefaultContextMenusEnabled = true;
            core.Settings.IsZoomControlEnabled = false;
            core.Settings.IsPasswordAutosaveEnabled = false;
            core.Settings.IsGeneralAutofillEnabled = false;
            core.Settings.AreBrowserAcceleratorKeysEnabled = false;
            core.SetVirtualHostNameToFolderMapping(Host, Path.Combine(AppContext.BaseDirectory, "StudioEditor"), CoreWebView2HostResourceAccessKind.DenyCors);
            // Anything that is not the editor's own files is refused.
            core.AddWebResourceRequestedFilter("*", CoreWebView2WebResourceContext.All);
            core.WebResourceRequested += (_, arguments) =>
            {
                if (Uri.TryCreate(arguments.Request.Uri, UriKind.Absolute, out var uri) && uri.Host == Host) return;
                arguments.Response = core.Environment.CreateWebResourceResponse(null, 403, "Forbidden", "");
            };
            core.NavigationStarting += (_, arguments) =>
            {
                if (!Uri.TryCreate(arguments.Uri, UriKind.Absolute, out var uri) || uri.Host != Host) arguments.Cancel = true;
            };
            core.NewWindowRequested += (_, arguments) => arguments.Handled = true;
            core.PermissionRequested += (_, arguments) => arguments.State = CoreWebView2PermissionState.Deny;
            core.DownloadStarting += (_, arguments) => arguments.Cancel = true;
            core.WebMessageReceived += (_, arguments) =>
            {
                string text;
                try { text = arguments.TryGetWebMessageAsString(); } catch (ArgumentException) { return; }
                if (Json.TryParse(text) is JsonObject message) OnMessage(message);
            };
            await core.AddScriptToExecuteOnDocumentCreatedAsync(await File.ReadAllTextAsync(Path.Combine(AppContext.BaseDirectory, "StudioEditor", "windows-bridge.js")));
            core.Navigate($"https://{Host}/index.html");
        }
        catch (Exception error)
        {
            Failed?.Invoke(error.Message);
        }
    }

    /// <summary>Shows <paramref name="content"/> as the document being edited.</summary>
    public void Open(string id, string content, bool readOnly = false)
    {
        documentID = id;
        sessionID = Guid.NewGuid().ToString();
        if (!IsReady) { pendingDocument = (id, content, readOnly); return; }
        Invoke("document.open", new JsonObject { ["content"] = content, ["version"] = 0, ["readOnly"] = readOnly, ["resources"] = new JsonArray() }, _ => { });
    }

    /// <summary>Reads the current text from the editor; null when it is not available.</summary>
    public Task<string?> ContentAsync()
    {
        var completion = new TaskCompletionSource<string?>();
        if (!IsReady) { completion.SetResult(null); return completion.Task; }
        Invoke("editor.getState", new JsonObject(), response => completion.TrySetResult(response.OptString("result") == "ok" ? response.OptString("content") : null));
        _ = Task.Delay(3000).ContinueWith(_ => completion.TrySetResult(null), TaskScheduler.Default);
        return completion.Task;
    }

    public void Format() { if (IsReady) Invoke("editor.format", new JsonObject(), _ => { }); }

    public void SetTheme(bool dark)
    {
        if (!IsReady) { pendingDark = dark; return; }
        Invoke("editor.setTheme", new JsonObject { ["theme"] = dark ? "dark" : "light" }, _ => { });
    }

    public void PublishDiagnostics(string? message)
    {
        if (!IsReady) return;
        var items = new JsonArray();
        if (message is not null) items.Append(new JsonObject { ["message"] = message, ["severity"] = "error" });
        Invoke("diagnostics.publish", new JsonObject { ["items"] = items }, _ => { });
    }

    private void Invoke(string name, JsonObject payload, Action<JsonObject> reply)
    {
        var replyID = Guid.NewGuid().ToString();
        replies[replyID] = reply;
        var envelope = new JsonObject { ["protocolVersion"] = 1, ["type"] = name, ["documentID"] = documentID, ["sessionID"] = sessionID, ["payload"] = payload };
        _ = view.ExecuteScriptAsync($"window.WKWebViewJavascriptBridge._invoke({Json.Quote(name)}, {Json.Stringify(envelope)}, {Json.Quote(replyID)});");
    }

    private void Respond(string? id, JsonObject response)
    {
        if (id is null) return;
        _ = view.ExecuteScriptAsync($"window.WKWebViewJavascriptBridge._respond({Json.Quote(id)}, {Json.Stringify(response)});");
    }

    /// <summary>A message from the page. Runs on the UI thread.</summary>
    private void OnMessage(JsonObject message)
    {
        if (message.OptString("kind") == "reply")
        {
            if (replies.TryRemove(message.OptString("replyID"), out var callback)) callback(message.OptObject("response") ?? new JsonObject { ["result"] = "failed" });
            return;
        }
        var id = message.IsNull("id") ? null : message.OptString("id");
        var data = message.OptObject("data") ?? new JsonObject();
        switch (message.OptString("name"))
        {
            case "studio.ready":
                IsReady = true;
                if (pendingDocument is { } pending) { pendingDocument = null; Open(pending.ID, pending.Content, pending.ReadOnly); }
                if (pendingDark is { } dark) { pendingDark = null; SetTheme(dark); }
                Ready?.Invoke();
                Respond(id, new JsonObject { ["result"] = "ok" });
                break;
            case "document.save":
            {
                var current = data.OptString("documentID") == documentID && (data.IsNull("sessionID") || data.OptString("sessionID") == sessionID);
                var content = data.OptObject("payload")?.OptStringOrNull("content");
                var saved = current && content is not null && (Save?.Invoke(content) ?? false);
                Respond(id, new JsonObject { ["result"] = saved ? "ok" : "failed" });
                break;
            }
            case "document.resources":
                Respond(id, new JsonObject { ["result"] = "ok", ["documentID"] = documentID, ["resources"] = new JsonArray() });
                break;
            default:
                Respond(id, new JsonObject { ["result"] = "ok" });
                break;
        }
    }
}
