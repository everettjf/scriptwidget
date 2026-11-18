# Location and widget authorization

<!-- platforms:start -->
> **Runs on:** iPhone and iPad, Android (widgets see the position saved while the app was open). **Not on:** Mac, Windows, Linux. Details and limits: [Platform support](platform-support.md).
<!-- platforms:end -->

`$location` is available on iOS/iPadOS. macOS returns `isAvailable() === false`, `authorizationStatus() === "unavailable"`, and rejected location promises. Package 2.0 must declare `location` in `permissions`; a present invalid manifest fails closed. Genuine legacy packages retain their existing behavior. Mock data does not grant package permission.

## Authorization

- `isAvailable()` checks whether system Location Services are enabled.
- `authorizationStatus()` returns `notDetermined`, `restricted`, `denied`, `authorizedWhenInUse`, `authorizedAlways`, `disabled`, or `unknown`. An undeclared Package 2.0 capability returns `undeclared`.
- `isAuthorizedForWidgetUpdates()` (Runtime 1.3) reports the separate system eligibility for widget location access. A cached coordinate never implies authorization. It is false on an unavailable platform or for an undeclared capability.
- `await requestAuthorization(options?)` requests When In Use authorization from the app. In a widget it checks existing widget authorization without prompting. Completion does not imply a location fix is available. Location requests and authorization attempts share the execution's eight-query system-data budget.

Apple requires the app's Location Services authorization and the user's approval to extend access to widgets. ScriptWidget's iOS widget extension declares `NSWidgetWantsLocation`; package permission still separately controls whether a script can request data. The OS prompt applies to the extension, which also hosts scripts that do not use location. See [Apple's widget location guide](https://developer.apple.com/documentation/widgetkit/accessing-location-information-in-widgets) and [`isAuthorizedForWidgetUpdates`](https://developer.apple.com/documentation/corelocation/cllocationmanager/isauthorizedforwidgetupdates).

## Reading a position

```jsx
// widget.json: permissions includes "location"; minimumRuntimeVersion: "1.3"
try {
  const position = await $location.current({ maxAge: 3600 });
  $render(<text>{position.isStale ? "Saved location" : "Location ready"}</text>);
} catch (error) {
  $render(<text>Open ScriptWidget → Settings → Location to check access.</text>);
}
```

`current(options?)` returns `latitude`, `longitude`, `altitude`, `accuracy` (horizontal metres), `verticalAccuracy`, `speed`, `course`, ISO `timestamp`, `accuracyAuthorization` (`full` or `reduced`), `age` (seconds), and `isStale`. Negative speed/course or vertical accuracy can indicate that Core Location has no measurement for that field. The property is `accuracy`, not `horizontalAccuracy`.

Legacy options remain supported: `timeout`/`maxAge` are seconds, `timeoutMs`/`maxAgeMs` are milliseconds; millisecond options take precedence. Invalid/nonpositive options use defaults. Requests default to ten seconds and are capped at thirty seconds, while the enclosing script's five-second execution budget still applies. `maxAge` defaults to zero and is capped at one day. `accuracy: "full"` can request temporary full precision only with a `purposeKey` declared in the app's usage-description dictionary; it cannot guarantee that a person grants full precision. Check the returned accuracy metadata.

The app uses Core Location; the widget reads the app-group snapshot after checking system and widget authorization. A widget can receive a stale snapshot and must display its age: `maxAge` is a freshness threshold for that snapshot, not permission to retain it forever. Snapshots older than 24 hours, with future/invalid timestamps, invalid coordinates/types, or more than 4 KiB are discarded. A reduced-accuracy session cannot consume a prior full-accuracy snapshot. The app does not use Core Location's old in-memory full-precision position as a reduced-precision fallback.

Observed revocation, disabled services, invalid cache contents, and precision downgrade clear the stored snapshot. The app checks when returning to the foreground and in its Location settings; widget reads recheck immediately before returning. This does not promise background execution at the instant a person changes Settings. Revoked package permission denies the script without granting access to shared location data. Package removal does not control the app-wide system permission.

Requests stop after script cancellation and do not deliver a result to an inactive execution. Permission loss during an app request prevents delivery and caching. Errors are reported without logging coordinates or raw system-error descriptions. Common failures include `[permission_denied]`, `[query_limit]`, `[widget_not_authorized]`, `[no_data]`, and service unavailability.

## Preview and acceptance

Web Studio supplies editable best-state samples with the native result shape. Location scenarios include denial, disabled services, no fix, and the per-method `isAuthorizedForWidgetUpdates` response. The preview enforces package permission, authorization before returning coordinate mocks, and the shared query budget. Samples stay in project preview settings and do not become a real device position or exported package data.

Deterministic tests cover the authorization matrix, stale/expired/invalid snapshots, precision changes, cache deletion, package permission and preview policy. Simulator execution and a successful build do not prove real widget authorization. Physical-device acceptance must cover extending/refusing widget access, app/widget revocation, reduced precision, foreground refresh, and frequently/infrequently visible widgets. Apple recommends testing location widgets over multiple days; that acceptance remains outstanding until recorded separately.

After building the iOS simulator test host, `node Scripts/test-location-simulator.mjs` creates a dedicated simulator, grants its test app location access through simctl, sets the public sample position 37.3349/-122.009, and runs the real JavaScriptCore-to-Core Location query. The script deletes that simulator in cleanup and retains the xcresult/evidence under a temporary output directory. This checks the app callback pipeline with simulated coordinates; simctl permission injection does not validate the user permission dialog or widget-specific consent. The normal suite skips this opt-in integration test.
