# ScriptWidget for Android

Status: version 1.2.0 on the `android` branch, ready for internal testing. Verified on a Pixel 6 running Android 17 and on Android 15 and Android 16 emulators. Other vendors' launchers and background limits have not been tested. See [Android test notes](testing.md).

The Android app runs the same Package 2.0 widgets as iPhone, iPad and Mac. The plan and its decisions are in [Android port research and plan](android-port-research-and-plan.md).

## How it works

```text
package (.swt, same as iOS)
  └─ prepare    Babel + manifest validation from Web/preview-engine, in QuickJS (compile context)
  └─ execute    shared kernel.js in a fresh QuickJS context; Kotlin implements the host and native APIs
  └─ layout     shared renderer.js + layout.js in QuickJS against a recording document
  └─ paint      Kotlin paints the recorded HTML/CSS and SVG subset on a Canvas → Bitmap
  └─ widget     RemoteViews: the bitmap, self-updating timers/clocks, transparent tap targets
```

| Directory | Contents |
| --- | --- |
| `Android/core` | QuickJS-NG and its JNI layer, runtime, native APIs, renderer, package store, Gallery, Skills, plugins, AI client |
| `Android/app` | Compose app, widget providers, configuration, Studio editor WebView |
| `Android/core/src/main/js` | Android host for the shared kernel and renderer |
| `Android/core/src/main/assets/scriptwidget` | Generated from `Web/preview-engine` and the support bundle. Do not edit |
| `Android/scripts` | `build-shared-js.mjs`, `device-test.sh`, `test-results.sh` |

Shared code is not forked. `kernel.js` and `renderer.js` have optional host hooks that only Android sets; the web hosts are unchanged and their tests still pass.

## Build and test

```bash
node Android/scripts/build-shared-js.mjs
```

Run this after changing `Web/preview-engine/src`, the support bundle or `Android/core/src/main/js`. It needs `npm install` in `Web/studio` once (for esbuild). The generated assets are checked in; CI fails when they are stale.

```bash
cd Android && ./gradlew :core:testDebugUnitTest :app:assembleDebug
```

Unit tests cover package and archive hardening, Gallery, Skills, plugins and the AI client. They run on the JVM.

```bash
Android/scripts/device-test.sh core
```

Device tests need a connected device or emulator. They cover the engine, parity with JavaScriptCore on the bundled corpus (`Web/preview-engine/test/parity/native-trees.json`), rendering of every corpus tree, native APIs (including a live HTTPS request) and the timeline planner. Pass a class name to run one suite, for example `device-test.sh core ParityTest`.

Requirements: JDK 21, Android SDK 37, NDK 28.1, Node 24. Create `Android/local.properties` with `sdk.dir=<path to the SDK>`.

## Differences from iOS

The package format, manifest, permissions and runtime API version are the same. A package that uses something Android lacks still installs; the app lists the gaps and the API reports `[unsupported_platform]`.

| Area | Android behavior |
| --- | --- |
| JavaScript engine | QuickJS-NG instead of JavaScriptCore. `Intl` is a subset backed by ICU: `DateTimeFormat`, `NumberFormat`, `PluralRules`, `RelativeTimeFormat`, `Collator`, `ListFormat` and the `toLocale*String` methods |
| Execution limit | A real interrupt at 5 seconds; no cancellation checks are compiled in |
| Fonts | Bundled Inter and Noto Sans SC by default; the device font is a setting. SF Pro and SF Symbols are not available: symbols are drawn with the look-alike Lucide icons the web preview uses |
| Sizes | Small, medium, large and extra-large providers. The launcher decides the real size; cells are not square, so `small` is not always square |
| Theme | A widget carries a light and a dark bitmap when they differ and the launcher picks one. The script runs once per theme only when it calls `$device.isdarkmode()` |
| Refresh | WorkManager, at most every 15 minutes, plus alarms at `timeline.dailyTimes` transitions. Android may delay background work, and alarms are inexact |
| Timeline | The script runs again at each transition as the current entry; there are no pre-rendered future entries |
| `<date>` | `timer` and a `time` of now tick by themselves (system font, `00:36` rather than `0:36`). `relative`, `offset` and `date` are redrawn on refresh |
| `<gif>` | Plays as up to 24 sampled frames at a uniform interval; the first frame when the system removes animations |
| `animation` | Standard clock effects (`clockSecond`, `clockMinute`, `clockHour`) are hands of a system clock view and show the real time. `swing` plays as 16 frames. A custom clock interval stays at its pose from the last refresh |
| `backgroundMaterial` | The opaque `background` fallback |
| Rendering modes | Always `fullColor` |
| Network | The manifest allowlist as on iOS, and names that resolve to private addresses are refused |
| Promises | Runtime promises have only `then(resolve, reject)`, as on iPhone |

