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
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern int SetForegroundWindow(nint window);
}
