# ScriptWidget for Windows: what was tested

Every entry says what ran, on which machine, and what the result was. A check that did not run is listed as not run; it is never described as passing.

## Machines

| Name | System | Notes |
| --- | --- | --- |
| Dev PC | Windows 11 Home build 26200, x64, one 3840×2160 display at 150% | Visual Studio 2026 (MSVC 14.51), Windows SDK 26100, .NET SDK 10.0.401, Node 26.13.1, Developer Mode on |
| CI x64 | GitHub Actions `windows-2025` (Windows Server 2025), x64 | `.github/workflows/windows.yml` |
| CI ARM64 | GitHub Actions `windows-11-arm` (Windows 11, ARM64) | Same workflow, job "Build and test (ARM64)" |

ARM64 runs on the CI ARM64 machine only; no ARM64 PC was available to a person, and the MSVC ARM64 tools are not installed on the Dev PC.

## How to run the automated checks

```
node Windows/scripts/build-shared-js.mjs          # needs `npm ci` in Web/studio once
powershell -File Windows/scripts/build-native.ps1 -Arch x64
cd Windows
dotnet test tests/ScriptWidget.Core.Tests -c Debug
```

`build-native.ps1 -Asan` builds swcore with AddressSanitizer; pass `-p:SwNativeSuffix=-asan --filter "FullyQualifiedName~QuickJs"` to `dotnet test` to run the engine binding tests against it.

## 2026-11-17, Dev PC

**The Dev PC was locked for the whole session.** Programs ran and windows existed on the desktop, but the screen showed the lock screen and no real mouse or keyboard input was possible. The desktop checks below therefore read what the windows themselves show (`PrintWindow`), read the window order (`GetWindow`), post pointer and system messages to the windows, and drive the management window through UI Automation. What that still leaves unchecked is listed under "Not run" and in [TODO.md](TODO.md).

### Automated

| Check | Result |
| --- | --- |
| Preview engine tests on Windows (`npm test` in `Web/preview-engine`) | 199 of 199 pass, after adding `.gitattributes` (a CRLF checkout broke the shared build scripts before) |
| `dotnet test` of `ScriptWidget.Core.Tests`, Debug, x64 | 235 of 235 pass |
| Parity: bundled packages that need no live data, element tree compared byte for byte with the JavaScriptCore reference | 127 of 127 identical |
| Renderer: every parity package drawn at 170×170, 329×170 and 329×345, scale 2 | No exception, no empty bitmap |
| Engine limits: memory limit, deadline, stack limit | Each raises its error (in `QuickJsTests`) |
| Local time across a daylight-saving change | Correct with the ICU-based offset (in `QuickJsTests`); the upstream Windows code returns today's offset for every date |
| Engine binding tests with AddressSanitizer in swcore | 15 of 15 pass |
| The rest of the suite with AddressSanitizer | Not run: the parity test did not finish in 9 minutes with a sanitized QuickJS inside the .NET test host |
| Native AOT: `swcli` published ahead of time, all 140 bundled packages run and drawn at medium size | 137 drawn; 3 hit the 5-second limit waiting for the network; no crash. Two of the three use `api.open-meteo.com`, which this network cannot reach (`curl` times out too); the third (`Daily Quote`) passed on a second run |
| `node Scripts/validate-doc-links.mjs` | Passes (its repository-boundary check assumed `/` separators and failed on Windows before) |

The shared-JavaScript build was refactored into `Scripts/lib/shared-js.mjs`; regenerating the Android assets with it changes one file, `android-apis.js`, by the two lines that take the platform name from the host. `render.js`, `kernel.js`, `prepare.js` and `contract.json` are byte-identical. After the change, in CI: the Android workflow regenerates the assets and finds no difference from the checked-in ones, and `:core:testDebugUnitTest` passes (run 44081171658). The core instrumented suite, which includes the QuickJS parity with JavaScriptCore and the renderer on the parity corpus, passes 30 of 30 on an API 35 x86_64 emulator (run 44082647890, the hand-started job "Core device tests on an emulator"). Not run: the core and app instrumented suites on a phone, and the app suite anywhere.

### Found and fixed by these runs

