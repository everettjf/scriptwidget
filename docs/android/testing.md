# Android test notes (1.2.0, build 7)

What was run before handing this build to testers, and what was not.

## Automated

| Suite | Count | Where | Command |
| --- | --- | --- | --- |
| Unit tests | 474 | JVM | `cd Android && ./gradlew :core:testDebugUnitTest` |
| Core device tests | 27 | see below | `Android/scripts/device-test.sh core` |
| App device tests | 56 | see below | `Android/scripts/device-test.sh app` |

Every suite was run with the final code (build 6) on every device below. Build 7 has the same code plus the Firebase configuration and a test hook in `Push`; with it the JVM tests passed and the app suite passed on the Pixel 6 (60 tests, the two that need a key or a push wait skipped). Build 7 was not re-run on the emulators. What is left is in the [to-do list](TODO.md).

| Device | Android | Core | App |
| --- | --- | --- | --- |
| Pixel 6 (physical) | 17 (API 37) | 27 passed (the example.com fetch check was skipped on the last run: the site answered 403; it had returned 200 on earlier runs) | 56 passed |
| Emulator, Google APIs image | 15 (API 35) | 27 passed | 56 passed (the picked-folder sync test skips: no folder was chosen there) |
| Emulator, 16 KB pages, Google Play image | 16.0 (API 36) | 27 passed, 2 of them skipped (no DNS in the emulator) | 56 passed (the picked-folder sync test skips: no folder was chosen there) |

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
- **AI against a live model** (`AiLiveModelTest`, 3 tests, Pixel 6 only, 13 November 2026): with a real Anthropic key and `claude-fable-5-2` over the app's HTTPS transport, the model wrote a medium countdown widget that ran and drew on the device, refined an existing widget as instructed, and a rejected key failed with a message that does not contain it. The test is skipped unless a key is passed (`-e aiKey`). The key was passed to the test in memory; typing a key into the AI settings screen and generating from the app's own screen with a live model was not exercised. Other providers (OpenAI-compatible, local) were not called live.

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

- **Push from a real push server, and delivery while the app is closed.** A Firebase project now exists (`scriptwidget-8ac0e`). On 13 November 2026 `PushDeliveryTest` passed on the Pixel 6: Firebase issued a device token, the app registered it for a placed package, and a message sent from the Firebase console with `packageID` and `channel` reached the device about two minutes later and scheduled that package's widget. The message carried a notification and the app was on screen. A data-only message sent by a server through the FCM API, delivery while the app is in the background or stopped, and a real registration endpoint receiving the token were not tested.
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
- `$maps.snapshot`, `$reminders`, `$home`, accessory families and the Dynamic Island are not available. Push-triggered refresh is on only in builds made with `Android/firebase.properties`; build 6 on Play internal testing was made without it and build 7 with it.
