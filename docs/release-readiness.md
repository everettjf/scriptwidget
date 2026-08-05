# ScriptWidget release readiness

This document is the ship gate for iOS 16+ and macOS 26+. A release candidate is ready only when the automated command below passes and every applicable device row has evidence attached to the release issue.

```sh
./Scripts/release-readiness.sh
```

## Automated gates

- All public runtime unit, execution, error, cache, security and template compatibility tests pass.
- Every bundled template has valid metadata and stays below the 512 KiB source limit.
- CodeMirror tests pass, its production bundle is reproducible, and no Monaco source remains.
- macOS app/tests and iOS Simulator app compile with signing disabled.
- Runtime execution stays below the checked performance budgets in `RuntimePerformanceTests`.
- CI runs the same entry point; no separate “CI-only” validation logic is allowed.

## Device matrix

| Platform | Required coverage | Checks |
| --- | --- | --- |
| iPhone, iOS 16 | oldest supported physical device | create/edit/save, Small/Medium/Large widget, offline relaunch |
| iPhone, current iOS | current physical device | all families, interactive controls, animation, background refresh |
| iPad, current iPadOS | current physical device | split view, keyboard editing, Extra Large widget |
| Apple silicon Mac, macOS 26 | oldest supported Mac | large-file editing, resize, widget gallery, sleep/wake |
| Apple silicon Mac, current macOS | current Mac | all widgets, iCloud sync, import/export, animation |

Record OS/build, hardware, commit, pass/fail, peak memory and links to screenshots or Instruments traces. Physical-device rows cannot be replaced by Simulator results.

## Performance budgets

- Cached trivial runtime render: median under 100 ms, p95 under 250 ms on release hardware.
- Full uncached template render: p95 under 1 s; hard runtime timeout remains 5 s.
- Editor: typing latency under 50 ms at 100 KiB and under 100 ms at 1 MiB.
- Preview refresh: debounce 300–500 ms; stale generations must never replace a newer preview.
- Widget timeline: peak resident memory below the platform extension limit with at least 20% headroom.

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
