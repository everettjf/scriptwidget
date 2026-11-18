# Reminders API

<!-- platforms:start -->
> **Runs on:** iPhone and iPad, Mac. **Not on:** Android, Windows, Linux. Details and limits: [Platform support](platform-support.md).
<!-- platforms:end -->

Runtime API 1.4 adds `$reminders` on iOS/iPadOS and macOS. Package 2.0 must declare `"reminders"` in `permissions`. A malformed manifest or missing permission cannot be overridden by Web mocks.

The native app asks for system Reminders access in **Settings → Reminders**. Apple grants full access. Reads require `reminders`; creating, updating and setting completion additionally require `remindersWrite` and a user-triggered declared action. Ordinary rendering, uninstalled previews, future timeline entries and Live Activity presentations cannot write. Deletion is not exposed.

## Methods

| Method | Return |
| --- | --- |
| `isAvailable()` | Boolean platform availability; an isolated uninstalled preview returns false |
| `authorizationStatus()` | `authorized`, `denied`, `restricted`, `notDetermined`, `unavailable`, or `undeclared` |
| `requestAuthorization()` | Promise of Boolean; app requests consent, widget only reports current status |
| `lists()` | Promise of up to 64 `{id, title}` records inside the user's selected scope |
| `items(options?)` | Promise of `{status, items, fetchedAt, source, stale, truncated}` |
| `create(options)` | Promise of `{id, listID, status: "applied", replayed}` |
| `update(options)` | Same receipt; updates only specified fields |
| `setCompleted(options)` | Same receipt; sets an explicit desired Boolean state |

`options` accepts only:

| Field | Default / bounds |
| --- | --- |
| `start`, `end` | ISO 8601 timestamps with timezone. Defaults: local midnight through next local midnight. Positive window, at most 31 × 24 hours |
| `listIDs` | Optional 1–16 unique opaque list IDs, each at most 256 UTF-8 bytes; every requested ID must exist and be allowed |
| `completed` | Boolean, default false. Pending items use the **due** window; completed items use the **completion** window |
| `limit` | Integer 1–50, default 10 |
| `maxAgeSeconds` | 0–86400 seconds, default 60; zero disables cache reuse |

Rows contain `{id, listID, title, due, hasTime, completed, completedAt, priority}`. `due` is an ISO timestamp when timed, a `YYYY-MM-DD` local floating date when all-day, or null. `completedAt` is an ISO timestamp or null. Priorities use EventKit's 0–9 range (0 means unset).

Undated pending items are excluded. A completed item with no readable completion timestamp cannot be placed in a completion window and is excluded. All-day dates overlap the selected local calendar day; they are not interpreted as UTC midnight. The end timestamp is exclusive.

`status` is `ready` or `empty`. `source` is `system` or `cache`; `stale` indicates a reused snapshot older than 60 seconds. Errors reject with a bracketed code such as `permission_denied`, `invalid_options`, `query_failed`, `query_limit` or `snapshot_required`. Do not present an error as “nothing due.”

## Scope and snapshots

Native Settings selects all lists, a subset, or none. Scripts can narrow this scope with `listIDs`, never enlarge it. Calendar and Reminders preferences are separate. IDs use exact UTF-8 identity; visually equivalent Unicode IDs are not aliases. Malformed or unsafe present preferences fail closed; they do not fall back to all lists.

Reads share the per-execution eight-query system-data budget. The EventKit request is cancelled when the execution ends. Processing scans up to 1,000 returned rows and reports `truncated` for unscanned or omitted results. EventKit itself returns an array without a pagination API: this is a processing/output bound, not a proven native peak-memory bound.

A private, package-owner-scoped snapshot is limited to 64 KiB. Each read and callback rechecks execution, authorization and selected scope before delivery. Future timeline entries and Live Activity presentations only use a matching saved snapshot; they cannot start live queries. Changing the query, selection, or completed flag prevents reuse. App/widget signed-container and physical-device behavior still require acceptance testing.

## Web Studio

The Reminders Mock Data group includes best-state samples, editable responses, failure/empty/denied scenarios and allowed-list JSON. `remindersSelection` is null for all, `[]` for none, or an array of selected IDs. Mock values stay in the browser draft and are excluded from widget exports. They cannot grant the package `reminders` permission. Dates, status and scope still filter mocked results.

```js
const result = await $reminders.items({ limit: 6, completed: false });
// Render result.items, or handle a rejected query with a setup/error state.
```

System authorization references: [Event store access](https://developer.apple.com/documentation/eventkit/accessing-the-event-store), [full Reminders access](https://developer.apple.com/documentation/eventkit/ekeventstore/requestfullaccesstoreminders(completion:)), [usage description](https://developer.apple.com/documentation/bundleresources/information-property-list/nsremindersfullaccessusagedescription).


## Explicit user actions and write receipts

Declare `reminders`, `remindersWrite`, and an action in `widget.json`; use `minimumRuntimeVersion: "1.4"`. The native action executor supplies authority, not `$getenv("action-id")` or a script-controlled flag. **Await every write.** Native actions now wait for the declared function to finish instead of treating entry rendering as completion.

All three operations require `requestID` (a canonical lowercase UUID for this user intent) and `listID` (one permitted list). `create` requires a nonblank `title` of at most 1024 UTF-8 bytes, accepts optional `due` and integer `priority` 0–9. `update` requires `id` and at least one of `title`, `due`, `priority`. An absent `due` preserves it; `null` removes it. Due values are a valid local `YYYY-MM-DD` or ISO date-time with timezone. `setCompleted` requires `id` and a strict `completed` Boolean. Unknown keys, empty updates, control characters, invalid dates and Boolean priorities are rejected. Existing reminders must belong to the specified selected list; scripts cannot move them to another list.

Save a request ID before issuing the write and retain it until its result is confirmed. A private per-installation ledger serializes requests across processes. The same ID and payload returns the prior receipt without applying again; changed payloads fail with `request_conflict`. Completed receipts are retained for seven days, at most 128 receipts / 64 KiB. A prepared receipt with an uncertain outcome never expires automatically and is never blindly repeated. Capacity is reserved before EventKit commits. If the action times out after a successful commit, a later retry can recover a completed receipt.

`outcome_unknown` means the system may already have applied the operation. Inspect Reminders before starting a new intent; generating another UUID automatically would risk a duplicate create. A failed source/permission/identity check before the durable marker does not reserve the ID. Settings source changes are locked out during a commit, and access is checked again immediately before committing and returning. Read caches are invalidated after successful or replayed writes. No raw titles, credentials or reminder contents are logged or stored in receipts.

## Web Studio action simulation

In **Mock Data**, select a declared action and choose **Run simulated action**. It runs in the isolated preview worker with the same permissions, scope, option validation, operation budget and replay rules. Create/update/completion change simulated items; the resulting items, receipts and `$storage` are saved only in the browser project. Previews immediately consume these changes. Switching projects or editing during a running simulation discards stale results. Exports never include this mock state.

Edit `$reminders.items` to change the simulated dataset and `$reminders.lists` to change available sources. Write receipt IDs come from the model, so healthy receipt overrides cannot bypass selection or invent a different target. Per-write error overrides remain editable. `remindersState` stores the preview dataset and receipts in Full JSON; `remindersCommitUncertain: true` simulates a commit whose confirmation was lost. **Reset simulated state** clears only preview action state and storage. The browser cannot grant system permissions or alter real reminders. The preview dataset is bounded to 1000 items.
