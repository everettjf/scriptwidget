//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Sunrise & Sunset
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

const url = `https://api.sunrise-sunset.org/json?lat=${lat}&lng=${lon}&formatted=0`;
const result = await fetch(url);
const data = JSON.parse(result);
const sunrise = data.results?.sunrise ? new Date(data.results.sunrise) : null;
const sunset = data.results?.sunset ? new Date(data.results.sunset) : null;

const formatTime = (date) => {
  if (!date) return "-";
  return date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
};

$render(
  <vstack frame="max" background="#1e293b">
    <text font="caption" color="#94a3b8">Sunrise & Sunset</text>
    <hstack spacing="12">
      <label title={formatTime(sunrise)} systemName="sunrise.fill" color="#f59e0b" />
      <label title={formatTime(sunset)} systemName="sunset.fill" color="#f97316" />
    </hstack>
  </vstack>
);
