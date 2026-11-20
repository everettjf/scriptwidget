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

- **Partner Center.** On 20 November 2026 the live dashboard confirmed submission 1 is in Microsoft Store. Update draft submission `1152921505702462477` was created for the 0.1.1 release. Build Store packages with the identity recorded in [testing.md](testing.md); the script's defaults remain for local testing only.
- **Store policy 10.2.2.** The submitted descriptions explicitly disclose user-written/imported JavaScript and JSX widgets; certification notes explain the interpreter, permissions and limitations. Microsoft's policy assessment is pending.
- **Store listing.** English and Simplified Chinese text, four screenshots per language, native app icons and the privacy link were submitted. Verify the live listings and the Store-signed install after approval. Add a Windows-specific privacy section covering local package data and user-selected network services.

Known gaps in the code:

- **The reference has no entry for `console`, `$getenv`, `$render`, `$import` and the animation attributes**; those are listed with their example only.

- **Daily Quote's intermittent slow preview.** Execution deadline errors now identify pending network operations and the configured duration without disclosing URLs or credentials. The original intermittent service delay was not reproduced; the diagnostic change does not claim to fix that remote delay.
- **The code editor's own toolbar (Layout, Theme, Assets) shows on a template's read-only code**, where it does nothing useful. It belongs to the shared editor bundle.
- **Animation Clock at the small size** wraps its text one letter per line.

- **Proxies.** Requests do not go through the system proxy, because the address behind a proxy cannot be checked against the private-address rule. A PC that reaches the Internet only through a proxy cannot fetch. Decide between keeping this and trusting a configured proxy.
- **Memory with a clock on the desktop.** The layout engine stays loaded while a widget redraws every minute or second: about 85 MB private memory against about 22 MB with only static widgets. Releasing it between redraws would cost a few hundred milliseconds of processor time each minute.
- **A timer redraws every second by laying the whole widget out again.** Fine for one or two timers; a host-drawn text layer over the bitmap would be cheaper.
- **`.zip` archives with a wrong declared size** are reported as `archive_corrupt` rather than `archive_size_mismatch`; nothing is installed either way.
- **Deleting a single file of a package** is not offered in the editor; the package folder can be opened instead.
- **Tile images** are not scale-specific: the 200% images are used at every scale.

## Aligning with the other platforms

Started on the Windows 11 x64 Dev PC on 19 November 2026. The plan for all platforms is in [the alignment plan](../platform-parity-plan.md). Work below remains in progress until its implementation and relevant tests are recorded in [testing.md](testing.md).

| Step | Current evidence / remaining work |
| --- | --- |
| Current Windows baseline | Shared assets and native engine rebuilt; 239 baseline Core tests passed; current Debug and Release solution builds pass with 0 warnings/errors. Studio library and templates inspected through Computer Use in English. |
| Template filtering and network diagnostics | Nested `.js`, `.jsx` and `.mjs` files checked; pending network calls identified in execution deadline errors without URLs or credentials. Nine new regression cases passed. |
| Desktop animation | Native painting of the saved layout, including GIF frames, clock hands, swings, clipping, stacking and moving hit regions. Twelve renderer/pose tests pass. Debug and final AOT desktop checks pass, including GIF-only changed pixels, no package reruns, posted lock/unlock and removal. The AOT 30-second resource sample passes; measurements are in testing.md. |
| Skills | Store, strict validator, transactional archive import/export, CLI, Studio page and AI prompt integration implemented. 25 tests passed. Real CLI round trip and built-in instructions inspected in Studio. |
| Gallery | Strict trusted-root catalog, bounded verified downloads, offline cache, transactional widget/Skill installs, explicit updates, CLI and Studio page implemented. 27 tests passed. Live 25-item catalog, verified widget and Skill installation, and Studio catalog/details checked. |
| AI | Core, CLI, streaming providers, bounded repair loop, generated C# JSX surface, saved conversations/versions, diffs, editor panel and settings implemented. Real DeepSeek generation, continuation, broken-code repair, apply/fork and three-size rendering pass. Unlocked UI acceptance covers send/cancel/retry, conversation Skills, version selection, fork, diffs, three preview sizes, manual editor changes and explicit Apply. A reproduced WinUI version-selection crash and preview/accessibility issues were fixed and retested. See testing.md. |
| Release checks | All 389 Release Core tests pass, none skipped. Repeatable CLI acceptance passes 41 offline checks and 60 with real Gallery/DeepSeek. The non-Xcode release gate passes. Updated x64 MSIX/NSIS artifacts are local; their exact checks are in testing.md. No release was published. |

- **For the owner: remove the Simplified Chinese Store listing.** The interface is English only since 19 November 2026 and the package now declares English only, but the Microsoft Store listing was submitted in English and Simplified Chinese. The owner decided on 19 November 2026 to delete the Chinese listing in Partner Center himself; nothing in the repository does it.
- **AI UI acceptance on the Dev PC is recorded in testing.md.** Real requests and model loading use the existing Credential Locker key; it was not displayed or changed. The earlier lock-screen captures remain excluded. Continue hardware/display acceptance separately.
- **Local AI connections are implemented.** Ollama and LM Studio presets support loopback HTTP, optional tokens, model discovery before selection, streaming and cancellation. Actual LM Studio model listing passed in the CLI and Studio; only an embedding model was installed, so real local chat inference remains unverified. Ollama was not installed. Deterministic socket/runner tests cover local generation and native validation. See testing.md.
- **Finish distribution visual/hardware acceptance.** Current AOT host and installer automation pass. Inspect English installer pages while unlocked, and keep the owner-only Store certification/listing follow-up separate. Real ARM64, mixed-DPI and login/logout need suitable hardware/session access.
- **Before submitting these new features to the Store**, update the submission's capability descriptions and privacy disclosures for user-configured AI providers. The 18 November preview submission did not include AI generation; the local 0.1.1 test build has not been submitted.
- **Publication copy is prepared** in [release-draft.md](release-draft.md): English changes, Windows privacy section, Store listing additions and certification notes. Owner review, Company website publication and Partner Center submission remain separate actions.
- **Failure recovery and extended stress coverage are implemented.** Provider/key metadata failures have compensation tests and applied widgets stay visible after conversation-file failures. Four GIF/swing widgets passed a 30-minute resource phase; a subsequent capture-readiness race in the test harness was fixed and the complete short rerun passes. See testing.md for exact measurements and the distinction between these results.
- **Copies of bundled templates** already declare their hosts (`Library.BundledManifest`); Android now does the same.
- **Template filtering:** fixed on Windows: the filter checks nested source files as well as `main.jsx`. The actual list is covered by a temporary-library regression test.
- **`frame` values the runtime ignores** are now reported by the C# AI check as on Apple/Android, with regression cases for `frame="max,auto"` and spaces after commas.

## After the preview

- **Send to phone.** A QR code or reverse pairing so a widget moves to the phone without a file; needs an `import` handler in the iPhone and Android apps with its own security review. Until then, export a `.swt` file.
- **A restricted engine process.** Run package code in a separate process inside an AppContainer with a job object for memory and processor limits.
- **`$music`, `$notifications`, `$location`.** Windows has system interfaces for all three; each needs the package identity and the user's consent.
- **The Windows Widgets board** as an extra surface: one generic provider that shows a rendered image with a row of buttons.
- **A smaller package.** The management window carries the .NET runtime (about 70 MB of the package). Compiling it ahead of time, as the host is, would remove most of that.
