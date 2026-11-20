using Microsoft.UI.Xaml;

namespace ScriptWidget.Studio;

public partial class App : Application
{
    private readonly Request initial;
    private MainWindow? window;

    public App(Request initial)
    {
        this.initial = initial;
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        window = new MainWindow();
        window.Activate();
        Handle(initial);
    }

    /// <summary>Another start of the program handed over its request. Called on a background thread.</summary>
    public void OnRedirected(Request request) => window?.DispatcherQueue.TryEnqueue(() =>
    {
        if (window is null) return;
        window.Activate();
        SetForegroundWindow(window.WindowHandle);
        Handle(request);
    });

    private void Handle(Request request)
    {
        if (window is null) return;
        if (request.ImportFile is { } file) _ = window.ImportArchiveAsync(file);
        else if (request.OpenPackage is { } package) window.OpenEditor(package);
        else if (request.Page == "templates") window.ShowTemplates();
        else if (request.Page == "components") window.ShowComponents();
        else if (request.Page == "apis") window.ShowApis();
        else if (request.Page is { } page && page.StartsWith("template:", StringComparison.Ordinal)) window.ShowDetail(page["template:".Length..]);
        else if (request.Page == "settings") window.ShowSettings();
        else if (request.Page == "ai") window.ShowAi();
        else if (request.Page == "skills") window.ShowSkills();
        else if (request.Page == "gallery") window.ShowGallery();
        if (request.Screenshot is { } picture) _ = CaptureAsync(picture);
    }

    /// <summary>Saves a picture of the window content and exits. The code editor (a WebView2) is not part of the picture.</summary>
    private async Task CaptureAsync(string file)
    {
        try
        {
            await Task.Delay(9000);
            var bitmap = new Microsoft.UI.Xaml.Media.Imaging.RenderTargetBitmap();
            await bitmap.RenderAsync(window!.Content);
            var pixels = await bitmap.GetPixelsAsync();
            using var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream();
            var encoder = await Windows.Graphics.Imaging.BitmapEncoder.CreateAsync(Windows.Graphics.Imaging.BitmapEncoder.PngEncoderId, stream);
            encoder.SetPixelData(Windows.Graphics.Imaging.BitmapPixelFormat.Bgra8, Windows.Graphics.Imaging.BitmapAlphaMode.Premultiplied, (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 96, 96, System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions.ToArray(pixels));
            await encoder.FlushAsync();
            var bytes = new byte[stream.Size];
            stream.Seek(0);
            await stream.ReadAsync(System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions.AsBuffer(bytes), (uint)bytes.Length, Windows.Storage.Streams.InputStreamOptions.None);
            await File.WriteAllBytesAsync(file, bytes);
            if (window.EditorPage is { } editorPage) await editorPage.CaptureEditorAsync(Path.ChangeExtension(file, ".editor.png"));
        }
        catch (Exception error) { await File.WriteAllTextAsync(file + ".error.txt", error.ToString()); }
        Exit();
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern int SetForegroundWindow(nint window);
}
