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
  if (parts.length >= 2) {
    const latValue = parseFloat(parts[0]);
    const lonValue = parseFloat(parts[1]);
    if (!Number.isNaN(latValue) && !Number.isNaN(lonValue)) {
      lat = latValue;
      lon = lonValue;
    }
  }
}

// formatted=0 asks the service for times in a form that new Date() can read.
const url = `https://api.sunrise-sunset.org/json?lat=${lat}&lng=${lon}&formatted=0`;
// fetch returns the response body as a string. A package with a widget.json must declare
// the "network" permission and the host in networkDomains for this call to work.
const result = await fetch(url);
const data = JSON.parse(result);
// ?. gives undefined instead of an error when the answer has no results.
const sunrise = data.results?.sunrise ? new Date(data.results.sunrise) : null;
const sunset = data.results?.sunset ? new Date(data.results.sunset) : null;

// The time in the device's own format and time zone, or "-" when it is missing.
const formatTime = (date) => {
  if (!date) return "-";
  return date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
};

// $getenv("widget-size") is the size being drawn: "small", "medium", "large", …
if ($getenv("widget-size") === "small") {
  // Small: the two times under each other.
  // frame="max" fills the widget; padding is the space around the content, in points.
  $render(
    <vstack frame="max" spacing="10" padding="12" background="#1e293b">
      <text font="caption" color="#94a3b8">
        Sunrise & Sunset
      </text>
      {/* <label> is an SF Symbol icon with a text beside it. */}
      <label title={formatTime(sunrise)} systemName="sunrise.fill" color="#f59e0b" />
      <label title={formatTime(sunset)} systemName="sunset.fill" color="#f97316" />
    </vstack>,
  );
} else {
  // Medium and larger: the two times side by side.
  $render(
    <vstack frame="max" background="#1e293b">
      <text font="caption" color="#94a3b8">
        Sunrise & Sunset
      </text>
      <hstack spacing="12">
        <label title={formatTime(sunrise)} systemName="sunrise.fill" color="#f59e0b" />
        <label title={formatTime(sunset)} systemName="sunset.fill" color="#f97316" />
      </hstack>
    </vstack>,
  );
}
