# Modern WidgetKit features

ScriptWidget packages can use the current WidgetKit presentation, interaction, Live Activity, Control Widget, App Intent, and push-update capabilities while retaining compatibility with older supported systems.

## Families and rendering modes

Add `systemExtraLargePortrait` to `supportedFamilies` for the tall extra-large family. At runtime, `$getenv("widget-size")` returns `extraLargePortrait`.

Use `$getenv("widget-rendering-mode")` to adapt to `fullColor`, `accented`, or `vibrant` rendering. The iOS editor and macOS Studio expose the same three rendering environments so conditional script branches can be tested. These editor canvases do not reproduce WidgetKit's final system tint pixel-for-pixel; verify the final appearance in a real widget. Set `widgetAccentable={true}` on a component to opt its content into the accent group. Images additionally accept `accentedRenderingMode="accented"`, `"desaturated"`, `"accentedDesaturated"`, or `"fullColor"`.

The root element's `background` is promoted to WidgetKit's container background on supported systems, including when the root is returned through custom components or a single-child Fragment. A Fragment with multiple top-level children has no unique container; wrap those children in one stack when the widget needs a removable container background.

## Live Activities

Live Activity content receives:

- `live-activity-state`: an app-controlled UTF-8 state payload, limited to 4 KiB.
- `live-activity-surface`: `lockScreen` or `dynamicIsland`.

The app-side manager can start an activity with initial state, update an activity by ID, end one with final state, or end all activities. Dynamic Island bottom content uses the system's below-if-too-wide placement so narrow landscape presentations remain readable. Interactive actions use `LiveActivityIntent` on iOS.

## Scriptable Control Widgets

Declare reusable actions once in `widget.json`, then reference them from ordinary
Widget buttons/toggles and Control Widgets. The same actions appear as a dynamic
entity picker in Siri and Shortcuts through **Run ScriptWidget Action**. A toggle
persists its Boolean state in package-scoped `$storage`, then calls its action
with `$getenv("action-value")` and the compatibility value
`$getenv("control-value")` set to `true` or `false`.

```json
{
  "permissions": ["storage"],
  "actions": [
    {
      "id": "refresh",
      "title": "Refresh Dashboard",
      "systemImage": "arrow.clockwise",
      "function": "refreshWidget"
    },
    {
      "id": "focus",
      "title": "Set Focus",
      "systemImage": "timer",
      "function": "setFocus"
    }
  ],
  "controls": [
    {
      "id": "refresh",
      "type": "button",
      "title": "Refresh",
      "systemImage": "arrow.clockwise",
      "actionID": "refresh"
    },
    {
      "id": "focus",
      "type": "toggle",
      "title": "Focus",
      "systemImage": "timer",
      "actionID": "focus",
      "stateKey": "focus.enabled"
    }
  ]
}
```

Use the same IDs in JSX:

```jsx
<button actionID="refresh">
  <label title="Refresh" systemName="arrow.clockwise" />
</button>
<toggle on={focusEnabled} actionID="focus" stateKey="focus.enabled">
  <text>Focus</text>
</toggle>
```

Direct `onClick` and control `action` functions remain compatible for older
packages but are intentionally not discoverable by Siri or Shortcuts. Studio
diagnostics reject mixing a declared `actionID` with those legacy forms.

Control actions and timeline reloads declare WidgetKit-extension execution targets. Ordinary widget and Live Activity actions declare main-app execution targets where the current SDK supports explicit targets.

The Xcode 27 test target uses `AppIntentsTesting` to load the app's extracted
metadata and verify the declared action entity plus the run/toggle parameter
contracts. Separate deterministic tests cover catalog resolution, fail-closed
manifests, storage permission enforcement, namespaced state, and compatibility
environment values.

## Widget push updates

Push registration is opt-in and self-hosted. It never grants a script access to the APNs token. A package declares an HTTPS registration endpoint and a channel:

```json
{
  "permissions": ["network"],
  "networkDomains": ["push.example.com"],
  "pushUpdates": {
    "registrationURL": "https://push.example.com/widget/register",
    "channel": "commute"
  }
}
```

On supported systems, ScriptWidget obtains WidgetKit's push token and registers only packages that are currently configured as widgets. The request is bounded and follows the package network allowlist across redirects. Reopen ScriptWidget after adding or changing configured widgets to refresh registrations. Server operation and APNs delivery remain the package author's responsibility.

Unsupported versions fail closed: older systems continue using timeline reloads and do not attempt push registration.
