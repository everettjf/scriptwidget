# ScriptWidget release readiness

This document is the ship gate for the iOS App/Share on iOS 16+, the iOS Widget extension on iOS 18+, and the macOS App/Widget on macOS 26+. The user confirmed retaining these existing deployment targets on 2026-10-22. A release candidate is ready only when the automated command below passes and every applicable device row has evidence attached to the release issue. Android, Windows and Linux are not covered by this gate; their checks are recorded in [Android test notes](android/testing.md), [Windows test notes](windows/testing.md) and [Linux test notes](linux/testing.md).

```sh
./Scripts/release-readiness.sh
./Scripts/device-matrix.sh
./Scripts/ipad-icloud-tests.sh
```

## Current staged scope

The 2026-10-22 A+B delivery scope (Spotify removed; C/D canceled) is recorded in the [staged delivery list](widget-capabilities-status.md), with authoring work and outstanding device acceptance in the [TODO](widget-capabilities-todo.md). Completing this development stage does not waive the ship gate above. No deployment, store upload or review submission is implied.

## Automated gates

- All public runtime unit, execution, error, cache, security and template compatibility tests pass.
- Every bundled template has valid metadata and stays below the 512 KiB source limit.
- CodeMirror tests pass, its production bundle is reproducible, and no Monaco source remains.
- macOS app/tests and iOS Simulator app compile with signing disabled.
- Runtime execution stays below the checked performance budgets in `RuntimePerformanceTests`.
- CI runs the same entry point; no separate “CI-only” validation logic is allowed.
- CI also runs the full shared test target on an iPad Simulator; real iCloud tests remain opt-in because hosted runners have no signed-in Apple ID.
- Local documentation links/images, Gallery file sizes and SHA-256 hashes, and required community-health files validate in the same gate.

## Device matrix

| Platform | Required coverage | Checks |
| --- | --- | --- |
| iPhone, iOS 16 | oldest supported App OS | App create/edit/save and offline relaunch; Widget extension is unavailable below iOS 18 |
| iPhone, iOS 18 | oldest supported Widget OS | Small/Medium/Large widget, declared actions, offline timeline fallback |
| iPhone, current iOS | current physical device | all families, interactive controls, animation, background refresh |
| iPad, current iPadOS | current physical device | split view, keyboard editing, Extra Large widget |
| Apple silicon Mac, macOS 26 | oldest supported Mac | large-file editing, resize, widget gallery, sleep/wake |
| Apple silicon Mac, current macOS | current Mac | all widgets, iCloud sync, import/export, animation |

Record OS/build, hardware, commit, pass/fail, peak memory and links to screenshots or Instruments traces. Physical-device rows cannot be replaced by Simulator results.

### iPad and iCloud automation

`ipad-icloud-tests.sh` always runs deterministic iPad tests for Extra Large families, package caching, eviction fallback, placeholder mapping, and every user-visible iCloud state. Supply `SCRIPTWIDGET_IPAD_UDID` to additionally invoke Simulator's `icloud_sync` command.

The runtime tests also run on a connected device (the test target signs automatically with the app's team); tests that read the repository checkout skip there, since a device cannot see the Mac's disk. For real iCloud I/O, connect and trust a signed-in iPad, then set `SCRIPTWIDGET_ICLOUD_DEVICE_DESTINATION` to its xcodebuild destination. For cross-device convergence, connect two signed-in devices using the same iCloud account and set both `SCRIPTWIDGET_ICLOUD_WRITER_DESTINATION` and `SCRIPTWIDGET_ICLOUD_READER_DESTINATION`. The test writes on one device and requires the other to observe the same token within 60 seconds. Real-container tests deliberately fail—not skip—when explicitly enabled but the entitlement/account/container is unavailable.

## Performance budgets

- Cached trivial runtime render: median under 100 ms, p95 under 250 ms on release hardware.
- Full uncached template render: p95 under 1 s; hard runtime timeout remains 5 s.
- Editor: typing latency under 50 ms at 100 KiB and under 100 ms at 1 MiB.
- Preview refresh: debounce 300–500 ms; stale generations must never replace a newer preview.
- Widget timeline: peak resident memory below the platform extension limit with at least 20% headroom.

The editor budgets are enforced by repeated CodeMirror state creation and edit transactions for 100 KiB and 1 MiB JSX documents. Runtime tests enforce cached execution and bounded trace history. Physical-device Instruments evidence remains mandatory for end-to-end typing, preview, cold-launch, and resident-memory measurements.

## Recovery and synchronization

- Source writes are atomic and immediately refresh the local build cache.
- While iCloud is reachable, the app proactively caches executable text and package image resources up to 25 MiB each. WidgetKit falls back to those local copies when cellular iCloud Drive is disabled or the primary ubiquitous files are evicted.
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

### GitHub releases

The repository's Releases list holds five products, told apart by tag prefix: `v<version>` for the Apple apps, `android-v<version>` for Android, `windows-v<version>` for Windows, `linux-v<version>` for Linux and `cli-v<version>` for the command line tool.

- The newest app release (Apple, Android, Windows or Linux) carries the Latest mark, so the repository page shows a recent date. Create it with `gh release create … --latest`.
- A command line tool release never takes the mark, and neither does a preview of an app (such as Windows 0.1.0 or Linux 0.1.0): create these with `--latest=false`.
- When an Apple version goes live on the App Store, tag the commit it was built from as `v<version>` and create a release with the App Store release notes and the two App Store links. It has no files attached.
- Do not publish a release without notes.

### Apple build/upload and manual review

For the current A/B release, App Review is submitted manually by the user.
`Scripts/release-apple.sh --testflight-only` increments the shared patch/build
versions, runs the release gate, archives iOS/macOS and uploads both builds to
TestFlight. It does not submit App Review with that option.

```sh
export APPLE_ID='developer@example.com'
export APPLE_SPECIFIC_PASSWORD='xxxx-xxxx-xxxx-xxxx'
export APPLE_TEAM_ID='ABCDE12345'

./Scripts/release-apple.sh --dry-run --testflight-only
./Scripts/release-apple.sh --yes --testflight-only
```

The helper always increments the project versions; inspect dry-run output before
using it. The current prepared source is 27.1.3 (27013), so calling the helper
would choose the next patch/build, rather than upload an existing 27013 archive.
If the intended store version is already prepared, archive/export that exact
source with Xcode and upload its artifacts without invoking this version bump.
A signed Debug device build is not an App Store distribution archive.

The Developer Team ID selects the signing team; Xcode still needs a valid local
distribution certificate/profile or an authenticated developer account. The
Apple ID and app-specific password authenticate binary validation and upload.
No third-party release tool or Ruby gem is used. The script reuses metadata and
screenshots already present in App Store Connect and does not commit or tag
changes automatically.

The existing general-purpose helper, when run **without `--testflight-only`**,
also waits for processing, attaches builds and submits App Review. That path
requires `APP_STORE_CONNECT_API_KEY_ID`, `APP_STORE_CONNECT_API_ISSUER_ID` and
`APP_STORE_CONNECT_API_KEY_PATH` with App Manager/Admin access. It is outside the
current user-authorized review workflow. Do not omit the option or invoke
`app-store-connect-submit.rb` for this release; the user completes review in
App Store Connect. Keep credentials and `.p8` files outside the repository.
