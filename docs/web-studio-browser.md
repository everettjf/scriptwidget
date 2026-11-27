# Web Studio in the browser

Design ScriptWidget widgets on Windows, macOS, Linux, or iPad in any modern
browser, see an instant preview, and export a `.swt` package that ScriptWidget
opens on iPhone, iPad, Mac, Android, Windows and Linux. No Mac,
Xcode, or connected device is needed while you work.

Open it from the ScriptWidget site (`/studio/`) or run it locally:

```bash
cd Web/studio && npm ci && npm run dev
```

This is different from [Web Studio on iPhone](web-studio.md), where the browser
edits files that live on a paired iPhone. The browser Studio keeps projects in
the browser and previews them itself.

## Create and edit

- **New** starts a blank Package 2.0 project. **Import** opens a `.swt` or `.zip`;
  you can also drop a package anywhere on the page. Dropping a PNG, JPEG, WebP,
  or GIF adds it to the open project as an image.
- **Gallery** lists the bundled templates and the Gallery widgets with live
  previews. Filter by category or **Featured**, or search. Open one to preview
  it at every size it handles, read its files, copy code, and **Create a copy**:
  the copy becomes a new project saved in this browser, and the template stays
  unchanged. The copy's `widget.json` carries the template's description,
  category, and tags, and declares the Lock Screen or extra-large sizes its
  script handles.
- The file list shows `widget.json`, the entry file, extra scripts for
  `$import`, and images under `image/`. **Add image…** uploads PNG, JPEG, WebP,
  or GIF files (up to 8 MB) for `<image id="name" />` and `<gif file="name" />`.
- The editor has ScriptWidget completions, hover help, and diagnostics.
- Projects are saved in this browser automatically after the editing debounce.
  Switching projects flushes the outgoing draft. **Saved in this browser** appears
  only after the tracked drafts are stored; an older completion cannot clear a
  newer edit or hide an outgoing draft. Saves/deletions are ordered. Wait for the
  saved state before closing; clearing site data removes drafts, so export a
  `.swt` to keep a copy. If storage is unavailable, the UI asks you to export.
- A project disappears only after its deletion commits. If the browser rejects
  deletion, an error keeps the project and any edits made while waiting; you can
  retry or export a backup. Existing disk projects still require a confirmed
  disk deletion after a later save has fallen back to memory.

## Preview

- Choose a device (iPhone sizes, iPad, or Mac), a widget size from the manifest's
  `supportedFamilies`, light or dark appearance, a rendering mode, and the
  `widget-param` value.
- **Reduce transparency** and **Reduce motion** simulate accessibility fallbacks without changing widget source. They start from browser media preferences. Material is a labeled CSS approximation of SwiftUI; the system's Liquid Glass and wallpaper refraction are not reproduced. See [Visual effects](visual-effects.md).
- The preview runs your code in an isolated sandbox with the same rules as the
  iPhone runtime: the same compiler, limits, `$render` behavior, and error
  categories. It renders with layout calibrated against iOS.
- **Problems** lists runtime errors, manifest validation, and preview notes
  (for example, an SF Symbol drawn with a look-alike icon, or a property the
  iPhone runtime ignores). **Console** shows `console.log` output. **Package**
  summarizes the manifest. **Mock Data** configures preview API responses.
- If a content blocker or browser setting blocks the preview sandbox
  (`sandbox.html`), the preview says so within a few seconds. Allow the site or
  use another browser; editing, export, and Install on device keep working.
- The web preview never uses the network. `fetch` and `$http` read the
  **Mock Data** rules; system services use editable sample responses. Fixtures stay in
  the browser and are not exported.

The browser preview is fast feedback, not a pixel-perfect WidgetKit render.
On Windows and Linux the Studio uses the bundled Inter font in place of SF
Pro, so text can wrap slightly differently, and WidgetKit controls the final
look, refresh, and interactions. Always check the widget on the device it is
for before sharing it. See [browser preview coverage](browser-preview-coverage.md) for
what is supported, approximated, or not yet rendered.

## Install on your device

1. Fix any errors in **Problems**; export is blocked until `widget.json` passes
   Package 2.0 validation.
2. Tap or click **Install on device**.
   - In the browser of a phone or tablet that can share files, the share sheet
     opens: choose **ScriptWidget**.
   - Otherwise the `.swt` file downloads, and a list says what to do with it.
3. Open the file in ScriptWidget:
   - **iPhone and iPad:** send it with AirDrop, iCloud Drive, or email, open
     it, tap **Share**, and choose **ScriptWidget**.
   - **Android:** send it to the device and open it with ScriptWidget.
   - **Mac, Windows and Linux:** open it with ScriptWidget on that computer.
4. Review the permissions, then add the widget where your system keeps widgets.

**Export .swt** downloads the same file without the instructions. Which
features and APIs each system has is in [Platform support](platform-support.md);
Windows and Linux are previews and have no personal-data APIs.

## For coding agents

The same engine is available from the command line and as an MCP server, so
Claude Code, Codex, and other agents can edit a package and check the result
without a browser:

```bash
node Web/preview-engine/bin/scriptwidget-preview.mjs MyWidget --family small --output preview.png --diagnostics preview.json
```

