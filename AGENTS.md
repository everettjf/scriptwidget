# Repository Guidelines

## Product and Architecture

ScriptWidget lets users author native widgets with JavaScript and JSX: WidgetKit on iPhone, iPad and Mac, and App Widgets on Android. `Shared/ScriptWidgetRuntime` is compiled into the iOS/macOS apps and widget extensions, so shared-source changes must remain valid in both application and extension contexts. The Android app does not use the Swift runtime; it runs the shared JavaScript from `Web/preview-engine` in QuickJS.

- `Shared/ScriptWidgetRuntime/Common/`: package/storage models, Package 2.0, secure archives, iCloud and local fallback cache.
- `Shared/ScriptWidgetRuntime/Widget/`: JavaScriptCore host, public APIs, runtime limits, JSX element mapping, App Intents, and support bundles.
- `Shared/ScriptWidgetRuntime/AI/`: provider profiles, prompt construction, agent loop/evals, and Skills 1.0.
- `Shared/ScriptWidgetRuntime/Gallery/`: verified GitHub catalog, offline index cache, transactional installer, and shared UI.
- `Shared/ScriptWidgetRuntime/Plugin/`: declarative Data Source Plugin 1.0 validation, import/export, request building, and `$dataSource` runtime.
- `iOS/ScriptWidget`, `ScriptWidgetWidget`, `ScriptWidgetShare`: iPhone/iPad app, WidgetKit/Live Activity/Control Widget extension, and share extension.
- `macOS/ScriptWidgetMac`, `ScriptWidgetMacWidget`: Studio app and macOS widget extension. Studio features live in `Editor/`, `AIGenerate/`, `Skills/`, `Plugin/`, and `Onboarding/`.
- `Editor/editorfe/`: Vite frontend with CodeMirror 6. Built files are copied into both platform `StudioEditor.bundle` directories.
- `Web/preview-engine/`: browser preview engine (plain JavaScript with `.d.ts` types); `Web/studio/`: Web Studio, a React + strict TypeScript + shadcn/ui app published to GitHub Pages. Its `kernel.js` and `renderer.js` are also the Android runtime, so a change there affects the browser preview and Android together.
- `Windows/`: the Windows 11 desktop app (preview). `native` builds `swcore.dll` from the QuickJS-NG sources under `Android/core/src/main/cpp/quickjs`; `src/ScriptWidget.Core` is a C# port of `Android/core` (engine wrapper, compiler, executor, packages, APIs, plugins, Win2D renderer); `src/ScriptWidget.App` is the always-running desktop host; `src/ScriptWidget.Studio` is the WinUI 3 management window; `src/ScriptWidget.Cli` is `swcli`. It runs the same shared JavaScript as Android, built by `Scripts/lib/shared-js.mjs`. `Windows/assets`, `Windows/native/out` and `Windows/artifacts` are generated; do not edit or commit them.
- `Android/core`: QuickJS-NG with its JNI layer, the Kotlin host and native APIs, Canvas renderer, package store, Gallery, Skills, plugins and AI client. `Android/app`: Compose app, widget providers, tiles, shortcuts, Live Updates and push. `Android/core/src/main/assets/scriptwidget` is generated; do not edit it. `Android/app/src/main/assets/Script.android` holds the templates for what only Android has: the scrolling `<list>`, the `material.<role>` colors and the automation entry point, all described under "Only on Android" in `docs/android/README.md`. `Android/play`: Google Play listing kit.
- `Tests/ScriptWidgetRuntimeTests/`: shared runtime, execution, performance, package/cache, iCloud-state, Gallery, AI, and security tests.
- `Gallery/`: curated Gallery 1.0 index, JSON Schema, widget seeds, and Skill seeds.
- `docs/`: authoritative user and contributor documentation; `docs/android/` covers the Android app, its test notes and its to-do. The native JSX switch is the runtime authority; Studio completion metadata lives in `Editor/editorfe/src/scriptWidgetAPI.js`. Package contracts live in `Shared/ScriptWidgetRuntime/Resource/*.schema.json`.

Widget packages live under `Scripts/<PackageName>/`. Package 2.0 uses `widget.json` plus a declared JS/JSX entry point (normally `main.jsx`) and optional nested source/resource files. `__Build/` is generated cache state, not authored source.

## Build, Test, and Development Commands

