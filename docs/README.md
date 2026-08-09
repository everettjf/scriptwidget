# ScriptWidget Documentation

Build native widgets for iPhone, iPad, and Mac with JavaScript and JSX. The quickest path is [Your first widget](getting-started.md).

## Start here

- [Your first widget](getting-started.md) — create, preview, debug, and install a widget.
- [ScriptWidget Studio](studio.md) — Mac editor, multi-size preview, Copilot, and Skills.
- [Runtime API](runtime-api.md) — supported components, properties, globals, and limits.
- [AI generation](ai-generate.md) — provider setup, prompting, iteration, privacy, and troubleshooting.

## Build and ship

- [Runtime API contract](scriptwidget-runtime-api.md) — versioning and compatibility policy.
- [Studio architecture](scriptwidget-studio-plan.md) — editor and bridge design.
- [Release readiness](release-readiness.md) — platform and quality checklist.
- [Contributing](../CONTRIBUTING.md) — repository workflow and contribution guide.

## Supported platforms

ScriptWidget focuses on iOS, iPadOS, and macOS. A single `main.jsx` can adapt its layout with `$getenv("widget-size")`. watchOS and visionOS are outside the current roadmap.
