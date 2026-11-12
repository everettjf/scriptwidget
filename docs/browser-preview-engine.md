# Browser preview engine

Status: all stages of the [research plan](browser-widget-preview-research.md)
are implemented as of 2026-10-17: the JavaScriptCore-compatible engine
(Stage 0), the SwiftUI-calibrated renderer (Stage 1), the
[Web Studio](web-studio-browser.md) website (Stage 2), the preview CLI and MCP
server (Stage 3), and broader parity for icons, gauges, charts, grids, dates,
animations, Lock Screen and iPad families, and rendering modes (Stage 4). This
page records what was built, what was measured, and the known differences.

The engine lives in [`Web/preview-engine`](../Web/preview-engine); the website
lives in [`Web/studio`](../Web/studio).

## Decisions

- **Product shape:** a public website on GitHub Pages. Users design and
  preview in the browser, then install the package on iPhone.
- **Promise:** the browser exposes the standard global `Promise` and emits a
  `compat.promise` warning when a script names `Promise`. The native shim is
  left unchanged for now; none of the 151 bundled `.jsx` files construct a
  `Promise` or call `.catch`, `.finally`, or `Promise.all`. `fetch`, `$http`,
  `$health`, and `$location` still return the native then-only object, so
  `fetch(url).catch(...)` fails in the browser exactly as it does on iPhone.
