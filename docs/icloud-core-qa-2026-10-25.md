# iCloud core-flow acceptance — 2026-10-25

After this QA, the user authorized preparing and submitting the 27.1.5 repair release (new build 27016). Record synchronization and automatic library migration remain deferred. This check used the installed TestFlight 27.1.5 (27015) on an iPhone 17 Pro running iOS 27.0.1, signed in to a real iCloud account. iCTRL 1.98.12 drove the UI over USB. No account sign-out, app uninstall, or deletion of existing user widgets was performed.

## Physical-device results

| Flow | Observed result |
| --- | --- |
| Open the existing iCloud library | Ready; the existing Activity Rings package remained listed |
| Create Habit Heatmap from the bundled template | Created in the selected iCloud library; preview finished successfully |
| Open nested resources | `lib/records.js` appeared in the package file list and was loaded by the running template |
| Save configuration | A custom habit name persisted and appeared on the Home Screen |
| Add and configure Home Screen widget | Edit Widget was available; the script selector listed the installed packages |
| Render small, medium, and large widgets | All three sizes displayed the actual heatmap; size changes briefly showed a placeholder before rendering |
| Real widget actions | Read and Run each changed from 0 to 1 day; their cells lit and their buttons changed to Done today |
| Repeat an already completed action | History remained two entries, one per habit on the same date |
| Terminate/reopen the app | The package, configuration and saved history remained available |
| Rename a habit | The existing record remained associated with the habit ID and the new display name appeared |
| Record backup and restore | Exported the test record JSON; reimport preview showed one record; confirmed restore and verified that record remained |
| Switch iCloud → local → iCloud | Local initially empty; created Datetime Current locally; switching back restored the two iCloud packages and the heatmap history |
| Create and rename an auxiliary package file | Created `qa-notes.txt`, renamed it to `qa-notes-final.txt`, and saw it in the saved package and subsequent preview |
| Remix and delete the test copy | The copy started with History (0); deleting that copy left the original package and records intact after relaunch |
| Export an individual package | Saved the test package as `Habit Heatmap.swt` in iCloud Downloads |
| Import the exported package through the Files picker | **Failed in 27015:** `.swt` was not selectable because the importer accepts ZIP and the app did not declare the `.swt` ZIP subtype |

The auxiliary file and Habit Heatmap test package are QA-created data. The local Datetime Current package is also QA-created. The pre-existing Activity Rings source was not edited on the phone. The phone was returned to the iCloud library with a medium Home Screen test widget.

## Findings and bounded follow-up

1. **Archive import:** register `com.everettjf.scriptwidget.archive`, with extension `swt` and conformance to `public.zip-archive`, on both native apps. Preserve the existing archive format, extraction preflight, limits and transaction logic. Add a regression check that the host's exported filename is accepted by the ZIP content-type filter. The installed phone build remains 27015 until a separate build is installed; do not describe the fixed picker as physically verified yet.
2. **Duplicate library choices:** the chooser displayed the same system location using `/var/...` and `/private/var/...`. The chooser deduplicates raw path strings, whereas profile activation resolves canonical paths and directory receipts. This is a reproducible presentation issue; the tested switch-back preserved the existing records. Follow up with canonical, receipt-aware deduplication without changing stored identities or treating replacement directories as the same library.
3. **Datetime Current small preview:** the built-in clock ran without an execution error, but its date/time text wrapped tightly in the small preview. Keep a separate layout follow-up; this does not demonstrate an iCloud failure.

## Current behavior and recommended iCloud experience

Current source behavior: a new library prefers available iCloud; an existing ready local selection stays local when iCloud later becomes available. Explicit selection switches independent libraries and does not move packages or records. `$storage` values remain local even when source files live in iCloud; see [the storage contract](storage-api.md).

Recommended follow-up, not implemented in this task:

- Offer a one-time migration prompt when iCloud becomes available to an existing local user. Provide “Move my widgets to iCloud” and “Keep using this device”. Never switch silently to an empty library.
- Copy and verify package sources/assets together with the appropriate local configuration/record bindings, then switch the selection only after the complete operation succeeds. Preserve a recoverable local copy and support interruption recovery.
- Preview conflicts and keep both copies by default. Do not overwrite same-name packages or merge record ownership by name.
- Preserve or deliberately rebind Home Screen selections during migration, with deterministic regression coverage.
- Explain separately that iCloud source-file sync does not currently sync `$storage` history between devices. Cross-device record synchronization needs its own contract and conflict policy.

## Coverage limits and evidence

This session does not prove cross-device convergence, iCloud account toggling, eviction/offline behavior, reinstall recovery, lock-screen widget behavior, Health/Calendar/Photos authorization, GitHub login, or all runtime APIs. Deterministic iCloud/cache and archive tests cover additional cases; these must not be called physical-device coverage.

Raw timestamped iCTRL responses and private screenshots are retained locally under `/tmp/scriptwidget-iphone17-qa/` (a copy of the JSON evidence is under ignored `__Release/capabilities/iphone17-icloud-qa/`). They are not published because screenshots contain unrelated personal apps and Files listings. Core widget screenshots include `04-checkin-one-day.jpg`, `07-large-home-settled.jpg` and `08-small-home.jpg`. The failed picker capture is `09-swt-import-disabled.jpg`.

Before the archive-type fix, the Activity Rings redesign passed the complete local readiness gate: macOS 713 passed / 0 failed / 32 skipped; iOS Simulator 719 passed / 0 failed / 31 skipped. Log: `/tmp/sw-rings-readiness.log`. Archive-type regression and final gate results are recorded separately after validation.

CI-only stabilization at `bf632af` passed [Release Readiness run 40264311950](https://github.com/everettjf/scriptwidget/actions/runs/40264311950), including iPad/iCloud. This run predates the uncommitted visual and archive metadata changes and is not evidence for those changes.

Archive-type focused verification: iOS Simulator passed both `testExportedWidgetArchiveIsSelectableByZIPImporter` and `testExportImportRoundTripDeduplicatesWithoutOverwrite` (2 passed, 0 failed), result bundle `Test-ScriptWidgetRuntimeTests-2026.10.25_21-29-59--0700.xcresult`. An earlier attempted baseline run stalled before launching the test host and was stopped; it is not counted as a product failure or a completed regression test. Restarting only the dedicated QA simulator allowed the focused run to complete. The real 27015 picker failure and the pre-fix system type lookup (`swt` was a dynamic type, not ZIP) are the before-fix evidence.

At the end of device testing, the original heatmap still showed History (2) after deleting its QA remix and cold-relaunching. The phone was left in the iCloud Studio list, and the iCTRL server/USB forwarding session were stopped. The signed TestFlight app and account settings were not replaced.

Final local release-readiness gate completed successfully (exit 0), including editor/Web/browser checks, native probes, both app builds and the shared runtime suites. macOS: 714 passed / 0 failed / 32 skipped (`Test-ScriptWidgetRuntimeTests-2026.10.25_21-32-27--0700.xcresult`). iOS Simulator: 720 passed / 0 failed / 31 skipped (`Test-ScriptWidgetRuntimeTests-2026.10.25_21-34-46--0700.xcresult`). Log: `/tmp/sw-icloud-qa-final-readiness.log`. Skipped checks remain skipped. `plutil -lint`, documentation-link checks and `git diff --check` also passed. This is local evidence for the current changes, not a new remote CI run or a new TestFlight upload.