```bash
claude mcp add scriptwidget -- node Web/preview-engine/bin/scriptwidget-mcp.mjs
```

Both need Chrome or Chromium (`CHROME_PATH` overrides the location). Every
result includes the package's source hash so a stale image cannot be mistaken
for the latest edit. With `--device` and `--pair-code`, the CLI also uploads
the package to an iPhone running Web Studio and saves the native preview next
to the web one. Details are in [browser preview engine](browser-preview-engine.md).

## Supported browsers

Every change to the web code is checked in Chromium, Firefox, and WebKit on
Linux and Windows (the Web Browsers workflow), and the engine is also checked
in Safari on iOS. Use a current version of Chrome, Edge, Firefox, or Safari.

## Development

Web Studio is a React 19 app in strict TypeScript, built with Vite 7,
Tailwind CSS 4, and shadcn/ui components on Radix primitives. CodeMirror 6
is the editor; the widget preview comes from `Web/preview-engine`.

```bash
cd Web/studio && npm install
```

```bash
npm run dev
```

`npm test` runs the project helper tests, `npm run build` typechecks and
builds `dist/`, and `node scripts/smoke.ts` checks the built site in headless
Chrome. Add shadcn components with `npx shadcn@latest add <name>`; they are
copied into `src/components/ui` and import `cn` from `@/lib/utils`.

## Privacy and security

- Your code runs in a sandboxed frame with an opaque origin and no network
  access; it cannot read the Studio page, your projects, or other sites.
- Projects, images, and fixtures stay in your browser. The Studio has no
  server-side storage and sends nothing anywhere.
- Imported `.swt` files are checked with the same archive limits as the iPhone
  app (size, entry count, paths, symlinks), and a malformed `widget.json` is
  rejected rather than reinterpreted.

## Mock Data

New projects include sample returns for every `$device` and `$system` method,
plus location and HealthKit availability, authorization, steps, active energy,
and heart rate, as well as calendar authorization, calendar lists and event results. These are example values, not readings from your computer or
phone. Dark mode follows the appearance control unless explicitly overridden.
Template gallery previews use the same default samples.

Open **Mock Data** below the preview and choose a data source and API. Primitive
fields have form controls; **Response JSON** handles complete objects, arrays,
nulls, and unusual return shapes. **Apply mock data** applies JSON edits. Choose
**Throw / reject error** to exercise an error branch. Location and calendar
have **Sample success**, **No data**, **Permission denied** and **Unavailable**
scenarios. Health uses **No shared data** instead of claiming read denial:
consent review remains completed and measurements return zero or empty results.
Unavailable Health and Location authorization requests reject, matching the native APIs. Calendar calls still require `calendar` in `widget.json`; mocks do not grant this permission. **Reset this API** restores only the selected API's example.
**Add missing samples** fills older projects without replacing existing method
mocks, legacy fixture values, custom keys, or network rules.

Network responses match an exact URL and method; response `body` is text and
JSON responses are encoded as strings. An `error` simulates a failure. There is
no wildcard response: unknown URLs produce a warning instead of invented data.
Package network permissions and host restrictions still apply. Data Source
rules match `pluginID` and `operationID` (regardless of parameters), with an
HTTPS `url` and either `value` or `error`; the package must declare the plugin,
network permission and domain. This previews the response shape without testing
a plugin's native installation, request mapping or authentication.

Storage provides initial key/value pairs for each preview run; writes are
visible in that run and reset on rerun. Edit project files to provide `$file`
inputs. Rendering, JSX, imports and XML parsing execute normally, `$getenv`
uses the preview controls, and `$runtime` reports the actual preview contract.
These computed APIs are not replaced with arbitrary return mocks.

All settings live with the project draft in this browser, persist across reloads
when browser storage is available, and never enter an exported `.swt` or
`widget.json`. Use **Full JSON** for all options and existing legacy fixtures.
Malformed JSON remains editable and shows a diagnostic rather than being lost.

The additive per-method format is:

```json
{
  "api": {
    "$health.stepCountToday": {
      "value": { "value": 6840, "unit": "count", "start": "2026-01-01T00:00:00Z", "end": "2026-01-01T12:00:00Z" }
    },
    "$location.current": { "error": "Location permission denied" },
    "$device.battery": { "value": { "level": 0.8, "state": "unplugged" } }
  },
  "storage": { "example.count": "7" },
  "fetch": [{ "url": "https://api.example.com/data", "method": "GET", "body": "{\"value\":42}" }],
  "dataSource": []
}
```

Each per-method rule has exactly one of `value` and `error`. Explicit rules take
precedence over legacy `location`, `health.*`, `device` and `system` fixtures.
The Node preview CLI also accepts this fixture format. Defaults in a project
are intentionally stable, including sample timestamps; change them when testing
time-sensitive scripts. Browser JavaScript's real clock is not frozen by mocks.


Preview compilation validates a present `widget.json` before executing scripts. A malformed or incompatible package shows a package error even if configured Mock Data would return success. Package files override a host-supplied manifest object. `minimumRuntimeVersion` targets native API compatibility; the preview's own engine version remains separate.
