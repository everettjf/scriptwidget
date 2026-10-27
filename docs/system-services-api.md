# System services (Runtime 1.6)

These APIs extend existing Calendar, HealthKit, network and App Intent capabilities. They use Apple's frameworks and the existing bounded HTTP transport; no third-party SDK, inference server or application server is added. Weather currently uses MET Norway rather than WeatherKit.

## Install and authorize

Use Package 2.0, `minimumRuntimeVersion: "1.6"`, and the relevant permissions below. Older runtimes reject unsupported permissions/versions. In the native widget list, open the widget's context menu → **System Access**, select capabilities and items, then **Save Access and Selections**. Separately authorize Notifications, Contacts, Home or Alarms there when needed. Calendar and Health authorization/source selection stay in app Settings.

Native grants are local, bound to the installation UUID, and absent from exported packages. Rename retains access; a remix, import or new same-name installation does not inherit it. Revoking access stops subsequent calls without removing user records or imported copies. Cancel outstanding notifications/alarms before revocation. Native deletion requests cancellation of that installation's schedules; delivery/cancellation after process termination or OS denial still needs device acceptance. Calendar events are never deleted during widget deletion.

All methods return Promises. All calls require a live installed execution, share the **8-query/execution** budget, and are denied during future timeline projections and scripted Live Activity presentations. Writes require a user-initiated native action. Native service callbacks recheck installation identity and the captured grant before delivery. No authorization sheets are presented automatically during widget rendering.

| Capability | Manifest permissions | Native support |
| --- | --- | --- |
| Notifications | `notifications` | iOS/iPadOS, macOS; OS notification authorization |
| Health history | `health` | iPhone/iPad with available HealthKit; review types in Settings |
| Calendar writes | `calendar`, `calendarWrite` | iOS/iPadOS, macOS; full Calendar access and permitted calendar |
| Forecast | `weather`, `network`, `networkDomains:["api.met.no"]` | iOS/iPadOS, macOS; supplied coordinates, no automatic GPS |
| Alarms/timers | `alarms` | iOS/iPadOS 26+; AlarmKit authorization; unavailable on native macOS |
| Imported data | `documents` | iOS/iPadOS, macOS; explicit native file importer |
| Contacts | `contacts` | iOS/iPadOS, macOS; OS access plus native per-widget selection |
| Maps/places | `maps` | iOS/iPadOS, macOS; supplied query/coordinates sent to Apple Maps |
| Home accessories/scenes | `home` | iPhone/iPad; HomeKit authorization and selected items; unavailable on native macOS |

Health history uses the existing Health review rather than the System Access toggle. Read authorization remains undisclosed by HealthKit: an empty result cannot establish denial. These APIs do not persist Health readings or log contacts, document contents, home values or system responses.

## Local notifications

```js
await $notifications.status(); // {authorization:"authorized"|...}
await $notifications.schedule({key:"reading",title:"Time to read",body:"One chapter",daily:{hour:20,minute:0}});
await $notifications.schedule({key:"one-time",title:"A reminder",body:"Take a break",date:"2026-11-01T12:00:00Z"});
await $notifications.pending(); // own keys, title, body, repeats, next date
await $notifications.cancel("reading"); // {key,status:"cancellationRequested"}
```

Supply exactly one of `date` (future ISO date-time, at most 366 days away) or `daily` (integer hour 0–23 and minute 0–59, system local clock). Daily reminders occupy one repeating slot; they do not require JavaScript to keep running. A key matches `[a-zA-Z0-9_-]{1,64}`. A repeated schedule with the same key replaces that installation's slot. Titles/body are nonempty, without control characters, at most 256/1024 UTF-8 bytes. Unknown fields reject.

At most 32 slots per installation, with a conservative application-wide capacity check at 60 pending requests and a cross-process lock. Scheduling acknowledges OS acceptance, not delivery: Focus, notification settings and system behavior still apply. An acknowledgment timeout is an unknown outcome; inspect `pending()` before retrying. Cancellation targets only owned pending notifications, not notifications from other apps or already delivered history.

[Runnable Reading Reminder](examples/notification-reminder).

## Health history

```js
const history = await $health.dailyStatistics({metric:"steps",days:7});
// {metric,unit,aggregation,timeZone,items:[{date:"YYYY-MM-DD",value,hasSamples}]}
```

Metrics: `steps` (count), `activeEnergy` (kcal), `walkingDistance` (meters), `water` (milliliters), `bodyMass` (kilograms), `heartRate` (beats/minute). Body mass and heart rate use daily averages; the others use sums. `days` is an integer 1–31, default 7, including the current partial day. Bins use Gregorian local days and calendar boundaries, including DST. Missing readings return `value:null,hasSamples:false`; a measured zero remains valid. No raw samples, write access, routes or source identifiers are exposed.

[Runnable Seven Day Steps](examples/health-history).

## Calendar writes

