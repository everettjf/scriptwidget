using ScriptWidget.App.Interop;

namespace ScriptWidget.App.Windowing;

/// <summary>One entry of a popup menu. A null <see cref="Text"/> is a separator.</summary>
internal sealed record MenuItem(string? Text, Action? Invoke = null, bool Checked = false, bool Enabled = true, IReadOnlyList<MenuItem>? Children = null)
{
    public static readonly MenuItem Separator = new((string?)null);
}

/// <summary>Shows a native popup menu and runs the chosen item.</summary>
internal static unsafe class PopupMenu
{
    public static void Show(nint owner, int x, int y, IReadOnlyList<MenuItem> items)
    {
        var actions = new List<Action?> { null }; // command 0 means "nothing chosen"
        var menu = Build(items, actions);
        try
        {
            // A menu only closes on an outside click when its owner is the foreground window.
            Win32.SetForegroundWindow(owner);
            var chosen = Win32.TrackPopupMenuEx(menu, Win32.TPM_RIGHTBUTTON | Win32.TPM_RETURNCMD | Win32.TPM_NONOTIFY, x, y, owner, null);
            Win32.PostMessageW(owner, Win32.WM_NULL, 0, 0);
            if (chosen > 0 && chosen < actions.Count) actions[chosen]?.Invoke();
        }
        finally { Win32.DestroyMenu(menu); }
    }

    private static nint Build(IReadOnlyList<MenuItem> items, List<Action?> actions)
    {
        var menu = Win32.CreatePopupMenu();
        foreach (var item in items)
        {
            if (item.Text is null) { Win32.AppendMenuW(menu, Win32.MF_SEPARATOR, 0, null); continue; }
            var flags = Win32.MF_STRING | (item.Checked ? Win32.MF_CHECKED : 0) | (item.Enabled ? 0 : Win32.MF_GRAYED);
            fixed (char* text = item.Text)
            {
                if (item.Children is { Count: > 0 } children) Win32.AppendMenuW(menu, flags | Win32.MF_POPUP, (nuint)Build(children, actions), text);
                else
                {
                    actions.Add(item.Invoke);
                    Win32.AppendMenuW(menu, flags, (nuint)(actions.Count - 1), text);
                }
            }
        }
        return menu;
    }
}

/// <summary>The notification-area icon. A left click or a right click opens the menu built by <see cref="Menu"/>.</summary>
internal sealed unsafe class TrayIcon : NativeWindow
{
    private const uint Callback = Win32.WM_APP + 2;
    private readonly nint icon;
    private string tip;
    private bool added;

    /// <summary>Builds the menu each time it is opened.</summary>
    public Func<IReadOnlyList<MenuItem>>? Menu { get; set; }
    /// <summary>Double click on the icon.</summary>
    public event Action? Activated;

    public TrayIcon(string tip, string? iconPath)
    {
        this.tip = tip;
        Create("ScriptWidgetTray", 0, 0);
        nint loaded = 0;
        if (iconPath is not null && File.Exists(iconPath))
        {
            fixed (char* path = iconPath) loaded = Win32.LoadImageW(0, path, Win32.IMAGE_ICON, 0, 0, Win32.LR_LOADFROMFILE | Win32.LR_DEFAULTSIZE);
        }
        icon = loaded != 0 ? loaded : Win32.LoadIconW(0, Win32.IDI_APPLICATION);
        Add();
    }

    /// <summary>Adds the icon; called again when Explorer restarts.</summary>
    public void Add()
    {
        var data = Data();
        data.Flags = Win32.NIF_MESSAGE | Win32.NIF_ICON | Win32.NIF_TIP | Win32.NIF_SHOWTIP;
        added = Win32.Shell_NotifyIconW(Win32.NIM_ADD, &data) != 0;
        data.VersionOrTimeout = Win32.NOTIFYICON_VERSION_4;
        Win32.Shell_NotifyIconW(Win32.NIM_SETVERSION, &data);
    }

    public void SetTip(string text)
    {
        tip = text;
        var data = Data();
        data.Flags = Win32.NIF_TIP | Win32.NIF_SHOWTIP;
        Win32.Shell_NotifyIconW(Win32.NIM_MODIFY, &data);
    }

    private Win32.NOTIFYICONDATAW Data()
    {
        var data = new Win32.NOTIFYICONDATAW { Size = (uint)sizeof(Win32.NOTIFYICONDATAW), Window = Handle, ID = 1, CallbackMessage = Callback, Icon = icon };
        var text = tip.Length > 127 ? tip[..127] : tip;
        text.AsSpan().CopyTo(new Span<char>(data.Tip, 127));
        return data;
    }

    protected override nint? OnMessage(uint message, nuint wParam, nint lParam)
    {
        if (message != Callback) return null;
        // With NOTIFYICON_VERSION_4 the event is in the low word of lParam and the position in wParam.
        var notification = (uint)Win32.LowWord((nuint)lParam);
        if (notification is Win32.WM_CONTEXTMENU or Win32.NIN_SELECT or Win32.NIN_KEYSELECT)
        {
            if (Menu?.Invoke() is { Count: > 0 } items)
            {
                Win32.POINT cursor;
                Win32.GetCursorPos(&cursor);
                PopupMenu.Show(Handle, cursor.X, cursor.Y, items);
            }
        }
        else if (notification == Win32.WM_LBUTTONDBLCLK) Activated?.Invoke();
        return 0;
    }

    public override void Dispose()
    {
        if (added && Handle != 0)
        {
            var data = Data();
            Win32.Shell_NotifyIconW(Win32.NIM_DELETE, &data);
            added = false;
        }
        base.Dispose();
    }
}
