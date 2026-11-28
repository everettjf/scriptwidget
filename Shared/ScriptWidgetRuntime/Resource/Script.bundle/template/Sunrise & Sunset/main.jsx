//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Sunrise & Sunset
// widget-param: "lat,lon" (optional)
//
// Shows how to call a web service that answers in JSON, and how to format a time.
// Try your own coordinates in the widget parameter.
//

// The default place is San Francisco. Latitude and longitude are in degrees.
let lat = 37.7749;
let lon = -122.4194;
// $getenv("widget-param") is the parameter text set for this widget. "48.85,2.35"
// replaces the default place; anything that is not two numbers is ignored.
const param = $getenv("widget-param");
if (param) {
  const parts = param.split(",").map((p) => p.trim());
  if (parts.length === 2 && parts[0] && parts[1]) {
    const latValue = Number(parts[0]);
    const lonValue = Number(parts[1]);
    if (
      Number.isFinite(latValue) &&
      Number.isFinite(lonValue) &&
      Math.abs(latValue) <= 90 &&
      Math.abs(lonValue) <= 180
    ) {
      lat = latValue;
      lon = lonValue;
    }
  }
}

// formatted=0 asks the service for times in a form that new Date() can read.
const url = `https://api.sunrise-sunset.org/json?lat=${lat}&lng=${lon}&formatted=0`;
// The network permission and this exact host are declared in widget.json.
let times;
try {
  const data = JSON.parse(await fetch(url));
  if (data?.status === "OK") times = data.results;
} catch {
  // Provider and network errors leave the widget in its unavailable state.
}

// Display valid timestamps in the device's own time zone and format.
const formatTime = (value) => {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}T/.test(value)) return null;
  const date = new Date(value);
  return Number.isFinite(date.getTime())
    ? date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })
    : null;
};
const sunrise = formatTime(times?.sunrise);
const sunset = formatTime(times?.sunset);
const small = $getenv("widget-size") === "small";
const labels = (
  <>
    <label title={sunrise ?? "—"} systemName="sunrise.fill" color="#f59e0b" />
    <label title={sunset ?? "—"} systemName="sunset.fill" color="#fb923c" />
  </>
);

// Small widgets stack the two labels. Wider widgets show them side by side.
$render(
  <vstack frame="max" spacing="8" padding="12" background="#1e293b">
    <text font="caption" color="#cbd5e1">
      Sunrise & Sunset
    </text>
    {sunrise || sunset ? (
      small ? (
        <vstack spacing="4">{labels}</vstack>
      ) : (
        <hstack spacing="12">{labels}</hstack>
      )
    ) : (
      <text font="caption" color="#f1f5f9">
        Times unavailable
      </text>
    )}
    <link url="https://sunrise-sunset.org/">
      <text font="caption2" color="#cbd5e1">
        Sunrise-Sunset.org
      </text>
    </link>
  </vstack>,
);
