# Platform support

What runs where. One Package 2.0 widget installs on every platform below; a feature a platform lacks reports `[unsupported_platform]` or falls back as the notes say. `$system.platform()` tells a script where it is running.

| | iPhone and iPad | Mac | Android | Windows | Linux |
| --- | --- | --- | --- | --- | --- |
| Status | Released | Released | Version 1.0.0 on GitHub Releases; Google Play closed test open to testers | Preview; not yet in the Microsoft Store | Preview for Omarchy 4.5 |
| System version | iOS 16 or later | macOS 26 or later | Android 15 or later | Windows 11 | Omarchy 4.5 (Arch Linux) |
| Widgets | WidgetKit | WidgetKit | App Widgets | Desktop widgets drawn by the app | Desktop widgets drawn by the app, shown by an Omarchy plugin |
| JavaScript engine | JavaScriptCore | JavaScriptCore | QuickJS-NG | QuickJS-NG | QuickJS-NG |

The browser preview in [Web Studio](web-studio-browser.md) is a design tool, not a place widgets are installed; its coverage is in [Browser preview coverage](browser-preview-coverage.md).

## Widgets and system surfaces

| Feature | iPhone and iPad | Mac | Android | Windows | Linux |
| --- | --- | --- | --- | --- | --- |
| Small, medium, large and extra-large widgets | Yes | Yes | Yes; the launcher decides the real size | Yes, at the Mac sizes | Yes, at the Mac sizes |
| Lock Screen (accessory) widgets | Yes | No | No | No | No |
| Accented and vibrant rendering modes | Yes | Yes | No, always `fullColor` | No, always `fullColor` | No, always `fullColor` |
| `backgroundMaterial` | Yes | Yes | The opaque `background` fallback | The opaque `background` fallback | The opaque `background` fallback |
| Buttons and toggles in a widget | Yes | Yes | Yes | Yes | Yes |
| Timeline with future entries | Yes | Yes | The script runs again at each transition | The script runs again at each transition | The script runs again at each transition |
| Live Activities and the Dynamic Island | Yes | No | A Live Update notification; the JSX layout is not drawn | No | No |
| Control Widgets | Yes | No | Quick Settings tiles | No | No |
| Siri and Shortcuts actions | Yes | Yes | App shortcuts and the automation entry point; no voice | No | No |
| Push-triggered refresh | On system versions that support it | On system versions that support it | Yes, through Firebase Cloud Messaging | No | No |
| Scrolling `<list>` | No, shows as an unknown tag | No | Yes | No | No |
| Wallpaper colors (`material.<role>`) | No, the color is ignored | No | Yes | No | No |
| Automation entry point for other apps | No | No | Yes | No | No |

## Data APIs

| API | iPhone and iPad | Mac | Android | Windows | Linux |
| --- | --- | --- | --- | --- | --- |
| `$device`, `$system`, `$storage`, `$file`, `fetch`, `$http` | Yes | Yes | Yes | Yes | Yes |
| `$dataSource` (Data Source Plugins) | Yes | Yes | Yes | Yes | Yes |
| `$weather` | Yes | Yes | Yes | Yes | Yes |
| `$calendar` | Yes | Yes | Yes, for calendars selected in the app | No | No |
| `$photos` | Yes | Yes | Individual photos picked in the app, no albums | No | No |
| `$contacts`, `$documents` | Yes | Yes | Yes, for items picked in the app | No | No |
| `$maps` | Yes | Yes | Geocoding and place search; no `snapshot` | No | No |
| `$notifications` | Yes | Yes | Yes, delivery is inexact | No | No |
| `$services` (GitHub) | Yes | Yes | With a fine-grained token, no OAuth sign-in | No | No |
| `$icloud` | Yes | Yes | A sync folder the user picks; cannot exchange data with an iPhone | No | No |
| `$location` | Yes | No | Yes; widgets see the position saved while the app was open | No | No |
| `$health` | Yes | No | Health Connect; no ring goals or stand time | No | No |
| `$music` | Yes | No | The active media session of any app | No | No |
| `$alarms` | Yes | No | Yes, inexact, no system alarm UI | No | No |
| `$reminders` | Yes | Yes | No | No | No |
| `$home` | Yes | No | No | No | No |

The Apple columns follow the generated [data API catalog](data-api-catalog.md), which stays the authority for each method. The Android column follows [ScriptWidget for Android](android/README.md), which explains every difference and what was tested on which device. The Windows column follows [ScriptWidget for Windows](windows/README.md), and the Linux column [ScriptWidget for Linux](linux/README.md).

## Authoring tools

| Tool | Runs on |
| --- | --- |
| [ScriptWidget Studio](studio.md), with multi-size preview, Copilot, Skills and the Data Source Lab | Mac |
| In-app editor, Gallery, Skills and AI generation | iPhone, iPad and Android |
| Management window with a code editor and a live preview | Windows, Linux |
| [Web Studio](web-studio-browser.md) | Any desktop browser |
| [Command line](mac-cli.md) | Mac |
| [Command line `scriptwidget`](linux/README.md#the-command-line) | Linux |