- **Native AOT broke every layout.** Win2D's array of line metrics cannot be marshalled under native AOT. The text engine now uses a fixed line box and hit-testing instead; the JIT and AOT builds draw the same picture.
- **A packaged program could not install a package.** Windows redirects `%LOCALAPPDATA%` for a packaged program and the redirection does not support moving a directory. Packaged, the data now lives in the package's real local folder.
- **The code editor asked to pair with a phone.** The shared editor bundle tells an embedding app from the Web Studio site by a marker object, which the Windows bridge now provides.
- **Requests without a user agent.** The GitHub API answered 403. Requests now send `ScriptWidget-Windows/<version>` unless the script sets its own.
- **Size names.** `supportedFamilies` uses `systemMedium`; it was compared with `medium`.
- **Show desktop was looked for in the wrong window.** Only a WorkerW that takes over the desktop icons was recognized, which is how Windows showed the desktop before 11 24H2. On 24H2 and later (this PC) Progman itself is raised; both are handled now.
- **Widgets were underneath the desktop.** `HWND_BOTTOM` put the widget windows below `Progman` in the window order on this Windows build, where they would be neither seen nor clicked. They are now inserted directly above the desktop window.

### Desktop host (`ScriptWidget.exe`)

`powershell -File Windows/scripts/desktop-check.ps1` runs these checks against a scratch data folder and saves pictures of the widget windows. It passed, 34 of 34, with the debug build and with the native AOT build from the package layout.

| Check | Result |
| --- | --- |
| First start: installs the clock template and places one widget | Yes |
| Windows accepts the tray icon | Yes |
| The actions of the tray menu and of the right-click menu of a widget, run through the host's debugging requests (the popup itself was not shown) | Size changes the window (494 to 255 pixels wide for small); "Lock positions" stops a drag and turns off again; "Add widget" adds one; "Refresh all" redraws; "Remove from desktop" removes the widget and its window; "Quit" ends the host with exit code 0 |
| What each widget window shows, captured from the window | The rendered widget, 494×255 pixels (329×170 points at 150%), with transparent rounded corners; the clock shows the current time |
| Window order with two widgets on the desktop | Both widget windows directly above `Progman` (the desktop) and below every other visible window; a window opened afterwards goes above them |
| Drag (posted pointer messages) | The widget moves by the dragged distance, snaps to the top edge of the screen, and the new place is saved in `widgets.json` |
| A click on a button (posted pointer messages) | "Check in" on Habit Heatmap ran the declared action `checkInRead`; the package storage then held the date of the day and the widget drew "Done today" |
| Import of a `.swt` archive and placing it, requests over the pipe | Work (`swcli pack`, `install`, `add`, `widgets`) |
| Display change, clock change, resume from sleep, session lock and unlock, theme change (the messages posted to the host) | Each is handled and the widgets are redrawn; the widget keeps its place |
| Explorer restart (the `TaskbarCreated` message posted to the host) | Handled: the window order is applied again and the tray icon is added again |
| A real Explorer restart on the Dev PC (Explorer ended with the native AOT host running; Windows started it again by itself) | The host kept running, logged the new taskbar and added its tray icon again (Windows accepted it), and the widget window was directly above the new desktop window and still drew its content. Nobody saw the screen |
| A new widget when another sits at the default place | Lands on the next free step instead of exactly on top (it did land on top before) |
| Redraw cost after the first render | Layout 3 to 35 ms, paint 1 to 65 ms |
| Idle cost, native AOT build, two widgets, one of them a clock | 85 MB private memory, 93 MB working set; 0.05 s of processor time in 30 s |
| Idle cost, native AOT build, one widget without dates | 22 MB private memory, 58 MB working set, 10 threads; 0.00 s of processor time in 30 s |
| "Show desktop", acted out with a stand-in for the desktop window (`--selftest-showdesktop`) | 14 of 14: a click on the wallpaper is not mistaken for it; when the desktop window is raised and is the foreground window the widget becomes topmost in front of it; afterwards the widget is back directly above the desktop and behind ordinary windows; a second round behaves the same |
| "Show desktop" for real | Not checkable while locked: `Shell.Application.ToggleDesktop` changed nothing in the window order. The detection follows what Rainmeter's source documents for Windows 11 24H2 and later (Progman itself is raised and becomes the foreground window) and for earlier versions (a WorkerW takes over the icons) |

### Management window (`ScriptWidgetStudio.exe`)

