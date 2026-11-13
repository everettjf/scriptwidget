# Changelog

Notable user-visible changes are recorded here. ScriptWidget follows semantic versioning for public package/runtime contracts even when App Store marketing versions use another cadence.

## 27.1.3 — release candidate (M1–M5 development in progress)

- Save real habit, hydration, mood and checklist records with history, undo and backup/recovery.
- Add configurable countdown, photo, weather, basic health, public GitHub data, launcher, local Live Activity, plant, pet and wallpaper templates.
- Expand verified Gallery packages and editable Web Studio sample data.
- Improve owner-scoped record storage, offline caches, Calendar source selection and bounded timeline generation.
- Fix library opening when read-only legacy preferences cannot synchronize after a successful file-backed storage write.
- Add selected-list Reminders reads and explicit create, update and completion actions with durable replay receipts.
- Simulate declared widget actions in Web Studio against persistent, editable preview data.
- Add explicit selected-photo/album access, private thumbnails and a scheduled Photo Album Rotator with equivalent Web sample data.
- Add bounded sleep, activity-ring and workout summaries, a Health Overview template and editable Web sample data.
- Fix native Promise callback ownership so completed and abandoned executions release their JavaScript VM and snapshot.
- Serialize native runtime subscription, result delivery and cancellation to prevent intermittent empty results and reference-lifetime crashes.
- Continue expanded personal-data APIs, authenticated services/music and visual editing on the same release branch; M3–M5 remain in progress.

## Unreleased

### Android (in development, `android` branch)

- Add an Android app that runs the same Package 2.0 widgets as iPhone, iPad and Mac: QuickJS-NG runtime with the shared execution kernel, the shared renderer painted to a bitmap, and small, medium and large home-screen widgets with tap actions, self-updating timers and light/dark variants.
- Add the library, the Studio editor, bundled templates, `.swt` import and export, Gallery, Skills, Data Source Plugins and AI generation with API-key providers to the Android app.
- Capabilities without an Android implementation report `[unsupported_platform]` and are listed on the package page. See [ScriptWidget for Android](docs/android/README.md).
- Verified on one device (Pixel 6, Android 17). Other vendors' launchers and background limits are untested; AI generation has not been run against a live provider.

### Compatibility fixes

- Allow confirmed deletion of late-synced or recreated unregistered widget folders without adopting their old records. Preserve confirmation-time directory identity, show deletion failures, and record diagnostic outcomes.
- Restore `eval` and dynamic Function/async/generator constructors, preserving direct eval scope and guarding recognized dynamic sources against runaway loops.
- Keep legacy `$storage` calls working with older empty-permission manifests while preserving owner isolation and preview-only writes.
- Keep native library choices available when private metadata fails; add explicit reconnection with preserved prior stores and independent recovered records.
- Add the system Paste control to the iOS editor, with document/session and read-only checks for asynchronous text delivery.

### Added

- Full macOS app and WidgetKit workspace with Studio editing, diagnostics, Console, multi-size previews, native commands, and first-run tutorial.
- OpenAI-compatible Widget generation with Keychain-backed credentials, structured prompts, run/diagnose/refine workflow, evaluations, and reusable Skills 1.0.
- Package 2.0 manifests, JSON schemas, migration compatibility, secure imports, and authoring documentation.
- GitHub-backed Widget & Skills Gallery with verified files, offline cache, install/update UI on macOS and iOS/iPadOS, seed content, and contributor workflow.
- Runtime XCTest targets, golden/template validation, release-readiness CI, and iPad/iCloud device scripts.
- Browser preview engine (`Web/preview-engine`): JavaScriptCore-compatible execution in a sandboxed browser worker and a SwiftUI-calibrated web renderer.
- Web Studio in the browser (`Web/studio`, published at `/studio/`): edit, preview, import, and export widgets on any desktop OS and install them on iPhone through the share sheet.
- `scriptwidget-preview` CLI and `scriptwidget-mcp` server for agent workflows, with optional sync to Web Studio on iPhone for native previews.
- ScriptWidget Preview (`Tools/ScriptWidgetPreview`), a macOS developer app that compares the native macOS rendering of a package with the web engine, one package at a time or across the whole corpus.
- A **Mac** device in the web preview and Web Studio, calibrated to macOS 26 text styles, colors, spacing, line breaking, buttons, and charts.
- Eight built-in widgets that lay out differently for small, medium, large, iPad extra large, and the three Lock Screen sizes: Month Calendar, Weather Glance, Activity Rings, World Clock Faces, Year in Dots, Habit Heatmap, Now Playing, and Portfolio Pulse.
- Web Studio **Gallery**: live previews of every bundled template and Gallery widget, category and Featured filters, search, a preview at every size a widget handles, read-only source with Copy, and **Create a copy** to start a project saved in the browser.
- Drop a `.swt` or `.zip` anywhere in Web Studio to import it, or an image to add it to the open project.
- A 100-item component catalog and a report page comparing iOS native, macOS native, and the web preview side by side.

