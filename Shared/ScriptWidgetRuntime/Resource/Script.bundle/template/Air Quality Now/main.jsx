//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Air Quality Now - Open-Meteo (no API key)
// widget-param: "lat,lon" (optional)
//
// Shows live air quality numbers for one place, read from a web API.
// Try changing the default coordinates below, or set them for each widget with the parameter.
//

// The default place: San Francisco, as latitude and longitude in degrees.
let lat = 37.7749;
let lon = -122.4194;
// $getenv("widget-param") is the parameter set for this widget (an empty string if none).
const param = $getenv("widget-param");
if (param) {
  // Use the parameter only if it holds two valid numbers; otherwise keep the default.
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

// Read the data from Open-Meteo.
// Here fetch returns the response body as text, so it is parsed with JSON.parse.
// This template has no widget.json. In a package that has one, fetch only works when
// widget.json declares the "network" permission and lists this host in "networkDomains".
const url = `https://air-quality-api.open-meteo.com/v1/air-quality?latitude=${lat}&longitude=${lon}&current=pm2_5,pm10,us_aqi&timezone=auto`;
const result = await fetch(url);
const data = JSON.parse(result);
// `current` can be missing from an answer; {} keeps the lines below from failing.
const current = data.current || {};

// frame="max" makes the stack fill the whole widget.
// `??` shows "-" when a value is missing.
$render(
  <vstack frame="max" background="#155e75">
    <text font="caption" color="#94a3b8">
      Air Quality
    </text>
    <text font="title2" color="#e2e8f0">
      AQI {current.us_aqi ?? "-"}
    </text>
    <hstack spacing="12">
      <vstack alignment="leading">
        <text font="caption2" color="#94a3b8">
          PM2.5
        </text>
        <text font="caption" color="#e2e8f0">
          {current.pm2_5 ?? "-"}
        </text>
      </vstack>
      <vstack alignment="leading">
        <text font="caption2" color="#94a3b8">
          PM10
        </text>
        <text font="caption" color="#e2e8f0">
          {current.pm10 ?? "-"}
        </text>
      </vstack>
    </hstack>
  </vstack>,
);
