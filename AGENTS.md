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
- `Android/core`: QuickJS-NG with its JNI layer, the Kotlin host and native APIs, Canvas renderer, package store, Gallery, Skills, plugins and AI client. `Android/app`: Compose app, widget providers, tiles, shortcuts, Live Updates and push. `Android/core/src/main/assets/scriptwidget` is generated; do not edit it. `Android/play`: Google Play listing kit.
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
- Android (not covered by `release-readiness.sh`): `node Android/scripts/build-shared-js.mjs` after changing `Web/preview-engine/src`, the support bundle or `Android/core/src/main/js`; `cd Android && ./gradlew :core:testDebugUnitTest :app:assembleDebug`; `sh Android/scripts/device-test.sh core` and `app` on a connected device or emulator; `./gradlew :app:bundleRelease` for the Play bundle.

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
- Never describe a skipped check as passing. Link the exact successful CI run or local evidence when claiming release readiness.

## Current Product Priorities

- Stabilize and document the now-versioned runtime, Package 2.0, Skills 1.0, Gallery 1.0, and Data Source Plugin 1.0 contracts before expanding them.
- Bring Android 1.2.0 to Google Play: finish the items in `docs/android/TODO.md`, keep it running the same Package 2.0 widgets as iOS, and document every difference in `docs/android/README.md`.
- Grow the curated Gallery and beginner templates while keeping every example verified, permission-correct, and runnable offline where appropriate.
- Improve Studio authoring ergonomics, diagnostics, accessibility, localization, and multi-file workflows without weakening crash recovery or iCloud conflict safety.
- Establish repeatable on-device performance baselines for timeline generation, JavaScript evaluation, cold launch, editor latency, and widget-extension memory.
- Design authenticated data sources only with an explicit, user-owned credential capability; never expose secrets directly to imported widgets or plugin manifests.
- Continue security review of execution, network, archive, shared-container, Gallery, AI, and plugin boundaries, and fail closed on unsupported capabilities.