### Changed

- Web Studio is rebuilt with React, strict TypeScript, Tailwind CSS, and shadcn/ui: accessible selects, dialogs, and tabs replace browser prompts and alerts, deletions ask in an in-page dialog, messages appear as toasts, and images open as previews instead of text.
- Expanded the template catalog to 78 validated examples and generated preview fixtures.
- Copies of bundled templates in Web Studio carry one manifest: `meta.json`'s description, category, and tags move into `widget.json`.
- ScriptWidget Preview compares widgets that use `fetch` and `$http`: it downloads each GET response once and gives it to the web engine, so both sides show the same data.
- Reworked documentation around a five-minute path, versioned Runtime API, Studio, AI, Skills, packages, Gallery, release readiness, and bilingual onboarding.

### Fixed

- Native Runtime 1.2 replaces a private JavaScriptCore timeout API with compiler-inserted cancellation checks. Old compiled caches are invalidated. Dynamic code compatibility (`eval` and function constructors) is restored by the compatibility fixes above. Native built-in calls and the trusted Babel parser cannot be forcibly interrupted.

- Web preview fidelity across every iOS widget size (16 sizes, 1,942 compared renders, 99.0% matching pixels; every medium, large, and iPad size above 99%): baselines, line pitch, VStack spacing, truncation, dictionary hyphenation for text styles, emoji metrics, and stack placement now follow measured SwiftUI behavior.
- Web preview rules measured against native renders: area charts fill opaque, chart axes use at most four 1/2/5 intervals and a hidden value axis ends at the data maximum, Chinese characters advance as in CoreText, serif text uses lining figures, `.fill` SF Symbols get their real widths, grid spacing separates rows only (columns use SwiftUI's 8-point default), text narrower than an ellipsis is drawn clipped when one line fits, and macOS toggles draw as checkboxes with hyphenated text styles.
- `fetch` in the browser preview: network templates such as Currency Pulse failed with "fetch is not a function".
- The web preview never started in Firefox, which throws when a sandboxed worker reads some hidden globals.
- Dark mode in the code editor (Web Studio and the app's built-in editor): variable and property names were dark blue on the dark background.
- When a content blocker blocks Web Studio's preview sandbox, the preview explains it within seconds instead of waiting 30 seconds.
- Web preview on iPhone sizes: line breaking now follows TextKit's standard strategy, truncation cuts mid-word without a space before "…", Chinese text is no longer hyphenated, charts use the iOS plot insets and label font, and buttons lay out their label side by side.
- Web Studio on iPhone: the native preview image is no longer blank, and packages whose names contain spaces open and save correctly from the browser.
- The share extension imports `.swt` and `.jsx` files shared from a web page (Web Share in Safari), which arrive as files rather than URLs.
- Importing a package with a malformed `widget.json` now fails instead of replacing the manifest with a legacy one.
- `fontWeight`, `fontDesign`, and the older `weight` property are now applied to text, dates, icons, labels, and images. They were documented and used by templates but previously ignored.
- Widgets keep rendering on iPhone and iPad after iCloud evicts their script: the build-cache fallback found no cached copy on devices, where package paths go through the `/var` → `/private/var` symlink and an evicted file's path no longer matched its package root. Found by running the runtime tests on a physical iPad Air.
- Added local build-cache fallback and proactive package caching for scripts evicted by iCloud. GitHub issue #6 remains open until the physical-iPhone offline acceptance matrix is complete.
