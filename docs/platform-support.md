# Platform support

What runs where. One Package 2.0 widget installs on every platform below; a feature a platform lacks reports `[unsupported_platform]` or falls back as the notes say. `$system.platform()` tells a script where it is running.

| | iPhone and iPad | Mac | Android | Windows | Linux |
| --- | --- | --- | --- | --- | --- |
| Status | Released | Released | Released on GitHub Releases; Google Play closed test open to testers | Preview in the Microsoft Store and on GitHub Releases | Preview for Omarchy 4.5 on GitHub Releases |
| System version | iOS 16 or later | macOS 26 or later | Android 13 or later | Windows 11 (21H2, build 22000) or later | Omarchy 4.5 (Arch Linux) |
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
| Push-triggered refresh | On system versions that support it | On system versions that support it | The Google Play build only, through Firebase Cloud Messaging; the APK on GitHub has none | No | No |
| Scrolling `<list>` | No scrolling; the rows that fit are drawn | No scrolling; the rows that fit are drawn | Yes | No scrolling; drawn in place and cut off at the bottom | No scrolling; drawn in place and cut off at the bottom |
| Wallpaper colors (`material.<role>`) | No; the names give a fixed palette | No; the names give a fixed palette | Yes | No; the names give a fixed palette | No; the names give a fixed palette |
| Automation entry point for other apps | No | No | Yes | No | No |

## Components

What a script draws with. Android, Windows and Linux use one shared renderer, so a component is on all three or on none; the rows say what a system draws differently. Each component's properties are in the [runtime API reference](scriptwidget-runtime-api.md).

<!-- components:start -->
| Component | iPhone and iPad | Mac | Android | Windows | Linux |
| --- | --- | --- | --- | --- | --- |
| Layout: `<vstack>`, `<hstack>`, `<zstack>`, `<vgrid>`, `<hgrid>`, `<spacer>`, `<divider>` | Yes | Yes | Yes | Yes | Yes |
| Text: `<text>`, `<label>`, `<badge>`, `<chip>`, `<stat>` | Yes | Yes | Yes, in Inter, which is wider than the Apple system font | Yes, in Inter | Yes, in Inter |
| Shapes: `<rect>`, `<roundedrect>`, `<capsule>`, `<ellipse>`, `<circle>`, `<line>` | Yes | Yes | Yes | Yes | Yes |
| Values: `<gauge>`, `<progress>`, `<ring>`, `<chart>` | Yes | Yes | Yes | Yes | Yes |
| `<image>` | Yes | Yes | Yes | Yes | Yes |
| `<icon>` and `systemName` images | Yes | Yes | Yes; SF Symbols are drawn with look-alike icons, and a name without one shows a placeholder | Yes; SF Symbols are drawn with look-alike icons, and a name without one shows a placeholder | Yes; SF Symbols are drawn with look-alike icons, and a name without one shows a placeholder |
| `<date>` | Yes | Yes | `timer` and a `time` of now tick by themselves; `relative`, `offset` and `date` are redrawn at each refresh | A timer is redrawn every second and a clock time every minute | A timer is redrawn every second and a clock time every minute |
| `<gif>` | Animated in the app's preview; in a widget the system decides and may hold one frame | The first frame | Up to 24 sampled frames | Animated on the desktop with bounded sampled frames; previews and CLI render show one frame | Animated on the desktop, at most 60 frames |
| The `animation` property (clock hands, swing) | Moves in the app's preview; in a widget the system schedules it and may hold one frame | Standard clock hands show the time without moving; the others stay at rest | Standard clock hands are a system clock; swing and custom intervals play as frames | Moves on the desktop: clock hands follow local or declared time zones; swing and custom intervals play at up to 20 frames a second. Previews and CLI render show one frame | Moves on the desktop: clock hands follow the time, swings and custom intervals play at up to 20 frames a second; `render` and the previews show one frame |
| `<button>`, `<toggle>` | Yes, from iOS 17 | Yes, from macOS 14 | Yes | Yes | Yes |
| `<link>` | Yes | Yes | Yes | `http`, `https` and `mailto` only | `http`, `https` and `mailto` only |
| The `backgroundMaterial` property | Yes | Yes | The opaque `background` fallback | The opaque `background` fallback | The opaque `background` fallback |
| Scrolling `<list>` | Draws the rows that fit; no scrolling | Draws the rows that fit; no scrolling | Yes | Drawn in place and cut off at its bottom edge; no scrolling | Drawn in place and cut off at its bottom edge; no scrolling |
| Wallpaper colors (`material.<role>`) | A fixed palette | A fixed palette | Yes | A fixed palette | A fixed palette |
<!-- components:end -->

## Data APIs

<!-- platforms:start -->
| API | iPhone and iPad | Mac | Android | Windows | Linux |
| --- | --- | --- | --- | --- | --- |
| `$device`, `$system`, `$storage`, `$file`, `fetch`, `$http`, `$xml` | Yes | Yes | Yes | Yes | Yes |
| `$dataSource` (Data Source Plugins) | Yes | Yes | Yes | Yes | Yes |
| `$weather` | Yes | Yes | Yes | Yes | Yes |
| `$calendar` | Yes | Yes | Yes, for calendars selected in the app | No | No |
| `$photos` | Yes | Yes | Individual photos picked in the app, no albums | No | Pictures picked for the widget in the management window, no albums |
| `$contacts` | Yes | Yes | Yes, for contacts picked in the app | No | No |
| `$documents` | Yes | Yes | Yes, for files picked in the app | No | Files picked for the widget in the management window |
| `$maps` | Yes | Yes | Geocoding and place search; no `snapshot` | No | No |
| `$notifications` | Yes | Yes | Yes, delivery is inexact | No | Yes, shown by the background service; delivery is inexact |
| `$services` (GitHub) | Yes | Yes | With a fine-grained token, no OAuth sign-in | No | With a fine-grained token kept in the system keyring, no OAuth sign-in |
| `$icloud` | Yes | Yes | A sync folder the user picks; cannot exchange data with an iPhone | No | No |
| `$location` | Yes | No | Yes; widgets see the position saved while the app was open | No | No |
| `$health` | Yes | No | Health Connect; no ring goals or stand time | No | No |
| `$music` | Yes | No | The active media session of any app | No | The active MPRIS player, read only |
| `$alarms` | Yes | No | Yes, inexact, no system alarm UI | No | No |
| `$reminders` | Yes | Yes | No | No | No |
| `$home` | Yes | No | No | No | No |
<!-- platforms:end -->

This table is written by `npm run docs` in `Editor/editorfe` from `src/platformSupport.js`, which also puts each API's line at the top of that API's page; change it there. The Apple columns follow the generated [data API catalog](data-api-catalog.md), which stays the authority for each method. The Android column follows [ScriptWidget for Android](android/README.md), which explains every difference and what was tested on which device. The Windows column follows [ScriptWidget for Windows](windows/README.md), and the Linux column [ScriptWidget for Linux](linux/README.md).

## Authoring tools

| Tool | Runs on |
| --- | --- |
| [ScriptWidget Studio](studio.md), with multi-size preview, Copilot, Skills and the Data Source Lab | Mac |
| In-app editor, Gallery, Skills and AI generation | iPhone, iPad and Android |
| Management window with a code editor and a live preview | Windows, Linux |
| Gallery, Skills and the AI conversation, in the management window and on the command line (`scriptwidget gallery`, `skills`, `ai`) | Linux |
| [Web Studio](web-studio-browser.md) | Any desktop browser |
| [Command line](mac-cli.md) | Mac |
| [Command line `scriptwidget`](linux/README.md#the-command-line) | Linux |
