# ScriptWidget for Windows

Status: preview. Not yet in the Microsoft Store. The plan is in [plan.md](plan.md), what was tested and on which machine is in [testing.md](testing.md), and what is left is in [TODO.md](TODO.md).

ScriptWidget for Windows puts the same Package 2.0 widgets that run on iPhone, iPad, Mac and Android on the Windows 11 desktop. A widget is a small window that the app draws itself: it sits on the desktop below your other windows, shows what its script returns, refreshes on a schedule, and reacts to clicks on buttons, toggles and links.

## What is in the app

| Part | What it does |
| --- | --- |
| Desktop host (`ScriptWidget.exe`) | Runs all the time behind a tray icon. Owns the widget windows, runs the scripts on a schedule, handles clicks |
| Management window (`ScriptWidgetStudio.exe`) | Opens from the Start menu or the tray icon. Your widgets, the templates, the code editor with a live preview, and the settings. Closing it frees its memory; the widgets keep running |
| Command line (`swcli.exe`) | Checks, runs and draws a package from a folder. Used by the build to produce reference images; not installed with the app |

## Using it

- **First start.** The app puts one clock widget on the desktop and opens the management window.
- **Add a widget.** In the management window pick a template or one of your widgets and choose "Add to desktop", or right-click the tray icon and choose "Add widget".
- **Move a widget.** Drag it. It snaps to the edges of the screen. "Lock positions" in the tray menu stops accidental drags.
- **Change its size or remove it.** Right-click the widget.
- **Edit it.** Right-click the widget and choose "Edit…". The preview next to the code is drawn by the same renderer as the desktop widget, so what you see there is what the desktop shows.
- **Move a widget to another device.** Export it as a `.swt` file in the management window and open that file in ScriptWidget on the other device. A `.swt` file from another device is imported the same way.

## How it runs a widget

The runtime is a port of the Android runtime, file by file, with the same tests.

1. **Compile.** The package's JSX is compiled by the Babel bundle the other platforms use, inside QuickJS. The manifest is checked by the shared validator.
2. **Execute.** The script runs in a fresh QuickJS context with a 64 MB memory limit, a stack limit and a 5-second deadline. It has no access to the system: `fetch`, `$storage`, `$file` and the other APIs are calls into the host, which checks the manifest's permissions and network domains first.
3. **Lay out.** The shared renderer from the web preview engine runs in a second QuickJS context, which only ever sees the element tree (data), never package code. Text is measured by the same DirectWrite layout that later draws it.
4. **Draw.** The laid-out tree is painted with Win2D (Direct2D and DirectWrite) into a bitmap with per-pixel transparency, and the bitmap is shown in the widget's window.

Every bundled package that needs no live data produces the same element tree on Windows as on iPhone, byte for byte; the build checks this.

## Differences from the other platforms

`$system.platform()` returns `"windows"`. The table lists everything that behaves differently; anything not listed works as on iPhone.

| Area | On Windows |
| --- | --- |
| Widget sizes | `small` 170×170, `medium` 329×170, `large` 329×345, `extraLarge` 639×345 points, the Mac desktop sizes, multiplied by the display scale. No Lock Screen sizes |
| Where widgets live | On the desktop, in windows the app draws. Not in the Windows Widgets board, which only accepts Adaptive Cards |
| Rendering modes | Always `fullColor` |
| `backgroundMaterial` | The opaque `background` fallback |
| Fonts | Inter and the six display fonts, as on Android. Chinese, Japanese, Korean and emoji use the Windows system fonts |
| Timeline | The script runs again at each transition instead of pre-rendering future entries, as on Android |
| `<date>` | A running timer is redrawn every second and a clock time every minute |
| `<gif>` and `animation` | The first frame |
| Links | `http`, `https` and `mailto` links open in the default program. Other schemes are refused, because a link comes from untrusted package content |
| Refresh | Every 15 minutes by default (5 minutes to 24 hours in the settings), at timeline transitions, after sleep, after a clock or theme change, and on demand. Paused while the session is locked or a full-screen program is in front |
| Dark mode | Follows the Windows app theme |
| Live Activities, Control Widgets, Siri actions, push refresh | Not available |

### Data APIs

