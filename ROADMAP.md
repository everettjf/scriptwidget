# ScriptWidget Roadmap

Last updated: 2026-08-09. This roadmap communicates direction, not a promise of dates. Priorities are decided by user impact, platform relevance, security, reliability, maintainability, and contributor capacity. iOS, iPadOS, and macOS are the supported product boundary; watchOS and visionOS are not currently planned.

## Product thesis

ScriptWidget aims to be the best open-source way for anyone to build native Apple widgets: approachable like a template tool, expressive like code, and current with WidgetKit. Its differentiator is a JavaScript/JSX authoring model rendered as native SwiftUI, paired with a first-class Mac Studio and a transparent, safe community ecosystem.

## Shipped foundation

- Native WidgetKit runtime for iPhone, iPad, and Mac, including interactive controls, Live Activity, and Dynamic Island surfaces.
- ScriptWidget Studio on Mac with CodeMirror, completion, diagnostics, Console, multi-family preview, command shortcuts, and first-run tutorial.
- Versioned Runtime API 1.0, Package 2.0 manifests, Skills 1.0, secure archive imports, and generated reference documentation.
- OpenAI-compatible generation with Keychain credentials, structured prompt context, run/diagnose/refine loops, evaluations, and reusable Skills.
- 70 validated templates with generated preview fixtures.
- Local build-cache fallback for iCloud-evicted scripts; physical-device acceptance for GitHub issue #6 remains open.
- GitHub-backed Widget & Skills Gallery with strict schema/path/host/size/SHA-256 checks, ETag caching, offline fallback, transactional install/update, and seed packages.
- Cross-platform Runtime tests and release-readiness CI.

## Now — prove reliability and contributor experience

- Complete issue #6's signed physical-iPhone offline matrix and publish the evidence.
- Keep Gallery submissions reviewable with automated hashes, runnable fixtures, screenshots, permissions, privacy, and compatibility checks.
- Maintain accurate bilingual onboarding and documentation with automated link and contract validation.
- Establish predictable governance, changelog, security, dependency updates, contribution templates, and release criteria.
- Measure cold launch, JavaScript evaluation, timeline generation, memory, and editor responsiveness on representative devices before adding heavier APIs.

## Next — make creation dramatically faster

- Project-aware Studio workspace: safe multi-file navigation, refactors, searchable API docs, richer diagnostics, and preview comparison.
- AI generation that plans across files, explains permissions/network use, proposes test cases, and produces reviewable diffs rather than opaque replacements.
- Gallery discovery improvements: categories, compatibility filters, screenshots, deterministic preview fixtures, update notes, and curator provenance.
- More guided templates for personal dashboards, accessibility, privacy-preserving data use, and resilient offline states.
- Reduce duplicated platform bridge code and split oversized Runtime modules behind stable tests.

## Later — a sustainable open ecosystem

- Signed or transparency-backed Gallery metadata if ecosystem scale makes the curated Git trust root insufficient.
- Reproducible performance baselines and public release scorecards.
- Local or self-hosted AI providers where platform constraints and quality allow.
- Community maintainer paths for Runtime, Studio, templates, documentation, and Gallery review.

## Explicit non-goals

- Running arbitrary native plugins from Gallery packages.
- Silent telemetry, selling user data, or uploading widget source without explicit action.
- Pretending AI output is trusted: generated code remains reviewable project source under the same Runtime boundaries.
- Expanding to more Apple platforms before the three supported platforms are reliable and coherent.

Proposals belong in a GitHub feature request. Significant Runtime/API changes should describe user need, alternatives, compatibility, security boundaries, tests, documentation, and migration behavior before implementation.
