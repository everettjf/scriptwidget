# ScriptWidget authoring essentials

This is a native widget DSL. JSX resembles React syntax, but there is no React/React Native, DOM, npm module resolution, hooks, timers or Node APIs. Use lowercase native tags such as `vstack`, `hstack`, `text`, `image`, `ring`, `chart` and `spacer`. Component functions may return native elements; do not pass functions as native props.

Call `$render(element)` once in the entry source; do not hide the only render call in an imported helper, because the current runtime uses entry-source render detection. Top-level `await` is supported by the runtime wrapper. Use `$import('lib/helpers.js')` for package source rather than ES module imports. Read resources with `$file` relative to the package; no absolute paths, links or traversal. `$storage` is package-namespaced and requires the storage permission in Package 2.0.

Use string padding (`padding="12"`) and native frame syntax (`frame="max,40"`). Named font styles and documented `fontWeight`/`fontDesign` are preferred. Do not infer an unsupported native prop from a web CSS property. SF Symbols are referenced by name; do not distribute Apple's artwork.

Minimal widget.json:

```json
{"formatVersion":2,"id":"com.example.my-widget","name":"My Widget","version":"1.0.0","runtimeVersion":"1.0","minimumRuntimeVersion":"1.4","entry":"main.jsx","supportedFamilies":["systemSmall","systemMedium","systemLarge"],"permissions":[],"networkDomains":[]}
```

Minimal main.jsx:

```jsx
const dark = $device.isdarkmode();
$render(
  <vstack spacing="8" padding="16" background={dark ? '#17202a' : '#f4f8fc'}>
    <text font="headline" color={dark ? '#ffffff' : '#17202a'}>My Widget</text>
    <text font="caption" color={dark ? '#b7cadc' : '#52687a'}>Created with JavaScript</text>
  </vstack>
);
```

For meaningful example previews use clearly synthetic values. For real behavior, read records and handle empty/missing data rather than silently treating demonstration records as the user's history. Denied HealthKit reads and no readable samples must not be conflated. Mock success cannot grant a manifest permission or prove real authorization.

A data API may be missing on the system the widget runs on (see [platform support](platform-support.md)): guard it with `isAvailable()` and draw a fallback, for example `if (!$health.isAvailable()) { $render(<text>Health is not available here</text>); } else { … }`.

Prefer a working subset of the user's request over invented APIs. Explain unsupported interaction or platform capabilities, and show the relevant report diagnostic.
