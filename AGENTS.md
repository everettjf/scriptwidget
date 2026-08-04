# Repository Guidelines

## Project Structure & Module Organization
- `Shared/ScriptWidgetRuntime/`: core Swift runtime (JavaScriptCore host, JSX → SwiftUI rendering, helper APIs).
- `iOS/ScriptWidget*`: iOS app, widget, and share extension sources (SwiftUI views under `View/`, managers under `Manager/`).
- `macOS/ScriptWidgetMac*`: macOS app + widget targets reusing the shared runtime.
- `Editor/editorfe/`: React 17 + CodeMirror 6 editor frontend (CRA).
- `Resource/`: marketing assets, screenshots, icons.
- `Scripts/<PackageName>/main.jsx`: runtime widget packages (synced via iCloud/app group); build artifacts land in `__Build/`.

## Build, Test, and Development Commands
- `open iOS/ScriptWidget.xcodeproj` and `open macOS/ScriptWidgetMac.xcodeproj`: build/run in Xcode (schemes: `ScriptWidget`, `ScriptWidgetWidget`, `ScriptWidgetShare`, `ScriptWidgetMac`, `ScriptWidgetMacWidget`).
- `cd Editor/editorfe && npm install`: install editor dependencies.
- `npm start`: run the editor dev server at `http://localhost:3000`.
- `npm test`: run editor tests (react-scripts).
- `npm run build`: produce static editor assets in `Editor/editorfe/build`.
- When running iOS/macOS targets, enable the `iCloud.ScriptWidget` container and `group.everettjf.scriptwidget` app group so script storage works.

## Coding Style & Naming Conventions
- Swift: 4-space indentation, Xcode defaults, `UpperCamelCase` for types, `lowerCamelCase` for methods/vars. Keep SwiftUI views in `View/` and managers in `Manager/`.
- JavaScript/React: 2-space indentation (match existing files), `UpperCamelCase` for components, `lowerCamelCase` for functions. Prettier is available but not wired; avoid broad reformatting.
- Runtime scripts: packages live under `Scripts/<PackageName>/` with `main.jsx` entrypoint.

## Testing Guidelines
- Editor: `npm test` (Jest via react-scripts + Testing Library). Add tests next to related components when feasible.
- Swift: no dedicated unit-test target yet; validate by running the iOS/macOS app and widget schemes. Smoke-test Live Activity/Dynamic Island rendering and iCloud migration paths when touching runtime or storage.

## Commit & Pull Request Guidelines
- History shows short, informal summaries (often lowercase) and merge commits; no strict convention. Use concise, action-oriented summaries and add a short body when context helps.
- PRs should include: a clear description, linked issue (if applicable), and screenshots for UI changes. Note which schemes/commands you ran (e.g., `ScriptWidgetWidget`, `npm test`).

## Current Product Priorities

- Define and version the public JavaScript/JSX runtime API, including supported components, properties, errors, storage, networking, and migration behavior.
- Add a Swift test target for parser/runtime semantics and golden rendering fixtures for representative widgets.
- Keep example templates runnable against the current runtime and validate them in CI.
- Treat script execution, network access, shared containers, and imported packages as security boundaries; document limits and fail closed on unsupported capabilities.
- Measure widget timeline generation, JavaScript evaluation, memory use, and cold launch on both iOS and macOS before adding heavier APIs.
