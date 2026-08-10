# Module Boundary Assessment

This Stage 8 assessment decides whether the shared runtime should be converted
to local Swift packages during the current stability-first refactoring.

## Observed graph

- `Shared/ScriptWidgetRuntime` contains 80 Swift files: 57 Widget, 16 AI, 4
  Common, 2 Gallery, and 1 Plugin source files.
- The shared sources are explicit file references in both Xcode projects and
  compile into different app, widget-extension, and test target combinations.
- There is no local `Package.swift`, `XCLocalSwiftPackageReference`, package
  build-tool plugin, macro package, or umbrella re-export in this graph.
- The module is below the roughly 200-file threshold where source count alone
  commonly creates an oversized incremental-build scope.
- `support.bundle` and `Script.bundle` are copied into selected application and
  extension targets. Current package and AI code resolves them with
  `Bundle.main`, which is not equivalent to SwiftPM's `Bundle.module`.
- Runtime code mixes JavaScriptCore, SwiftUI, WidgetKit, App Intents, UIKit or
  AppKit conditionals, and platform capabilities. AI also consumes runtime and
  package types, while Plugin consumes both package and runtime promise types.
- The release gate currently validates the direct-source layout across macOS
  tests/app builds and iOS app/tests. No before/after build benchmark exists for
  a package layout.

## Decision

Do not introduce local Swift packages in this refactoring. The present graph
does not provide evidence that more module tasks would reduce wall-clock build
time, while changing resource lookup, access control, target membership, and
extension linkage together would create a broad compatibility risk. The safe
result of this stage is an explicit deferred decision, not an unmeasured split.

## Future recommendations

### Establish a resource-provider seam before packaging

- **Wait-time impact:** None expected by itself; it removes a correctness blocker
  for a later benchmarked package experiment.
- **Actionability:** `repo-local`
- **Observed evidence:** Shared code currently uses `Bundle.main`, while the same
  resources have different membership in app and extension targets.
- **Estimated impact:** High migration-risk reduction, no claimed build-speed gain.
- **Confidence:** High.
- **Approval required:** Yes; resource lookup is runtime behavior.
- **Benchmark verification status:** Not yet verified.

### Separate UI features from lower-level contracts before defining modules

- **Wait-time impact:** Impact on build wait time is uncertain; re-benchmark after
  boundaries exist.
- **Actionability:** `repo-local`
- **Observed evidence:** AI and Gallery contain SwiftUI views, AI depends on
  runtime element/package types, and Plugin spans storage plus JavaScriptCore APIs.
- **Estimated impact:** Medium architecture improvement; uncertain build impact.
- **Confidence:** Medium.
- **Approval required:** Yes; public/internal access and target membership change.
- **Benchmark verification status:** Not yet verified.

### Benchmark one narrow package experiment before adopting SPM

- **Wait-time impact:** Measurement only; it prevents claiming an optimization
  from cumulative task counts that may not reduce developer wait time.
- **Actionability:** `package-manager`
- **Observed evidence:** Modular targets add compile, dependency-scan, and module
  emission tasks; this repository has no measured package-layout comparison.
- **Estimated impact:** High decision quality, no direct speed improvement.
- **Confidence:** High.
- **Approval required:** Yes; use a disposable branch and compare clean plus
  incremental builds for both projects and representative extension targets.
- **Benchmark verification status:** Not yet verified.

## Re-entry criteria

A package migration can be proposed after all of the following are available:

1. A target/source/resource matrix for both projects and every extension.
2. Resource lookup abstraction with app-bundle and package-bundle tests.
3. One-way candidate boundaries with no UI-to-core or target dependency cycle.
4. Repeatable clean and incremental build baselines.
5. A prototype showing equal runtime tests and a measurable wall-clock benefit,
   or a separately approved non-performance reason for modularization.
