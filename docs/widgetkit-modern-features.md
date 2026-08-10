# Modern WidgetKit features

ScriptWidget packages can use the current WidgetKit presentation, interaction, Live Activity, Control Widget, App Intent, and push-update capabilities while retaining compatibility with older supported systems.

## Families and rendering modes

Add `systemExtraLargePortrait` to `supportedFamilies` for the tall extra-large family. At runtime, `$getenv("widget-size")` returns `extraLargePortrait`.

Use `$getenv("widget-rendering-mode")` to adapt to `fullColor`, `accented`, or `vibrant` rendering. Studio exposes the same three preview modes. Set `widgetAccentable={true}` on a component to opt its content into the accent group. Images additionally accept `accentedRenderingMode="accented"`, `"desaturated"`, `"accentedDesaturated"`, or `"fullColor"`.

## Live Activities

Live Activity content receives:

- `live-activity-state`: an app-controlled UTF-8 state payload, limited to 4 KiB.
- `live-activity-surface`: `lockScreen` or `dynamicIsland`.

The app-side manager can start an activity with initial state, update an activity by ID, end one with final state, or end all activities. Dynamic Island bottom content uses the system's below-if-too-wide placement so narrow landscape presentations remain readable. Interactive actions use `LiveActivityIntent` on iOS.

## Scriptable Control Widgets

Declare controls in `widget.json`. A button calls its JavaScript action. A toggle persists its Boolean state in package-scoped `$storage`, then calls its action with `$getenv("control-value")` set to `true` or `false`.

```json
{
  "permissions": ["storage"],
  "controls": [
    {
      "id": "refresh",
      "type": "button",
      "title": "Refresh",
      "systemImage": "arrow.clockwise",
      "action": "refreshWidget"
    },
    {
      "id": "focus",
      "type": "toggle",
      "title": "Focus",
      "systemImage": "timer",
      "action": "setFocus",
      "stateKey": "focus.enabled"
    }
  ]
}
```

Control actions and timeline reloads declare WidgetKit-extension execution targets. Ordinary widget and Live Activity actions declare main-app execution targets where the current SDK supports explicit targets.

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
