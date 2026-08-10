# ScriptWidget Web Studio

Web Studio is a browser authoring surface backed by the ScriptWidget app on an
iPhone or iPad. The browser never implements the JSX renderer. The device is
the only runtime and native-preview authority.

## Version 1 workflow

1. Open **Widgets → Web Studio** and tap **Start Web Studio**.
2. Keep the Web Studio screen in the foreground.
3. From a computer on the same local network, open one of the displayed URLs.
4. Enter the six-digit pairing code.
5. Select an editable widget and text file. Changes save after a 700 ms debounce;
   an unsaved browser draft is retained locally if the connection drops.
6. The selected package entry is evaluated and refreshed in Device Preview.

The first release supports Safari 15.4+, Chrome/Edge 100+, and Firefox 100+
through ordinary HTTP requests. It does not require a Mac. CSS includes a
fallback for browsers that predate `light-dark()`. A Studio session stops when
its view is dismissed or the app leaves the foreground.

## Architecture

- `StudioEditor.bundle` is served directly by the app. The same frontend uses
  the WKWebView bridge in App Studio and HTTP transport in Web Studio.
- `WebStudioServer` owns an ephemeral `NWListener`, advertises
  `_scriptwidget._tcp` through Bonjour, and accepts bounded HTTP requests.
- Package enumeration and writes go through `ScriptManager` and
  `ScriptWidgetPackage`. Request paths are never used as filesystem roots.
- `WebStudioServerView` observes the selected package entry and recreates the
  existing `ScriptCodePreviewView` after a successful save.
- The HTTP transport is an implementation detail. A later WebSocket transport
  can carry the existing versioned Studio envelopes without changing runtime
  ownership.

## HTTP API v1

Static frontend files are public while the manually-started listener exists.
All `/api/v1/*` routes except pairing require `X-Studio-Token`.

| Method | Route | Purpose |
| --- | --- | --- |
| `POST` | `/api/v1/pair` | Exchange the displayed code for an ephemeral token. |
| `GET` / `DELETE` | `/api/v1/session` | Read device/preview state or explicitly end the session. |
| `GET` | `/api/v1/packages` | List writable packages, entries, and editable text files. |
| `GET` | `/api/v1/document?package=&path=` | Read one package-relative text file. |
| `PUT` | `/api/v1/document` | Atomically save one bounded package-relative text file. |
| `POST` / `DELETE` | `/api/v1/document` | Create a supported text file or delete a non-entry text file. |
| `GET` | `/api/v1/events?after=` | Resume bounded device events after a sequence number. |
| `GET` | `/api/v1/preview` | Read the latest PNG captured from the native device preview. |

Document reads return a SHA-256 `revision`. Saves must send that value as
`baseRevision`. If the device copy changed, the server returns `409 Conflict`
with its current revision and content and does not write. Web Studio then lets
the author compare both copies, keep the device version, or explicitly rebase
and save the browser draft.

The server accepts one paired browser per session. Tokens and pairing state are
memory-only and rotate whenever the server starts.

## Security boundaries

- The listener is off by default and stops outside the active scene.
- Requests are limited to 2 MiB; document content is limited to 1 MiB.
- Only known editable packages returned by `ScriptManager` can be selected.
- `ScriptWidgetPackage.resolvedPackageURL` rejects absolute paths, traversal,
  symlink escapes, and package-boundary escapes.
- Only an allowlist of text extensions is exposed. Binary resources and app,
  app-group, iCloud, build-cache, Keychain, and credential paths are not APIs.
- Existing Package 2.0 validation, permissions, network-domain checks, runtime
  budgets, and fail-closed behavior remain authoritative during evaluation.
- Static responses disable caching and MIME sniffing. Version 1 is intended for
  trusted local networks; it does not claim confidentiality against a hostile
  network because transport is HTTP.

## Web Studio 1.0 authoring experience

- A professional Explorer/editor/Inspector workspace scales down to drawer-style
  sidebars on narrow browsers.
- The status bar distinguishes connection, local draft, saving, saved, conflict,
  and native-preview-requested states. It never claims that native rendering
  succeeded when the device has only received a request.
- The Problems panel exposes local ScriptWidget diagnostics and navigates to the
  affected line. The command palette and documented keyboard shortcuts cover
  save, format, Explorer, Inspector, and Problems actions.
- Recovery and conflict notices require an explicit choice and never silently
  replace either copy.
- Saves are serialized and bound to a fixed package/path identity. Switching a
  file first attempts to save and otherwise asks before leaving the local draft;
  closing the page with an unsaved, failed, or conflicted save shows the browser's
  standard leave warning.

## 1.0 contract freeze

For the first public release, Package 2.0, StudioBridge v1, Runtime API schema,
Skills 1.0, Gallery 1.0, Data Source Plugin 1.0, and Web Studio HTTP API v1 are
compatibility contracts. Changes before release should be additive unless they
fix data loss, a security boundary, or behavior that cannot be supported. A
breaking correction requires a documented migration and matching regression
tests in the same change.

## Known version 1 limits

- Browser-to-device updates use serialized, debounced HTTP. Device-to-browser
  console, file-list, presence, and preview events use a resumable sequence
  channel with automatic reconnect rather than WebSocket.
- The optional browser preview is a PNG captured from the device's native
  SwiftUI preview. The browser never recreates WidgetKit rendering.
- File rename, binary upload, TLS, and multi-client collaboration are deferred.
- A network with client isolation, restrictive VPN, or firewall rules may block
  direct access even when both devices appear to use the same Wi-Fi.

## P0 stability behavior

- The device screen provides a QR code, copyable addresses and pairing code,
  Local Network settings guidance, recent safe logs, and a shareable diagnostic
  report that excludes tokens, pairing codes, and source content.
- The browser sends a heartbeat every five seconds. The device grants a
  15-second writer lease, so refreshes reconnect while closed or abandoned
  browsers automatically release the session.
- Browser offline/online state is visible, and an explicit Disconnect action
  rotates credentials immediately.
- The physical-device and failure-path release matrix is maintained in
  [`web-studio-p0-test-plan.md`](web-studio-p0-test-plan.md).

## Next protocol-compatible improvements

1. Replace resumable event polling with WebSocket only when profiling shows a
   material latency or energy benefit; retain the cursor as reconnect fallback.
2. Add package rename and bounded binary-resource upload using the existing
   secure package APIs.
3. Add opt-in multi-client collaboration after per-client ownership and conflict
   semantics are specified.
