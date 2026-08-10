# ScriptWidget Web Studio

Web Studio is a browser authoring surface backed by the ScriptWidget app on an
iPhone or iPad. The browser never implements the JSX renderer. The device is
the only runtime and native-preview authority.

## Version 1 workflow

1. Open **Widgets → Web Studio** and tap **Start Web Studio**.
2. Keep the Web Studio screen in the foreground.
3. From a computer on the same local network, open one of the displayed URLs.
4. Enter the six-digit pairing code.
5. Select an editable widget and text file. Changes save after a 700 ms debounce.
6. The selected package entry is evaluated and refreshed in Device Preview.

The first release supports Safari, Chrome, Edge, and Firefox through ordinary
HTTP requests. It does not require a Mac. A Studio session stops when its view
is dismissed or the app leaves the foreground.

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
| `GET` | `/api/v1/packages` | List writable packages, entries, and editable text files. |
| `GET` | `/api/v1/document?package=&path=` | Read one package-relative text file. |
| `PUT` | `/api/v1/document` | Atomically save one bounded package-relative text file. |

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

## Known version 1 limits

- The browser shows the editor and save state; native preview remains visible
  only on the device.
- Browser-to-device updates use debounced HTTP rather than WebSocket push.
- File creation, rename, deletion, binary upload, QR codes, TLS, and browser-side
  device-preview screenshots are deferred.
- A network with client isolation, restrictive VPN, or firewall rules may block
  direct access even when both devices appear to use the same Wi-Fi.

## Next protocol-compatible improvements

1. Add WebSocket transport for diagnostics, console output, presence, and
   reconnect without changing editor message names.
2. Add server-issued revisions and reject stale writes with `409 Conflict`.
3. Add package operations and bounded resource upload using the existing secure
   package APIs.
4. Add device-rendered preview snapshots for optional browser display. This is
   a remote view of the native renderer, never a browser renderer.
