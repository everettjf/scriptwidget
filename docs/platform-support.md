# Platform support

What runs where. One Package 2.0 widget installs on every platform below; a feature a platform lacks reports `[unsupported_platform]` or falls back as the notes say. `$system.platform()` tells a script where it is running.

| | iPhone and iPad | Mac | Android |
| --- | --- | --- | --- |
| Status | Released | Released | Version 1.0.0 on GitHub Releases; Google Play closed test in review |
| System version | iOS 16 or later | macOS 26 or later | Android 15 or later |
| Widgets | WidgetKit | WidgetKit | App Widgets |
| JavaScript engine | JavaScriptCore | JavaScriptCore | QuickJS-NG |

The browser preview in [Web Studio](web-studio-browser.md) is a design tool, not a place widgets are installed; its coverage is in [Browser preview coverage](browser-preview-coverage.md).

## Widgets and system surfaces

| Feature | iPhone and iPad | Mac | Android |
| --- | --- | --- | --- |
| Small, medium, large and extra-large widgets | Yes | Yes | Yes; the launcher decides the real size |
| Lock Screen (accessory) widgets | Yes | No | No |
| Accented and vibrant rendering modes | Yes | Yes | No, always `fullColor` |
| `backgroundMaterial` | Yes | Yes | The opaque `background` fallback |
| Buttons and toggles in a widget | Yes | Yes | Yes |
| Timeline with future entries | Yes | Yes | The script runs again at each transition |
| Live Activities and the Dynamic Island | Yes | No | A Live Update notification; the JSX layout is not drawn |
| Control Widgets | Yes | No | Quick Settings tiles |
| Siri and Shortcuts actions | Yes | Yes | App shortcuts and the automation entry point; no voice |
| Push-triggered refresh | On system versions that support it | On system versions that support it | Yes, through Firebase Cloud Messaging |
| Scrolling `<list>` | No, shows as an unknown tag | No | Yes |
| Wallpaper colors (`material.<role>`) | No, the color is ignored | No | Yes |
| Automation entry point for other apps | No | No | Yes |

## Data APIs

| API | iPhone and iPad | Mac | Android |
| --- | --- | --- | --- |
| `$device`, `$system`, `$storage`, `$file`, `fetch`, `$http` | Yes | Yes | Yes |
| `$dataSource` (Data Source Plugins) | Yes | Yes | Yes |
| `$weather` | Yes | Yes | Yes |
| `$calendar` | Yes | Yes | Yes, for calendars selected in the app |
| `$photos` | Yes | Yes | Individual photos picked in the app, no albums |
| `$contacts`, `$documents` | Yes | Yes | Yes, for items picked in the app |
| `$maps` | Yes | Yes | Geocoding and place search; no `snapshot` |
| `$notifications` | Yes | Yes | Yes, delivery is inexact |
| `$services` (GitHub) | Yes | Yes | With a fine-grained token, no OAuth sign-in |
| `$icloud` | Yes | Yes | A sync folder the user picks; cannot exchange data with an iPhone |
| `$location` | Yes | No | Yes; widgets see the position saved while the app was open |
| `$health` | Yes | No | Health Connect; no ring goals or stand time |
| `$music` | Yes | No | The active media session of any app |
| `$alarms` | Yes | No | Yes, inexact, no system alarm UI |
| `$reminders` | Yes | Yes | No |
| `$home` | Yes | No | No |

The Apple columns follow the generated [data API catalog](data-api-catalog.md), which stays the authority for each method. The Android column follows [ScriptWidget for Android](android/README.md), which explains every difference and what was tested on which device.

## Authoring tools

| Tool | Runs on |
| --- | --- |
| [ScriptWidget Studio](studio.md), with multi-size preview, Copilot, Skills and the Data Source Lab | Mac |
| In-app editor, Gallery, Skills and AI generation | iPhone, iPad and Android |
| [Web Studio](web-studio-browser.md) | Any desktop browser |
| [Command line](mac-cli.md) | Mac |
