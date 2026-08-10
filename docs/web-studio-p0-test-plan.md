# Web Studio P0 Test Plan

This is the release checklist for the local-network Web Studio stability pass.
Do not mark a row as passed unless it was executed on the named environment.

## Automated gates

- [x] Editor unit and performance tests pass (`cd Editor/editorfe && npm test`).
- [x] Editor production bundle builds and is copied to iOS and macOS (`npm run release`).
- [x] HTTP parser rejects incomplete, negative-length, and duplicate-query edge cases.
- [x] A real `NWListener` serves the Studio HTML over loopback.
- [x] Pairing produces a token and authenticated heartbeat succeeds.
- [x] Explicit disconnect invalidates the previous token.
- [x] An abandoned browser lease expires and releases the writer.
- [x] HTTP saves reach the real `ScriptWidgetPackage` and persist the final source.
- [x] Stale document revisions return 409 with the current device copy and never overwrite it.
- [x] Browser draft recovery and save/conflict state transitions have deterministic unit tests.
- [x] Requests larger than 2 MiB return 413 and the listener stays available.
- [x] iOS app and hosted runtime tests build on the supported deployment target.
- [x] macOS app and runtime tests remain green after the shared editor rebuild.

## Executed physical-device smoke

On 2026-08-09, a signed Debug build was installed on an iPhone 17 Pro. Web
Studio was started with the non-interactive QA launch argument, advertised a
Wi-Fi address, and a separate Mac successfully fetched `/` over that physical
local-network route. The returned HTML referenced the current generated Web
Studio assets. No pairing code, token, or source was logged.

## Physical iPhone and iPad matrix

For every row, record device model, OS version, browser version, network type,
result, and a shared diagnostics report when it fails.

| Device | Computer/browser | Network | Required behavior |
| --- | --- | --- | --- |
| iPhone | Windows Edge or Chrome | Home/office Wi-Fi | Pair, edit, save, and refresh native preview. |
| iPhone | macOS Safari | Home/office Wi-Fi | Pair, edit, save, and refresh native preview. |
| iPad | Windows Edge or Chrome | Home/office Wi-Fi | Pair and keep preview usable in landscape. |
| iPad | macOS Safari or Chrome | Personal hotspot | Pair and save without Bonjour dependency. |

For each successful session:

1. Start Web Studio and accept Local Network access.
2. Scan the QR code, then separately test **Copy Address**.
3. Enter the pairing code and open `main.jsx`.
4. Make ten rapid edits; confirm the final source and native preview agree.
5. Refresh the browser; confirm the existing token reconnects.
6. Close the browser, wait 20 seconds, and confirm Connected Browsers becomes 0.
7. Pair a second browser and confirm it becomes the only writer.
8. Use **Disconnect** and confirm the old browser token no longer works.
9. Background the app and confirm the server stops.
10. Share Diagnostics and confirm no token, pairing code, or file content appears.

## Failure-path matrix

| Scenario | Expected result |
| --- | --- |
| Local Network permission denied | Listener shows an actionable error and an Open Settings button. |
| Computer is offline | Browser status says the computer is offline; no source is lost. |
| Device and computer are on isolated guest Wi-Fi | Help explains same-network, VPN, and client-isolation checks. |
| VPN blocks the device address | Help suggests disabling VPN; Share Diagnostics remains available. |
| Invalid pairing code | Browser stays in pairing dialog and reports the failure. |
| A second browser tries to pair | It receives a clear “another browser” response. |
| Browser sleeps longer than the lease | It requests the newly displayed code after returning. |
| Source exceeds 1 MiB | Save fails without modifying the package. |
| Request exceeds 2 MiB | Server returns HTTP 413 and remains available. |
| Package path contains traversal or an absolute path | Request fails without reading or writing outside the package. |
| iCloud source is not downloaded | Existing iCloud state/error is shown; server remains responsive. |

## Debug-only physical network smoke test

A Debug build accepts `-WebStudioAutoStart`. This starts the listener without UI
automation and logs only its non-secret address. It never logs pairing codes,
tokens, or source. Use it to verify that another machine can fetch `/` from a
signed physical device before running the interactive matrix.
