# ScriptWidget for Android

Status: in development on the `android` branch. Verified on one device, a Pixel 6 running Android 17. Other vendors' launchers and background limits have not been tested.

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
| Sizes | Small, medium and large providers. The launcher decides the real size; cells are not square, so `small` is not always square |
| Refresh | WorkManager, at most every 15 minutes, plus alarms at `timeline.dailyTimes` transitions. Android may delay background work |
| Timeline | The script runs again at each transition as the current entry; there are no pre-rendered future entries |
| `<date>` | `timer` and a `time` of now tick by themselves (system font). `relative`, `offset` and `date` are redrawn on refresh |
| Animations, GIF | Static: clock and swing effects rest, a GIF shows its first frame |
| `backgroundMaterial` | The opaque `background` fallback |
| Rendering modes | Always `fullColor` |
| Network | The manifest allowlist as on iOS, and names that resolve to private addresses are refused |
| Not available | `$health`, `$reminders`, `$music`, `$icloud`, `$maps`, `$weather`, `$alarms`, `$documents`, `$contacts`, `$home`, Live Activities, Dynamic Island, Control Widgets, accessory families, push updates. See the plan for which later release adds each |

## Security notes

- Package code runs only in a per-execution QuickJS context with a memory limit and a time limit. It cannot reach the native bridge functions: they are captured by the host script and removed from the global object first.
- Policy is enforced in Kotlin (manifest permissions, hosts, budgets, storage namespaces). JavaScript checks exist only for early errors, because package code can replace built-ins.
- The compile and layout contexts run trusted code only. The layout context receives the element tree as data.
- The Studio editor WebView loads bundled assets from a private origin, cannot navigate away and has no file access.
