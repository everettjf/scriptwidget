# Contributing to ScriptWidget

Thank you for helping make native widget creation accessible to everyone. Contributions to the runtime, ScriptWidget Studio, templates, tests, and documentation are welcome.

## Before you start

- Search existing issues and discussions before opening a duplicate.
- Use an issue for behavior changes that need product or API agreement.
- Keep the current platform scope to iOS, iPadOS, and macOS.
- Treat execution, network access, imported packages, iCloud, and app-group storage as security boundaries.

## Development setup

1. Fork and clone the repository.
2. Open `iOS/ScriptWidget.xcodeproj` or `macOS/ScriptWidgetMac.xcodeproj` in Xcode.
3. Configure `iCloud.ScriptWidget` and `group.everettjf.scriptwidget` for storage testing.
4. In `Editor/editorfe`, run `npm ci`, `npm test`, and `npm run build`.

## Pull requests

- Make one focused change and avoid unrelated formatting.
- Add or update tests when behavior changes.
- Keep bundled templates runnable against the current runtime.
- Update the public API documentation when components, properties, globals, limits, or migration behavior change.
- Include screenshots or a short recording for visible UI changes.
- State the Xcode schemes and commands you verified.

Before submitting, run `./Scripts/release-readiness.sh` on a compatible Mac. Live AI and real iCloud tests are opt-in because they require credentials or signed-in devices.

## Adding a template

Put the entry point under `Shared/ScriptWidgetRuntime/Resource/Script.bundle/template/<Name>/main.jsx`, avoid secrets and private endpoints, provide useful fallback UI, and verify every bundled template test passes.

## Submitting to the Gallery

Community widgets and Skills are reviewed through the versioned `Gallery/index.json`; the app does not install arbitrary GitHub archives. Follow the [Gallery submission and curator guide](docs/gallery.md), commit the exact package files, update byte sizes and SHA-256 hashes, and run `./Scripts/release-readiness.sh`. Treat all index, source URL, package path, permission, network, and Prompt changes as security-sensitive review surface.

## Community standards

Be respectful, assume good intent, and focus review on the work. Security vulnerabilities should be reported privately according to [SECURITY.md](SECURITY.md), not posted as public issues.
