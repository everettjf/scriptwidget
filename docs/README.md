# ScriptWidget Documentation

Build native widgets for iPhone, iPad, and Mac with JavaScript and JSX. The quickest path is [Your first widget](getting-started.md).

## Start here

- [Your first widget](getting-started.md) — create, preview, debug, and install a widget.
- [Five-minute tutorial](five-minute-tutorial.md) — the built-in first-launch walkthrough and its complete workflow.
- [ScriptWidget Studio](studio.md) — Mac editor, multi-size preview, Copilot, and Skills.
- [Web Studio in the browser](web-studio-browser.md) — design and preview on Windows, macOS, or Linux, then install on iPhone.
- [Runtime API](runtime-api.md) — supported components, properties, globals, and limits.
- [Package storage](storage-api.md) — saved records, bounded compare-and-set updates, and contention handling.
- [Reminders API](reminders-api.md) — selected-list reads, bounded windows and explicit user actions with write receipts.
- [Calendar API](calendar-api.md) — real read-only events, package permission, bounded queries, and cache behavior.
- [Location API](location-api.md) — app/widget authorization, precision-aware snapshots, and revocation.
- [Scheduled widget states](timeline-api.md) — daily transitions, planned dates, read-only future entries and preview.
- [Data API capability catalog](data-api-catalog.md) — native platforms, authorization, sync/async behavior, and editable preview samples.
- [AI generation](ai-generate.md) — provider setup, prompting, iteration, privacy, and troubleshooting.
- [AI quality testing](ai-quality-testing.md) — bounded live generation, native snapshots, offline replay, and visual review.
- [Apple PCC AI plan](apple-pcc-ai-plan.md) — feasibility, constraints, architecture, and zero-key rollout.
- [Skills 1.0](skills.md) — reusable AI guidance, authoring, safe sharing, and package format.
- [Widget & Skills Gallery](gallery.md) — discover, verify, install, update, and submit community packages.
- [Data Source Plugins](data-source-plugins.md) — safe third-party API connectors and the Mac Data Source Lab.
- [Package 2.0](package-format.md) — `widget.json`, compatibility, and secure imports.
- [Modern WidgetKit features](widgetkit-modern-features.md) — rendering modes, Live Activities, controls, intents, and push updates.
- [Local Live Activities](live-activities.md) — start, update, restore and finish installation-bound activities; local demo and platform limits.
- [Local plants and pets](local-companions.md) — explicit care, saved history, personal schedules and original JSX companions.
- [Public animation scheduling](public-animations.md) — clock/swing/GIF timing, static fallbacks and system scheduling limits.
- [Wallpaper Match](wallpaper-match.md) — crop calibration, size/appearance backgrounds and PNG export.
- [Package files](file-api.md) — text reads and bounded local binary-resource presence.

## Build and ship

- [Widget delivery plan](widget-capabilities-plan.md) — complete authoring quality and release acceptance (A+B); service expansion and long-term tracks are canceled.
- [Widget delivery status](widget-capabilities-status.md) and [TODO](widget-capabilities-todo.md) — implemented scope, authoring work and release acceptance; [original capability plan](widget-capabilities-plan-history.md) is historical reference.
- [Runtime API contract](scriptwidget-runtime-api.md) — versioning and compatibility policy.
- [Connected Services API](services-api.md) — authenticated GitHub profiles, per-widget access and editable Web mocks.
- [Music playback API](music-api.md) — read-only iOS Music app snapshots and editable Web samples.
- [Visual Layout editing](visual-layout.md) — shared native/Web layer editing, properties, dragging and source preservation.
- [Widget themes](widget-themes.md) — reusable color, font and spacing tokens saved in ordinary source.
- [Studio assets](studio-assets.md) — package images and original JSX with retained provenance and licenses.
- [Visual effects](visual-effects.md) — public material, static depth, accessibility fallbacks and system/legacy limits.
- [Service account foundation](service-accounts-foundation.md) — native GitHub credentials, per-widget grants, disconnect and secure-store boundaries.
- [Studio architecture](scriptwidget-studio-plan.md) — editor and bridge design.
- [Browser widget preview research](browser-widget-preview-research.md) — browser-first fast preview proposal, fidelity model, and staged validation plan.
- [Browser preview engine](browser-preview-engine.md) — engine, renderer, measured JavaScriptCore and SwiftUI parity (iOS and macOS), sandbox isolation, and known differences. The macOS comparison app lives in `Tools/ScriptWidgetPreview`.
- [Browser preview coverage](browser-preview-coverage.md) — generated per-tag and per-property support matrix.
- [Release readiness](release-readiness.md) — platform and quality checklist.
- [Contributing](../CONTRIBUTING.md) — repository workflow and contribution guide.
- [Roadmap](../ROADMAP.md), [governance](../GOVERNANCE.md), and [changelog](../CHANGELOG.md) — direction, decisions, and shipped work.

## Supported platforms

ScriptWidget focuses on iOS, iPadOS, and macOS. A single `main.jsx` can adapt its layout with `$getenv("widget-size")`. Native watchOS is unsupported and outside the current [A/B scope](widget-capabilities-plan.md). visionOS is outside this plan.

- [Opt-in iCloud JSON API](icloud-json-api.md) — native grants, immutable revisions, conflicts and Web mocks.
