# ScriptWidget for Windows: what was tested

Every entry says what ran, on which machine, and what the result was. A check that did not run is listed as not run; it is never described as passing.

## Machines

| Name | System | Notes |
| --- | --- | --- |
| Dev PC | Windows 11 Home build 26200, x64, one 3840×2160 display at 150% | Visual Studio 2026 (MSVC 14.51), Windows SDK 26100, .NET SDK 10.0.401, Node 26.13.1, Developer Mode on |
| CI | GitHub Actions `windows-2025`, x64 | `.github/workflows/windows.yml` |

No ARM64 machine was available. ARM64 is compiled in CI and has never been run. The MSVC ARM64 tools are not installed on the Dev PC.

## How to run the automated checks

```
node Windows/scripts/build-shared-js.mjs          # needs `npm ci` in Web/studio once
powershell -File Windows/scripts/build-native.ps1 -Arch x64
cd Windows
dotnet test tests/ScriptWidget.Core.Tests -c Debug
```

`build-native.ps1 -Asan` builds swcore with AddressSanitizer; pass `-p:SwNativeSuffix=-asan --filter "FullyQualifiedName~QuickJs"` to `dotnet test` to run the engine binding tests against it.

## 2026-11-17, Dev PC

**The Dev PC was locked for the whole session.** Programs ran and windows were created, but nothing on the desktop could be seen and no real mouse or keyboard input was possible. What that leaves unchecked is listed under "Not run" and in [TODO.md](TODO.md).

### Automated

| Check | Result |
| --- | --- |
| Preview engine tests on Windows (`npm test` in `Web/preview-engine`) | 199 of 199 pass, after adding `.gitattributes` (a CRLF checkout broke the shared build scripts before) |
| `dotnet test` of `ScriptWidget.Core.Tests`, Debug, x64 | 234 of 234 pass |
| Parity: bundled packages that need no live data, element tree compared byte for byte with the JavaScriptCore reference | 127 of 127 identical |
| Renderer: every parity package drawn at 170×170, 329×170 and 329×345, scale 2 | No exception, no empty bitmap |
| Engine limits: memory limit, deadline, stack limit | Each raises its error (in `QuickJsTests`) |
| Local time across a daylight-saving change | Correct with the ICU-based offset (in `QuickJsTests`); the upstream Windows code returns today's offset for every date |
| Engine binding tests with AddressSanitizer in swcore | 15 of 15 pass |
| The rest of the suite with AddressSanitizer | Not run: the parity test did not finish in 9 minutes with a sanitized QuickJS inside the .NET test host |
| Native AOT: `swcli` published ahead of time, all 140 bundled packages run and drawn at medium size | 137 drawn; 3 hit the 5-second limit waiting for the network; no crash. Two of the three use `api.open-meteo.com`, which this network cannot reach (`curl` times out too); the third (`Daily Quote`) passed on a second run |
| `node Scripts/validate-doc-links.mjs` | Passes (its repository-boundary check assumed `/` separators and failed on Windows before) |

Android was not re-run. The shared-JavaScript build was refactored into `Scripts/lib/shared-js.mjs`; regenerating the Android assets with it changes one file, `android-apis.js`, by the two lines that take the platform name from the host. `render.js`, `kernel.js`, `prepare.js` and `contract.json` are byte-identical. The Android JVM and device suites should run before this is merged.

### Found and fixed by these runs

- **Native AOT broke every layout.** Win2D's array of line metrics cannot be marshalled under native AOT. The text engine now uses a fixed line box and hit-testing instead; the JIT and AOT builds draw the same picture.
- **A packaged program could not install a package.** Windows redirects `%LOCALAPPDATA%` for a packaged program and the redirection does not support moving a directory. Packaged, the data now lives in the package's real local folder.
- **The code editor asked to pair with a phone.** The shared editor bundle tells an embedding app from the Web Studio site by a marker object, which the Windows bridge now provides.
- **Requests without a user agent.** The GitHub API answered 403. Requests now send `ScriptWidget-Windows/<version>` unless the script sets its own.
- **Size names.** `supportedFamilies` uses `systemMedium`; it was compared with `medium`.
- **Widgets were underneath the desktop.** `HWND_BOTTOM` put the widget windows below `Progman` in the window order on this Windows build, where they would be neither seen nor clicked. They are now inserted directly above the desktop window.

### Desktop host (`ScriptWidget.exe`)

Run with a scratch data folder (`SCRIPTWIDGET_DATA`).

| Check | Result |
| --- | --- |
| First start: installs the clock template and places one widget | Yes; `widgets.json` holds the placement at the top right of the work area |
| Widget windows exist, are visible to the window manager, and have the size of the widget | Two windows, 494×255 pixels (329×170 points at 150%), layered, tool-window and no-activate styles |
| Window order, read with `GetWindow` while two widgets were on the desktop | Both widget windows directly above `Progman` (the desktop) and below every other visible window; a window opened afterwards went above them |
| Requests over the pipe: `list`, `add`, `remove` | Work (`swcli widgets`, `swcli add`) |
| Import of a `.swt` archive and placing it | Works (`swcli pack`, `swcli install`, `swcli add` with Habit Heatmap) |
| A click on a button runs its declared action | A click posted to the window at the "Check in" button ran `checkInRead`; the package's storage then held today's date and the widget drew "Done today". The click was a posted window message, not a real mouse click |
| Idle cost, native AOT build, two widgets, one of them a clock | 85 MB private memory, 93 MB working set; 0.05 s of processor time in 30 s |
| Idle cost, native AOT build, one widget without dates | 22 MB private memory, 58 MB working set, 10 threads; 0.00 s of processor time in 30 s |
| Refresh while the session is locked | Not observed: the session was already locked when the host started, so it never received the lock notification |

### Management window (`ScriptWidgetStudio.exe`)

Checked from pictures the program saves of its own content (`--screenshot`), since the screen could not be seen.

| Check | Result |
| --- | --- |
| "My widgets": cards with previews drawn by the desktop renderer, "On desktop" count from the host | Drawn correctly |
| "Templates": groups, search box, previews | Drawn correctly; 130 templates listed |
| Editor: file list, code editor with the file loaded and highlighted, preview, output | Drawn correctly; the editor reported ready and returned the file's 8,153 characters |
| "Settings" | Drawn correctly |
| Typing, saving, dialogs, file pickers, drag and drop | Not run |

### MSIX package

| Check | Result |
| --- | --- |
| `package.ps1 -Arch x64` | Builds `ScriptWidget_0.1.0.0_x64.msix`, 74.7 MB, not signed, with the Windows App SDK and the .NET runtime inside |
| Registered from the layout folder in Developer Mode | Registers; removed again afterwards |
| The host inside the package | Reports package identity; data in `…\Packages\<family>\LocalState\ScriptWidget`; first start installs and places the clock widget |
| The management window inside the package | Starts the host, lists the widget with "On desktop: 1" |
| `-FrameworkDependent` (the Store form) | Not run |
| Signed install, Start menu launch, `.swt` file association, startup task | Not run |
| Store submission | Not run: needs the Partner Center account |

### Not run

- Anything that needs to see or touch the desktop: how widgets look in place, window order under other windows, Win+D, dragging and snapping, the tray icon and menus, right-click menus, real clicks.
- Explorer restart, sleep and resume, sign-out and sign-in, a display change, a second display, a scale change.
- A full-screen program in front, a dark-theme switch, a clock or time-zone change while running.
- ARM64 on a real machine.
- The Android suites after the shared-JavaScript refactor.
