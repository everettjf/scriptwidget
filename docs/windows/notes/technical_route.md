# Technical route for a Windows 11 host for script-driven desktop widgets (state: 2026-11-16)

Labelling used throughout:

- **[official]** read in this session on a Microsoft Learn page or a project's own README/source; the page's own "updated" date is given.
- **[source]** read in this session in a project's source code or in this repository.
- **[secondary]** third-party article, forum post or search-result summary; not confirmed at the primary source.
- **[inference]** my own reasoning from the above.
- **[unverified]** background knowledge I could not confirm at a source in this session. Treat as a hypothesis, not a fact.

Nothing in these notes was run on a Windows machine. Every behavioural claim about Windows 11 needs the prototype listed at the end.

---

## 1. Desktop-level windows on Windows 11 24H2/25H2

### Takeaway
Windows 11 24H2 (from build 26100.2454) reordered the desktop shell window hierarchy and broke both the classic "parent to WorkerW" wallpaper technique and Rainmeter's Win+D handling; Lively and Rainmeter both shipped rewrites that branch on the new layout. For widgets (as opposed to wallpapers) the Rainmeter approach, a normal top-level window kept at the bottom of the z-order and re-raised when "Show Desktop" is detected, is the better model than re-parenting into the shell's windows, but it is a polling/heuristic design that must be validated on each Windows feature update.

