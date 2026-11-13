# Android test notes (1.2.0)

What was run before handing this build to testers, and what was not. Everything was run on one device: a Pixel 6 on Android 17.

## Automated

| Suite | Count | Where | Command |
| --- | --- | --- | --- |
| Unit tests | 468 | JVM | `cd Android && ./gradlew :core:testDebugUnitTest` |
| Core device tests | 27 | Pixel 6 | `Android/scripts/device-test.sh core` |
| App device tests | 49 | Pixel 6 | `Android/scripts/device-test.sh app` |

All passed on the final build. The device suites cover:

- **Engine and parity**: QuickJS limits (time, memory, stack), and 127 bundled packages producing trees byte-identical to JavaScriptCore.
- **Rendering**: every corpus tree renders; every one of the 146 bundled templates installs, runs and renders without an internal error or timeout.
- **Widgets through a real `AppWidgetHost`**: bitmap, tap targets, button and toggle actions, timers, GIF frames, light and dark bitmaps, error card, removed-package state, bitmap budget, all four sizes.
- **Library**: `.swt` import and export, rejection of traversal, bad manifests and source that does not compile, identity across rename and duplicate.
- **Native APIs against real device services**: storage, HTTPS fetch, a Data Source Plugin request, Calendar Provider read and write with replay, notifications and alarms scheduling, Photo thumbnails, location policy, Health Connect queries, MET Norway forecast, geocoding, synced documents with two simulated devices.
- **System surfaces**: declared actions, toggle persistence, app shortcuts, Live Update notification start, update and end.

Two live-service tests skip instead of failing when the remote service does not answer in time (Open-Meteo, MET Norway).

## Checked by hand on the Pixel 6

- Pinning a widget from the app, and the Pixel Launcher drawing it with system corners.
- Tapping a widget button: the action runs without opening the app and the widget redraws.
- A timer counting and a GIF animating on the home screen.
- Light and dark switching while the app process is killed.
- The Studio editor: loads, highlights, autosaves, and a saved edit redraws the placed widget.
- Gallery: the index loads from GitHub and a widget installs.
- A Live Update notification with title, detail, progress and its End button.
- Location: "Refresh position" stores a real position.
- The release build (code and resource shrinking on) installs and redraws widgets.

## Not tested

- **AI generation against a live provider.** No API key was available. The client is covered by unit tests with a fake transport only.
- **GitHub services with a real token.** Only the not-connected and policy-rejection paths ran.
- **A notification or alarm actually arriving.** Scheduling, listing and cancelling ran; delivery was not waited for.
- **Documents, contacts and music with real selections.** Only the empty and not-authorized states ran.
- **Quick Settings tiles in the system panel.** Actions and state are tested; the tile's appearance was not looked at.
- **Synced documents through a real cloud provider**, and any exchange with an iPhone (not possible today).
- **Other devices.** No Samsung, Xiaomi, OPPO or vivo device, no tablet or foldable, no Android 15 or 16 device.
- **Background refresh over time.** Whether widgets keep refreshing for hours or days under Doze was not measured.
- **The GitHub Actions workflow** has not run on GitHub yet.
- **Accessibility** (TalkBack) beyond a content description on the widget image.

## Known limitations to tell testers

- After a force stop, the launcher shows a placeholder for the app's widgets until the app is opened again. This is Android behavior.
- Clock and swing animations do not move; they show the pose at the last refresh.
- Timers use the system font and read `00:36` where iOS reads `0:36`.
- Alarms and notifications are inexact and can be about ten minutes late.
- `$maps.snapshot`, `$reminders`, `$home`, accessory families, the Dynamic Island and push-triggered refresh are not available.