- Open projects: `open iOS/ScriptWidget.xcodeproj` and `open macOS/ScriptWidgetMac.xcodeproj`.
- Main schemes: `ScriptWidget`, `ScriptWidgetWidget`, `ScriptWidgetShare`, `ScriptWidgetMac`, `ScriptWidgetMacWidget`, and `ScriptWidgetRuntimeTests` in both projects.
- Full local/CI-equivalent gate: `./Scripts/release-readiness.sh`.
- Deterministic iPad and iCloud-state coverage: `./Scripts/ipad-icloud-tests.sh`.
- Simulator/Mac build matrix plus physical-device checklist entry point: `./Scripts/device-matrix.sh`.
- Editor setup: `cd Editor/editorfe && npm install`.
- Editor development: `npm start`, `npm test`, `npm run build`, `npm run docs`.
- Editor release: `npm run release`; this rebuilds and replaces both checked-in `StudioEditor.bundle` directories. Always include generated bundle changes when frontend source or API completions change.
- Metadata-only release checks: `node Scripts/validate-release.mjs` and `node Scripts/validate-doc-links.mjs`.
- Android (not covered by `release-readiness.sh`): `node Android/scripts/build-shared-js.mjs` after changing `Web/preview-engine/src`, the support bundle or `Android/core/src/main/js`; `cd Android && ./gradlew :core:testDebugUnitTest :app:assembleDebug`; `sh Android/scripts/device-test.sh core` and `app` on a connected device or emulator; `./gradlew :app:bundlePlayRelease` for the Play bundle and `:app:assembleFossRelease` for the APK published on GitHub Releases. The app has two flavors: `play` contains Firebase Cloud Messaging, `foss` must contain no Google or other proprietary library.

- Windows (not covered by `release-readiness.sh`; needs Windows 11, Visual Studio with the C++ workload, the .NET 10 SDK and Node): `node Windows/scripts/build-shared-js.mjs` after changing `Web/preview-engine/src`, the support bundle or `Android/core/src/main/js`; `powershell -File Windows/scripts/build-native.ps1 -Arch x64`; `cd Windows && dotnet test tests/ScriptWidget.Core.Tests`; `powershell -File Windows/scripts/desktop-check.ps1` after touching the desktop host; `powershell -File Windows/scripts/package.ps1` for the MSIX (add `-FrameworkDependent` and the Partner Center identity for the Store); `powershell -File Windows/scripts/installer.ps1` for the NSIS installer published on GitHub Releases (tag `windows-v<version>`), checked by `Windows/scripts/installer-check.ps1` and built for both processors by the hand-started "Windows installers" workflow. Record what ran, on which machine, in `docs/windows/testing.md`, and keep `docs/windows/TODO.md` current.

The app uses `iCloud.ScriptWidget` and `group.everettjf.scriptwidget`. Signed real-container tests require a trusted, signed-in device; deterministic cache/iCloud-state tests do not.

The Android application ID is `com.atomsprout.scriptwidget`; the Kotlin namespace stays `com.everettjf.scriptwidget`. Take the package name from `context.packageName` and class names from the class, never from a literal. `Android/keystore.properties`, `Android/firebase.properties`, `google-services.json` and keystores are git-ignored and must stay out of the repository; a build without `firebase.properties` has push turned off.

## Public Contracts and Compatibility

- `scriptWidgetAPI.js` is static Studio completion/documentation metadata, not a runtime-loaded contract. Keep it aligned with the native JSX switch; after changing it, run `npm run docs` and `npm run release` in `Editor/editorfe`.
- Package 2.0 is defined by `WidgetPackageManifest`, its validator, `widget.schema.json`, and `docs/package-format.md`. Unknown keys and unsupported versions fail closed. Preserve legacy `main.jsx`/`meta.json` reading unless an explicit migration removes it.
- Skills 1.0 packages contain exactly `skill.json` and `SKILL.md`; Skills augment prompts only and never grant tools or runtime permissions.
- Gallery 1.0 trusts only its configured GitHub raw-content root and verifies path, byte count, and SHA-256 before transactional installation.
- Data Source Plugin 1.0 packages contain `plugin.json` and optional `README.md`. They are declarative HTTPS mappings, not executable native plugins.
- Additive runtime changes are preferred within a contract version. Breaking global/component/property semantics require an explicit version and migration plan.

## Security Invariants

Treat scripts, imported ZIPs, Gallery content, Skills, plugin manifests, network responses, iCloud files, and app-group files as untrusted.

- Resolve package paths canonically and reject traversal, absolute paths, symlinks, backslashes, case collisions, and boundary escapes.
- Keep archive entry/file/expanded-size limits intact. Preflight before extraction, use unique temporary directories, and install transactionally.
- Package 2.0 network calls require `network` and a matching `networkDomains` declaration. Generic fetches allow public HTTP(S); Data Source Plugins are HTTPS-only. Reject private/local hosts and enforce request/response budgets.
- `$file` remains package-relative; `$storage` remains package-namespaced and bounded.
- Do not log credentials, OAuth tokens, full sensitive responses, HealthKit data, or user file contents.
- AI credentials remain Keychain-backed and must not be serialized into UserDefaults, packages, prompts, logs, Skills, or Gallery metadata.
- Imported Skills cannot execute code; Data Source Plugins cannot load native code or enlarge widget permissions.
- The Android automation receiver is exported. Keep it off by default, gated by the user's token and per-package permission, rate-limited, and limited to actions a manifest declares. Never log the token. A list row tap carries only a number that the app resolves from its own saved taps.
- Malformed present manifests must fail closed; do not silently reinterpret them as legacy packages.