Driven through UI Automation (the real controls are invoked, with no pointer), and checked from captures of the window.

| Check | Result |
| --- | --- |
| Opening the window starts the desktop host | Yes |
| "My widgets": cards with previews drawn by the desktop renderer, "On desktop" count from the host | Drawn correctly |
| "New widget": name dialog, the package is created, the editor opens on it | Works; the starter widget is drawn in the preview |
| Editor: file list, code editor with the file loaded and highlighted, preview, output | Drawn correctly; the editor reported ready and returned the text of the file |
| "Add to desktop" with a size from its menu | The host shows one more widget |
| "Save" | Works |
| "Templates": groups, search box, previews; "Use this template" | Drawn correctly, 130 templates; the template is installed, placed on the desktop and opened in the editor |
| "Settings": "Lock positions" | Written to `settings.json` |
| The interface in Simplified Chinese (`SCRIPTWIDGET_LANGUAGE=zh`) | "My widgets", the editor and "Settings" are drawn correctly; nothing is cut off |
| Accessible names | The back button, the "more actions" button, the switches and the inputs had none; they have now |
| Typing in the code editor, file pickers (import, export), rename, duplicate, delete | Not run |

### MSIX package

Both forms were built, registered from their layout folder in Developer Mode, tried, and removed again.

| Check | Result |
| --- | --- |
| `package.ps1 -Arch x64` | `ScriptWidget_0.1.0.0_x64.msix`, 74.7 MB, with the Windows App SDK and the .NET runtime inside |
| `package.ps1 -Arch x64 -FrameworkDependent` (the Store form) | `ScriptWidget_0.1.0.0_x64-store.msix`, 54.3 MB, depends on the Windows App Runtime 1.6 framework package |
| Store form started the way the Start menu starts it (`shell:AppsFolder\<family>!ScriptWidget`) | The management window opens and starts the host; both have the package identity; data in `…\Packages\<family>\LocalState\ScriptWidget`; the first start installs and places the clock widget |
| Opening a `.swt` file (file association) | Goes to the running management window, which asks for confirmation; "Import" installs the package |
| "Start when I sign in" in the packaged app | Turns the startup task on and off. Signing out and in was not done |
| Signed install, install from the Store, upgrade | Not run: needs the Partner Center identity |

The Store form at first showed "This application could not be started": the bootstrapper for unpackaged programs ran inside the package. It is switched off for that form now.

## 2026-11-17, CI

GitHub Actions run 44076023162 on `windows-2025` (Windows Server 2025, x64, 100% scale, no graphics card).

| Check | Result |
| --- | --- |
| Build of swcore, the shared JavaScript and the solution for x64; build for ARM64 | Pass |
| Preview engine tests on Windows | Pass |
| `dotnet test`, Release, x64 | Pass |
| Engine binding tests with AddressSanitizer in swcore | Pass |
| `desktop-check.ps1` on the build agent's desktop | 24 of 24, with the 14 show-desktop stand-in checks: the widgets were drawn (329×170 pixels), sat directly above the desktop window, were dragged and clicked, and Windows accepted the tray icon. The uploaded pictures show the clock and the habit widget drawn correctly |

This is a second machine and another Windows version, but nobody looked at its screen either.

Run 44077877354 added the ARM64 machine (`windows-11-arm`, image `windows-11-vs2026-arm64`): swcore and the solution were built natively for ARM64, `dotnet test` passed 235 of 235 (the parity packages and the renderer included), and `desktop-check.ps1` passed with both widgets drawn correctly in the uploaded pictures.

### Not run on any machine

- Looking at the desktop: how the widgets look against the wallpaper and icons, and that nothing flickers.
- The real "Show desktop" (Win+D). Its handling passes with a stand-in desktop window; whether Windows moves the real desktop window the way that stand-in is moved has not been seen. If it does not, widgets are covered until the desktop is left; they are never raised over ordinary windows.
- A real mouse: dragging, clicking, the pointer shape. The popup menus on screen (their actions were run without showing them).
- A real sleep and resume, signing out and in, a second display, a scale change, a full-screen program in front.
- ARM64 in a person's hands: it ran on the CI ARM64 machine only.
- The Android instrumented suites on a phone, and the app suite, after the shared-JavaScript refactor. The JVM tests and the core suite on an emulator pass in CI.
