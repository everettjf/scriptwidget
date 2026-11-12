//
// ScriptWidget
// https://atomsprout.com/scriptwidget
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
    let location;
    try {
      location = await $location.current({ maxAge: 3600 });
    } catch(error) {
      const message = String(error);
      const needsWidgetAccess = message.includes("widget_not_authorized");
      const compactLocation = $getenv("widget-size") === "small";
      $render(
        <vstack frame="max" padding={compactLocation ? "12" : "14"} spacing="6" background="#f1f5f9">
          <icon systemName="location.slash" size={compactLocation ? "22" : "28"} color="#64748b"/>
          <text font={compactLocation ? "subheadline" : "headline"} color="#0f172a">{needsWidgetAccess ? (compactLocation ? "Allow widgets" : "Allow widget location") : (compactLocation ? "No location yet" : "Location unavailable")}</text>
          <text font="caption" color="#475569">{needsWidgetAccess ? "In Settings, allow location for the app and widgets." : "Open ScriptWidget → Settings → Location, then refresh."}</text>
        </vstack>
      );
      return;
    }
    const lat = location.latitude.toFixed(4);
    const lon = location.longitude.toFixed(4);
    const accuracy = Math.max(0, Math.round(location.accuracy));

    $render(
      <vstack frame="max" background="#111827" spacing="6">
        <text font="caption" color="#94a3b8">Location Snapshot</text>
        <text font="title3" color="#e2e8f0">{lat}, {lon}</text>
        <text font="caption" color="#94a3b8">Accuracy: {accuracy}m</text>
        <text font="caption2" color="#94a3b8">{location.isStale ? "Saved · " + Math.round(location.age / 60) + "m ago" : "Updated " + new Date(location.timestamp).toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" })}</text>
      </vstack>
    );
  }
}
