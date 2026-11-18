# Calendar API

<!-- platforms:start -->
> **Runs on:** iPhone and iPad, Mac, Android (for calendars selected in the app). **Not on:** Windows, Linux. Details and limits: [Platform support](platform-support.md).
<!-- platforms:end -->

Native Runtime 1.3 adds read-only EventKit access on iOS, iPadOS and macOS. The browser preview engine simulates these methods with editable Mock Data. This is the current source contract; the previously uploaded 27.1.2 (27012) build does not include it.

## Package and system access

Add `"calendar"` to `widget.json`'s `permissions` array and declare `minimumRuntimeVersion: "1.3"`. A present malformed or unsupported manifest is rejected before any script executes. Calendar methods additionally reject undeclared permission or a missing manifest. Legacy packages must adopt Package 2.0 and explicitly declare this capability. A successful preview mock cannot bypass this check.

`$calendar.isAvailable()` reports platform availability. `$calendar.authorizationStatus()` returns `undeclared` if the package cannot use Calendar; otherwise it returns `notDetermined`, `authorized`, `writeOnly`, `denied`, `restricted` or `unavailable`.

`await $calendar.requestAuthorization()` explicitly requests system access from the main application and returns a Boolean. Widget extensions never show the prompt; they return `true` only for existing full access, otherwise `false`. A system prompt may outlast the script execution deadline: approve access in the application and run the template again after the prompt. The recommended setup is **Settings → Calendar** on iOS, or **Settings → Data Access → Calendar** on Mac. This native settings action runs outside the script deadline. The template’s Open ScriptWidget link opens this setup sheet through `scriptwidget://calendar-access`; it does not request access until the person presses Allow.

