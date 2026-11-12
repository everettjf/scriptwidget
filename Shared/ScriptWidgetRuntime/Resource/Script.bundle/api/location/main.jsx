//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Usage for api location
// Note: Location requires main app permission.
// This API reads current location only.
// Options are optional; default accuracy is reduced.
// Use maxAge/maxAgeMs for cached location to return faster.
//

if (!$location.isAvailable()) {
  $render(
    <vstack frame="max" background="#0f172a">
      <text font="title3" color="#f87171">Location Unavailable</text>
      <text font="caption" color="#94a3b8">This device does not support location services.</text>
    </vstack>
  );
} else {
  const status = $location.authorizationStatus();
  let granted = status === "authorizedWhenInUse" || status === "authorizedAlways";

  if (!granted) {
    granted = await $location.requestAuthorization({ timeout: 10 });
  }

  if (!granted) {
    $render(
      <vstack frame="max" background="#0f172a">
        <text font="title3" color="#fbbf24">Permission Needed</text>
        <text font="caption" color="#94a3b8">Enable Location access in the main app.</text>
      </vstack>
    );
  } else {
    const location = await $location.current({
      timeout: 10,
      accuracy: "full",
      purposeKey: "ScriptWidgetLocation"
    });

    $render(
      <vstack frame="max" background="#0f172a">
        <text font="caption" color="#94a3b8">Current Location</text>
        <text font="title3" color="#e2e8f0">
          {location.latitude.toFixed(5)}, {location.longitude.toFixed(5)}
        </text>
        <text font="caption" color="#94a3b8">
          Accuracy: {Math.round(location.accuracy)}m ({location.accuracyAuthorization})
        </text>
        <text font="caption2" color="#64748b">
          Age: {location.age.toFixed(1)}s {location.isStale ? "(stale)" : ""}
        </text>
        <text font="caption2" color="#64748b">Updated: {location.timestamp}</text>
      </vstack>
    );
  }
}