- **Icons:** 283 SF Symbol names map to 252 look-alike [Lucide](https://lucide.dev)
  icons (ISC license, generated subset with the license in
  `src/render/icons.generated.js`). Unmapped names show a placeholder and an
  `icon.unmapped` warning. No Apple symbol artwork is distributed.
- **Install flow:** the website exports a validated `.swt`. On iPhone, the Web
  Share sheet hands it to the existing ScriptWidget share extension; elsewhere
  the file is downloaded and sent with AirDrop, iCloud Drive, or email.
- **Hosting:** GitHub Pages serves the Studio at `/studio/` next to the
  existing `site/`; the workflow builds it from source on every relevant push
  to `main`.
- **Font weight properties:** `fontWeight`, `fontDesign`, and the older
  `weight` were documented but ignored natively; the native font modifier now
  applies them (see below).
- **Tree JSON:** the canonical serialization is a test artifact
  (`BrowserPreviewParityTests.swift` and `kernel.js`), not part of the runtime
  contract.

## Architecture

```text
Studio page (GitHub Pages, CSP script-src 'self')
  └─ <iframe sandbox="allow-scripts" src="sandbox.html">  opaque origin, own CSP, connect-src 'none'
       ├─ compiler Worker (blob:)               bundled Babel, prepares the package
       └─ executor Worker (blob:), one per run  kernel + user code, terminated at the deadline
```

Pages without a CSP (the demo and the CLI's render page) may pass the same
document as `srcdoc`. A `srcdoc` frame inherits the parent's policy, so the
Studio loads `sandbox.html` by URL to keep its own policy strict.

| File | Role |
| --- | --- |
| `src/kernel.js` | Self-contained execution kernel evaluated inside the user realm. Mirrors `internalExecuteJavaScriptForWidget`, `resolveWidgetElementTree`, `validateElementTree`, host APIs, and the JavaScriptCore bridge. |
| `src/contract.js` | Limits, API version, compiler fingerprint, error categories, `$main` wrapper. `test/contract.test.js` checks them against the Swift sources. |
| `src/compiler.js`, `src/prepare.js` | Babel wrapper. The entry is wrapped in `$main`; every script file is precompiled unwrapped so `$import` stays synchronous and Babel never enters the user realm. |
| `src/node.js`, `src/nodeWorker.js` | Node host for tests and the future CLI: one `worker_threads` Worker per run, user code in a fresh `vm` context. Not a security boundary. |
| `src/browser/*` | Browser host: sandboxed frame, compiler and executor Workers, parent-page client. |
| `scripts/build-browser.mjs` | Generates `dist/sandbox-sources.js`, copies the support scripts, and writes the browser parity corpus. |

Run `npm test` in `Web/preview-engine`. For the browser check, run
`node scripts/build-browser.mjs`, serve `Web/preview-engine` (the
`preview-engine` entry in `.claude/launch.json`), and open `/demo/`.

## Native semantics reproduced

These were measured against JavaScriptCore on macOS 27, not inferred:

| Input crossing `$element.createElement` | Native result |
| --- | --- |
| `undefined` prop | key dropped |
| `null` prop, `null`/`undefined` array member or child | `NSNull` (`null`) |
| number | `NSNumber` double; `1` and `1.0` are identical |
| boolean | `CFBoolean`; `<text>{true}</text>` renders `1` natively |
| function, `Map`, `RegExp`, class instance | dictionary of own enumerable properties (functions become `{}`) |
| `Date` | `NSDate` |
| primitive props object | `TypeError: Cannot convert primitive to NSDictionary` |
| array as props | dictionary keyed `"0"`, `"1"`, … |

Function components receive the bridged dictionary, so function-valued props
are `{}` inside the component. JavaScriptCore has no `setTimeout`,
`setInterval`, `queueMicrotask`, `structuredClone`, `TextEncoder`, `URL`, or
`atob`; `console` has only `log` and `error`. The browser realm hides them.

Execution flow matches the native host: `util.js`, then Moment when the
transpiled code contains `moment(` or `moment.`, then the entry, then `$main()`.
A missing `$main` is `undefinedRender`. If the transpiled code does not contain
the text `$render`, the result is a `#UI Not Found#` text element. The first
`$render`, `$error`, or uncaught exception completes the run, and the first
completion is captured deterministically. Babel syntax errors are reported as
`scriptException` (category Runtime), because the native compiler receives
`undefined` output and then reports the exception.

## Parity results

`BrowserPreviewParityTests.swift` runs every package under
`Script.bundle/{api,component,template}` and `Gallery/widgets` with a shared
[prelude](../Web/preview-engine/test/parity/prelude.js) that fixes the clock,
randomness, `$device`, and `$system`, then writes the canonical tree JSON to
`Web/preview-engine/test/parity/native-trees.json`. Packages that need live
data (`fetch`, `$http`, `$location`, `$health`, `$dataSource`) are skipped on
both sides.

| Host | Engine | Result |
| --- | --- | --- |
| macOS 27 `ScriptWidgetRuntimeTests` | JavaScriptCore | reference: 118 packages, 100 trees, 18 skipped |
| iOS 27.0 Simulator (iPhone 17) `ScriptWidgetRuntimeTests` | JavaScriptCore | identical to the reference |
| Node 24 (`npm test`) | V8 | 100/100 byte-identical |
| Claude browser pane (Chromium) via sandboxed frame | V8 | 100/100 byte-identical; warm edit to tree 13–16 ms; sandbox ready 311 ms |

Regenerate the reference after an intentional runtime change:

```bash
TEST_RUNNER_SCRIPTWIDGET_UPDATE_PARITY=1 xcodebuild -project macOS/ScriptWidgetMac.xcodeproj -scheme ScriptWidgetRuntimeTests -destination 'platform=macOS' test -only-testing:ScriptWidgetRuntimeTests/BrowserPreviewParityTests
```

JavaScriptCore reads the process time zone once, so the native comparison
skips itself on a machine whose time zone differs from the recorded one. The
Node and browser comparisons run in the recorded zone.

## Isolation results

Probes run as user code in the sandboxed executor (Chromium):

| Probe | Result |
| --- | --- |
| `XMLHttpRequest`, `importScripts`, `postMessage`, `indexedDB`, `self`, `navigator`, `setTimeout`, `Babel`, `WebSocket` | all `undefined` |
| real `fetch` reached through the prototype chain, `no-cors` | blocked by CSP; the same request from the parent page succeeds (control) |
| real `importScripts` of an HTTPS URL through the prototype chain | blocked (`NetworkError`) |
| nested `Worker` | unavailable |
| frame `postMessage` through the prototype chain | unreachable; the frame also accepts only one schema-checked result per run |
| `while (true) {}` | Worker terminated, `resourceLimit` |
| `eval("1 + 1")` | `2` (`'unsafe-eval'` is allowed inside the opaque frame for JavaScriptCore parity) |

The CSP, not the global scrubbing, is the security boundary; scrubbing exists
for parity. The same probes pass in iOS 27 Safari (see the verification
matrix), and in Chromium, Firefox, and WebKit on Linux and Windows (the Web
Browsers workflow).

## Known differences

- Error message text differs between engines (`ReferenceError: x is not
  defined` versus `Can't find variable: x`). Compare error kinds and categories,
  not messages.
- The browser stops runaway JavaScript by terminating its Worker. Native
  Runtime 1.2 uses only public JavaScriptCore APIs: Babel adds sticky cancellation
  checks to loop iterations, function entries, catch blocks and finally blocks.
  The compiler fingerprint invalidates older uninstrumented caches. Native
  built-ins (for example a single expensive regular expression) and Babel's
  parser cannot be preempted by these checks; the native deadline is cooperative,
  not a hard VM interruption.
- Native Runtime 1.2 disables `eval`, `Function`, and async/generator function
  constructors, including prototype constructor access, so dynamic source cannot
  bypass cancellation checks. Migrate dynamic source to package files loaded with
  `$import`, or use ordinary functions and `JSON.parse` for data. The browser
  preview still permits dynamic code in its disposable Worker. The identifier
  `__scriptWidgetCheckExecution` is reserved and `with` statements are unsupported.
- Built-ins differ by OS: iOS versions ship different JavaScriptCore releases,
  and the browser may offer newer `Array`/`Object` methods. The parity reference
  is macOS 27 and matches the iOS 27.0 simulator; older iOS releases and
  physical devices have not been compared.
- `$xml.parse` reports "not available in the web preview yet" because Workers
  have no `DOMParser`; a bounded parser matching `ScriptWidgetXMLParser` is
  pending.
- Props with object cycles fail with a bounded-depth error in the browser.
- `Intl` output depends on the host locale; the reference recorded `en-US`.

## Stage 1: visual renderer

Status: core renderer complete, 2026-10-17. `src/render/` turns the canonical
tree JSON into a widget-sized DOM element. Try it with `npm run build`, then
serve `Web/preview-engine` and open `/demo/preview.html`.

| File | Role |
| --- | --- |
| `src/render/props.js` | Ports of the native property readers and parsers: string-only `padding`, ARGB 8-digit hex, `frame` modes, fonts, points, gradients. |
| `src/render/layout.js` | SwiftUI-style propose/size/place layout: stacks give space to the least flexible child first and spacers only the leftover; text wraps with the browser's line breaker and truncates by available height. |
| `src/render/renderer.js` | Element builders in native modifier order (padding, frame, background, corner, clip, opacity, rotation, shadow), the widget container, and drawing with absolutely positioned elements. |
| `src/render/coverage.js` | Coverage matrix; published as [browser preview coverage](browser-preview-coverage.md). |
| `scripts/compare-snapshots.mjs` | Renders every package in headless Chrome and compares it with native iOS snapshots. |

### Calibration

`BrowserPreviewParityTests.testExportNativeSnapshots` renders the corpus and
the cases in `test/render/cases.json` on the iOS 27 simulator the way the
widget composes its root (root `background` as container background, root
view centered) at the 393-point iPhone sizes: small 158×158, medium 338×158,
large 338×354.

```bash
TEST_RUNNER_SCRIPTWIDGET_EXPORT_SNAPSHOTS=1 xcodebuild -project iOS/ScriptWidget.xcodeproj -scheme ScriptWidgetRuntimeTests -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:ScriptWidgetRuntimeTests/BrowserPreviewParityTests/testExportNativeSnapshots
```

Measured from those snapshots and encoded in the renderer:

- Single-line `Text` height is `ceil(size × 1.1934 × 2) / 2`: 20.5 for body, 41 for
  largeTitle. Additional lines advance by the Dynamic Type leading (22 for body).
- HStack default spacing is 8. In a VStack, text to text is the leading minus
  the natural height (2 for body, 1 for title); text to other views is about
  `8 + 0.18 × font size`; other views are 8 apart. Backgrounds keep a view's
  spacing behavior; padding and frames reset it. An HStack takes the largest
  text edge of its children.
- Spacers reserve their 8-point minimum and only take leftover space.
- Truncated text reports the whole offered width.
- Named colors are the iOS 26 system palette (blue `#0088FF`, red `#FF383C`, …);
  `secondary` is `rgba(60,60,67,0.6)`. Button labels default to the accent blue.

### Results

`npm run compare` against the native snapshots (pixels differing by more than
48 of 255 in any channel, Chrome on macOS with SF fonts):

| Set | Count | Median | ≤1% | ≤3% | ≤5% | ≤10% | ≤20% |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Corpus (100 packages × 3 sizes) | 300 | 1.79% | 105 | 192 | 242 | 283 | 296 |
| Calibration cases | 30 | 0.63% | 20 | 26 | 28 | 30 | 30 |

At Stage 1, `gauge`, `chart`, and grids were placeholders and SF Symbols were
placeholder glyphs; Stage 4 below replaced them. Smaller differences come from line-breaking choices
in large text (iOS sometimes hyphenates or breaks one word earlier) and
sub-pixel text positioning. On Windows and Linux, fonts fall back from SF Pro,
so widths and wrapping can differ more than these numbers.

### Results after Stage 4

The latest `npm run compare` (after icons, gauges, charts, grids, animations,
and the native font weight fix, with snapshots re-exported):

| Set | Count | Median | ≤1% | ≤3% | ≤5% | ≤10% | ≤20% |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Corpus (100 packages × 3 sizes) | 300 | 1.87% | 102 | 193 | 244 | 288 | 298 |
| Calibration cases (incl. dark, gauges, charts, grids, accessories) | 40 | 0.84% | 22 | 32 | 36 | 39 | 40 |

The largest remaining differences are animated templates (see Stage 4) and
Swift Charts styling.

### Native behaviors worth knowing

The renderer reproduces these because they are what users see on iPhone:

- `padding={10}` (a number) is ignored; only strings like `"10"` apply.
- `frame="max,20"` sets only the height; the width is not expanded.
- `#fff` (3-digit hex) is nearly transparent black; 8-digit hex is ARGB.
- Until 2026-10-17, `weight`, `fontWeight`, and `fontDesign` were not read by
  any native builder even though Studio completions advertised them; the
  bundled templates used `weight` 76 times with no effect. They are now
  applied by `ScriptWidgetAttributeFontModifier` (`fontWeight` wins over the
  older `weight`), on iPhone and in the web preview.
- An invalid color falls back to the shape's default fill (black in light mode).

## Stage 2: Web Studio

See the user guide, [Web Studio in the browser](web-studio-browser.md).

| File | Role |
| --- | --- |
| `Web/studio/src/App.tsx` | React app: projects, files, preview controls, templates, import, export, install. Built with shadcn/ui components (Radix primitives, Tailwind CSS 4) in `src/components/ui`. |
| `Web/studio/src/components/*.tsx` | Top bar, sidebar, editor pane, preview pane (Problems/Console/Package/Mock Data tabs), and dialogs. |
| `Web/studio/src/hooks/*.ts` | `useProjects` (drafts and debounced saves), `usePreview` (sandbox runs and rendering, stale results dropped), `useConfirm`, `useColorScheme`. |
| `Web/studio/src/editor.ts` | CodeMirror 6 with the Studio completions, diagnostics, and hover from `Editor/editorfe`. |
| `Web/studio/src/store.ts` | IndexedDB drafts with an in-memory fallback and a visible warning when storage is unavailable. |
| `Web/studio/vite.config.ts` | Generates `sandbox.html`, copies the runtime scripts, and builds `templates.json` from the 70 bundled templates and the Gallery. |
| `src/package/manifest.js` | Ports of `ScriptWidgetPackage.readManifest` (strict keys, Codable types) and `WidgetPackageManifestValidator`. |
| `src/package/archive.js` | Port of `ScriptPackageArchivePreflight`, extraction with the native root detection, and stored-ZIP export under the package directory. |

The Studio is written in strict TypeScript; `npm run build` typechecks before
bundling. The engine stays plain JavaScript because it runs directly in Node
and is concatenated into the sandbox; `.d.ts` files beside its public modules
(`src/types.d.ts`, `browser/client.d.ts`, `render/*.d.ts`, `package/*.d.ts`)
type it for the Studio. `scripts/smoke.ts` (headless Chrome: starter,
templates, `.swt` import, live editing, phone layout) and
`scripts/cross-browser.ts` (Playwright Chromium, Firefox, WebKit) run on Node
24 without a build step.

A present but malformed `widget.json` fails closed in the browser. Package
export is checked natively: `BrowserPreviewParityTests.testWebExportedPackageImportsNatively`
imports `test/fixtures/web-export.swt` (written by the web export code) with the
native preflight, SSZipArchive extraction, manifest validator, image lookup,
and execution.

## Stage 3: CLI and MCP

```bash
node Web/preview-engine/bin/scriptwidget-preview.mjs path/to/MyWidget --family small --output preview.png --diagnostics preview.json
```

- Runs the package in headless Chrome's sandboxed runtime frame (not in the Node
  process) and writes a PNG plus diagnostics: `sourceHash` (SHA-256 of every
  package file), size, fixtures hash, `engineVersion`, `compilerFingerprint`,
  timings, logs, validation issues, and the resolved tree.
- A failed render deletes the previous PNG so a stale image is never mistaken
  for the current edit. `--watch` re-renders on change.
- `--device http://<ip>:<port> --pair-code 123456` also pushes the text files to
  an iPhone or iPad running Web Studio (HTTP API v1, entry file last, revision
  checked) and saves the device's native SwiftUI preview as
  `preview.native.png`, rendered at the size selected in the app's preview.
  Binary resources are not part of that API and are reported as skipped.
- Debug builds launched with `-WebStudioAutoStart` open Web Studio and log
  `Web Studio QA pairing: port … code …`, so the loop can run unattended in the
  simulator: `xcrun simctl launch booted com.everettjf.scriptwidget -WebStudioAutoStart`,
  then read the code with `xcrun simctl spawn booted log show --last 1m --predicate 'eventMessage CONTAINS "Web Studio QA pairing"'`.
- `bin/scriptwidget-mcp.mjs` is a stdio MCP server with
  `render_widget_preview` (image plus diagnostics), `validate_widget_package`,
  and `export_widget_package`. Package paths are confined to the working
  directory (or `SCRIPTWIDGET_MCP_ROOTS`).

```bash
claude mcp add scriptwidget -- node Web/preview-engine/bin/scriptwidget-mcp.mjs
```

## Stage 4: broader parity

- Gauges follow `MineGaugeView`: segment arcs, round end caps, needle, and the
  native quirk that the default label is always `60%`. System gauge styles are
  approximated.
- Charts draw Swift Charts marks (bar, stacked bar, line, point, area, rule,
  Gantt) with 1/2/5 tick steps, grid lines, and a category legend.
- Lazy grids implement fixed, flexible, and adaptive tracks.
- Clock-hand animations rotate at the current time (hour, minute, second,
  custom period, time zone, anchor) and swing animations move with CSS.
  The native in-app snapshots are static because the animation modifier only
  runs in the widget target, so animated templates differ from them by design.
- Lock Screen families (circular, rectangular, inline) and an iPad profile
  (extra large, extra large portrait) are available; accented and vibrant
  rendering modes are approximated, honoring `widgetAccentable`.
- Dates use the real clock like the widget and the native `date` names
  (`now`, `tomorrow`, `start of today`, `+3h`, `-2d`, or milliseconds).
- SF Symbols ending in `.fill` draw their look-alike icon solid; long words that
  do not fit a line are hyphenated like UIKit, carrying at least three letters
  to the next line (`ScriptWid-get`); chart category labels that do not fit
  their band are truncated with "…".

## macOS comparison: ScriptWidget Preview

`Tools/ScriptWidgetPreview` is a small macOS app that renders each package
with the native runtime on macOS and with the web engine in a `WKWebView`,
side by side, and measures the difference (see its README). It made it
practical to compare every corpus package on macOS, and it showed that macOS
SwiftUI differs from iOS in ways the iOS-calibrated renderer did not model.
The web engine now has a `macos` device profile (also offered as **Mac** in
Web Studio) that uses these measured macOS 26 behaviors:

- Text styles are smaller (`body` 13 pt, `title` 22 pt, `headline` bold) and
  text lays out on whole points; sized fonts use a measured height table.
- `.primary` is black or white at 84.7% opacity and `.secondary` 49.8% /
  54.9%; dark `gray` is (152, 152, 157); the widget background (`.background`)
  is (46, 46, 46) in dark mode.
- In a `VStack`, text to text adds only the upper font's leading, text above
  another view 0.4729 × size, and a view above text 0.2109 × size, each plus
  a half-point step of about 0.118 × size (iOS uses 8 + 0.18 × size).
- Words wider than the line break between characters without a hyphen, a
  short last-line orphan is pushed down a line ("October / 18, 2026"),
  truncation drops the space before "…", and a narrow column keeps wrapping
  one character per line.
- `<button>` uses the bordered style: a 5-point rounded bezel of 7.45%
  primary around 4 × 12 points of padding, with the label in the primary
  color.
- Swift Charts starts the plot at the top edge and reserves 20 points for x
  labels and 20.5 for y labels.

SF Symbols now use their real proportions on every platform:
`symbolMetrics.generated.js` holds the SwiftUI size of all 281 mapped
symbols, so an `hourglass` is 0.825 em wide instead of 1.2 em.

Results from `--batch` (macOS 27, `WKWebView`, same 48/255 rule):

| Set | Count | Median | ≤1% | ≤3% | ≤5% | ≤10% | ≤20% |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Corpus, iOS metrics at macOS sizes (before) | 300 | 3.23% | 62 | 142 | 190 | 268 | 298 |
| Corpus, `macos` profile (after) | 300 | 0.97% | 153 | 254 | 280 | 296 | 299 |
| Calibration cases (before) | 38 | 1.92% | 15 | 23 | 30 | 36 | 37 |
| Calibration cases (after) | 38 | 0.24% | 30 | 35 | 37 | 38 | 38 |

The iOS comparison did not regress with the shared symbol metrics: corpus
median 1.80% (247/300 within 5%, 299/300 within 20%), cases unchanged at
0.84%. The largest remaining macOS differences are animated or time-based
templates (native clock hands are not captured by `ImageRenderer`), a few
narrow multi-column layouts, and icon artwork.

## iOS recalibration with TextKit as the reference

After the macOS work, the iOS snapshots were re-exported on the iOS 27
simulator (`testExportNativeSnapshots`) and compared again. To pin down line
breaking exactly, TextKit's `.standard` line break strategy served as a
reference: a sweep of 24,441 width, size, and weight combinations
(`Tools/ScriptWidgetPreview/Scripts/line-break-sweep.swift`) showed that
both platforms push a word down only when a two-line paragraph would end in a
single word, the moved line fits, and the first line stays at least 55% as wide
as the new last line ("October / 18, 2026" but "Hello from / GitHub"). The web
rule matches TextKit in 24,420 of those cases. Other fixes from this pass:

- Swift Charts on iOS: the plot starts at the top edge, x labels take 18 pt
  and y labels 19 pt (6 pt after the plot), labels use `caption2` (11 pt) and
  may fill their band (chart renders 16% → about 4%).
- Truncation cuts mid-word and drops the space before "…" ("Hello fr…") on
  both platforms; narrow columns break one character per line.
- Hyphenation skips CJK text and gives up when two letters and a hyphen do
  not fit.
- `<button>` lays out its label views side by side.
- Text is drawn with a 0.5 pt allowance instead of 2 pt, so a 12 pt Chinese
  line no longer fits one more character than the layout measured.

| Set (iOS 27 simulator, Chrome) | Count | Median | ≤1% | ≤3% | ≤5% | ≤10% | ≤20% |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Corpus before | 300 | 1.78% | 104 | 202 | 249 | 291 | 298 |
| Corpus after | 300 | 1.71% | 106 | 207 | 262 | 293 | 298 |
| Calibration cases after | 40 | 0.84% | 22 | 33 | 36 | 40 | 40 |

macOS improved with the shared changes: corpus median 0.94% (280/300 within
5%, 300/300 within 20%). The largest remaining iOS differences are animated or
time-based templates, controls that `ImageRenderer` draws as placeholders
(`toggle`), and how an HStack splits width between two text columns in narrow
small widgets.

## Coverage across every iOS size

The comparison now covers every widget size the iOS app offers, not just
the 393-point iPhone:

| Profile | Families compared |
| --- | --- |
| iPhone 393 pt | small, medium, large, accessoryCircular, accessoryRectangular, accessoryInline |
| iPhone 430 pt | small, medium, large |
| iPhone 375 pt | small, medium, large |
| iPad 1024 pt | medium, large, extraLarge, extraLargePortrait (its small equals the 430-pt small) |

That is 16 sizes × 100 corpus widgets plus the calibration cases (1,649
renders). The native export reads the sizes from `src/render/profiles.js`,
so both sides always agree:

```bash
TEST_RUNNER_SCRIPTWIDGET_EXPORT_SNAPSHOTS=1 TEST_RUNNER_SCRIPTWIDGET_EXPORT_PROFILES=all xcodebuild -project iOS/ScriptWidget.xcodeproj -scheme ScriptWidgetRuntimeTests -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:ScriptWidgetRuntimeTests/BrowserPreviewParityTests/testExportNativeSnapshots
```

```bash
cd Web/preview-engine && npm run build && npm run compare
```

`npm run compare` prints a table per size and writes
`dist/compare-summary.json` with the same statistics per size and per
component tag (every tag the renderer supports is compared at several
sizes). To keep runs deterministic, absolute `<date>` styles use the
parity prelude's clock on both sides (`ScriptWidgetRenderClock`, test-only),
and snapshot runs draw animations and GIFs the way `ImageRenderer` captures
them (clock hands at rest, swing layout at angle 0, the GIF frame its arc
masks expose). Relative timers still follow the real clock.

### Rules measured for this pass

Each rule was measured on the iOS 27 simulator with
`testPrintTextBaselines`, `testPrintTextSpacing` (8× rendering), or the
calibration cases, and applied in the renderer:

- First baseline at the SF ascent (0.9521 × size on iOS; a measured
  whole-point table on macOS), corrected for each browser's rounding.
- Line pitch: a sized font advances by its natural height (size × 1.1934);
  a text style by its style line height.
- VStack spacing: text to text adds the lower text's Dynamic Type leading
  (none for sized fonts); a view above text 0.3625 × size (rounded up); text
  above a view 0.6094 × size; SF Symbols sit flush against text and other
  symbols and leave 0.135 × size next to other views. HStack spacing is 8.
- Truncation reports the width it draws, cuts mid-word, and never
  hyphenates a single line. Text offered no width draws nothing.
- Hyphenation applies only to text styles and only to words wider than the
  line, at TeX/Apple dictionary breaks (99.4% agreement with
  `CFStringGetHyphenationLocationBeforeIndex`); other fonts break between
  characters. No break before closing punctuation.
- Emoji take CoreText's advance and glyph size where a browser draws them at
  1 em (Chrome).
- Stacks place children with the offers they were sized with; a rigid child
  wider than the proposal does not widen the other rows.
- Padding, frames, and stacks re-offer what they were offered when placing a
  child that came out smaller; offering only its final size made texts that
  needed the room lose lines on each pass.
- A text narrower than "…" and its first character keeps the offered width
  and draws a clipped "…" instead of widening its row.
- iOS draws grayscale-antialiased glyphs: the web turns off macOS font
  smoothing for iOS profiles (text ink was 15% heavier in Chrome); macOS
  widgets keep it.
- Han ideographs advance as in CoreText (0.99 em up to 19 pt, 0.95 em from
  20 pt; same on iOS and macOS); serif text uses lining figures.
- Small emoji grow around their middle, so enlarged emoji drop by half the
  enlargement; swing animations leave content at its own position in a
  snapshot.
- Swift Charts: at most four value-axis intervals, no rounding when the value
  axis is hidden, opaque areas without a line.
- iOS puts each view's vertical origin on the 2x pixel grid in widget
  coordinates (rounding half up); horizontal positions stay fractional.
  macOS keeps fractional positions.
- `x.circle.fill` and `x.square.fill` symbols draw a filled circle or rounded
  square with the inner symbol cut out; `airplane` points level and
  `quote.opening` opens.
- Where the closest Lucide icon differs a lot in silhouette, the web draws an
  original stand-in from simple primitives, sized from the native render
  mapped into the same 24-unit box (`src/render/symbolShapes.js`; 49 of the
  64 symbols the bundled scripts use).
- Truncation follows CoreText: the kept prefix keeps its advance from the
  full string (kerning with the next character) and "…" is added unkerned,
  so "07…" cut from "07:00 AM" needs 41.4 points, not 39.4; runs of spaces
  are kept; and emoji break like CJK characters (UAX #14 ID class).

### Results

| Size (iOS 27 simulator, Chrome) | Mean matching pixels | Renders ≥ 99% identical |
| --- | --- | --- |
| small (375 / 393 / 430 pt) | 98.63% / 98.70% / 98.87% | 53% / 53% / 58% |
| medium (375 / 393 / 430 pt, iPad) | 99.10% / 99.24% / 99.35% / 99.39% | 69–82% |
| large (375 / 393 / 430 pt, iPad) | 99.50% / 99.58% / 99.65% / 99.67% | 88–94% |
| extraLarge, extraLargePortrait (iPad) | 99.82% / 99.84% | 98% / 99% |
| accessory circular / rectangular / inline | 97.36% / 98.01% / 97.53% | 30–35% |
| **All 1,936 averaged renders** (108 corpus entries × 16 sizes, 141 calibration cases including one per SF Symbol the scripts use, 100-item component catalog) | **99.01%** (98.18% before this pass) | **69.4%** |

Not averaged (33 renders, still compared and listed by `npm run compare`):
`component/date` (relative timers read the real clock at export time) and
`component/toggle` / `catalog/076-toggle` (ImageRenderer draws Toggle as a
placeholder).

Per size, over the corpus renders (the 33 unreproducible renders above
excluded), and the same without widgets that draw SF Symbols, whose
look-alike artwork is the one difference the engine cannot remove:

| Size | Renders | Mean matching pixels | Without SF Symbols | Mean matching pixels |
| --- | --- | --- | --- | --- |
| small~iphone-375 | 106 | 98.63% | 61 | 99.03% |
| small | 106 | 98.70% | 61 | 99.05% |
| small~iphone-430 | 106 | 98.87% | 61 | 99.20% |
| medium~iphone-375 | 106 | 99.10% | 61 | 99.35% |
| medium | 106 | 99.24% | 61 | 99.48% |
| medium~iphone-430 | 106 | 99.36% | 61 | 99.58% |
| medium~ipad-1024 | 106 | 99.40% | 61 | 99.63% |
| large~iphone-375 | 106 | 99.51% | 61 | 99.65% |
| large | 106 | 99.59% | 61 | 99.73% |
| large~iphone-430 | 106 | 99.65% | 61 | 99.79% |
| large~ipad-1024 | 106 | 99.67% | 61 | 99.80% |
| extraLarge~ipad-1024 | 106 | 99.82% | 61 | 99.89% |
| extraLargePortrait~ipad-1024 | 106 | 99.84% | 61 | 99.90% |
| accessoryCircular | 106 | 97.37% | 61 | 97.60% |
| accessoryRectangular | 106 | 98.01% | 61 | 98.64% |
| accessoryInline | 106 | 97.53% | 61 | 97.96% |

The 99% target applies to Home Screen sizes: without SF Symbols every Home
Screen size is at least 99% identical. Small and accessory sizes are reported
both ways because symbol artwork cannot be redistributed. The
accessory sizes stay below 99% either way: most corpus widgets were designed
for the Home Screen and overflow a 72-point frame, where SwiftUI's squeezing
of rows and clipping still differ from the web by a point or two.

**Accepted limits.** The 99% target is met on every Home Screen size for
widgets without SF Symbols, and that is the accuracy bar for this engine.
Small sizes with symbols (about 98.6–98.9%) and the accessory sizes (about
97.4–98.0%) are known limits rather than open work:

- Small: the remaining gap is SF Symbol artwork. 49 of the 64 symbols the
  bundled scripts use already have measured stand-ins; the rest appear in
  one widget each, and drawing four more moved small sizes by 0.01 points.
- Accessory: the `lock-*` calibration cases (vertical and horizontal
  overflow, padded and frame-max stacks at accessoryCircular and
  accessoryRectangular) match iOS structurally; what remains is sub-pixel
  glyph placement and per-template quirks. Rules tried for overflow (equal
  shares in stacks, bottom-anchored inline content) made the full
  comparison worse and were dropped.

By content, over the 1,696 averaged corpus renders:

| Content | small | medium | large | extraLarge | accessory |
| --- | --- | --- | --- | --- | --- |
| Text, shapes, images only | 99.35% | 99.59% | 99.81% | 99.92% | 98.21% |
| Uses SF Symbols | 98.23% | 98.94% | 99.41% | 99.74% | 97.04% |
| Other approximated features | 98.38% | 99.29% | 99.56% | 99.82% | 97.66% |

macOS (ScriptWidget Preview, `WKWebView`): 584 renders (corpus, calibration
cases, and the component catalog); mean 99.30% matching pixels over the 517
renders without the per-symbol cases, 99.05% on the per-symbol cases.

The 64 per-symbol cases (`case/symbol-*`, one SF Symbol at 40 points in a
small widget) measure each look-alike on its own: 1.11% of the widget differs
on average (2.26% with Lucide icons alone).

### What still differs

- **SF Symbols.** They cannot be redistributed, and the system font does not
  carry them for the browser to use, so the web draws Lucide look-alikes or
  original stand-ins at the measured symbol sizes. Symbols remain the largest
  share of the difference at small and accessory sizes.
- **Overflowing rows and crowded chart labels.** When a row cannot fit its
  children (four large emoji in a 148-point widget, launcher tiles), SwiftUI
  squeezes frames in ways the web does not model; Swift Charts collapses
  crowded axis labels to "…".
- **Accessory sizes.** Most corpus widgets were designed for Home Screen
  sizes and overflow a 72-point frame; clipping and centering of overflowing
  content still differ by a point or two.
- **ImageRenderer artifacts.** `toggle` renders as a placeholder in native
  snapshots, and relative timers depend on the real clock, so those renders
  are not meaningful comparisons.
- **Overflowing small layouts.** When a 148–170 pt widget cannot fit its
  content, SwiftUI's split of the leftover width between a text column and a
  symbol can differ from the web by a fraction of a point, which changes how
  many characters fit per line.

## Verification matrix

| Check | Result |
| --- | --- |
| Tree parity, macOS 27 JavaScriptCore reference | 100/100 corpus trees |
| Tree parity, iOS 27.0 simulator JavaScriptCore | identical to the reference |
| Tree parity, Node 24 / Chromium (headless and Claude pane) | 100/100 byte-identical |
| Tree parity, iOS 27 Safari (WebKit) in the simulator | 100/100 byte-identical; all isolation probes blocked; CSP control reached |
| Pixel comparison vs iOS 27 snapshots, Chrome on macOS | every iOS size: 1,933 averaged renders, 99.01% matching pixels, 69.4% at least 99% identical (see Coverage across every iOS size) |
| Pixel comparison vs macOS 27 native, `WKWebView` (ScriptWidget Preview) | 599 renders; 99.30% matching pixels without the per-symbol cases |
| Web Studio, headless Chrome smoke test | starter, 71 templates, image template, `.swt` import all render |
| Web Studio, iOS 27 Safari | renders with the strict page CSP and URL-loaded sandbox |
| Web-exported `.swt` imported by native code | passes preflight, extraction, validation, execution |
| Device sync, end to end | CLI → ScriptWidget app (Debug, iOS 27 simulator) over Web Studio API v1: paired, uploaded the changed entry, received the native PNG of the same source |
| Non-Apple fonts | corpus median 2.58% with the bundled Inter fallback (222/300 within 5%, 299/300 within 20%); 2.67% with generic fallback fonts |
| Pages layout | `site/` + Studio at `/studio/` assembled like the workflow passes the smoke test; both workflows parse |
| Chromium, Firefox, WebKit on Ubuntu and Windows (GitHub Actions, Web Browsers workflow) | Studio renders (28–90 ms), 71 templates, `.swt` import; 100/100 byte-identical trees; every isolation probe blocked; engine test suite passes on both OSes |
| Live site | https://atomsprout.com/scriptwidget/studio/ deployed by Pages and rendering over HTTPS in headless Chrome |
| Web Share in iOS 27 Safari (simulator) | `navigator.canShare` accepts the exported `Widget.swt` (`application/zip`) in a secure context, so **Install on iPhone** opens the share sheet; the share extension builds with the file-representation import path |
| **Not verified** | A physical iPhone, and choosing ScriptWidget in the share sheet through to a completed import (needs taps on the device or simulator) |

WebKit note: revoking a blob URL immediately after `new Worker(url)` prevents
WebKit from starting the Worker because it fetches the script asynchronously.
The sandbox frame keeps the URL alive; this was found and fixed in the
simulator check above.

## Native fixes found by this work

- **Web Studio snapshot was blank.** The capture view lived in a `.background`,
  so it captured only the background host, and the preview was usually
  scrolled off-screen. Web Studio now renders the widget itself with
  `ImageRenderer`, composed like the real widget.
- **Package names with spaces failed in Web Studio.** Browsers encode query
  spaces as `+`, which `URLComponents` does not decode; opening or deleting a
  file in a package such as "My Widget" returned "Document not found". The
  server now decodes form spaces (`WebStudioServerTests.testDecodesFormEncodedQuerySpaces`).
- **Malformed manifests were reinterpreted on import.** A present but invalid
  `widget.json` was replaced by a legacy manifest; import now fails closed
  (`ScriptManagerLifecycleTests.testMalformedPresentManifestFailsClosedOnImport`).
- **Font weight properties were ignored** (see Stage 1 notes above).

## Fonts outside Apple platforms

SF Pro is not distributed with the site. The renderer's font stack falls back
to "ScriptWidget Inter", which the Studio bundles (Inter, SIL Open Font
License 1.1; license published at `/studio/licenses/`), so Windows and Linux
previews share one set of metrics. Measured on the corpus by excluding Apple
fonts (`SW_FONTS=inter npm run compare`): median 2.58% versus 1.87% with SF.

## Corrections to the research proposal

- `undefinedRender` means `$main` is missing. A script whose text never
  contains `$render` renders `#UI Not Found#`. A script that contains it but
  never calls it times out.
- `$import` needs real classic-script evaluation. Indirect `eval` does not
  share `let`/`const` between files the way `JSContext.evaluateScript` does.

### Editable preview API mocks (engine 0.3.0)

`fixtures.api` provides per-method `{ value }` or `{ error }` responses for
`$device`, `$system`, `$health` and `$location`. Sync/async call behavior is
preserved; values are bridged freshly on each call. Legacy fixture keys remain
supported. `fixtures.storage` seeds each run; `fixtures.dataSource` provides
explicit plugin/operation response rules with normal package network checks.
Web Studio's `mockData.ts` defines the sample catalog and configuration helpers,
and `MockDataPanel.tsx` provides forms, JSON editing and permission scenarios.
See [Mock Data](web-studio-browser.md#mock-data) for the user-facing contract.
