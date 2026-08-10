# ScriptWidget Documentation

Build native widgets for iPhone, iPad, and Mac with JavaScript and JSX. The quickest path is [Your first widget](getting-started.md).

## Start here

- [Your first widget](getting-started.md) — create, preview, debug, and install a widget.
- [Five-minute tutorial](five-minute-tutorial.md) — the built-in first-launch walkthrough and its complete workflow.
- [ScriptWidget Studio](studio.md) — Mac editor, multi-size preview, Copilot, and Skills.
- [Runtime API](runtime-api.md) — supported components, properties, globals, and limits.
- [AI generation](ai-generate.md) — provider setup, prompting, iteration, privacy, and troubleshooting.
- [Skills 1.0](skills.md) — reusable AI guidance, authoring, safe sharing, and package format.
- [Widget & Skills Gallery](gallery.md) — discover, verify, install, update, and submit community packages.
- [Data Source Plugins](data-source-plugins.md) — safe third-party API connectors and the Mac Data Source Lab.
- [Package 2.0](package-format.md) — `widget.json`, compatibility, and secure imports.
- [Modern WidgetKit features](widgetkit-modern-features.md) — rendering modes, Live Activities, controls, intents, and push updates.

## Build and ship

- [Runtime API contract](scriptwidget-runtime-api.md) — versioning and compatibility policy.
- [Studio architecture](scriptwidget-studio-plan.md) — editor and bridge design.
- [Release readiness](release-readiness.md) — platform and quality checklist.
- [Contributing](../CONTRIBUTING.md) — repository workflow and contribution guide.
- [Roadmap](../ROADMAP.md), [governance](../GOVERNANCE.md), and [changelog](../CHANGELOG.md) — direction, decisions, and shipped work.

## Supported platforms

ScriptWidget focuses on iOS, iPadOS, and macOS. A single `main.jsx` can adapt its layout with `$getenv("widget-size")`. watchOS and visionOS are outside the current roadmap.
