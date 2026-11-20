# ScriptWidget for Windows: to do

What is left before and after the first Store release. The plan is in [plan.md](plan.md); what has been tested is in [testing.md](testing.md).

## Before the Store preview

Checks that need a person at an unlocked Windows desktop. The first night of development ran while the development PC was locked; the next morning the desktop was unlocked and the first four rows were run with real input and screen pictures (they found three bugs, now fixed; see the test notes). What is left of those rows is a person's own look. `Windows/scripts/desktop-check.ps1` covers what can be checked without looking (window content, window order, drag, clicks, system events) and passes; these are the ones it cannot do.

| Check | How |
| --- | --- |
| Widgets look right against the wallpaper and icons | Start `ScriptWidget.exe` and look. Screen pictures were taken and look right |
| Widgets stay visible when the desktop is shown | Press Win+D twice. Done with the real key on Windows 11 build 26200 after two fixes; other Windows builds are untried |
| A template with a link opens the browser | Click the link. Dragging, a button click and the hand pointer were done with real mouse input |
| The tray menu appears where expected | Left and right click the tray icon. The right-click menu of a widget was opened with the real mouse and appeared at the pointer |
| The widgets come back after signing out and in | Turn on "Start when I sign in", sign out, sign in |
| Explorer restart, seen on screen | Restart Explorer in Task Manager and look: the tray icon and the widgets must come back. A real restart was run with the screen locked; the host re-added its icon and kept the widget above the new desktop window |
| Sleep and resume, seen on screen | Sleep the PC for a minute; the clock must be right afterwards. A real 107-second sleep was run with the screen locked; the host redrew on resume |
| Two displays with different scales | Drag a widget across; unplug and replug the second display |
| Typing in the code editor, import and export through the file pickers | Edit the text of a widget and watch the preview and the desktop widget follow |
| ARM64 on a PC | Install and run on an ARM64 PC. The tests and the desktop check pass on the CI ARM64 machine |

`ScriptWidget.exe --selftest-window 30 <log file>` shows one test card for 30 seconds and writes the window order once a second; use it while trying Win+D.

The installer on GitHub Releases:

- **It is not signed.** SmartScreen warns on every download. A code-signing certificate (or Azure Trusted Signing) would remove the warning.
- **No automatic update.** A newer version has to be downloaded and run by hand. A check for a newer release, or a winget manifest, would help.
- **The installer and the Store version do not know of each other.** Both can be installed; there is one host per user and each keeps its widgets in its own folder. Neither warns about the other.
- **Seen by a person:** the installer's pages, the question about deleting the widgets when uninstalling, a double-click on a `.swt` file, and an installation on a PC without the development tools.

Decisions and accounts:

- **Partner Center.** The name is reserved and submission `1152921505702441674` for Store ID `9MVR97B9C938` entered certification on 18 November 2026. Check its result and handle any certification feedback. Build future Store packages with the identity recorded in [testing.md](testing.md); the script's defaults remain for local testing only.
- **Store policy 10.2.2.** The submitted descriptions explicitly disclose user-written/imported JavaScript and JSX widgets; certification notes explain the interpreter, permissions and limitations. Microsoft's policy assessment is pending.
- **Store listing.** English and Simplified Chinese text, four screenshots per language, native app icons and the privacy link were submitted. Verify the live listings and the Store-signed install after approval. Add a Windows-specific privacy section covering local package data and user-selected network services.

Known gaps in the code:

- **The reference has no entry for `console`, `$getenv`, `$render`, `$import` and the animation attributes**; those are listed with their example only.

- **A slow request is reported as "Script exceeded the 5-second execution limit".** The message does not say that the script was waiting for the network. Daily Quote's preview failed this way four times in the management window on 17 November 2026 and then never again; the cause was not found (see the test notes).
- **The code editor's own toolbar (Layout, Theme, Assets) shows on a template's read-only code**, where it does nothing useful. It belongs to the shared editor bundle.
- **Animation Clock at the small size** wraps its text one letter per line.