```js
const result = await $calendar.create({requestID:"11111111-1111-4111-8111-111111111111",calendarID:"<selected native ID>",title:"Focus",start:"2026-11-01T12:00:00Z",end:"2026-11-01T12:30:00Z",allDay:false});
await $calendar.update({requestID:"22222222-2222-4222-8222-222222222222",calendarID:"<same calendar>",id:result.id,title:"Updated focus",start:"2026-11-01T13:00:00Z",end:"2026-11-01T13:30:00Z",allDay:false});
// {id,calendarID,status:"applied",replayed:boolean}
```

Create/update accept closed fields and a canonical lowercase request UUID. Start/end are explicit ISO date-times with positive duration up to 366 days. Update supplies the complete title/start/end, not a partial patch. Titles are at most 512 UTF-8 bytes. Calendar must be in the native selected source scope and writable. Updates are limited to single, nonrecurring events this installation created; importing an event ID cannot grant ownership. Recurrence, deletion and modification of other events are deliberately outside this contract. The native ownership registry is bounded to 128 events and stored outside script-accessible `$storage`.

Create/update use private native replay receipts. A repeated requestID with the same operation returns its confirmed result; different arguments reject. Prepared/uncertain receipts cannot be retried blindly. Up to 128 receipts/64 KiB are retained; completed receipts expire after seven days, prepared receipts are not automatically discarded. Save the pending operation locally **before** calling the API. Retry an unchanged recent request only; inspect Calendar before resetting an old or uncertain operation. A system write can succeed even if the widget execution expires before receiving its result.

[Runnable Focus Session with durable pending request](examples/calendar-focus).

## Weather

```js
const forecast = await $weather.forecast({latitude:37.33,longitude:-122.01,hours:24});
// {provider,attribution:{text,url},latitude,longitude,fetchedAt,isStale,
//  hours:[{time,temperatureC,windMetersPerSecond,precipitationMM,condition}]}
```

Coordinates are rounded to two decimals before transmission; latitude/longitude bounds are enforced. `hours` is an integer 1–48, default 24. MET Norway's compact forecast is normalized and bounded. Fresh matching private cache can be used for one hour; failures may return matching cache up to six hours old with `isStale:true`. `fetchedAt` is the fetch time, not an observation timestamp. Missing precipitation/condition remain null. Display the returned provider attribution and link. No WeatherKit entitlement, Apple weather quota or API key is involved. Network/domain restrictions, redirects, cancellation and request budgets still apply.

[Runnable Weather Ahead with attribution](examples/weather-forecast).

## Alarms and timers

```js
await $alarms.status();
await $alarms.schedule({requestID:"11111111-1111-4111-8111-111111111111",key:"focus",title:"Focus complete",seconds:1500});
// Or supply date:<future ISO date-time> instead of seconds.
await $alarms.pending(); // this installation's {key,state} items
await $alarms.pause("focus"); await $alarms.resume("focus");
await $alarms.stop("focus"); await $alarms.cancel("focus");
```

Use exactly one of `seconds` (60–86400) or `date` (future, at most 366 days). Titles are at most 128 UTF-8 bytes. Up to 32 named keys are tracked per installation. IDs are derived natively from installation + key; scripts cannot supply another alarm UUID. An active alarm is not silently replaced: cancel it explicitly first. Pause/resume depend on the system's current countdown state. Schedule uses the same bounded seven-day replay-receipt rules as calendar writes. Preserve pending requests when an outcome is unknown.

The extension includes native AlarmKit countdown Live Activity/Dynamic Island UI. It displays system dates without rerunning JavaScript. AlarmKit authorization, presentation, locked-device behavior, delivery and acknowledgments require physical-device acceptance. This API does not enumerate or edit alarms owned by Apple's Clock app.

[Runnable Focus Timer](examples/alarm-focus-timer).

## Imported JSON and CSV

```js
const files = await $documents.list(); // [{id,name,type,bytes}]
const object = await $documents.readJSON(files.find(f => f.type === "json").id);
const table = await $documents.readCSV(files.find(f => f.type === "csv").id);
// {headers:[...],rows:[[...]],truncated:false}
```

Enable documents and import through System Access. The native picker authorizes a source file; a bounded descriptor read rejects links, nonregular files and concurrent source changes. The original is never modified. Copies and handles are installation-local and not exported with the script. Up to eight files, 256 KiB each; JSON root must be an object or array. CSV supports UTF-8/BOM, quoted delimiters/newlines and escaped quotes, up to 500 data rows, 32 unique nonempty headers and 8 KiB per cell. Ragged rows, invalid UTF-8, unclosed quotes and excess data reject rather than silently truncate. IDs are native UUIDs, never paths or bookmarks. Reimport captures an updated source; automatic live-file synchronization is not provided.

[Runnable My JSON Data](examples/document-data).

## Selected contacts

```js
const people = await $contacts.selected();
// [{id,name,organization,phones:[...],emails:[...]}]
```

Authorize Contacts and select up to 20 contacts in System Access, then save. The selection UI lists at most 200 system-accessible contacts. On iOS, limited authorization is respected. Each returned contact includes up to three phone numbers and three email addresses. Notes, photos, birthdays, arbitrary search and contact mutation are not exposed. No native contacts cache is retained; revocation is checked on reads. Data sent to Web Studio is always an editable sample, never this native selection.

[Runnable People Close By](examples/selected-contacts).

