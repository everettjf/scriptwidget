# Android test notes (1.0.0)

What was run before handing this build to testers, and what was not.

## Automated

| Suite | Count | Where | Command |
| --- | --- | --- | --- |
| Unit tests | 502 | JVM | `cd Android && ./gradlew :core:testDebugUnitTest` |
| Core device tests | 27 | see below | `Android/scripts/device-test.sh core` |
| App device tests | 56 | see below | `Android/scripts/device-test.sh app` |

Every suite was run with the final code (build 6) on every device below. Build 7 has the same code plus the Firebase configuration and a test hook in `Push`; with it the JVM tests passed and the app suite passed on the Pixel 6 (60 tests, the two that need a key or a push wait skipped). Build 7 was not re-run on the emulators. What is left is in the [to-do list](TODO.md).

After the application ID changed to `com.atomsprout.scriptwidget` (13 November 2026) the JVM tests passed, the debug and release builds carried the new package name, and the app suite passed on the Android 15 emulator (60 tests; the push delivery and picked-folder tests skip there). One test had assumed that class names start with the application ID and was corrected. With the new ID the Android 16 emulator has not been run.

Build 8 (the new icon and the reworked UI, see the [UI review](ui-review.md)) was run on the Pixel 6 only: JVM tests passed, the app suite passed (60 tests, the live-model and push-wait tests skipped). The core suite passed (27 tests) just before the UI changes, which did not touch the core module. `PushDeliveryTest` then passed with the new Firebase project `scriptwidget-77792` and the new package name: the app was in the foreground and received a test message sent from the Firebase console to the device's token, with `packageID` and `channel` as custom data. A campaign sent to all installs of the app ten minutes earlier had not arrived by then. The emulators were not re-run with build 8.

The release build of build 8 (minified, signed with the upload key) was installed on the Pixel 6 as an APK: it started, drew the starter widgets and the template previews, and logged no crash. This replaced the debug build on that phone and removed its placed widgets. The bundle itself has not been installed through Google Play.

The three Android-only features (scrolling `<list>`, `material.` colors, the automation entry point; 14 November 2026, same version and build number as build 8) were run on the Pixel 6 only: 482 JVM tests, 199 preview-engine tests, 30 core device tests and 64 app device tests passed. In the app suite the live-model, push-wait and picked-folder tests skipped, as before. The emulators and other phones were not run. What was checked by hand is under [Android-only features](#android-only-features-checked-by-hand-on-the-pixel-6).

The version was then renumbered to 1.0.0 (version code 1) with no code change: the 482 JVM tests passed, and the debug APK and the release bundle were built, the bundle signed with the upload key. The debug APK reports `versionName` 1.0.0 and `versionCode` 1. This build was not installed on a device and the device suites were not re-run. The Pixel 6 still has the earlier debug build (version code 8); Android refuses to install a lower version code over it, so that build must be uninstalled first, which removes its widgets.

The app was then split into the `play` and `foss` flavors (14 November 2026; see [Android distribution](distribution.md)), moving the Firebase code out of the shared source. On the Pixel 6: the 482 JVM tests passed; the app suite passed as `foss` (63 tests; it has no push delivery test) and as `play` (64 tests), with the live-model, push-wait and picked-folder tests skipped as before. The core suite was not re-run, since `core` did not change. The signed `foss` release APK (28.5 MB, no Firebase or Google Play services classes, not debuggable) was installed in place of the debug build: it started, listed the starter widgets, drew the three Android-only template previews, and logged no crash. Widgets were not placed on the home screen from this APK.

The AI conversation (19 November 2026) was run on the Pixel 6 only, as a debug copy installed beside the Play Store app (`-PdevSuffix=.dev`): the 502 JVM tests passed, both flavors built, and the app suite passed (66 tests; the live-model, push-wait and picked-folder tests skipped). Two of them are new: `AiConversationUiTest` drives the real screen with the real runtime and a scripted model through making a widget, a repaired change, a network widget, a change that never runs, an older version, saving, improving the saved widget and applying with a new host, and through Stop, Send again and drafts. It saves a picture of each step under the app's external files. The conversation was not run with a live model on a device: that copy has no key. The core device suite was not rerun; the core change is covered by JVM tests. The emulators were not used.

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

On 16 November 2026, after the Habit Heatmap template gained a total count, the unit tests passed and the core device suite passed on the Pixel 6 (30 tests, including parity with JavaScriptCore on the regenerated trees). The app device suite was not run for that change, and the widget was not placed on a home screen.

### After the shared-JavaScript build moved to `Scripts/lib/shared-js.mjs` (`windows` branch)

The build script now calls the library shared with Windows, and `android-apis.js` takes the platform name in its "not supported" message from the host (default: Android). In CI on that branch: the regenerated assets equal the checked-in ones, `:core:testDebugUnitTest` passes (run 44081171658), and on an API 35 x86_64 emulator the core instrumented suite passes 30 of 30 and the app suite (`foss` flavor) 63 of 63 (run 44094364212; start it from Actions > Android > Run workflow). Earlier emulator runs failed for reasons of the job, not of the code: Open-Meteo did not answer once, and with system animations turned off the four widget animation tests fail, because the app shows no animation frames then. Not re-run: both instrumented suites on the Pixel 6.

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

## Android-only features, checked by hand on the Pixel 6

Android 17, Pixel Launcher, debug build, 14 November 2026.

- **Scrolling list**: the Scrolling Checklist template as a large widget scrolled, kept its position after a redraw, and its row toggles updated both the row and the count in the header. A test package with 100 rows showed all 100 and a toggle on row 98 worked. In a second test package a `<link>` row opened the browser, a `linkurl` row and a plain row opened the app, a `<button>` row ran its action, and a tap on the header outside the list opened the app. Light and dark mode both drew.
- **Redraw time of the 100-row list**: about 1.3 seconds once the app was running (layout 0.5 s, drawing 0.6 s), and 12 to 13 seconds for the first drawing right after a debug build was installed. Before row images were cached and encoded in parallel a redraw took about 5 seconds.
- **Wallpaper colors**: the Wallpaper Colors template drew the phone's Material colors in light and in dark mode. The wallpaper was not changed, so the redraw after a wallpaper change was not seen.
- **Automation**: turned on in Settings → Automation and the Automation Counter package allowed. With `adb shell am broadcast`: a correct request ran the action and the widget showed the new count and "Changed by automation"; it also worked addressed by package only, with a boolean `value`, and with the app process killed first. Refused, with the documented reason: automation off, a wrong token, a missing token, a package that was not allowed, an unknown package, a name with `../`, an action the manifest does not declare, and a `value` that is not a boolean. Of 36 requests sent in one burst, 30 were accepted and 6 refused as too many. Tasker and MacroDroid themselves were not used.

Three problems showed up on the phone and are fixed: the system accepts a collection only in a widget's root layout; a tap target that is the root of its own layout gets no click listener, and a focusable one stops taps beside it; and on Android 15 and later a list fed by a `RemoteViewsService` is packed into the update and cut off at about 800 KB (17 of 20 rows were shown, and none of 100), so the rows are now sent as collection items in images large enough to travel by reference.

Not checked: a list in landscape, in a small or medium widget on the home screen, after resizing the widget, with rows that hold photos, on other launchers, on Android 15 and 16, and through Google Play.

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
