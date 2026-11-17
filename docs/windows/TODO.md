# ScriptWidget for Windows: to do

What is left before and after the first Store release. The plan is in [plan.md](plan.md); what has been tested is in [testing.md](testing.md).

## Before the Store preview

Checks that need a person at an unlocked Windows desktop. The first night of development ran while the development PC was locked. `Windows/scripts/desktop-check.ps1` covers what can be checked without looking (window content, window order, drag, clicks, system events) and passes; these are the ones it cannot do.

| Check | How |
| --- | --- |
| Widgets look right against the wallpaper and icons | Start `ScriptWidget.exe` and look |
| Widgets stay visible when the desktop is shown | Press Win+D twice. The detection in `DesktopLayer.cs` follows the approach Rainmeter uses and has not been seen working. If the widgets disappear while the desktop is shown, it needs adjusting for this Windows version; they should never appear over ordinary windows |
| Dragging and clicking with a real mouse; the pointer becomes a hand over a button | Drag a widget; use the Habit Heatmap template ("Check in") and a template with a link |
| Tray icon, its menu, the right-click menu of a widget | Left and right click |
| The widgets come back after signing out and in | Turn on "Start when I sign in", sign out, sign in |
| Explorer restart | Restart Explorer in Task Manager; the tray icon and the widgets must come back |
| Sleep and resume | Sleep the PC for a minute; the clock must be right afterwards |
| Two displays with different scales | Drag a widget across; unplug and replug the second display |
| Typing in the code editor, import and export through the file pickers | Edit the text of a widget and watch the preview and the desktop widget follow |
| ARM64 | Install and run on an ARM64 PC. ARM64 is compiled in CI and has never run |

`ScriptWidget.exe --selftest-window 30 <log file>` shows one test card for 30 seconds and writes the window order once a second; use it while trying Win+D.

Decisions and accounts:

- **Partner Center.** Reserve the app name, then build with `package.ps1 -IdentityName … -Publisher … -PublisherDisplayName … -FrameworkDependent`. The default identity is for local testing only.
- **Store policy 10.2.2.** Ask Microsoft whether an app that runs user-written widget scripts needs anything beyond saying so in its description.
- **Store listing.** Screenshots, description in English and Chinese, privacy policy link.

Known gaps in the code:

- **Proxies.** Requests do not go through the system proxy, because the address behind a proxy cannot be checked against the private-address rule. A PC that reaches the Internet only through a proxy cannot fetch. Decide between keeping this and trusting a configured proxy.
- **Memory with a clock on the desktop.** The layout engine stays loaded while a widget redraws every minute or second: about 85 MB private memory against about 22 MB with only static widgets. Releasing it between redraws would cost a few hundred milliseconds of processor time each minute.
- **A timer redraws every second by laying the whole widget out again.** Fine for one or two timers; a host-drawn text layer over the bitmap would be cheaper.
- **`.zip` archives with a wrong declared size** are reported as `archive_corrupt` rather than `archive_size_mismatch`; nothing is installed either way.
- **Deleting a single file of a package** is not offered in the editor; the package folder can be opened instead.
- **Tile images** are not scale-specific: the 200% images are used at every scale.

## After the preview

- **Send to phone.** A QR code or reverse pairing so a widget moves to the phone without a file; needs an `import` handler in the iPhone and Android apps with its own security review. Until then, export a `.swt` file.
- **Animations.** Play `<gif>` and the clock and swing animations; the renderer already returns their positions.
- **A restricted engine process.** Run package code in a separate process inside an AppContainer with a job object for memory and processor limits.
- **`$music`, `$notifications`, `$location`.** Windows has system interfaces for all three; each needs the package identity and the user's consent.
- **Gallery, Skills and AI generation**, as on the other platforms. AI credentials must be stored with the Windows credential locker, never in settings or packages.
- **The Windows Widgets board** as an extra surface: one generic provider that shows a rendered image with a row of buttons.
- **A smaller package.** The management window carries the .NET runtime (about 70 MB of the package). Compiling it ahead of time, as the host is, would remove most of that.