## Maps and places

```js
await $maps.search({query:"park",latitude:37.33,longitude:-122.01,radiusMeters:3000});
await $maps.geocode("Cupertino, California");
await $maps.reverseGeocode({latitude:37.33,longitude:-122.01});
const map = await $maps.snapshot({latitude:37.33,longitude:-122.01,radiusMeters:2000,size:256});
// map: {image:<data URL>,width,height,provider:"Apple Maps"}
```

Search/geocoding return up to five results. Queries/address text are bounded to 256 UTF-8 bytes; supplied coordinates are validated. Region radius is 100–50000 meters. Snapshots are square, integer 128–512 points, bounded JPEGs of at most 256 KiB; iOS uses scale 1 to bound decoded pixels. Preserve map attribution when displaying the image. New systems use MapKit geocoding requests; older iOS uses the supported fallback. Place results expose name/address/coordinates, not arbitrary provider objects. Older iOS returns the same bounded name/address/coordinate shape through its fallback. No device location is read implicitly. Requests are cancellable and system service availability/extension resource limits still apply.

[Runnable A Place to Go](examples/map-place).

## Home accessories and scenes

```js
const items = await $home.items(); // selected {id,name,kind,metric,unit,value,isCached:true}
await $home.setPower({id:"<selected power item>",on:true});
await $home.runScene({id:"<selected scene>",requestID:"11111111-1111-4111-8111-111111111111"});
```

Authorize Home, select up to 20 exposed items and save. Discovery is bounded and exposes power, temperature, humidity, motion/contact sensors and scenes. Only power-state characteristics are directly writable; `setPower` is an absolute Boolean, never a blind toggle. Sensor values are HomeKit's cached readings and can be null; no claim of live accessory connectivity is made. Native macOS returns unavailable.

Scenes can contain security-sensitive actions according to the user's Home configuration; native selection describes this before granting access. Only explicitly selected scenes execute, and platform authentication/lock restrictions remain in force. Scene execution uses private bounded replay receipts, with the same uncertainty and retention rules as calendar writes. An acknowledgment is not proof that every physical accessory reached its target. No arbitrary characteristic writes, lock/door API, discovery pairing, camera streaming or Home configuration changes are exposed.

[Runnable A Calmer Home](examples/home-light).

## Web Studio, CLI and validation

Web Studio has editable per-method samples plus a **System access grants** section. `systemAccess.permissions` and selected `contacts`/`home` IDs model native scope. Manifest permission, Runtime 1.6, action-only writes, argument bounds and query budgets run before mock replies. Simulated notification/alarm/calendar/home mutations return `systemState` into the browser draft; Reset simulated state clears it. `systemCommitUncertain:true` models prepared mutation receipts. None of this touches Apple's services or changes package exports. Simulated receipts operate on the saved preview state; they do not certify real seven-day retention or OS side effects.

Native CLI check/pack validate manifests and syntax. CLI renders use isolated read fixtures, with diagnostics that offline replies do not certify native query arguments; new system writes are rejected. An offline fixture cannot authorize a real system operation. Native record/receipt/grant files are separate from package-relative `$file` and public `$storage` keys.

Run `node Scripts/test-system-services.mjs` for deterministic native validators, grants, file imports and private-key isolation. Application-host tests also verify real JSExport calls deny unmanaged/preview packages. Preview tests cover scopes, writes, replay/uncertainty, lifecycle simulation and budgets. Native builds/fixtures are not proof of real permissions, delivery or hardware behavior.

## Physical-device acceptance before release

- Fresh install, deny/grant/revoke each OS permission; verify missing native grant, copied widget and retired owner stay denied.
- One-time/daily notifications: replace/cancel, local-time/DST behavior, Focus suppression, capacity and concurrent app/extension requests.
- Health: readable data, no shared samples, actual zeros, new metric review, day boundaries and widget memory.
- Calendar: selected/writable source, create/update, denied foreign/recurring event, same request replay, changed arguments, interruption and unchanged existing events.
- Weather/Maps: offline/cache expiry, native attribution, geocoding, snapshot pixels, cancellation and extension memory.
- AlarmKit: authorize/deny, countdown Live Activity/Dynamic Island, pause/resume/stop/cancel, locked device, acknowledgment timeout and no Clock-app access.
- File picker: iCloud Drive and local files, UTF-8/quoted CSV, source unchanged, copies surviving relaunch, cross-widget denial and stale grant writes.
- Contacts/Home: limited selection, revocation, missing items, no automatic prompts in widgets, selected lights/scenes only, system authentication and stale sensor labels.
- Delete/rename/remix: native schedule cleanup requests, grant isolation, original package records retained and no same-name inheritance.

Sources: [local notifications](https://developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app), [HealthKit statistics](https://developer.apple.com/documentation/healthkit/hkstatisticscollectionquery), [EventKit access](https://developer.apple.com/documentation/eventkit/accessing-the-event-store), [AlarmKit](https://developer.apple.com/documentation/alarmkit), [Contacts access](https://developer.apple.com/documentation/contacts/accessing-the-contact-store), [HomeKit](https://developer.apple.com/documentation/homekit).
