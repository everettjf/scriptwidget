# ScriptWidget Roadmap

Last updated: 2026-11-18. This roadmap communicates direction, not a promise of dates. Priorities are decided by user impact, platform relevance, security, reliability, maintainability, and contributor capacity. ScriptWidget runs on iPhone, iPad, Mac and Android, and as a preview on Windows 11 and Linux (Omarchy); see [Platform support](docs/platform-support.md). Native watchOS support requires a later feasibility gate; visionOS is outside the current plan.

The [Widget capability expansion plan](docs/widget-capabilities-plan.md) turns research across 10 widget apps into 22 tracked capabilities. It sequences existing templates and interactions, real personal data, authenticated services and music, visual creation, shared experiences, and a gated Watch track. Each capability requires native behavior, preview mocks, compatibility, tests, and release evidence before being marked shipped.

## Product thesis

ScriptWidget aims to be the best open-source way for anyone to build their own widgets: approachable like a template tool, expressive like code, and current with WidgetKit. Its differentiator is one JavaScript/JSX package rendered natively on each system, paired with a first-class Mac Studio and a transparent, safe community ecosystem.

## Shipped foundation

- Native WidgetKit runtime for iPhone, iPad, and Mac, including interactive controls, Live Activity, and Dynamic Island surfaces.
- Android 1.0.0 (App Widgets, QuickJS-NG) and previews for Windows 11 and Linux (Omarchy 4.5) that run the same Package 2.0 widgets.
- ScriptWidget Studio on Mac with CodeMirror, completion, diagnostics, Console, multi-family preview, command shortcuts, and first-run tutorial.
- Versioned native Runtime API 1.2, Package 2.0 manifests, Skills 1.0, secure archive imports, and generated reference documentation.
- OpenAI-compatible generation with Keychain credentials, structured prompt context, run/diagnose/refine loops, evaluations, and reusable Skills.
- Validated templates with generated preview fixtures, including persistent habit check-ins in source; availability in uploaded binaries is tracked separately.
- Local build-cache fallback for iCloud-evicted scripts; physical-device acceptance for GitHub issue #6 remains open.
- GitHub-backed Widget & Skills Gallery with strict schema/path/host/size/SHA-256 checks, ETag caching, offline fallback, transactional install/update, and seed packages.
- Cross-platform Runtime tests and release-readiness CI.

## Current release scope

The next release targets M1–M5 together on `codex/release-m1-m2` (PR #62). M1/M2 foundations and templates are retained; M3 personal-data expansion, M4 authenticated services/music and M5 visual editing are in progress, not complete. The Reminders checkpoint is restored on this same branch. Watch and remote/social updates remain outside scope.

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
- Expanding to more Apple platforms before the supported platforms are reliable and coherent.

Proposals belong in a GitHub feature request. Significant Runtime/API changes should describe user need, alternatives, compatibility, security boundaries, tests, documentation, and migration behavior before implementation.