### System data

| API | Android source | Notes |
| --- | --- | --- |
| `$location` | `LocationManager`, no Play Services | Read while the app is open; widgets see the saved position. Background location is never requested |
| `$calendar` | Calendar Provider | Nothing is shared until calendars are selected in System Access |
| `$photos` | Photo Picker | Individual photos only, no albums; thumbnails are copied when picked |
| `$notifications`, `$alarms` | `AlarmManager` and notifications | Inexact: delivery can be about ten minutes late. No system alarm UI or snooze |
| `$services` | GitHub with a fine-grained token | No OAuth sign-in |
| `$health` | Health Connect | No ring goals or stand time (`null`); background reads need the user's extra consent |
| `$weather` | MET Norway, as on iOS | |
| `$documents` | Storage Access Framework | The user picks files in the app |
| `$contacts` | System contact picker | No contacts permission; fields are stored when picked |
| `$music` | Active media session of any app | Needs notification-listener access; `provider` is `androidMediaSession` |
| `$dataSource` | Data Source Plugin 1.0 | Same as iOS |
| `$maps` | `android.location.Geocoder` | `geocode` and `reverseGeocode` work. `search` finds named places and addresses, not business categories. `snapshot` is not supported |
| `$icloud` | A sync folder the user picks (Storage Access Framework) or a folder on this device only | The same revision file layout as iOS. Syncs between Android devices that share the folder; sharing with an iPhone is not possible today (see below) |

### System surfaces

| iOS | Android |
| --- | --- |
| Control Widgets | Eight Quick Settings tile slots that the user assigns to package `controls` |
| Siri and Shortcuts actions | App shortcuts on the launcher icon for package `actions`; no voice or automation entry point |
| Live Activities | A Live Update notification with title, detail, progress and countdown. The package's JSX layout and the Dynamic Island are not drawn |

### Synced documents and iPhone

`$icloud` on Android keeps the iOS contract: immutable revisions, both heads preserved on concurrent writes, explicit resolve, and no claim that an upload finished. It cannot exchange data with an iPhone. iOS reads only its iCloud container, which no Android documents provider exposes, and the two platforms encode fractional numbers and some key orders differently, so iOS would reject Android-written revisions. Exchange between two Android devices is covered by unit tests on a plain directory; it has not been tested through a real cloud provider.

### Not available

`$reminders`, `$home`, accessory (Lock Screen) families, the Dynamic Island, accented and vibrant rendering modes, and push-triggered refresh. Push needs a Firebase project that has not been set up for this app.

## Security notes

- Package code runs only in a per-execution QuickJS context with a memory limit and a time limit. It cannot reach the native bridge functions: they are captured by the host script and removed from the global object first.
- Policy is enforced in Kotlin (manifest permissions, hosts, budgets, storage namespaces). JavaScript checks exist only for early errors, because package code can replace built-ins.
- The compile and layout contexts run trusted code only. The layout context receives the element tree as data.
- The Studio editor WebView loads bundled assets from a private origin, cannot navigate away and has no file access.
