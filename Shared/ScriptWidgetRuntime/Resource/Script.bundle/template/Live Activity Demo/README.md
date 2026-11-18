# Live Activity Demo

A local, app-updated Live Activity with lock-screen and all Dynamic Island regions. Install the template, then open **Settings → Live Activities** on iOS 16.2 or later. Select this installation and use the 25-minute focus preset, or supply JSON:

```json
{"title":"Reading","detail":"Chapter finished","progress":3,"total":8}
```

Alternatively, provide `endsAt` as a timezone-qualified ISO date for a native timer. The screen can update state, mark it stale, finish it or dismiss it; reopening restores the system's running activity list. Empty state shows setup guidance, rather than invented measurements. Invalid input shows a repair instruction without echoing its contents.

Supported optional fields: `title`, `detail`, integer `progress` and `total`, and `endsAt`. The package requires no network, location or storage permission. Activity attributes and state together must fit the system's 4 KiB budget.

Ordinary Home Screen preview is supported at small and medium size; the small widget shows the state and the title. Web preview is a layout preview; actual ActivityKit and Dynamic Island presentation require a supported iPhone. System scheduling controls display and timer/stale transitions. Remote updates and interactive Island buttons are not included.

See [local Live Activities](../../../../../../../docs/live-activities.md) for lifecycle, installation binding, data constraints and verification limits.
