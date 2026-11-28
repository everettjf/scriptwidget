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
  if (parts.length === 2 && parts.every(Boolean)) {
    const [latValue, lonValue] = parts.map(Number);
    if (Math.abs(latValue) <= 90 && Math.abs(lonValue) <= 180) {
      lat = latValue;
      lon = lonValue;
    }
  }
}

// Read the data from Open-Meteo.
// Here fetch returns the response body as text, so it is parsed with JSON.parse.
// The network permission and this exact host are declared in widget.json.
const url = `https://air-quality-api.open-meteo.com/v1/air-quality?latitude=${lat}&longitude=${lon}&current=pm2_5,pm10,us_aqi&timezone=auto`;
let current;
try {
  const data = JSON.parse(await fetch(url))?.current;
  if (Number.isFinite(data?.us_aqi)) current = data;
} catch {
  // Unavailable data should never be shown as a measurement.
}

// frame="max" makes the stack fill the whole widget.
$render(
  <vstack frame="max" background="#155e75">
    <text font="caption" color="#bae6fd">
      Air Quality
    </text>
    {current ? (
      <>
        <text font="title2" color="#e2e8f0">
          AQI {current.us_aqi}
        </text>
        <hstack spacing="12">
          <vstack alignment="leading">
            <text font="caption2" color="#bae6fd">
              PM2.5
            </text>
            <text font="caption" color="#e2e8f0">
              {Number.isFinite(current.pm2_5) ? current.pm2_5 : "-"}
            </text>
          </vstack>
          <vstack alignment="leading">
            <text font="caption2" color="#bae6fd">
              PM10
            </text>
            <text font="caption" color="#e2e8f0">
              {Number.isFinite(current.pm10) ? current.pm10 : "-"}
            </text>
          </vstack>
        </hstack>
      </>
    ) : (
      <text font="caption" color="#e2e8f0">
        Air quality unavailable
      </text>
    )}
    <link url="https://open-meteo.com/en/docs/air-quality-api">
      <text font="caption2" color="#bae6fd">
        Open-Meteo · CAMS
      </text>
    </link>
  </vstack>,
);
