# Changelog

Notable user-visible changes are recorded here. ScriptWidget follows semantic versioning for public package/runtime contracts even when App Store marketing versions use another cadence.

## Unreleased

### Added

- Full macOS app and WidgetKit workspace with Studio editing, diagnostics, Console, multi-size previews, native commands, and first-run tutorial.
- OpenAI-compatible Widget generation with Keychain-backed credentials, structured prompts, run/diagnose/refine workflow, evaluations, and reusable Skills 1.0.
- Package 2.0 manifests, JSON schemas, migration compatibility, secure imports, and authoring documentation.
- GitHub-backed Widget & Skills Gallery with verified files, offline cache, install/update UI on macOS and iOS/iPadOS, seed content, and contributor workflow.
- Runtime XCTest targets, golden/template validation, release-readiness CI, and iPad/iCloud device scripts.

### Changed

- Expanded the template catalog to 70 validated examples and generated preview fixtures.
- Reworked documentation around a five-minute path, versioned Runtime API, Studio, AI, Skills, packages, Gallery, release readiness, and bilingual onboarding.

### Fixed

- Added local build-cache fallback and proactive package caching for scripts evicted by iCloud. GitHub issue #6 remains open until the physical-iPhone offline acceptance matrix is complete.
