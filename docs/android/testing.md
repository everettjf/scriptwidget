# Android test notes (1.2.0, build 5)

What was run before handing this build to testers, and what was not.

## Automated

| Suite | Count | Where | Command |
| --- | --- | --- | --- |
| Unit tests | 468 | JVM | `cd Android && ./gradlew :core:testDebugUnitTest` |
| Core device tests | 27 | see below | `Android/scripts/device-test.sh core` |
| App device tests | 55 | see below | `Android/scripts/device-test.sh app` |

Every suite was run with the final code on every device below.

| Device | Android | Core | App |
| --- | --- | --- | --- |
| Pixel 6 (physical) | 17 (API 37) | 27 passed | 55 passed |
| Emulator, Google APIs image | 15 (API 35) | 27 passed | 55 passed (the picked-folder sync test skips: no folder was chosen there) |
| Emulator, 16 KB pages, Google Play image | 16.0 (API 36) | 27 passed, 2 of them skipped (no DNS in the emulator) | 55 passed (the picked-folder sync test skips: no folder was chosen there) |

Set `ANDROID_SERIAL` to choose the device when several are connected.

The Android 16 emulator run found a crash that the Pixel could not show: starting a Live Update on Android 16.0 called a method that only exists from Android 16 QPR. It is fixed and the suite passes there.

All passed on the final build. The device suites cover:

- **Engine and parity**: QuickJS limits (time, memory, stack), and 127 bundled packages producing trees byte-identical to JavaScriptCore.
- **Rendering**: every corpus tree renders; every one of the 146 bundled templates installs, runs and renders without an internal error or timeout.
- **Widgets through a real `AppWidgetHost`**: bitmap, tap targets, button and toggle actions, timers, GIF frames, light and dark bitmaps, error card, removed-package state, bitmap budget, all four sizes.
- **Library**: `.swt` import and export, rejection of traversal, bad manifests and source that does not compile, identity across rename and duplicate.
- **Native APIs against real device services**: storage, HTTPS fetch, a Data Source Plugin request, Calendar Provider read and write with replay, notifications and alarms scheduling, Photo thumbnails, location policy, Health Connect queries, MET Norway forecast, geocoding, synced documents with two simulated devices.
- **System surfaces**: declared actions, toggle persistence, app shortcuts, Live Update notification start, update and end.
- **AI loop**: generate, validate on the device, feed the error back, accept the fix; with a scripted local model.

Two live-service tests skip instead of failing when the remote service does not answer in time (Open-Meteo, MET Norway).

## Checked by hand on the Pixel 6

- Pinning a widget from the app, and the Pixel Launcher drawing it with system corners.
- Tapping a widget button: the action runs without opening the app and the widget redraws.
- A timer counting, a GIF animating and the Animation Clock template showing the current time with a moving second hand on the home screen.
- Light and dark switching while the app process is killed.
- The Studio editor: loads, highlights, autosaves, and a saved edit redraws the placed widget.
- Gallery: the index loads from GitHub and a widget installs.
- A Live Update notification with title, detail, progress and its End button.
- Location: "Refresh position" stores a real position.
- The release build (code and resource shrinking on) installs and redraws widgets.

## Not tested

- **AI generation against a live model.** No API key was available. On the Pixel the loop runs end to end with a real HTTP exchange against a local server that answers in the Anthropic Messages format with scripted text: a broken first answer is rejected by the runtime and fed back, the corrected answer renders, and the loop stops at its limit. What a real model returns, and a real provider's errors and timing, are untested.
- **GitHub services with a real token.** Only the not-connected and policy-rejection paths ran.
- **A notification or alarm actually arriving.** Scheduling, listing and cancelling ran; delivery was not waited for.
- **Documents, contacts and music with real selections.** Only the empty and not-authorized states ran.
- **Quick Settings tiles in the system panel.** Actions and state are tested; the tile's appearance was not looked at.
- **Synced documents through a cloud provider** such as Google Drive. The exchange was run through a folder picked with the system picker on the Pixel (the device's own storage provider), which exercises the same code path but not a remote service's delays. Exchange with an iPhone is not possible today.
- **Other physical devices.** No Samsung, Xiaomi, OPPO or vivo device, no tablet or foldable. Android 15 and 16 were covered by emulators only, which do not show vendor launchers or real background limits.
- **Background refresh over time.** Whether widgets keep refreshing for hours or days under Doze was not measured.
- **The GitHub Actions workflow** has not run on GitHub yet.
- **Accessibility** (TalkBack) beyond a content description on the widget image.

## Known limitations to tell testers

- After a force stop, the launcher shows a placeholder for the app's widgets until the app is opened again. This is Android behavior.
- A clock animation with a custom interval turns at the right speed but its phase is not tied to the time; standard clock hands show the real time.
- Timers use the system font and read `00:36` where iOS reads `0:36`.
- Alarms and notifications are inexact and can be about ten minutes late.
- `$maps.snapshot`, `$reminders`, `$home`, accessory families, the Dynamic Island and push-triggered refresh are not available.