### Cited Findings
- **Lively, classic path [source]:** sends message `0x052C` to `Progman` ("This message directs Progman to spawn a WorkerW behind the desktop icons"), enumerates top-level windows to find the one that has `SHELLDLL_DefView` as a child, takes the next sibling `WorkerW`, and calls `SetParent(wallpaper, workerW)`. — [Lively WinDesktopCore.cs](https://raw.githubusercontent.com/rocksdanister/lively/core-separation/src/Lively/Lively/Core/WinDesktopCore.cs) (branch `core-separation`, read 2026-11-16)
- **Lively, new path [source]:** detects the "raised desktop" by testing whether `Progman` has `WS_EX_NOREDIRECTIONBITMAP`; in that case `WorkerW` is looked up as a **child of Progman** (`FindWindowEx(progman, 0, "WorkerW", 0)`), the wallpaper is parented to `Progman` itself, placed in z-order directly after `SHELLDLL_DefView` via `SetWindowPos(hwnd, shellDLL_DefView, …)`, and `EnsureWorkerWZOrder()` pushes WorkerW to `HWND_BOTTOM` (it logs "Unexpected WorkerW Z-order."). The file quotes a Microsoft explanation: "When the desktop is split out from the list view window (aka the 'raised desktop') we no longer create multiple top-level HWNDs to support this scenario. Instead, the top-level 'Progman' window is now created with WS_EX_NOREDIRECTIONBITMAP". The code has no build-number check; it keys on the window style. — [same file](https://raw.githubusercontent.com/rocksdanister/lively/core-separation/src/Lively/Lively/Core/WinDesktopCore.cs)
- **Lively adds `WS_EX_LAYERED` before `SetParent`** where needed (comment: "Godot fails to apply WS_EX_LAYERED if attached after SetParent") and handles "WorkerW destroyed" by re-attaching. — [same file](https://raw.githubusercontent.com/rocksdanister/lively/core-separation/src/Lively/Lively/Core/WinDesktopCore.cs)
- **Lively release notes [secondary, release-note aggregator]:** v2.2.0.0 says core components were "fully rewritten to adapt to platform changes introduced in Windows 11 24H2". — [newreleases.io copy of Lively v2.2.0.0](https://newreleases.io/project/github/rocksdanister/lively/release/v2.2.0.0)
- **Lively breakage report [secondary]:** issue #2506 reports Lively failing on 24H2 build 26100.2454 while working on 22H2. — [Lively issue #2506](https://github.com/rocksdanister/lively/issues/2506)
- **Rainmeter does not re-parent into WorkerW [source]:** it keeps its skins as top-level windows and positions them "relative to the parent of SHELLDLL_DefView, which is what contains the desktop icons". `ShouldUseShellWindowAsDesktopIconsHost()` tests whether `user32` exports `GetCurrentMonitorTopologyId`, commented as present only from "Windows 11 build 10.0.26100.2454"; on those builds the desktop-icons host is the `Progman` shell window, otherwise it searches visible `WorkerW` windows. A comment block states "Windows 11 24H2 reordered the desktop shell window hierarchy" with before/after Spy++ dumps. — [Rainmeter Library/System.cpp](https://raw.githubusercontent.com/rainmeter/rainmeter/master/Library/System.cpp) (master, read 2026-11-16)
- **Rainmeter Show Desktop handling [source]:** no hook on Win+D exists; `CheckDesktopState()` infers the state from where a hidden helper window ("RainmeterSystem") sits relative to the desktop host, driven by `EVENT_SYSTEM_FOREGROUND` (up to 5 retries, "Wait for 2-16 ms before retrying") and a polling timer (`INTERVAL_SHOWDESKTOP` 250 ms, `INTERVAL_RESTOREWINDOWS` 100 ms). When the desktop is shown, the helper is made `HWND_TOPMOST` and "On Desktop" skins are re-inserted behind it; otherwise it sits at `HWND_BOTTOM`. Z positions are re-applied in the order Normal → OnBottom (only when not showing desktop) → OnDesktop. — [Rainmeter Library/System.cpp](https://raw.githubusercontent.com/rainmeter/rainmeter/master/Library/System.cpp)
- **Rainmeter DPI detail [source]:** the helper window "must be created DPI-unaware to reproduce the legacy DPI-unaware SetWindowPos coordinate mapping", i.e. Rainmeter still maps coordinates through a DPI-unaware window. — [Rainmeter Library/System.cpp](https://raw.githubusercontent.com/rainmeter/rainmeter/master/Library/System.cpp)
- **Rainmeter resume handling [source]:** a 1000 ms `TIMER_RESUME` refreshes skins after `PBT_APMRESUMESUSPEND`. — [Rainmeter Library/System.cpp](https://raw.githubusercontent.com/rainmeter/rainmeter/master/Library/System.cpp)
- **Rainmeter 24H2 regression [secondary]:** a Rainmeter developer confirmed on the forum that skins are "minimized" by Win+D on 24H2 while 23H2 was unaffected; release-note copies attribute the fix ("didn't allow Rainmeter skins to remain visible when the WIN-D (Show Desktop) function of Windows was used") to 4.5.22 in one source and to a 4.5.18-dated section in another. Conflict not resolved; the official release-notes URL I tried returned 404. — [Rainmeter forum thread](https://forum.rainmeter.net/viewtopic.php?p=227877); [malwaretips copy of release notes](https://malwaretips.com/threads/rainmeter-4-5-release-notes.85045/latest); [Neowin 4.5.22](https://www.neowin.net/software/rainmeter-4522/)
- **Microsoft compatibility hold [secondary]:** Microsoft placed a 24H2 safeguard hold on machines with wallpaper customization apps and lifted it gradually in April 2025; Wallpaper Engine shipped a 24H2 compatibility release in February 2025. — [The Register, 2025-04-14](https://www.theregister.com/2025/04/14/windows_11_24h2_hold/); [TechRadar](https://www.techradar.com/computing/windows/couldnt-install-windows-11-24h2-because-of-your-wallpaper-microsoft-has-finally-lifted-blocks-on-upgrades-due-to-customization-apps-with-some-catches)
- **Wallpaper Engine [secondary, developer forum post]:** a 24H2 bug kept wallpapers invisible at startup when desktop icons were turned off; workaround was to turn icons on first. — [Steam discussion](https://steamcommunity.com/app/431960/discussions/1/4846526727955382962)
- **Seelen UI [official README]:** says its widgets render "directly on the desktop layer"; it is distributed as a signed MSIX via Microsoft Store and winget plus an .exe on GitHub. — [Seelen-UI README](https://github.com/eythaann/Seelen-UI) (read 2026-11-16)

### Inferences
- There are two distinct techniques, and they failed differently on 24H2: (a) *wallpaper layer* (child of WorkerW/Progman, behind icons) needed a re-parenting rewrite; (b) *bottom-most top-level window* (Rainmeter) needed a Show-Desktop rewrite. A widget host wants (b): widgets must be above the icons and receive clicks; a child of the shell's window lives in another process's window tree, gets no normal activation, and is destroyed when Explorer restarts.
- The minimal window recipe for (b) is a top-level popup with `WS_EX_TOOLWINDOW` (no taskbar/Alt-Tab entry), `WS_EX_NOACTIVATE` (clicks do not steal focus), `WS_EX_LAYERED` with per-pixel alpha via `UpdateLayeredWindow`, kept at `HWND_BOTTOM` on `WM_WINDOWPOSCHANGING`. **[unverified]** these style semantics are from memory, not re-read on Learn in this session.
- Because the host only blits a pre-rendered bitmap a few times a minute, a GDI layered window (`UpdateLayeredWindow` with a premultiplied BGRA DIB) is sufficient; DirectComposition (`WS_EX_NOREDIRECTIONBITMAP` + a composition swap chain) only pays off for animation or many large surfaces. **[unverified]** no measurement.
- Both reference projects depend on undocumented shell internals (window class names, message 0x052C, an export-presence check). Microsoft changed them once in a servicing build (26100.2454), not only at a feature update, so the host needs a self-test at startup and a safe fallback ("normal window, not pinned to desktop").
- Explorer restart must be handled (re-find the desktop host, re-assert z-order); the standard signal is the registered `TaskbarCreated` message. **[unverified]**

### Gaps
- **Virtual desktops:** whether a `WS_EX_TOOLWINDOW` bottom-most window appears on all virtual desktops or only the one it was created on, on 24H2/25H2. I found no primary source; the public `IVirtualDesktopManager` API only exposes query/move for the app's own windows **[unverified]**. Needs prototype.
- **Multiple monitors / per-monitor DPI v2 / fractional scaling:** no source read on how Lively/Rainmeter handle `WM_DPICHANGED`; Rainmeter's DPI-unaware helper suggests it does *not* use PMv2 natively. For a bitmap host the rule is: declare PerMonitorV2, render the bitmap at the monitor's physical pixel size (points × scale, e.g. 1.25/1.5/1.75), re-render on `WM_DPICHANGED` **[inference]**. Needs prototype at 125 % and 175 %.
- **HDR:** no source found on how an sRGB layered window looks on an HDR desktop (SDR content brightness slider applies to SDR windows **[unverified]**). Needs prototype on an HDR display.
- **Peek at desktop / Win+D on 25H2 and on the 2026 feature update:** only Rainmeter source as evidence; not tested.
- **Wallpaper Engine internals:** closed source; only forum statements.
- **Zebar z-order options:** the README excerpt I could read did not cover them.
- **Full-screen apps / games:** whether the host should hide or stop refreshing when a full-screen app is in front (Lively has "wallpaper pausing"; rules not read).

---

## 2. Rendering options: WebView2 vs native Direct2D/DirectWrite vs shared Rust painter

### Takeaway
WebView2 gives pixel-identical output to the existing browser preview for the least code but puts a Chromium process group (browser + GPU + renderer(s)) in memory all day and offers no official per-instance memory figure; a painter that turns the recorded element tree into a bitmap (the Android and planned Linux architecture) keeps the host small and lets Windows share almost everything with Linux, at the cost of porting ~1,400 lines of painter and owning CJK/emoji text quality. The deciding unknown is text fidelity of the Rust text stack on Windows fonts, which only a prototype can answer.

### Cited Findings
**WebView2**
- **Runtime availability [official, page updated 2026-10-02]:** "The Evergreen WebView2 Runtime will be included as part of the Windows 11 operating system … However, some devices might not have the Runtime pre-installed, so it's a good practice to check whether the Runtime is present on the client." Detection is via the `pv` value under `…\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}` or `GetAvailableCoreWebView2BrowserVersionString`. The bootstrapper is "approximately 2 MB"; the Fixed Version runtime is "over 250 MB". — [Distribute your app and the WebView2 Runtime](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution)
- **Long-running apps keep an old runtime [official]:** "if your app runs continuously, your app will continue to use the previous version of the WebView2 Runtime. This has security implications"; the app must release all environment references or restart (`NewBrowserVersionAvailable`). — [same page](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution)
- **Process model [official, page updated 2026-06-12]:** one process group per user data folder: "A single browser process", "One or more renderer processes", and helpers "such as the GPU process and the Audio service process". "A given renderer process is not associated with a single CoreWebView2 instance, because the renderer process can serve frames in multiple CoreWebView2 instances that use the same user data folder, depending on website isolation." Creating another WebView2 from the same environment "with a different domain … will usually start a new renderer process". — [Process model for WebView2 apps](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/process-model)
- **Transparency [official API reference, via search summary]:** `DefaultBackgroundColor` supports only fully opaque colours or full transparency (alpha 0 or 255); with full transparency the WebView renders no background so windows behind show through; setting it early through controller options avoids a white flash. — [CoreWebView2Controller.DefaultBackgroundColor](https://learn.microsoft.com/en-us/dotnet/api/microsoft.web.webview2.core.corewebview2controller.defaultbackgroundcolor)
- **Transparency caveat [secondary]:** a WinUI issue reports the transparent setting rendering as the theme's dark grey in the XAML `WebView2` control. — [lightrun mirror of microsoft-ui-xaml issue](https://lightrun.com/answers/microsoft-microsoft-ui-xaml-webview2defaultbackgroundcolor-cannot-be-set-to-a-transparent-background)
- **Memory guidance [official, via search summary]:** Microsoft gives no numbers; it recommends `MemoryUsageTargetLevel = Low` on inactive WebViews and measuring with Process Explorer/DevTools. — [WebView2 performance best practices](https://learn.microsoft.com/microsoft-edge/webview2/concepts/performance)
- **Memory numbers [secondary, uncontrolled, conflicting]:** blog figures for idle Tauri (WebView2) apps on Windows range from ~40 MB to ~170 MB total; one write-up attributes ~36 MB to the Rust backend and "everything above it" to WebView2. None separates browser/GPU/renderer processes. — [dev.to Tauri vs Electron](https://dev.to/gethopp/tauri-vs-electron-performance-bundle-size-and-the-real-trade-offs-1el4); [tech-insider.org](https://tech-insider.org/tauri-vs-electron-2026/)
- **Comparable projects use webviews [official READMEs]:** Zebar widgets are "native webviews" (HTML + CSS/JS per widget, defined in `zpack.json`) and its FAQ tells Windows users to update the WebView2 runtime; Seelen UI requires "the WebView runtime" (and says Microsoft Edge must be installed) and warns of a white/dark screen on fresh Windows installs until Windows Update has run. — [Zebar README](https://github.com/glzr-io/zebar); [Seelen-UI README](https://github.com/eythaann/Seelen-UI)

**Rust painter (shared with the Linux plan)**
- **tiny-skia [official README]:** CPU rasterizer; fills/strokes with solid colours, gradients, patterns, dashing, clipping, image blending, PNG I/O. "The main missing feature" is text rendering; GPU is a non-goal. "20-100% slower than Skia on x86-64 and about 100-300% slower on ARM"; "adds around 200KiB to your binary" versus Skia's "3-8 MiB". Self-described as "more of a research project" and "not a Skia replacement and never will be". — [tiny-skia README](https://github.com/linebender/tiny-skia) (read 2026-11-16)
- **cosmic-text [official README]:** shaping via HarfRust, custom layout in safe Rust with bidi, font fallback "reusing static fallback lists from browsers" (Chromium and Firefox), colour emoji via the swash rasterizer; Linux, macOS and Windows listed as supporting the full feature set; the roadmap still lists items that "must be supported before this is 'ready'" (e.g. hinting, caching). Dual MIT/Apache-2.0. — [cosmic-text README](https://github.com/pop-os/cosmic-text) (read 2026-11-16)

**What the existing renderer needs from a painter [source, this repository, 2026-11-16]**
- The shared renderer (`Web/preview-engine/src/render/renderer.js`, 1,337 lines; `layout.js`, 664 lines) builds HTML/SVG DOM and takes text metrics through a `measurer` object (`measure`, `ellipsisWidth`, `baseline`, `textAdjustments`); `renderer.js` line 218 accepts an injected `textMeasurer`. — `Web/preview-engine/src/render/layout.js`, `renderer.js`
- `layout.js` contains browser-specific corrections ("Chrome draws emoji at exactly 1 em, so the measurer resizes…", "the measurer letter-spaces Han runs to match"), i.e. CJK and emoji metrics are already normalised at the measurer boundary. — same file, lines 537–558
- Android runs the same renderer in QuickJS against a recording `document` (`entry.mjs`, 164 lines, imports `renderer.js` directly and implements `createElement`/`createElementNS`), then paints the recorded tree with a Kotlin painter totalling 1,379 lines (`DomPainter.kt` 593, `SvgPainter.kt` 225, `WidgetRenderer.kt` 201, `Css.kt` 183, `TextEngine.kt` 66, `FontRegistry.kt` 60, `GifFrames.kt` 51). — `Android/core/src/main/js/render/entry.mjs`, `Android/core/src/main/java/com/everettjf/scriptwidget/core/render/`
- The Kotlin painter depends on `android.graphics` features a port must supply: `Canvas`, `Path`, `Matrix`, `Camera` (3D transforms), `BlurMaskFilter` (shadows/blur), `PorterDuff` blend modes and colour filters, `ColorMatrix`, `DashPathEffect`, `PathMeasure`, `Movie` (GIF), and for text `MeasuredText`/`LineBreaker`/`TextPaint`. — same directory (import lists)
- The Linux plan already names the painter "the largest piece of new work" and leaves tiny-skia + cosmic-text versus Cairo + Pango to a phase-0 comparison; it requires that text measuring and drawing be "the same code". — `docs/linux/plan.md` §3, §4.1

### Inferences
Comparison (my assessment; fidelity and memory columns are estimates until measured):

| | (1) WebView2 runs the browser renderer | (2) Native painter, Direct2D + DirectWrite (or Win2D) | (3) Shared Rust painter (tiny-skia + cosmic-text, or Skia) → layered window |
| --- | --- | --- | --- |
| Fidelity vs. Web Studio preview | Identical by construction (same Chromium engine, same DOM renderer) | High for text (system shaping, fallback, colour emoji); shapes/blur/3D need hand mapping | Shapes good; text depends on cosmic-text fallback + swash with Windows fonts (Microsoft YaHei, Yu Gothic, Segoe UI Emoji): unknown |
| CJK + emoji | Chromium's own | DirectWrite's own; best native result | Static fallback lists; colour-emoji format support for Segoe UI Emoji must be tested |
| Memory, all-day | A Chromium process group stays resident unless the WebView is destroyed between refreshes; no official figure | Small: one process, bitmaps only | Small: one process, bitmaps only |
| Startup | Environment creation + page load per cold start | Fast | Fast |
| Sandbox for widget JS | Chromium renderer sandbox + existing iframe/Worker sandbox (`Web/preview-engine/src/browser/sandboxFrame.js`) | Must build own (see §7) | Must build own (see §7) |
| Engine parity with iOS/Android | V8, not QuickJS/JSC: a third engine for the same script; has Intl | QuickJS-NG, same as Android | QuickJS-NG, same as Android and Linux |
| New code | Smallest: host shell + bridge for native APIs | Painter port to D2D/DWrite in C++/C#/Rust (Windows-only code) | Zero Windows-only painter code if Linux painter exists |
| Shared with Linux | Only the JS | JS + QuickJS host; painter is Windows-only | JS + QuickJS host + painter + daemon + CLI |
| Feeds Widgets Board bitmap | Needs an off-screen capture step (`CapturePreview`) | Yes, same bitmap | Yes, same bitmap |
| Headless CLI/CI `render` | Awkward | Possible | Yes, identical to Linux |

- A hybrid is possible and cheap to keep open: (3) for the always-on desktop host and Widgets Board, (1) only inside the management app for an authoring preview, created on demand and destroyed afterwards. This bounds WebView2's memory cost to the time the user is editing.
- A second hybrid for text only: keep the Rust painter for shapes but implement the `measurer` + glyph drawing with DirectWrite on Windows (via `windows-rs`). This keeps "measure and draw are the same code" true per platform, trades cross-platform pixel identity for native-quality CJK/emoji. Worth prototyping only if cosmic-text fails the fidelity gate.
- WebView2 as the *all-day* renderer conflicts with requirement (e) and with the documented "long-running app keeps an outdated runtime" caveat; Zebar and Seelen accept that cost because their widgets are live HTML. ScriptWidget widgets are timeline snapshots, so a bitmap host matches the product model better.
- Skia (`skia-safe`) would remove the text risk (Skia's paragraph module with DirectWrite font manager **[unverified]**) but the tiny-skia README's own numbers put Skia at 3–8 MiB of binary and a multi-GiB build, and it would become a dependency of the Linux build too.

### Gaps
- No authoritative per-process WebView2 memory figure exists in what I read; the blog range (≈40–170 MB) is not comparable across sources. **Prototype:** one hidden WebView2 rendering one widget, measure private working set of every `msedgewebview2.exe` at idle, with and without `MemoryUsageTargetLevel.Low`, and after `Close()`.
- WebView2 cold-start time on Windows 11 for a shared environment: no figure found.
- Whether a transparent WebView2 hosted in a `WS_EX_LAYERED`/bottom-most window composites correctly (windowed vs. composition hosting): not read; needs prototype if route (1) is considered.
- cosmic-text and tiny-skia current version numbers and release dates: the README fetches did not show them.
- Whether swash renders Windows 11's Segoe UI Emoji colour tables correctly, and whether cosmic-text's Windows fallback picks the right Han face for zh-Hans / zh-Hant / ja / ko (Han unification): no source; **prototype**.
- Win2D status in 2026 (the WinAppSDK variant `Microsoft.Graphics.Win2D`): not researched; it is a C#/C++ wrapper over Direct2D/DirectWrite **[unverified]**, so it would only matter for route (2).
- Cost of `Camera` (3D transform) and `BlurMaskFilter` equivalents in tiny-skia (neither is built in **[inference]** from the feature list).

---

## 3. JS engine: QuickJS-NG on Windows, bindings, limits, Intl

### Takeaway
QuickJS-NG with a memory limit and interrupt handler is already the Android engine in this repository (v0.18.0) and is the natural Windows engine; the one concrete risk is that rquickjs marks Windows MSVC targets "experimental" while Windows GNU targets are fully supported. Windows ships ICU as a system C API (`icu.dll`, since Windows 10 1903), so the Android approach of backing an `Intl` subset with the platform's ICU carries over.

### Cited Findings
- **Repository engine version [source]:** the vendored QuickJS-NG is `QJS_VERSION_MAJOR 0`, `MINOR 18`, `PATCH 0`. — `Android/core/src/main/cpp/quickjs/quickjs.h` lines 1500–1503
- **Limits already wired on Android [source]:** `scriptwidget_jni.c` (336 lines) calls `JS_SetMemoryLimit`, `JS_SetMaxStackSize` and `JS_SetInterruptHandler` (lines 187–189). — `Android/core/src/main/cpp/scriptwidget_jni.c`
- **Android research conclusions [source, repo doc dated 2026-11-12]:** QuickJS-NG v0.18.0 (2026-11-01) was chosen for synchronous host functions, interrupt callback + `JS_SetMemoryLimit`, bytecode cache, and because from 0.18 OOM/InternalError cannot be caught by script; drawbacks: "no `Intl`, upstream says it will not support it", interpreter only. With a real interrupt callback the Babel cancellation instrumentation is not needed. — `docs/android/android-port-research-and-plan.md` §3.1
- **Intl on Android [source]:** `android-host.js` (266 lines) defines an `Intl` subset (`DateTimeFormat`, `NumberFormat`, `PluralRules`, `RelativeTimeFormat`, `Collator`, `ListFormat`, `getCanonicalLocales`) "backed by ICU on the device". — `Android/core/src/main/js/android-host.js` lines 31–152
- **rquickjs binds QuickJS-NG [official README, read 2026-11-16]:** "a high level bindings of the QuickJS-NG JavaScript engine". Platform table (shipped bindings / tested / supported by QuickJS): Windows GNU x86_64 and i686 ✅/✅/✅; **Windows MSVC x86_64 ✅/✅/❌ "experimental!"; Windows MSVC aarch64 ✅/❌/❌ "experimental!"**. A `bindgen` feature exists for platforms without shipped bindings. — [rquickjs README](https://github.com/DelSkayn/rquickjs)
- **rquickjs exposes the limits [secondary: docs.rs source via search summary]:** rquickjs-core 0.12.0 has `Runtime::set_memory_limit` and `set_interrupt_handler` (returning true raises an uncatchable exception); a fragment notes the memory limit "does nothing" when a custom allocator is used. — [rquickjs-core 0.12.0 runtime/base.rs](https://docs.rs/crate/rquickjs-core/0.12.0/source/src/runtime/base.rs)
- **QuickJS-NG on MSVC [secondary: third-party docs mirror]:** the project moved to CMake "to support Windows better" and treats Windows "as a first-class citizen, with the addition of support for the MSVC compiler"; `JS_SetMemoryLimit` is a hard cap after which allocations fail and the runtime stays valid. — [mintlify mirror: differences from original](https://www.mintlify.com/quickjs-ng/quickjs/resources/differences-from-original); [mintlify mirror: memory API](https://www.mintlify.com/quickjs-ng/quickjs/api/runtime/memory)
- **QuickJS-NG repo [official README, read 2026-11-16]:** ships `CMakeLists.txt`, `Makefile` and `meson.build`; the README itself states no compiler matrix. — [quickjs-ng/quickjs](https://github.com/quickjs-ng/quickjs)
- **ICU in Windows [official, page updated 2025-04-15]:** "In Windows 10 Creators Update, ICU was integrated into Windows, making the C APIs and data publicly accessible." Version 1703 added `icuuc.dll` and `icuin.dll`; 1709 added the combined header `icu.h`; **1903 added the combined `icu.dll`/`icu.lib`**. "The version of ICU in Windows only exposes the C APIs. It does not expose any of the C++ APIs." With the combined library on 1903+ the `CoInitializeEx` call can be omitted. "Not all data returned by ICU APIs will align with the Windows OS". The exported API list includes `udat_*`, `unum_*`/`unumf_*`, `uplrules_*`, `ureldatefmt_*`, `ucol_*`, `ulistfmt_*`, `ucal_*`, `udatpg_*`, `uloc_*`. — [International Components for Unicode (ICU), Win32](https://learn.microsoft.com/en-us/windows/win32/intl/international-components-for-unicode--icu-)

### Inferences
- Confirmed: `icu.dll` is part of Windows 10 1903+ and therefore of every Windows 11 build. The exported function families map one-to-one onto the six `Intl` constructors the Android host implements, so the same JS-side `Intl` shim can call a Windows native bridge. ICU *version* differs per Windows build (not documented on the page), so output can differ slightly between Windows versions and from Android/iOS; parity tests should compare structure, not bytes.
- The "experimental MSVC" label in rquickjs is about QuickJS's own support column; two ways around it: (a) build the vendored 0.18.0 C sources directly with `cc`/`cmake` crates and write a thin FFI (the JNI file is only 336 lines, so the needed surface is small), or (b) build with clang-cl or the `x86_64-pc-windows-gnu` target. Option (a) also guarantees the *same* engine source as Android and Linux, which the Linux plan already requires ("compile from the same source").
- V8-through-WebView2 gives Intl and a JIT for free but (i) has no synchronous host bridge from a Worker to native code comparable to QuickJS host functions (`host.readFile`, `host.evaluateScript`, `host.compiledImport` in `kernel.js` are synchronous) — the browser host solves this by preloading files into the sandbox; (ii) per-script memory limits are not exposed by WebView2 **[unverified]**; the browser host enforces only a deadline by terminating the Worker (`sandboxFrame.js`).
- ChakraCore: **[unverified]** Microsoft ended its support in 2021 and it is community-maintained with little activity; I did not re-check in this session. Not a candidate regardless: no parity with any other platform.

### Gaps
- QuickJS-NG's latest release number/date and its CI compiler matrix (MSVC, clang-cl, MinGW, ARM64) as of November 2026: the README fetch did not show them, and the MSVC statements come from a third-party mirror. **Prototype:** build the vendored 0.18.0 with MSVC x64 and ARM64, run the 164 parity trees.
- rquickjs's current crate version and which QuickJS-NG release it vendors: not shown on the README.
- Whether Windows' ICU passes the Android `Intl` test set (e.g. `formatToParts`, `dateStyle`/`timeStyle`, `hourCycle`, `numberingSystem`, ListFormat): untested. ICU4X is the fallback named in the Linux plan.
- Windows on ARM64: rquickjs marks MSVC aarch64 untested.

---

## 4. UI framework for the management app and tray

### Takeaway
The comparable open-source desktop-widget projects that I could verify are web-stack apps over the system webview (Zebar, Seelen UI); Windows App SDK is current at 2.x with Widgets provider APIs in the stable channel, and is needed in some form anyway if the app feeds the Widgets Board. The framework choice is secondary to the split "tiny always-on host process + separately launched management UI".

### Cited Findings
- **Windows App SDK [official, page updated 2026-11-07]:** stable channel latest is **2.6.5, released 2026-11-02**; the 2.0 line was first released 2026-04-29 and is "Current" with end of servicing 2027-04-29; 1.8 (2025-09-09) reached end of servicing 2026-09-24. Major releases come "no more than every six months". WinUI, DWriteCore, windowing, app notifications and **Windows Widgets** are all "Available" in Stable. — [Windows App SDK release channels](https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/release-channels)
- **Widgets walkthrough pins WinAppSDK 2.5.1 [official, page updated 2026-10-27]** and uses framework-dependent deployment of the Windows App SDK runtime in an MSIX packaging project. — [Implement a widget provider (C++/WinRT)](https://learn.microsoft.com/en-us/windows/apps/develop/widgets/implement-widget-provider-win32)
- **Seelen UI [official README, read 2026-11-16]:** widget SDK is Svelte + TypeScript; repo topics include `tauri`; Rust workspace; needs the WebView runtime ("Windows 11 includes it") and says Microsoft Edge must be installed; shipped as signed `.msix` (Microsoft Store, winget `Seelen.SeelenUI`) and `.exe`; Store updates take "1–3 business days". — [Seelen-UI](https://github.com/eythaann/Seelen-UI)
- **Zebar [official README, read 2026-11-16]:** Rust crates plus a pnpm workspace; widgets are HTML/CSS/JS in "native webviews", described as "similar" to Electron but "more lightweight". The excerpt I read does not name Tauri. — [Zebar](https://github.com/glzr-io/zebar)
- **Lively [source]:** the desktop core is C# (`WinDesktopCore.cs`, P/Invoke). — [Lively source](https://raw.githubusercontent.com/rocksdanister/lively/core-separation/src/Lively/Lively/Core/WinDesktopCore.cs)
- **Rainmeter [source]:** native C++ Win32. — [Rainmeter System.cpp](https://raw.githubusercontent.com/rainmeter/rainmeter/master/Library/System.cpp)

### Inferences
| Option | Fit | Notes (all **[inference]**/**[unverified]** unless cited above) |
| --- | --- | --- |
| Rust + `windows-rs`, no framework, for the host | Best for the always-on process | Tray icon, layered windows, COM widget provider are all plain Win32/WinRT; one static exe; shares the Linux crate. Building a rich management UI this way is slow. |
| Tauri 2 for the management UI | Good | Reuses the existing Web Studio (React + TypeScript + shadcn, `Web/studio/`) as the UI, Rust backend links the same core crate; WebView2 exists only while the window is open. Same stack as Seelen UI. |
| WinUI 3 / Windows App SDK (C#) | Good native look; second language | Stable and current (2.6.5). Needs C# ↔ Rust FFI for the core; Native AOT and self-contained size were **not verified** in this session. |
| WPF | Works; legacy look | No benefit over WinUI 3 or Tauri here. Not researched. |
| Flutter | Poor fit | A third UI toolkit, no reuse of Web Studio or of Swift/Kotlin UI. Not researched. |

- If "no GUI on Linux" (Linux plan §1) is mirrored, Windows could ship as CLI + tray host first and add the Tauri-wrapped Web Studio later; but Windows users, unlike Omarchy users, expect a GUI, so the management window is probably required for a Store listing.
- The widget-provider COM server (§5) must be an executable inside an MSIX package; implementing `IWidgetProvider` from Rust via `windows-rs` is plausible but I found no example; C++/WinRT and C# are the documented paths.

### Gaps
- Tauri 2 current version, Windows App SDK Native AOT status and self-contained package size, WPF/.NET 10 status, Flutter Windows status: not researched in this session (budget); mark all as to-verify before a decision.
- Lively's UI framework (**[unverified]**: WinUI 3 for the v2 UI) was not confirmed at a source.
- Whether `IWidgetProvider` can be implemented in Rust (`windows-rs` `implement` macro with the WinAppSDK winmd) without the C#/C++ projections: **prototype**.

---

## 5. Feeding the official Widgets Board

### Takeaway
A packaged (MSIX) COM-server provider that answers `IWidgetProvider` callbacks and pushes an Adaptive Card through `WidgetManager.UpdateWidget` is the only native route; HTML "web widgets" are documented as EEA-only. Showing the host-rendered bitmap as a card image is plausible but none of the practical limits (image source schemes, payload size, update rate, tap regions) are stated in the pages I read, so this is the largest block of prototype work.

### Cited Findings
- **Provider model [official, page updated 2026-10-27]:** "Currently you can implement a widget provider using a packaged Win32 desktop app or a Progressive Web App (PWA)." The provider implements `IWidgetProvider` "for widget creation, deletion, activation, context changes, and user actions" and sends updates through `WidgetManager`. "The widget host can activate and release your provider independently of the lifetime of pinned widgets. Restore widget state when the provider starts". — [Widget providers](https://learn.microsoft.com/en-us/windows/apps/develop/widgets/widget-providers)
- **Registration [official, page updated 2026-10-27]:** the walkthrough registers through an MSIX manifest: a `ComServer` extension with a CLSID (activated `CLSCTX_LOCAL_SERVER`) plus a `uap3:Extension` widget-provider block with `Definition` elements, `AllowMultiple="true"`, declared `Size` names (`small`, `medium`, `large`), icons and screenshots. — [Implement a widget provider (C++/WinRT)](https://learn.microsoft.com/en-us/windows/apps/develop/widgets/implement-widget-provider-win32)
- **Activate/Deactivate [official]:** `Activate` notifies the provider "that the widget host is currently interested in receiving updated content", per widget; `Deactivate` ends that. — [same page](https://learn.microsoft.com/en-us/windows/apps/develop/widgets/implement-widget-provider-win32)
- **Template and host properties [official, page updated 2026-10-27]:** cards use Adaptive Cards schema `"version": "1.6"` with a separate JSON data payload and template binding; host properties: `$host.widgetSize` ("small" | "medium" | "large"), `$host.hostTheme` ("light" | "dark"), `isSettingsPayload`, `isHeaderSupported`, `isHeader`, `isWebSupported`, `isUserContextAuthenticated`. "When this value [isUserContextAuthenticated] is false, the only action that is supported is Action.OpenUrl." The Designer "uses its own renderer… Don't assume that features it offers are supported by the Widgets Board." — [Create a widget template](https://learn.microsoft.com/en-us/windows/apps/develop/widgets/widgets-create-a-template)
- **Actions [official]:** `Action.Execute` with a `verb` is forwarded to `OnActionInvoked`; `Action.OpenUrl` navigates without calling the provider. — [same page](https://learn.microsoft.com/en-us/windows/apps/develop/widgets/widgets-create-a-template)
- **Images in the official sample [official]:** the sample template uses `"backgroundImage": "https://raw.githubusercontent.com/…jpg"` and an `Image` element — i.e. https URLs are demonstrated; no other scheme is shown. — [Implement a widget provider (C++/WinRT)](https://learn.microsoft.com/en-us/windows/apps/develop/widgets/implement-widget-provider-win32)
- **Design limits [official, page updated 2026-10-27]:** three sizes only; small should have "1 touch target", medium "2-3 touch targets", large "no more than 3-4 touch targets"; default layout has a 16 px margin and reserves a 48 px attribution/header area; where header customization is supported the provider can set `header` to `null` to extend content into the header region "but that region isn't clickable"; "The widget background supports customization with either a solid light/dark background, gradient tint, or image background." — [Widget design fundamentals](https://learn.microsoft.com/en-us/windows/apps/design/widgets/widgets-design-fundamentals)
- **Web widgets [official, page updated 2026-10-27]:** a card with `metadata.webUrl` loads HTML; `IWidgetResourceProvider.OnResourceRequested` can intercept requests matching the manifest's `WebRequestFilter` and answer them from the provider (the example returns a packaged PNG for `https://contoso.com/logo-image`); messaging via `window.chrome.webview.postMessage` and `WidgetManager.SendMessageToContent`. **"This feature is available only to users in the European Economic Area (EEA)."** Introduced in Windows App SDK 1.6.3. — [Web widget providers](https://learn.microsoft.com/en-us/windows/apps/develop/widgets/web-widget-providers)
- **Analytics callbacks [official]:** `IWidgetProviderAnalytics` is supported by the Widgets Board "starting with Windows 11 build 26900". — [Widget providers](https://learn.microsoft.com/en-us/windows/apps/develop/widgets/widget-providers)
- **Adaptive Cards schema, not widget-specific [secondary: schema explorer via search summary]:** the `Image` element accepts PNG, JPEG and GIF, and data URIs are documented from schema version 1.2; rendered size "will vary per host". — [Adaptive Cards schema explorer: Image](https://adaptivecards.io/explorer/Image.html)
- **A payload cap exists in another host [secondary]:** Microsoft Teams caps card payloads at roughly 25 KB, which base64 images exceed quickly; this is a Teams limit, not a documented Widgets Board limit. — [PnP blog](https://pnp.github.io/blog/post/display-images-in-adaptive-cards)

### Inferences
- Implementation shape: the tray host (or a tiny companion exe in the same MSIX) is the COM local server. On `CreateWidget`/`Activate` it renders the pinned ScriptWidget package at the size given by the context, and calls `UpdateWidget` with a template that is essentially one full-bleed image (`backgroundImage` or an `Image` with `selectAction`) plus `actions` for buttons. On timeline ticks it re-renders and calls `UpdateWidget` again while the widget is active.
- Getting the bitmap into the card, in order of what I would test: (1) `data:image/png;base64,…` in the data payload (schema allows it since 1.2; Board support and size cap unknown); (2) a file in the package's own storage via `ms-appdata:`/`file:` (not documented for widgets); (3) the web-widget resource interception (documented, but EEA-only and it means running HTML); (4) an https URL (would require uploading renders to a server, which is unacceptable for privacy and offline use).
- Tap regions: Adaptive Cards has no absolute positioning, so arbitrary hit rectangles over one image are not expressible. Options: (a) map each ScriptWidget button to an `Action.Execute` rendered by the host as a native button row beneath the image (loses layout fidelity; the 1 / 2-3 / 3-4 touch-target guidance fits this); (b) slice the bitmap into a `ColumnSet` grid of images, each with its own `selectAction` (fragile: gutters, scaling); (c) whole-card `selectAction` only. As on Android list rows, the verb should carry only an index that the provider resolves from its own saved action table.
- The Board decides size from three names, not pixels; the pages I read give no pixel sizes, so the render size per `$host.widgetSize` and DPI must be measured. ScriptWidget's four families (small/medium/large/extraLarge) map onto three.
- `$host.hostTheme` is evaluated in the template, so a light and a dark render can both be sent and switched with `$when` without a provider round trip, doubling payload.
- Because providers must be packaged, the Widgets Board feature forces MSIX (or packaging with external location) for at least that component, which in turn makes `StartupTask` (§6) the natural auto-start mechanism.

### Gaps (open questions to name for the platform-rules researcher and the prototype)
- Does the Widgets Board accept `data:` URIs for `Image.url` and `backgroundImage`? Maximum template + data payload size? None of the four widget pages I read states this.
- Is there a throttle on `UpdateWidget` calls (per minute/hour) or a minimum interval? Not stated in the pages read.
- Pixel dimensions of small/medium/large content areas at 100/125/150/200 % scaling; whether images are rescaled (blur) by the host.
- Does `selectAction` on `Image`/`Container`/`ColumnSet` with `Action.Execute` work in the Board, and does the 3–4 touch-target guidance have an enforced limit?
- Is `isUserContextAuthenticated` ever false for local accounts (which would disable all `Action.Execute` taps)?
- Can a provider create widgets dynamically per installed ScriptWidget package, or must every `Definition` be declared statically in the manifest (so one generic "ScriptWidget" definition with `AllowMultiple` + per-instance customization state is the only option)? The manifest-based registration suggests static; confirm in the manifest reference (`widget-provider-manifest`), which I did not read.
- Whether the 25H2/2026 Widgets Board still shows third-party widgets by default in all regions and on the lock screen — covered by the other researcher.
- Animated content (GIF in `Image`) and refresh of relative time text without a provider call: unknown.

---

## 6. Background model

### Takeaway
A packaged desktop app can auto-start through the `windows.startupTask` manifest extension without a consent dialog, with the user able to disable it in Settings/Task Manager; an always-on tray process should opt itself into EcoQoS and treat timers as coalescable. Sleep/Modern Standby and battery-saver effects on a Win32 tray process are not documented in what I read and must be measured.

### Cited Findings
- **StartupTask [official API reference; moniker up to winrt-28000]:** supported for "desktop applications in a Windows app package" since Windows 10 1607. Manifest: `uap5:Extension Category="windows.startupTask" Executable="…" EntryPoint="Windows.FullTrustApplication"` with `uap5:StartupTask TaskId DisplayName Enabled`. "If RequestEnableAsync is called from a packaged desktop app, no user-consent dialog is shown. Desktop apps can set their startup tasks to Enabled in the manifest". "to enable startup functionality, the user must either launch the app at least once, or they must enable startup functionality… Once enabled, the user is in control" via Settings > Startup or Task Manager. If the user disabled it, `RequestEnableAsync` "will not override their choice" (`DisabledByUser`); `DisabledByPolicy` also exists. Multiple startupTask extensions with different executables are allowed for packaged desktop apps. — [StartupTask class](https://learn.microsoft.com/en-us/uwp/api/windows.applicationmodel.startuptask)
- **EcoQoS [official, page updated 2025-07-01]:** opting into `PROCESS_POWER_THROTTLING_EXECUTION_SPEED` via `SetProcessInformation(ProcessPowerThrottling)` classifies the process as EcoQoS: "The system will try to increase power efficiency through strategies such as reducing CPU frequency or using more power efficient cores. EcoQoS should be used when the work is not contributing to the foreground user experience". Without an explicit choice "the system will use its own heuristics to automatically infer a Quality of Service level". — [SetProcessInformation](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-setprocessinformation)
- **Timer resolution [official, same page]:** "By default in Windows 11 if a window owning process becomes fully occluded, minimized, or otherwise non-visible to the end user, and non-audible, Windows may automatically ignore the timer resolution request". `PROCESS_POWER_THROTTLING_IGNORE_TIMER_RESOLUTION` opts in explicitly. — [SetProcessInformation](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-setprocessinformation)
- **Memory priority [official, same page]:** `ProcessMemoryPriority` can lower the default memory priority so pages are trimmed from the working set earlier. — [SetProcessInformation](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-setprocessinformation)
- **Resume handling in practice [source]:** Rainmeter waits 1000 ms after `PBT_APMRESUMESUSPEND` and then refreshes all skins. — [Rainmeter System.cpp](https://raw.githubusercontent.com/rainmeter/rainmeter/master/Library/System.cpp)
- **Network rules to re-implement [source, repository]:** "Package 2.0 network calls require `network` and a matching `networkDomains` declaration. Generic fetches allow public HTTP(S); Data Source Plugins are HTTPS-only. Reject private/local hosts and enforce request/response budgets." — `AGENTS.md` (Security Invariants)

### Inferences
- Auto-start: MSIX build → `StartupTask` (user-visible, user-revocable, no registry writes). Unpackaged/portable build → `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` **[unverified]** (not re-read). If the Widgets Board provider forces MSIX anyway, ship only the StartupTask path.
- Scheduling: the timeline scheduler is the app's own (as in the Linux daemon: "no system refresh quota"). Use one coalescable timer for the next due entry across all widgets (`SetCoalescableTimer`/threadpool timer with a window **[unverified]**), never a high-resolution timer; re-evaluate all timelines on `PBT_APMRESUMEAUTOMATIC`/`PBT_APMRESUMESUSPEND` and on system time change, because timers do not fire while the machine sleeps.
- The host should set EcoQoS on itself and on the script-runner child, and low memory priority on the host; raise QoS only while the management window is in front.
- Battery saver / Energy saver: subscribe to power-setting notifications and stretch refresh intervals; pause refresh entirely when the session is locked or the display is off, and when a widget's window is fully covered (Rainmeter has a `WindowOcclusionTracker`; DWM cloaking/occlusion checks **[unverified]**).
- Private/loopback blocking must live in our own HTTP client and be applied **after DNS resolution and on every redirect hop** (connect-time IP check), covering 10/8, 172.16/12, 192.168/16, 127/8, 169.254/16, ::1, fc00::/7, fe80::/10, IPv4-mapped IPv6, and `localhost`/`.local` names; the Swift and Android test cases for this are the spec. In Rust this means a custom resolver/connector (e.g. on `reqwest`/`hyper`) rather than WinHTTP, which also keeps the code identical to Linux. **[inference]**
- An AppContainer runner without `privateNetworkClientServer` would add an OS-level second barrier for LAN addresses (§7), but if networking is done by the host on the script's behalf, the runner needs no network capability at all — the stronger design.

### Gaps
- Modern Standby (S0 low-power idle): whether a Win32 tray process is suspended by the Desktop Activity Moderator and what happens to its timers on wake — not read; **prototype** on a Modern Standby laptop (overnight log of timer firings and wake reasons).
- Windows 11 Energy saver behaviour toward background Win32 processes in 24H2/25H2: not read.
- Whether Windows' automatic "Efficiency mode" heuristics already throttle a windowless tray process: stated only generally ("system will use its own heuristics").
- Metered-connection handling for scheduled fetches: not researched.

---

## 7. Sandboxing the script runner

### Takeaway
Windows offers three stackable, documented mechanisms for a child process that runs untrusted script: an AppContainer or LPAC token (file/registry/network/window/process isolation), job-object limits (memory, CPU rate, UI restrictions) and in-engine limits (QuickJS memory limit + interrupt). Win32 app isolation, the MSIX-level packaging of the same idea, is still labelled preview in the page I read.

### Cited Findings
- **AppContainer [official, page updated 2025-09-03]:** "AppContainers are isolated from accessing processes and windows belonging to other applications as well as from devices, files/directories, registry keys, the network, and credentials. Thus, they provide a mechanism for sandboxing potential risky operations such as parsing untrusted data safely." They "run with a Low Integrity Level". "without the *network* capability, an AppContainer cannot access the network". Effective access is the intersection of user SIDs and AppContainer SIDs. — [Launch an AppContainer](https://learn.microsoft.com/en-us/windows/win32/secauthz/implementing-an-appcontainer)
- **Launching from a normal Win32 app [official, same page]:** no MSIX needed: choose a moniker, `CreateAppContainerProfile` (or `DeriveAppContainerSidFromAppContainerName` if it exists), build `SECURITY_CAPABILITIES`, set `PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES` in `STARTUPINFOEX`, `CreateProcess` with `EXTENDED_STARTUPINFO_PRESENT`. The profile gives the child its own `LOCALAPPDATA`/`TEMP` under `…\AppData\Local\Packages\<name>\AC`. — [same page](https://learn.microsoft.com/en-us/windows/win32/secauthz/implementing-an-appcontainer)
- **LPAC [official, same page]:** "more isolated than a regular AppContainer"; needs explicit capabilities even for what AppContainers get by default, e.g. "cannot open any keys in the registry unless it has the *registryRead* capability and cannot use COM unless it has the *lpacCom* capability"; enabled with `PROC_THREAD_ATTRIBUTE_ALL_APPLICATION_PACKAGES_POLICY = PROCESS_CREATION_ALL_APPLICATION_PACKAGES_OPT_OUT`. — [same page](https://learn.microsoft.com/en-us/windows/win32/secauthz/implementing-an-appcontainer)
- **Precedent [official]:** from WebView2 Fixed Version 120 the renderer process runs "inside the App Container", requiring ACLs for `ALL APPLICATION PACKAGES` (S-1-15-2-1) and `ALL RESTRICTED APPLICATION PACKAGES` (S-1-15-2-2) on the runtime folder for unpackaged apps on Windows 10. — [Distribute your app and the WebView2 Runtime](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution)
- **Job objects [official, page updated 2024-02-22]:** `SetInformationJobObject` accepts `JobObjectExtendedLimitInformation` (`JOBOBJECT_EXTENDED_LIMIT_INFORMATION`), `JobObjectCpuRateControlInformation` (`JOBOBJECT_CPU_RATE_CONTROL_INFORMATION`; fails with error 50 if Dynamic Fair Share Scheduling is enabled), `JobObjectBasicUIRestrictions`, `JobObjectNetRateControlInformation`, and notification-limit classes. — [SetInformationJobObject](https://learn.microsoft.com/en-us/windows/win32/api/jobapi2/nf-jobapi2-setinformationjobobject)
- **Win32 app isolation [official, page dated 2024-10-01, updated 2025-05-15]:** "**This feature is in preview**: Some information relates to a prerelease product which may be substantially modified before it's commercially released." Targets Win32, Desktop Bridge and packaged-with-external-location apps; minimum "Windows 11, version 24H2 (build 26100) or later" and Visual Studio 17.10.2; capabilities are discovered with the Application Capability Profiler (v0.1.1). — [Win32 app isolation overview](https://learn.microsoft.com/en-us/windows/win32/secauthz/app-isolation-overview)
- **In-engine limits already used [source]:** `JS_SetMemoryLimit`, `JS_SetMaxStackSize`, `JS_SetInterruptHandler` in the Android JNI layer. — `Android/core/src/main/cpp/scriptwidget_jni.c` lines 187–189

### Inferences
- Recommended layering, cheapest first:
  1. **In-process QuickJS limits** (memory cap, stack cap, interrupt deadline) plus "the engine exposes no system interface" — identical to Android and to Linux v1. This is the v1 baseline.
  2. **Runner child process in a job object**: `JOB_OBJECT_LIMIT_PROCESS_MEMORY` (hard backstop above the QuickJS cap, also covering painter allocations), `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` (no orphans if the host dies), `JOB_OBJECT_LIMIT_ACTIVE_PROCESS = 1` (no child processes), CPU rate cap, UI restrictions (no clipboard, no desktop switching, no global atoms). **[unverified]** flag names are from memory; the page read lists only the information classes.
  3. **LPAC token with zero capabilities** for the runner: no file system beyond its profile, no registry, no network, no window access. All I/O (package files, `$storage`, `fetch`) is brokered by the host over an inherited pipe, which is already how the kernel's `host` interface is shaped.
  This mirrors the Linux plan's later-phase Landlock + seccomp step and can likewise be deferred past v1.
- AppContainer does not require the app itself to be packaged, so the sandbox design is independent of the MSIX decision; Win32 app isolation would sandbox the *whole app* and is both preview and 24H2-only, so it is not something to depend on.
- The painter should run in the same sandboxed child as the script (it parses untrusted images, fonts declared by packages, SVG paths); the host only receives a bitmap and a hit-region table.
- Restricted tokens (`CreateRestrictedToken`) are the older alternative used by Chromium's sandbox alongside AppContainer **[unverified]**; not needed if LPAC works.

### Gaps
- Whether Win32 app isolation left preview after May 2025: the overview page still says preview at its 2025-05-15 update; I did not read its release-notes page. Treat as preview.
- Whether an LPAC child can load system fonts and `icu.dll` data without extra capabilities (LPAC denies default file access that regular AppContainers have): **prototype**. If it cannot, measure text in the host or grant read ACLs/`lpacCom`-style capabilities selectively.
- Process start cost per render when the runner is short-lived vs. a warm pooled runner: measure.
- Interaction between nested jobs and a host that is itself inside a job (e.g. launched by the Widgets Board COM activation): untested.

---

## 8. Getting a widget from the PC to a phone

### Takeaway
The QR + one-shot LAN download flow from the Linux plan is technically the same on Windows; the Windows-specific risk is the inbound-firewall prompt for a listening socket, which I could not confirm at a primary source. No public programmatic route through Phone Link or Quick Share was found.

### Cited Findings
- **Planned flow [source, repo doc dated 2026-11-16]:** `scriptwidget send`: pack `.swt`, serve it once on the LAN with a one-time token, show a QR containing `scriptwidget://import?...` with URL, size and SHA-256; the phone app downloads, verifies and runs the existing untrusted-archive import flow; needs a new `import` URL handler in both phone apps. Fallback: `pack` and transfer manually. — `docs/linux/plan.md` §5
- **Existing phone-side pieces [source, same doc]:** Android opens `.swt` and registers `scriptwidget://`; iOS registers `scriptwidget://` (handled URLs not verified there); iOS has Web Studio pairing with a six-digit code on the LAN (`Web/preview-engine/src/cli/deviceSync.js`); Android equivalent not verified. — `docs/linux/plan.md` §5
- **Quick Share for Windows exists as a consumer app [official product pages via search summary]:** Google's Quick Share app targets 64-bit Windows 10 and up; regional pages conflict on ARM support (one says ARM not supported, another says newly available on ARM with Windows 11); sending is by drag-and-drop or the right-click "Send with Quick Share" entry. No developer API is described. — [android.com Quick Share app](https://www.android.com/better-together/quick-share-app/); [Google support changelog](https://support.google.com/product-documentation/answer/14185560?hl=en)

### Inferences
- LAN server on Windows: binding a TCP listener makes Windows Defender Firewall show a first-use "allow access" prompt for an unpackaged exe (and adding the allow rule needs elevation), while a block is silent if the user dismisses it **[unverified]**. For an MSIX-packaged app the manifest capability `privateNetworkClientServer` is the declared way to accept inbound connections on private networks **[unverified]**. Either way, networks classified "Public" (the Windows default for new Wi-Fi) will block inbound connections. This makes "PC listens, phone connects" less reliable on Windows than on Linux.
- Reversing the direction avoids the firewall entirely: the **phone** listens and the PC connects out. That is exactly the existing iOS Web Studio pairing (six-digit code, PC pushes files). On Windows the first-choice design is therefore "pair with the phone app, PC pushes the package", with QR used only to carry the phone's address + code to… nothing (the PC has no camera flow) — so the pairing code typed on the PC is the practical UX. Needs the Android side to gain the same endpoint.
- Zero-network alternatives, in increasing friction: (a) QR that *embeds* a small package (a compressed single-file widget fits in a QR only up to ~2–3 KB **[unverified]**, so only tiny widgets); (b) save `.swt` into a cloud folder the phone also has (OneDrive is preinstalled on Windows 11; iCloud Drive for Windows exists) and open it from the phone's Files app — works today on Android per the plan, no app change; (c) user sends the `.swt` with Quick Share / Phone Link / chat manually.
- `scriptwidget://` on Windows itself: registering the protocol (MSIX `windows.protocol` extension or `HKCU\Software\Classes`) lets Gallery web pages and Web Studio (`https://asp.run/scriptwidget/studio/`) hand a widget to the Windows app; same trust rules as the phone import (user-initiated, untrusted archive pipeline). **[inference]**
- Phone Link: **[unverified]** no public third-party API for pushing a file to the paired phone; not confirmed in this session.

### Gaps
- Exact Windows 11 24H2/25H2 firewall behaviour for (i) unpackaged exe first listen, (ii) MSIX app with `privateNetworkClientServer`, on Private vs Public network profiles: **prototype**; I found no primary source in this session.
- Whether Quick Share for Windows or Phone Link expose a share-target or CLI that an app can invoke with a file: not found; the Windows Share UI (`DataTransferManager`) might list them as targets **[unverified]** — worth a 10-minute check on a real machine, since "Share → Quick Share / Phone Link" would give a no-code path.
- iOS `scriptwidget://` handled routes and Android pairing endpoint: flagged unverified in the Linux plan and still unverified.

---

## 9. Repository reuse and the value of a shared Rust core

### Takeaway
Everything that makes a widget *behave* the same (kernel, layout/renderer, package validation, parity trees, QuickJS host shim, QuickJS-NG source) is platform-neutral JavaScript/C already running outside a browser on Android; the only substantial non-reusable piece is the ~1,400-line Kotlin painter. If the Linux plan's Rust daemon is built first, Windows needs roughly a window host, a Widgets Board provider, an ICU bridge and packaging on top of it.

### Cited Findings (all [source], this repository, read 2026-11-16)
- **Kernel:** `Web/preview-engine/src/kernel.js` (1,385 lines) reaches the platform only through a `host` object: `evaluateScript`, `compiledImport`, `readFile`, `fileExists`, `parseXML`, `log`, `defer`, `timeout`, `supportScript`, `installNativeAPIs`, `finish`. — `Web/preview-engine/src/kernel.js`
- **Platform id:** the kernel's default platform is `"ios"` and is supplied by the host (line 538 per the Linux plan). — `docs/linux/plan.md` §4.3
- **Renderer:** `render/renderer.js` 1,337 lines + `layout.js` 664 + `props.js` 370 + generated symbol metrics/icons; text only through the injected measurer. — `Web/preview-engine/src/render/`
- **QuickJS render entry:** `Android/core/src/main/js/render/entry.mjs` (164 lines) has no Android-specific code per the Linux plan and imports the shared renderer by relative path. — `Android/core/src/main/js/render/entry.mjs`
- **QuickJS host shim:** `android-host.js` (266 lines) removes native entry points, supplies the `Intl` subset and the boot function; the Linux plan calls it "mostly platform-independent, extract into a shared file". — `Android/core/src/main/js/android-host.js`
- **Engine source:** QuickJS-NG 0.18.0 amalgamated sources (`quickjs.c`, `libregexp.c`, `libunicode.c`, `dtoa.c`, headers) vendored under `Android/core/src/main/cpp/quickjs`; JNI glue is one 336-line C file. — `Android/core/src/main/cpp/`
- **Package code:** `Web/preview-engine/src/package/` (`archive.js`, `manifest.js`, `index.js`) plus `packageFiles.js`, `compiler.js`, `timeline.js`, `timeZones.js`. — `Web/preview-engine/src/`
- **Acceptance corpus:** `Web/preview-engine/test/parity/native-trees.json` (the Linux plan counts 164 trees) plus ~18 further tree files (weather, timeline, wallpaper, live-activity, etc.). — `Web/preview-engine/test/parity/`
- **Browser host:** `Web/preview-engine/src/browser/` (`sandboxFrame.js` 114 lines, `executorBootstrap.js` 113, `client.js` 104, `compilerBootstrap.js` 30): an opaque-origin, no-network iframe that owns a compiler Worker and one executor Worker per run and enforces the deadline by terminating the Worker. — `Web/preview-engine/src/browser/sandboxFrame.js`
- **Painter:** 1,379 lines of Kotlin bound to `android.graphics`/`android.text`. — `Android/core/src/main/java/com/everettjf/scriptwidget/core/render/`
- **Android's own conclusion on reuse:** bitmap + click overlay was chosen as the baseline backend ("C. whole bitmap + click mask … high fidelity (static) … all versions"). — `docs/android/android-port-research-and-plan.md` §3.2
- **Linux plan scope and estimates:** Rust CLI + daemon with package store/validation, QuickJS kernel + renderer, painter → PNG + click regions, timeline scheduler, restricted network/storage/file modules, Unix-socket protocol; phases: 0 (1–2 weeks), CLI (2–3), daemon + plugin (2–3), send-to-phone (2–3), release (1–2), explicitly "rough estimates with nothing to calibrate against". — `docs/linux/plan.md` §4, §8
- **Contract rules that bind a new platform:** Package 2.0 unknown keys fail closed; network needs `network` + `networkDomains`; private/local hosts rejected; `$file` package-relative; `$storage` namespaced and bounded; archive limits and transactional install; every difference documented per platform; changes to `Web/preview-engine` need its own tests plus the Android suites. — `AGENTS.md`

### Inferences
**Reuse classification for Windows**

| Asset | Windows status |
| --- | --- |
| `kernel.js`, `render/*`, `package/*`, `timeline.js`, `compiler.js`, parity trees, templates, Gallery/Skills/plugin JSON contracts | Unchanged |
| `entry.mjs` recording document, `android-host.js` (minus Android API stubs → Windows `[unsupported_platform]` table) | Unchanged after the extraction the Linux plan already schedules |
| QuickJS-NG 0.18.0 C sources | Unchanged source; new build (MSVC/clang-cl, x64 + ARM64) |
| `scriptwidget_jni.c` | Not reusable as is (JNI), but it is the specification for the ~15 engine calls the Rust FFI must expose |
| Kotlin painter | Port (once, in Rust, shared with Linux) — the dominant new work |
| Intl bridge | New native side: Windows `icu.dll` C API (Linux: system ICU/ICU4X); same JS shim |
| Web Studio (`Web/studio/`) | Reusable as the management/authoring UI inside a webview window, or simply linked to as the hosted site |
| Browser host (`src/browser/`) | Reusable only on the WebView2 route or inside the management UI preview |
| Swift runtime (`Shared/ScriptWidgetRuntime`), Kotlin host/APIs, Compose app | Not reusable; they are behavioural references and test-case sources |
| MCP server + creator Skill (`Web/preview-engine/bin/scriptwidget-mcp.mjs`), Mac CLI command design | Reusable as on Linux |

**What a shared Rust core saves.** Mapping the Linux plan's components onto Windows:

| Component | Shared with Linux? | Windows-only work |
| --- | --- | --- |
| Package store, manifest/archive validation, path canonicalisation | Yes, with Windows path cases added (drive letters, UNC, reserved names like `CON`, alternate data streams `:`, trailing dots/spaces, case-insensitive FS, 8.3 names) — more security tests | Tests |
| QuickJS embedding, kernel boot, limits | Yes | MSVC build |
| Renderer-in-QuickJS + painter → bitmap + hit regions | Yes | Font discovery/fallback tuning; possibly a DirectWrite text backend |
| Timeline scheduler | Yes (logic) | Power/resume/occlusion signals |
| HTTP client with private-host rejection, `$storage`, `$file` | Yes | None beyond tests |
| CLI (`new/check/render/pack/add/doctor`) | Yes | Console/Unicode quirks |
| IPC | Protocol yes | Named pipe instead of Unix socket (ACL to the current user) |
| Display surface | No (Omarchy QML plugin) | Layered-window host, tray, multi-monitor/DPI, Show-Desktop handling |
| Widgets Board | No | MSIX COM provider, Adaptive Card generation |
| Sandbox | No (Landlock/seccomp) | Job object + LPAC |
| Send to phone | Mostly | Firewall/pairing direction |
| Distribution | No (AUR) | MSIX signing, Store/winget, StartupTask |

- By component count, the Linux plan's phases 1–2 minus the QML plugin (its two largest phases, 4–6 of its ~8–13 estimated weeks) carry over to Windows unchanged; the Windows-only list above is mostly platform glue, the Widgets Board provider being the piece with real uncertainty. I cannot give a calibrated percentage; "the daemon/CLI/painter are written once; Windows adds a host shell, a provider, a sandbox and packaging" is the defensible statement.
- Conversely, choosing WebView2 or a Direct2D painter for Windows forfeits the painter sharing (the largest item) and leaves only the JS and QuickJS embedding shared; choosing WebView2 additionally forfeits the QuickJS sharing and adds a third JS engine to keep in parity.
- Sequencing consequence: the painter decision in Linux phase 0 (tiny-skia + cosmic-text vs Cairo + Pango) should be taken with Windows in the room. Cairo + Pango is a poor Windows dependency (GLib stack, fontconfig); if Windows is a goal, the Linux bake-off should be tiny-skia + cosmic-text vs Skia, both of which are cross-platform.

### Gaps
- `android-host.js` and `entry.mjs` were skimmed (grep), not read line by line; the claim that they are platform-neutral rests on the Linux plan plus the import list.
- No size/complexity estimate for the Rust painter exists beyond "about the size of the Kotlin one"; Kotlin leans on `android.graphics` for blur, 3D camera, text layout and GIF decode, which Rust must assemble from crates.
- Windows-specific API mapping (`$music` → SMTC/GlobalSystemMediaTransportControls, `$notifications` → app notifications, `$weather`/`$location`, calendar) was not researched; assume the Linux v1 table (core APIs only) as the Windows v1 scope.

---

## 10. Recommendation and the list of unknowns that need a prototype

### Takeaway
Recommended architecture: one Rust core shared with Linux (QuickJS-NG 0.18 from the vendored source, shared JS kernel/renderer, Rust painter producing BGRA bitmap + hit regions) running in a sandboxable runner process; a small always-on Win32 host (tray + bottom-most layered windows, Rainmeter-style z-order handling) that only blits bitmaps and forwards action indices; an MSIX package that adds a StartupTask and a Widgets Board COM provider reusing the same bitmaps; and a management window that is the existing Web Studio in an on-demand webview (Tauri or plain WebView2), closed when not in use. WebView2 is deliberately kept out of the all-day path.

### Cited Findings
- The bitmap + click-mask architecture is already the shipped Android baseline and the planned Linux design. — `docs/android/android-port-research-and-plan.md` §3.2; `docs/linux/plan.md` §4
- WebView2 keeps a multi-process group per user data folder and a continuously running app stays on an outdated runtime until it releases the environment. — [Process model](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/process-model); [Distribution](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution)
- Widget providers must be packaged apps; packaged desktop apps get consent-free StartupTask. — [Widget providers](https://learn.microsoft.com/en-us/windows/apps/develop/widgets/widget-providers); [StartupTask](https://learn.microsoft.com/en-us/uwp/api/windows.applicationmodel.startuptask)
- The desktop-pinning technique changed in a 24H2 servicing build and both reference projects had to branch on it. — [Rainmeter System.cpp](https://raw.githubusercontent.com/rainmeter/rainmeter/master/Library/System.cpp); [Lively WinDesktopCore.cs](https://raw.githubusercontent.com/rocksdanister/lively/core-separation/src/Lively/Lively/Core/WinDesktopCore.cs)

### Inferences
**Why this route against the five requirements**
- (a) untrusted JS with limits: same QuickJS limits as Android, plus job object/LPAC available later; no dependence on Chromium.
- (b) fidelity incl. CJK/emoji: the open risk; mitigations are a DirectWrite text backend or Skia. WebView2 would win on this axis alone.
- (c) desktop + Widgets Board: one bitmap pipeline feeds both.
- (d) timeline + taps: own scheduler; taps are index-only, resolved from the host's saved action table (same rule as Android list rows and the Linux socket).
- (e) memory: one small host process, runner alive only while rendering (or one warm runner), no browser processes at idle.

**When to pick WebView2 instead:** if the phase-0 text gate fails for both cosmic-text and a DirectWrite backend, or if Windows must ship before the Linux core exists and the measured idle footprint of a single shared, hidden WebView2 (rendering all widgets to bitmaps and then suspended) proves acceptable.

**Prototype list (real Windows 11 24H2 and 25H2 machines; nothing below is verified)**

Desktop host
1. Bottom-most `WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE` window with `UpdateLayeredWindow`: stays behind normal windows, above icons, clickable, no focus steal, absent from Alt-Tab/taskbar.
2. Win+D, the Show Desktop corner, Win+M, Aero Peek, Task View: does the window survive; implement and test the Rainmeter-style detection on build ≥ 26100.2454 and on the newest 25H2/2026 build.
3. Explorer restart, sign-out/in, sleep/resume, display topology change, RDP session.
4. Virtual desktops: visible on all or one; behaviour when switching.
5. Mixed-DPI multi-monitor at 100/125/150/175 %: PerMonitorV2, bitmap rendered at physical pixels, drag between monitors, `WM_DPICHANGED` re-render; text sharpness at fractional scales.
6. HDR display: colour/brightness of an sRGB layered window; whether a composition surface is needed.
7. Full-screen game/video in front: occlusion detection and refresh pause.

Engine and Intl
8. Build vendored QuickJS-NG 0.18.0 with MSVC and clang-cl for x64 and ARM64; run all parity trees byte-for-byte; verify memory-limit and interrupt behaviour (uncatchable OOM/timeout).
9. rquickjs on `x86_64-pc-windows-msvc` vs. a hand-written FFI over the vendored sources.
10. `icu.dll` bridge against the Android `Intl` test set; record ICU version per Windows build.

Rendering
11. Rust painter text gate on Windows fonts: 10 representative templates incl. Simplified/Traditional Chinese, Japanese, Korean, emoji (ZWJ sequences, flags, skin tones), charts; diff against Web Studio screenshots; check Han-variant fallback by locale and Segoe UI Emoji colour rendering in swash.
12. If 11 fails: DirectWrite measurer + glyph-run drawing into the same pixmap; re-run the gate.
13. Blur/shadow, 3D transform, blend modes, GIF frames in tiny-skia vs. the Kotlin painter's output.
14. Baseline numbers: host private working set with 1, 5, 10 widgets; render time per widget; runner process start cost.
15. Control experiment: one hidden WebView2 (shared environment) running the browser renderer — private memory of every `msedgewebview2.exe` at idle, with `MemoryUsageTargetLevel.Low`, and after `Close()`; cold-start time; transparent background inside a layered bottom-most window.

Widgets Board
16. Minimal MSIX provider (C# or C++/WinRT first; then try Rust) showing one image-only card.
17. Image delivery: `data:` URI in `Image.url` and `backgroundImage`; maximum payload; `ms-appdata`/file URIs; quality after host scaling; pixel size per `$host.widgetSize` and DPI.
18. Update throttling: push `UpdateWidget` every 1 s / 10 s / 60 s and observe; behaviour when the Board is closed; `Activate`/`Deactivate` cadence; provider process lifetime.
19. Taps: `selectAction` on images/containers with `Action.Execute`; sliced-grid hit regions; `isUserContextAuthenticated` on a local account; header set to `null`.
20. Static vs. dynamic `Definition`s: can one definition with `AllowMultiple` serve arbitrary user packages via per-instance customization state.
21. Light/dark double render switched by `$host.hostTheme`.

Background, sandbox, transfer
22. StartupTask enable/disable round trip; behaviour after the user disables it.
23. Overnight Modern Standby log: timer firings, wake behaviour, battery drain with EcoQoS on vs. off; Energy saver on.
24. LPAC runner with zero capabilities + job object: can it load fonts and `icu.dll`, read package files through the broker pipe only; memory-limit kill behaviour; start-up cost.
25. Firewall: first-listen prompt for unpackaged exe vs. MSIX with `privateNetworkClientServer`, on Private and Public network profiles; then the reversed direction (PC connects to phone pairing endpoint).
26. Windows Share UI: does it offer Quick Share / Phone Link as targets for a `.swt` file.
27. `scriptwidget://` protocol activation and `.swt` file association from an MSIX package.

### Gaps
- Not researched in this session (out of time budget), so no claims are made: Tauri 2 version/status; WinUI 3 Native AOT and package size; WPF and Flutter status; Win2D status; DirectComposition specifics; ChakraCore status; Phone Link API; Quick Share developer surface; Windows 11 25H2-specific shell changes beyond what Rainmeter/Lively source shows; Microsoft Store policy on apps that interpret downloaded script (the platform-rules researcher's area).
- Version/date facts I could not read at a primary source: QuickJS-NG latest release; rquickjs, tiny-skia, cosmic-text, skia-safe current versions; Rainmeter's latest version and the exact release that fixed 24H2 Win+D (sources conflict: 4.5.22 vs a 4.5.18-dated note); Lively's latest version.
- The Windows App SDK table reads "2.0 … latest patch 2.6.5" on the release-channels page; I report it as written and did not open the 2.x release notes to see what changed between 2.0 and 2.6.