Apple requires full Calendar authorization to read events; the OS does not offer a separate read-only EventKit authorization. ScriptWidget nevertheless exposes only read methods. On iOS 17+ / macOS 14+ the application requests full access using the modern API and includes the usage description; iOS 16 uses the legacy request. Sandboxed Mac targets include the Calendar entitlement. See [Apple's EventKit authorization documentation](https://developer.apple.com/documentation/eventkit/accessing-the-event-store).

After connecting, use **Sources available to widgets** in that same native settings screen. **All calendars, including newly added ones** preserves the existing default. Turn it off to select up to 64 specific calendars, then press **Save Calendar Sources**. An empty selection blocks event queries and returns an empty calendar list; it does not revoke the separate OS authorization. The selection applies to all widgets on this device, across libraries. It is not exported with widget packages or synchronized as a calendar-account preference to another device.

Selections are drafts until saved. Reload Sources discards the draft; returning from the background preserves unsaved choices while refreshing available sources. A second settings window cannot silently overwrite a selection saved elsewhere: saving a stale draft requires reloading. Unavailable saved IDs remain visible as a count until explicitly removed. Malformed present settings block reads rather than reverting to all calendars; the native editor can explicitly replace a malformed regular settings file. Script-visible files and storage cannot modify this native preference.

## Calendar lists and event queries

```jsx
// widget.json must include permissions: ["calendar"].
const calendars = await $calendar.calendars();
const result = await $calendar.events({
  start: "2026-10-20T00:00:00-07:00",
  end: "2026-10-21T00:00:00-07:00",
  limit: 10,
  calendarIDs: [calendars[0].id],
  maxAgeSeconds: 60,
});
$render(<vstack>{result.items.map(event => <text>{event.title}</text>)}</vstack>);
```

Handle an empty calendar list before indexing it in a real script. `calendars()` returns up to 64 `{id, title}` entries within the native source selection. Scripts cannot request sources outside this selection. Source identifiers are opaque and compared by exact UTF-8 bytes, including Unicode normalization differences. `events(options?)` accepts only these options:

| Option | Default | Validation |
| --- | --- | --- |
| `start` | Start of the current local day | Full ISO-8601 timestamp with time zone |
| `end` | One local calendar day after start | After start; total interval at most 31 × 24 hours |
| `limit` | 10 | Integer from 1 through 50 |
| `calendarIDs` | Currently available sources within the native selection | If supplied, 1–16 unique, nonempty IDs, at most 256 UTF-8 bytes each; unavailable or out-of-selection IDs reject |
| `maxAgeSeconds` | 60 | Finite number from 0 through 86400; zero bypasses cache |

Calendar-day arithmetic respects local daylight-saving transitions. Unknown options, Boolean numbers, invalid dates and oversized requests reject with `[invalid_options]`. An execution can make at most eight Calendar read queries, shared across `events` and `calendars`, exposed as `$runtime.limits.systemDataQueries`. Existing Health/Location APIs have not yet migrated to this new query budget.

The result has `{status, items, fetchedAt, source, stale, truncated}`:

- `status` is `ready` or `empty`; empty does not mean authorization was denied.
- Each item has `id`, `calendarID`, `title`, `start`, `end` and `allDay`. Dates are ISO-8601 timestamps. Notes, attendees, locations and URLs are not exposed.
- `source` is `system` or `cache`; `fetchedAt` describes the original fetch time.
- A cached result older than 60 seconds is marked `stale`, even when the caller explicitly permits a longer cache age.
- `truncated` indicates that more matching records exist beyond the bounded enumeration. Returned records are sorted by start and identifier; the API does not provide pagination.

## Cache, revocation and failures

At most one 64 KiB event snapshot is stored per package storage namespace. Its key includes the namespace; the record includes the query window, selected calendars and limit. Different queries cannot reuse a snapshot. Cache data is validated as untrusted input, including shape, record count, calendar selection, timestamps and byte bounds. Cache-disabled, expired, future-dated or malformed records are ignored.

New snapshots also record the native selection identity. Narrowing or clearing the selection prevents an older broader snapshot from being returned, including in future timeline entries. Authorization and native selection are checked again before storing a new snapshot and delivering any response, including a cache hit. A scope change during an in-flight query rejects its result. Older untagged snapshots remain usable only under the default all-calendars selection. A query-window mismatch does not erase a valid current-window snapshot. Event changes within the same selection still follow the requested cache age; the source list is not a guarantee of instant account/calendar-change propagation.

Every native read checks system authorization before querying or using cache, and again before delivering results. A read or authorization request observing revoked access clears that package's cached snapshot. No cached data is delivered after the operation observes revocation. This does not claim proactive deletion at the instant Settings changes while the app is stopped.

Errors use bounded messages with prefixes such as `[permission_denied]`, `[invalid_options]`, `[query_limit]` and `[authorization_failed]`; they do not log event contents. Catch failures and display a useful state. Calendar sync and WidgetKit refresh timing remain controlled by the OS.

## Template and preview

The bundled **Calendar Agenda** template uses real events, shows authorization and empty states, and accepts optional comma-separated calendar IDs through the widget parameter. A scope/query error shows a setup/check-access state in accessory widgets too, rather than falsely saying there are no events. Browser previews start with an isolated sample event; those samples are never saved as actual events or exported as user records. Mock Data includes success, denial and unavailable scenarios.

In Web Studio, **Mock Data → Calendar → Allowed calendar sources (JSON)** edits the preview-only `calendarSelection` field: `null` (or omission) means all sources, `[]` selects none, and `["sample.personal"]` selects a subset. It accepts at most 64 unique, nonempty IDs of at most 256 UTF-8 bytes each. Metadata and event response overrides are still filtered by this selection and query IDs; an arbitrary successful response does not bypass it. Keep the calendars and events mock responses consistent when adding new source IDs. Invalid scope JSON is preserved for repair and cannot fall back to all sources. Native OS authorization and native source selection are not changed by editing mocks.

Deterministic tests cover strict input limits, DST, package policy, cache boundaries and preview permission behavior. Real Calendar permission dialogs, authorized device reads and revocation still require the separate device acceptance checklist; simulated layout tests are not evidence of authorized real-data access.
