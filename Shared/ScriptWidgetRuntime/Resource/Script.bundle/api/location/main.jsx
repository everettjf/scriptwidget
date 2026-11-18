//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Usage for api location
// Note: Location requires main app permission.
// This API reads current location only.
// Options are optional; default accuracy is reduced.
// Use maxAge/maxAgeMs for cached location to return faster.
// This example shows the position, its accuracy and its age.
// Runs on iPhone, iPad and Android. Not on Mac, Windows or Linux: check isAvailable() first.
// A Package 2.0 widget must list "location" under permissions in widget.json.
//

// Fallback for a system without location.
if (!$location.isAvailable()) {
  $render(
    <vstack frame="max" background="#0f172a">
      <text font="title3" color="#f87171">
        Location Unavailable
      </text>
      <text font="caption" color="#94a3b8">
        This device does not support location services.
      </text>
    </vstack>,
  );
} else {
  // Ask for access only when it was not given before.
  const status = $location.authorizationStatus();
  let granted = status === "authorizedWhenInUse" || status === "authorizedAlways";

  if (!granted) {
    // timeout is in seconds.
    granted = await $location.requestAuthorization({ timeout: 10 });
  }

  // Fallback when access was refused or the request ran out of time.
  if (!granted) {
    $render(
      <vstack frame="max" background="#0f172a">
        <text font="title3" color="#fbbf24">
          Permission Needed
        </text>
        <text font="caption" color="#94a3b8">
          Enable Location access in the main app.
        </text>
      </vstack>,
    );
  } else {
    // accuracy: "full" asks for the precise position. timeout is in seconds.
    const location = await $location.current({
      timeout: 10,
      accuracy: "full",
      purposeKey: "ScriptWidgetLocation",
    });

    $render(
      <vstack frame="max" background="#0f172a">
        <text font="caption" color="#94a3b8">
          Current Location
        </text>
        {/* Latitude and longitude, with five decimals. */}
        <text font="title3" color="#e2e8f0">
          {location.latitude.toFixed(5)}, {location.longitude.toFixed(5)}
        </text>
        {/* accuracy is in metres; accuracyAuthorization is "full" or "reduced". */}
        <text font="caption" color="#94a3b8">
          Accuracy: {Math.round(location.accuracy)}m ({location.accuracyAuthorization})
        </text>
        {/* age is in seconds. isStale marks a saved position that is old. */}
        <text font="caption2" color="#64748b">
          Age: {location.age.toFixed(1)}s {location.isStale ? "(stale)" : ""}
        </text>
        <text font="caption2" color="#64748b">
          Updated: {location.timestamp}
        </text>
      </vstack>,
    );
  }
}
