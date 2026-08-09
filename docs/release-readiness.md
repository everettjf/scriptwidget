# ScriptWidget release readiness

This document is the ship gate for iOS 16+ and macOS 26+. A release candidate is ready only when the automated command below passes and every applicable device row has evidence attached to the release issue.

```sh
./Scripts/release-readiness.sh
./Scripts/device-matrix.sh
./Scripts/ipad-icloud-tests.sh
```

## Automated gates

- All public runtime unit, execution, error, cache, security and template compatibility tests pass.
- Every bundled template has valid metadata and stays below the 512 KiB source limit.
- CodeMirror tests pass, its production bundle is reproducible, and no Monaco source remains.
- macOS app/tests and iOS Simulator app compile with signing disabled.
- Runtime execution stays below the checked performance budgets in `RuntimePerformanceTests`.
- CI runs the same entry point; no separate “CI-only” validation logic is allowed.
- CI also runs the full shared test target on an iPad Simulator; real iCloud tests remain opt-in because hosted runners have no signed-in Apple ID.

## Device matrix

| Platform | Required coverage | Checks |
| --- | --- | --- |
| iPhone, iOS 16 | oldest supported physical device | create/edit/save, Small/Medium/Large widget, offline relaunch |
| iPhone, current iOS | current physical device | all families, interactive controls, animation, background refresh |
| iPad, current iPadOS | current physical device | split view, keyboard editing, Extra Large widget |
| Apple silicon Mac, macOS 26 | oldest supported Mac | large-file editing, resize, widget gallery, sleep/wake |
| Apple silicon Mac, current macOS | current Mac | all widgets, iCloud sync, import/export, animation |

Record OS/build, hardware, commit, pass/fail, peak memory and links to screenshots or Instruments traces. Physical-device rows cannot be replaced by Simulator results.

### iPad and iCloud automation

`ipad-icloud-tests.sh` always runs deterministic iPad tests for Extra Large families, package caching, eviction fallback, placeholder mapping, and every user-visible iCloud state. Supply `SCRIPTWIDGET_IPAD_UDID` to additionally invoke Simulator's `icloud_sync` command.

For real iCloud I/O, connect and trust a signed-in iPad, then set `SCRIPTWIDGET_ICLOUD_DEVICE_DESTINATION` to its xcodebuild destination. For cross-device convergence, connect two signed-in devices using the same iCloud account and set both `SCRIPTWIDGET_ICLOUD_WRITER_DESTINATION` and `SCRIPTWIDGET_ICLOUD_READER_DESTINATION`. The test writes on one device and requires the other to observe the same token within 60 seconds. Real-container tests deliberately fail—not skip—when explicitly enabled but the entitlement/account/container is unavailable.

## Performance budgets

- Cached trivial runtime render: median under 100 ms, p95 under 250 ms on release hardware.
- Full uncached template render: p95 under 1 s; hard runtime timeout remains 5 s.
- Editor: typing latency under 50 ms at 100 KiB and under 100 ms at 1 MiB.
- Preview refresh: debounce 300–500 ms; stale generations must never replace a newer preview.
- Widget timeline: peak resident memory below the platform extension limit with at least 20% headroom.

The editor budgets are enforced by repeated CodeMirror state creation and edit transactions for 100 KiB and 1 MiB JSX documents. Runtime tests enforce cached execution and bounded trace history. Physical-device Instruments evidence remains mandatory for end-to-end typing, preview, cold-launch, and resident-memory measurements.

## Recovery and synchronization

- Source writes are atomic and immediately refresh the local build cache.
- Studio records a debounced crash-recovery draft before autosave completes.
- A draft is restored only if the underlying file hash is unchanged. If iCloud or another device changed the file, the stale draft is ignored instead of overwriting newer content.
- Successful manual save, autosave, or Copilot Apply removes the recovery draft.
- The iPad/iCloud automation covers deterministic cache and placeholder behavior; signed-in device destinations enable real round-trip and two-device convergence tests.

## Security and privacy review

- Script file access is package-relative and rejects traversal/symlink escape.
- Network access permits public HTTP(S), rejects local/private hosts, and caps responses at 2 MiB.
- Storage is namespaced per package, with bounded keys/values; clear only affects that package.
- Console output is bounded. Secrets and complete response bodies must not be written to unified logs.
- Health and location remain explicit, purpose-string-backed permissions and must fail closed.
- Imported packages are untrusted content. Review new APIs against filesystem, network, storage and privacy boundaries.

## Release procedure

1. Freeze runtime schema and regenerate docs with `npm run docs` in `Editor/editorfe`.
2. Run the automated gate from a clean checkout.
3. Complete the device matrix and archive the evidence.
4. Verify App Store privacy answers, screenshots, support/privacy URLs, version and build numbers.
5. Archive both apps with distribution signing, validate, then distribute to TestFlight for a final smoke pass.
6. Tag the exact tested commit; never rebuild from an untested commit.
