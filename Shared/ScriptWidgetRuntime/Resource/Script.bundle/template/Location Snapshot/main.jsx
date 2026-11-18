//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Location Snapshot
// Requires Location permission in the main app.
//

// The card of the two states without a location. At the small size a row has
// no room for the icon beside the words, so the icon sits above them.
const Card = ({ symbol, title, detail }) => {
  const compact = $getenv("widget-size") === "small";
  const words = <vstack alignment="leading" spacing="4"><text font="caption" color="#c7d2fe">LOCATION SNAPSHOT</text><text font={compact ? "subheadline" : "title2"} weight="bold" color="white">{title}</text><text font="caption" color="#e0e7ff">{detail}</text></vstack>;
  return compact
    ? <vstack frame="max" alignment="leading" background="#312e81" padding="14" spacing="8"><icon systemName={symbol} size="26" color="#a5b4fc"/>{words}</vstack>
    : <hstack frame="max" background="#312e81" padding="14" spacing="14"><icon systemName={symbol} size="44" color="#a5b4fc"/>{words}</hstack>;
};

if (!$location.isAvailable()) {
  $render(<Card symbol="map.fill" title="Made for iPhone" detail="See coordinates and accuracy on iOS." />);
} else {
  const status = $location.authorizationStatus();
  const authorized = status === "authorizedWhenInUse" || status === "authorizedAlways";

  if (!authorized) {
    $render(<Card symbol="location.circle.fill" title="Enable location" detail="Allow access to reveal your coordinates." />);
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
