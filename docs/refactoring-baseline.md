# Architecture Refactoring Baseline

This document records the behavior-preserving baseline used for the staged
architecture refactoring. Each implementation stage must keep this gate green
before it is committed and pushed.

## Baseline

- Date: 2026-08-09
- Branch: `codex/wwdc26-widgetkit`
- Starting commit: `1ebd948`
- Xcode: 27.0 (`27A5228h`)
- Node.js: 23.11.0
- Command: `./Scripts/release-readiness.sh`
- Result: passed

The gate verified:

- release metadata, Gallery templates, API documentation, and editor sources;
- local documentation links and images;
- all 27 editor tests;
- deterministic Studio editor bundle regeneration;
- macOS `ScriptWidgetRuntimeTests`;
- the macOS `ScriptWidgetMac` application build;
- the iOS `ScriptWidget` Simulator build; and
- iOS `ScriptWidgetRuntimeTests` on an iPhone 17 Simulator.

## Known baseline warnings

The iOS test target is configured with an iOS 16.0 deployment target while the
Xcode 27 XCTest support libraries report a minimum version of iOS 17.0. The
linker emits deployment-version warnings, but the tests complete successfully.
This warning predates the refactoring and must not be reported as a new
regression.

## Stage gate

After each stage:

1. Run focused tests for the changed behavior.
2. Run `./Scripts/release-readiness.sh`.
3. Confirm generated editor bundles have no unexplained differences.
4. Confirm the worktree contains only the intended stage changes.
5. Commit and push the stage independently.

Signed physical-device and real iCloud-container checks remain separate from
this deterministic local gate and must never be described as passing unless
they were actually performed.