- **Proxies.** Requests do not go through the system proxy, because the address behind a proxy cannot be checked against the private-address rule. A PC that reaches the Internet only through a proxy cannot fetch. Decide between keeping this and trusting a configured proxy.
- **Memory with a clock on the desktop.** The layout engine stays loaded while a widget redraws every minute or second: about 85 MB private memory against about 22 MB with only static widgets. Releasing it between redraws would cost a few hundred milliseconds of processor time each minute.
- **A timer redraws every second by laying the whole widget out again.** Fine for one or two timers; a host-drawn text layer over the bitmap would be cheaper.
- **`.zip` archives with a wrong declared size** are reported as `archive_corrupt` rather than `archive_size_mismatch`; nothing is installed either way.
- **Deleting a single file of a package** is not offered in the editor; the package folder can be opened instead.
- **Tile images** are not scale-specific: the 200% images are used at every scale.

## Aligning with the other platforms

Written on 19 November 2026 from a Mac, while the same work was done for Linux and Android; nothing here was started. It needs a Windows 11 PC. The plan for all platforms is in [the alignment plan](../platform-parity-plan.md).

- **For the owner: remove the Simplified Chinese Store listing.** The interface is English only since 19 November 2026 and the package now declares English only, but the Microsoft Store listing was submitted in English and Simplified Chinese. The owner decided on 19 November 2026 to delete the Chinese listing in Partner Center himself; nothing in the repository does it.
- **After the Chinese interface was removed** (19 November 2026, edited on a Mac: the texts of the management window, the desktop host and the installer, `zh-cn` in the package manifest, `zh-Hans` in the satellite resource languages): on a Windows PC, build, run the tests, `Windows/scripts/desktop-check.ps1` and `Windows/scripts/installer-check.ps1`, and look once at the management window, the tray menu and the installer's pages. Nothing of this was built or run on Windows.
- **AI conversation.** Port `Linux/crates/sw-core/src/ai` (itself a port of `Android/core/.../core/ai`) into `ScriptWidget.Core`: profiles, the streaming client for Anthropic and OpenAI-compatible endpoints, edits and diffs, the JSX check, the prompt, the repair loop on the Windows executor, saved conversations. Then `swcli ai …` as `scriptwidget ai …` on Linux, and a conversation panel beside the editor and an AI section in the settings of the management window, as `Linux/crates/sw-studio/src/ai.rs` and `ui/ai.rs`.
  - The key goes to the Windows credential locker (`PasswordVault`) or DPAPI, never to settings, packages, prompts or conversations; a test must show a saved profile and a saved conversation hold no key.
  - The provider address is `https://` only and redirects are not followed, as on Android and Linux.
  - `Editor/editorfe/scripts/generate-jsx-surface.mjs` writes the tag and attribute list for Swift, Kotlin and Rust; add a C# output instead of copying the list.
  - The prompt needs a "not supported on Windows" section, built from the same list that filters the templates.
- **`animation` and `<gif>` playback.** `Linux/crates/sw-render/src/motion.rs` computes the pose of an animated element for an instant from the record the shared renderer already writes, and `Linux/crates/sw-host/src/schedule.rs` (`motion_plan`) turns swings and custom intervals into a cycle of at most 60 pictures, one every 50 ms. Port both to the Win2D renderer and the desktop host; decode GIF frames in the host as Linux does.
- **Skills and Gallery**, after they exist on Linux: the same stores, the same verification (path, byte count, SHA-256, the one trusted root), a page for each in the management window.
- **Copies of bundled templates** already declare their hosts (`Library.BundledManifest`); Android now does the same.
- **The template list still shows "Local Weather (Location)"**, which cannot run: the filter reads only `main.jsx`. Linux has the same gap.
- **`frame` values the runtime ignores** are reported by the AI check on Apple and Android since 19 November 2026 (`frame="max,auto"`, a space after the comma). The C# check should follow when the AI port is made.

## After the preview

- **Send to phone.** A QR code or reverse pairing so a widget moves to the phone without a file; needs an `import` handler in the iPhone and Android apps with its own security review. Until then, export a `.swt` file.
- **Animations.** Play `<gif>` and the clock and swing animations; the renderer already returns their positions.
- **A restricted engine process.** Run package code in a separate process inside an AppContainer with a job object for memory and processor limits.
- **`$music`, `$notifications`, `$location`.** Windows has system interfaces for all three; each needs the package identity and the user's consent.
- **Gallery, Skills and AI generation**, as on the other platforms. AI credentials must be stored with the Windows credential locker, never in settings or packages.
- **The Windows Widgets board** as an extra surface: one generic provider that shows a rendered image with a row of buttons.
- **A smaller package.** The management window carries the .NET runtime (about 70 MB of the package). Compiling it ahead of time, as the host is, would remove most of that.
