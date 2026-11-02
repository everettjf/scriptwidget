# ScriptWidget runtime API 1.4

The public JavaScript/JSX host contract is versioned independently from the app. Scripts can read `$runtime.apiVersion` and must feature-detect optional device capabilities.

## Global API

Version 1.4 adds `$reminders`, `$photos`, expanded Health summaries, `$services` and read-only iOS Music app snapshots through [`$music`](music-api.md). [Connected Services](services-api.md) starts with authenticated GitHub profiles through native account approval; Web samples do not grant real access. The additive `backgroundMaterial` JSX property supplies bounded public SwiftUI frosted material with accessibility fallbacks; see [Visual effects](visual-effects.md). These additions remain under development in the unified release branch.

Version 1.3 adds the read-only `$calendar` API, explicit `calendar` package permission and bounded queries/cache. See [Calendar API](calendar-api.md). This describes the current source contract; earlier uploaded builds do not contain these additions.

Version 1.1 adds `$xml` to the 1.0 globals: `$component`, `$console`, `$dataSource`, `$device`, `$dynamic_island`, `$element`, `$error`, `$fetch`, `$file`, `$getenv`, `$health`, `$http`, `$import`, `$location`, `$render`, `$runtime`, `$storage`, `$system`, `console`, and `fetch`.

`$dataSource.request(pluginID, operationID, parameters)` calls an installed declarative connector. It is available only to Package 2.0 widgets that declare the plugin identifier, `network` permission, and the connector host. See [Data Source Plugins](data-source-plugins.md).

Removing or changing the meaning of a 1.0 global requires a new major API version. Additive properties may ship in a minor version.

### Built-in text and data handling

JavaScript already provides `String.prototype.includes`, `indexOf`, `match`, and `replace` for text search, plus `JSON.parse` and `JSON.stringify` for JSON. `$json(value)` remains a shorthand for `JSON.stringify(value)` when a JSX property needs a JSON string.

`$xml.parse(source)` parses an XML string into a node with `name`, `attributes`, `text`, and `children`. `text` contains only direct text in that node; child text stays in its child node. Whitespace is preserved. The result is a plain JavaScript object, not a DOM or XPath interface.

```jsx
const feed = $xml.parse('<feed><title>News</title></feed>');
const title = feed.children.find(child => child.name === 'title')?.text ?? 'Untitled';
$render(<text>{title}</text>);
```

XML input is limited to 256 KiB, 2,048 elements, 32 levels, and 256 KiB of decoded text. DTDs and entity declarations are rejected, and external entities are never resolved. Invalid or oversized XML throws an `Error`. This parser requires no package permission and cannot read files or make network requests. Package 2.0 network permissions still apply when the XML comes from a URL.

## Local record updates

Runtime 1.3 adds package-scoped `$storage.compareAndSetString` and `$storage.compareAndSetJSON`. Use them for concurrent application/widget updates; a separate read followed by an ordinary set does not prevent lost records. See [package storage](storage-api.md).

## Health permission privacy

Runtime 1.3 adds `$health.authorizationStatus()`, which returns `notDisclosed` on devices with HealthKit data availability and `unavailable` elsewhere. It does not report individual read grants. `requestAuthorization()` completes the consent flow; its Boolean is not proof that every read type was shared. Empty or zero-valued results can mean no records or data the person chose not to share. Settings reports review status without probing private samples to infer consent. This follows [Apple’s HealthKit read-permission privacy rule](https://developer.apple.com/documentation/healthkit/hkhealthstore/authorizationstatus%28for%3A%29). Web Mock Data provides a matching **No shared data** scenario.

Packages may declare an optional `minimumRuntimeVersion` public API floor, independently of their Package 2.0 `runtimeVersion` ABI. Incompatible packages are rejected before compilation, rendering or actions. See [Package 2.0 compatibility](package-format.md#compatibility).

## Resource limits

- Source text: 512 KiB per execution.
- Transpiled JavaScript: 2 MiB per execution.
- Execution: 5 seconds, including unresolved asynchronous work. Compiler-inserted checks at loops, function entries, catch and finally blocks unwind synchronous scripts after cancellation. Cancellation is sticky, so catching an exception cannot resume another guarded loop. Native built-ins and the trusted Babel parser cannot be forcibly interrupted using public JavaScriptCore APIs.
- Legacy dynamic JavaScript is supported: direct `eval` retains caller scope; indirect eval and `Function`, async/generator constructors retain global scope. Compiler-recognized eval calls and dynamic constructor bodies receive cancellation checks, including nested source. Reflectively obtained intrinsic eval, dynamic `with` scopes, and native built-ins cannot be guaranteed to unwind synchronously using public JavaScriptCore APIs. Dynamic source uses the same source/compile budgets as package source. Legacy non-strict `with` statements are supported. The internal `__scriptWidgetCheckExecution`, `__scriptWidgetPrepareEval`, `__scriptWidgetIndirectEval`, and `__scriptWidgetResolveEval` identifiers remain reserved.
- Old compiled artifacts are rebuilt with compiler fingerprint `scriptwidget-babel-v5` before execution; authored package files remain unchanged.

Limits are available under `$runtime.limits`. Exceeding one produces a visible resource-limit error instead of a blank widget. Widget extensions remain subject to stricter operating-system CPU and memory budgets.

Bundled templates are contract-tested against the source limit. New examples must keep `main.jsx` UTF-8 encoded and runnable without undocumented globals.

## Frame and appearance

A finite, nonnegative numeric `frame` or a numeric string sets a square size: `frame={64}` and `frame="64"` both mean 64 × 64 points. Existing `frame="64,48"`, `frame="max"`, and alignment forms remain supported. Leave space around stroked shapes for their line width.

`$device.isdarkmode()` uses the appearance captured when its runtime is created, so JavaScript worker threads preserve the rendering context's light/dark choice. On macOS this resolves the native drawing appearance instead of always reporting dark mode.

Location authorization, snapshots, and limits: [Location API](location-api.md).

Scheduled dates, slot environments and future-entry restrictions: [Scheduled widget states](timeline-api.md).
