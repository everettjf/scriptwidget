# ScriptWidget for Windows: to do

What is left before and after the first Store release. The plan is in [plan.md](plan.md); what has been tested is in [testing.md](testing.md).

## Before the Store preview

Checks that need a person at an unlocked Windows desktop. The whole first night of development ran while the development PC was locked, so none of these could be seen; each has a command or a step.

| Check | How |
| --- | --- |
| Widgets look right on the real desktop | Start `ScriptWidget.exe`, look at the clock widget, add two more from the management window |
| Widgets stay below ordinary windows and keep out of the taskbar and Alt-Tab | Open and move windows over them |
| Widgets stay visible when the desktop is shown | Press Win+D twice. The detection in `DesktopLayer.cs` follows Rainmeter's approach and has not been seen working; if the widgets disappear while the desktop is shown, it needs adjusting for this Windows version |
| Dragging, snapping to the screen edges, "Lock positions" | Drag a widget; toggle the lock in the tray menu |
| Clicks on buttons, toggles and links with a real mouse | Use the Habit Heatmap template ("Check in") and a template with a link |
| Tray icon, its menu, the widget's right-click menu | Left and right click |
| The widget returns to its place after signing out and in | Turn on "Start when I sign in", sign out, sign in |
| Explorer restart | Restart Explorer in Task Manager; the tray icon and the widgets must come back |
| Sleep and resume | Sleep the PC for a minute; the clock must be right afterwards |
| Two displays with different scales | Drag a widget across; unplug and replug the second display |
| Opening a `.swt` file from Explorer (packaged install) | Double-click an exported file |
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
