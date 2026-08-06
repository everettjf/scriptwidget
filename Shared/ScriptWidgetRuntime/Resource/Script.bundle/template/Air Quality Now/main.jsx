//
// ScriptWidget
// https://xnu.app/scriptwidget
//
// Air Quality Now - Open-Meteo (no API key)
// widget-param: "lat,lon" (optional)
//

let lat = 37.7749;
let lon = -122.4194;
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

const url = `https://air-quality-api.open-meteo.com/v1/air-quality?latitude=${lat}&longitude=${lon}&current=pm2_5,pm10,us_aqi&timezone=auto`;
const result = await fetch(url);
const data = JSON.parse(result);
const current = data.current || {};

$render(
  <vstack frame="max" background="#155e75">
    <text font="caption" color="#94a3b8">Air Quality</text>
    <text font="title2" color="#e2e8f0">AQI {current.us_aqi ?? "-"}</text>
    <hstack spacing="12">
      <vstack alignment="leading">
        <text font="caption2" color="#94a3b8">PM2.5</text>
        <text font="caption" color="#e2e8f0">{current.pm2_5 ?? "-"}</text>
      </vstack>
      <vstack alignment="leading">
        <text font="caption2" color="#94a3b8">PM10</text>
        <text font="caption" color="#e2e8f0">{current.pm10 ?? "-"}</text>
      </vstack>
    </hstack>
  </vstack>
);