| API | On Windows |
| --- | --- |
| `$device`, `$system`, `$storage`, `$file`, `fetch`, `$http`, `$xml` | Yes, with the same permissions, network-domain declarations, private-address refusal and budgets |
| `$dataSource` (Data Source Plugins) | Yes |
| `$weather` | Yes, the MET Norway forecast for supplied coordinates, as on Android |
| `$calendar`, `$reminders`, `$health`, `$photos`, `$contacts`, `$documents`, `$home`, `$icloud`, `$alarms`, `$maps`, `$services`, `$music`, `$notifications`, `$location` | No. `isAvailable()` returns `false` and calls reject with `[unsupported_platform]` |

Templates that use an API from the last row are left out of the template list.

`$device` and `$system` report what Windows can tell without a permission: `model` is `"PC"`, `name` and `hostName` are the computer name, `brightness` is always `1`, `thermalState` is always `"nominal"`, and a desktop without a battery reports `level` 1 and state `"full"`.

## Security

Scripts, imported archives and network responses are untrusted, as on every platform. The Windows-specific parts:

- **Package paths.** In addition to the shared rules (no traversal, absolute paths, symlinks, backslashes or case collisions), Windows refuses reserved device names such as `CON` and `NUL` with or without an extension, names that end in a dot or a space, colons (alternate data streams and drive letters), UNC and drive-letter forms, and reparse points.
- **Network.** Requests go through `HttpClient` with a connect step that resolves the host itself and refuses private, loopback and link-local addresses before connecting to the address it checked. Redirects are followed by hand with the same checks at every hop.
- **Engine isolation.** In this release package code runs inside the host process, as on iPhone and Android: QuickJS exposes no system interface, and memory, stack and time are bounded. A separate restricted process is planned (see [TODO.md](TODO.md)). The build runs the tests of the engine binding a second time with AddressSanitizer in the QuickJS library.
- **Local time.** QuickJS on Windows computed every date's local time from today's UTC offset, which is wrong across a daylight-saving change. The Windows build asks ICU for the offset at the date in question; the vendored QuickJS source is unchanged.
- **The management window's editor** is the only web content in the app. It loads files from the app's own folder under a private host name and cannot navigate, open windows, download or reach the network.
- **The pipe** between the management window and the host is created for the current user only. Requests name packages and widgets; nothing sent over it is run as code.

## Building

Needs Windows 11, Visual Studio 2026 (or the Build Tools) with the C++ workload, the .NET 10 SDK and Node 24 or later.

```
cd Web/studio && npm ci                      # once, for esbuild
node Windows/scripts/build-shared-js.mjs      # shared JavaScript -> Windows/assets
powershell -File Windows/scripts/build-native.ps1 -Arch x64    # swcore.dll (QuickJS)
cd Windows
dotnet build ScriptWidget.slnx -c Debug -p:Platform=x64
dotnet test tests/ScriptWidget.Core.Tests -c Debug
```

`powershell -File Windows/scripts/package.ps1` builds the MSIX package into `Windows/artifacts`. For a Store submission pass the identity values from Partner Center (`-IdentityName`, `-Publisher`, `-PublisherDisplayName`) and `-FrameworkDependent`.

Run `node Windows/scripts/build-shared-js.mjs` again after changing `Web/preview-engine/src`, the support bundle or `Android/core/src/main/js`. Those sources are shared with Android: a change there needs the Android suites as well.

## Folders

| Folder | Contents |
| --- | --- |
| `Windows/native` | `swcore`: QuickJS-NG (the Android app's sources) and its C binding |
| `Windows/src/ScriptWidget.Core` | The runtime: engine wrapper, compiler, executor, packages, APIs, plugins, renderer. No windows |
| `Windows/src/ScriptWidget.App` | The desktop host |
| `Windows/src/ScriptWidget.Studio` | The management window |
| `Windows/src/ScriptWidget.Cli` | `swcli` |
| `Windows/tests` | xUnit tests, most of them ported from `Android/core` |
| `Windows/package` | MSIX manifest and images |
| `Windows/assets`, `Windows/native/out`, `Windows/artifacts` | Generated; not checked in |

User data is in `%LOCALAPPDATA%\ScriptWidget` (`Packages`, `Storage`, `Plugins`, `Cache`, `widgets.json`, `settings.json`, `host.log`). When the app is installed from the Store it is in the package's own folder instead, `%LOCALAPPDATA%\Packages\<package family>\LocalState\ScriptWidget`, which Windows removes on uninstall.
