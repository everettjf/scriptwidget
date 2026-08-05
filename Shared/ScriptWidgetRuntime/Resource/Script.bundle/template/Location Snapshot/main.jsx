//
// ScriptWidget
// https://xnu.app/scriptwidget
//
// Location Snapshot
// Requires Location permission in the main app.
//

if (!$location.isAvailable()) {
  $render(
    <hstack frame="max" background="#312e81" padding="14" spacing="14"><icon systemName="map.fill" size="44" color="#a5b4fc"/><vstack alignment="leading" spacing="4"><text font="caption" color="#c7d2fe">LOCATION SNAPSHOT</text><text font="title2" weight="bold" color="white">Made for iPhone</text><text font="caption" color="#e0e7ff">See coordinates and accuracy on iOS.</text></vstack></hstack>
  );
} else {
  const status = $location.authorizationStatus();
  const authorized = status === "authorizedWhenInUse" || status === "authorizedAlways";

  if (!authorized) {
    $render(
      <hstack frame="max" background="#312e81" padding="14" spacing="14"><icon systemName="location.circle.fill" size="44" color="#a5b4fc"/><vstack alignment="leading" spacing="4"><text font="caption" color="#c7d2fe">LOCATION SNAPSHOT</text><text font="title2" weight="bold" color="white">Enable location</text><text font="caption" color="#e0e7ff">Allow access to reveal your coordinates.</text></vstack></hstack>
    );
  } else {
    const location = await $location.current();
    const lat = location.latitude.toFixed(4);
    const lon = location.longitude.toFixed(4);
    const accuracy = Math.max(0, Math.round(location.accuracy));

    $render(
      <vstack frame="max" background="#111827" spacing="6">
        <text font="caption" color="#94a3b8">Location Snapshot</text>
        <text font="title3" color="#e2e8f0">{lat}, {lon}</text>
        <text font="caption" color="#94a3b8">Accuracy: {accuracy}m</text>
        <text font="caption2" color="#64748b">{location.timestamp}</text>
      </vstack>
    );
  }
}
