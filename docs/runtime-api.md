# ScriptWidget runtime API 1.0

The public JavaScript/JSX host contract is versioned independently from the app. Scripts can read `$runtime.apiVersion` and must feature-detect optional device capabilities.

## Global API

Version 1.0 exposes `$component`, `$console`, `$dataSource`, `$device`, `$dynamic_island`, `$element`, `$error`, `$fetch`, `$file`, `$getenv`, `$health`, `$http`, `$import`, `$location`, `$render`, `$runtime`, `$storage`, `$system`, `console`, and `fetch`.

`$dataSource.request(pluginID, operationID, parameters)` calls an installed declarative connector. It is available only to Package 2.0 widgets that declare the plugin identifier, `network` permission, and the connector host. See [Data Source Plugins](data-source-plugins.md).

Removing or changing the meaning of a 1.0 global requires a new major API version. Additive properties may ship in a minor version.

## Resource limits

- Source text: 512 KiB per execution.
- Transpiled JavaScript: 2 MiB per execution.
- Execution: 5 seconds, including unresolved asynchronous work.

Limits are available under `$runtime.limits`. Exceeding one produces a visible resource-limit error instead of a blank widget. Widget extensions remain subject to stricter operating-system CPU and memory budgets.

Bundled templates are contract-tested against the source limit. New examples must keep `main.jsx` UTF-8 encoded and runnable without undocumented globals.

## Frame and appearance

A finite, nonnegative numeric `frame` or a numeric string sets a square size: `frame={64}` and `frame="64"` both mean 64 × 64 points. Existing `frame="64,48"`, `frame="max"`, and alignment forms remain supported. Leave space around stroked shapes for their line width.

`$device.isdarkmode()` uses the appearance captured when its runtime is created, so JavaScript worker threads preserve the rendering context's light/dark choice. On macOS this resolves the native drawing appearance instead of always reporting dark mode.