## Coding Style

- Swift: 4-space indentation, Xcode defaults, `UpperCamelCase` types and `lowerCamelCase` members. Prefer small SwiftUI views, modern Observation for new state models where deployment allows, stable `ForEach` identity, and accessibility labels for icon-only controls.
- JavaScript/React: 2-space indentation, `UpperCamelCase` components and `lowerCamelCase` functions. Match surrounding formatting; avoid unrelated whole-file rewrites.
- Runtime examples: keep `main.jsx` UTF-8, deterministic, within runtime budgets, and compatible with their declared permissions/hosts/plugins.
- Xcode projects use explicit file references. When adding shared Swift sources, add them to every app/widget/test target that compiles or references them, then lint both `.pbxproj` files with `plutil -lint`.
- Preserve user-authored or unrelated dirty-worktree changes. Generated editor bundles are the exception only when deliberately rebuilt from matching frontend source.

## Testing Expectations

- Run focused tests while iterating, then `./Scripts/release-readiness.sh` before handoff for changes affecting runtime, packaging, editor, Gallery, Skills, plugins, or project files.
- Add deterministic tests for validator semantics, permission denial, archive hardening, path boundaries, cache fallback, and migrations. Security fixes need a regression test that fails before the fix.
- Runtime/global/component changes should include execution tests, editor schema alignment, generated API docs, and representative template validation.
- iCloud/cache work must cover primary reads, proactive caching, eviction fallback, nested imports, supported binary resources, and user-visible iCloud states. Do not claim physical-device coverage unless it was actually executed.
- UI changes require the relevant iOS/macOS scheme build and screenshots when the visual result matters.
- Live Activity, Dynamic Island, Control Widget, app/widget shared-container, and extension-memory behavior need targeted smoke tests when touched.
- Android changes need the JVM tests and the instrumented suites on a device or emulator; changes to `Web/preview-engine` need both its own tests and the Android suites. Record what ran, on which device, in `docs/android/testing.md`, and keep `docs/android/TODO.md` current.

## Commits and Pull Requests

- When the user asks to "commit" (or says “提交”), commit the requested changes and push the resulting commit to the current remote branch.
- When the user asks to "merge" (or says “合并”), merge the requested work into `main` and push `main` to the remote.
- Use concise, action-oriented commit subjects. Add a body when behavior, security tradeoffs, migrations, or generated artifacts need explanation.
- PRs should state the user outcome, linked issue, security/compatibility impact, commands/schemes run, and any skipped physical-device or signed-iCloud checks.
- Include before/after screenshots for visible UI changes and keep documentation/schema/generated bundles in the same PR as the behavior they describe.
- GitHub releases: the newest app release (Apple `v…`, Android `android-v…` or Windows `windows-v…`) is marked Latest; `cli-v…` releases and previews are created with `--latest=false`. See `docs/release-readiness.md`.
- Never describe a skipped check as passing. Link the exact successful CI run or local evidence when claiming release readiness.

## Current Product Priorities

- Stabilize and document the now-versioned runtime, Package 2.0, Skills 1.0, Gallery 1.0, and Data Source Plugin 1.0 contracts before expanding them.
- Bring Android 1.0.0 to Google Play: finish the items in `docs/android/TODO.md`, keep it running the same Package 2.0 widgets as iOS, and document every difference in `docs/android/README.md`.
- Grow the curated Gallery and beginner templates while keeping every example verified, permission-correct, and runnable offline where appropriate.
- Improve Studio authoring ergonomics, diagnostics, accessibility, localization, and multi-file workflows without weakening crash recovery or iCloud conflict safety.
- Establish repeatable on-device performance baselines for timeline generation, JavaScript evaluation, cold launch, editor latency, and widget-extension memory.
- Design authenticated data sources only with an explicit, user-owned credential capability; never expose secrets directly to imported widgets or plugin manifests.
- Continue security review of execution, network, archive, shared-container, Gallery, AI, and plugin boundaries, and fail closed on unsupported capabilities.

## Public website ownership

Maintain and deploy functional Web Studio only from this repository at `https://asp.run/scriptwidget/studio/`. Product marketing, app downloads, support and original privacy policies remain at `https://atomsprout.com/scriptwidget/`. The Pages workflow must assemble the tested Studio build using `Scripts/build-web-site.mjs`; never rewrite Studio or sandbox HTML into Company redirects.

The `/scriptwidget/` root is a simple entry page with links to Web Studio and the official Company product website. Do not auto-redirect it or publish old Company product redirect pages. Reuse the native App icon for the entry page, Studio header and browser favicon.
