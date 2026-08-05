//
// ScriptWidget
// https://xnu.app/scriptwidget
//
// Local Weather (Location)
// Requires Location permission in the main app.
//

if (!$location.isAvailable()) {
  $render(
    <hstack frame="max" background="#0c4a6e" padding="14" spacing="14"><icon systemName="location.slash.fill" size="44" color="#38bdf8"/><vstack alignment="leading" spacing="4"><text font="caption" color="#7dd3fc">LOCAL WEATHER</text><text font="title2" weight="bold" color="white">Location on iPhone</text><text font="caption" color="#bae6fd">Add on iOS for weather where you are.</text></vstack></hstack>
  );
  return;
}

const status = $location.authorizationStatus();
const authorized = status === "authorizedWhenInUse" || status === "authorizedAlways";

if (!authorized) {
  $render(
    <hstack frame="max" background="#0c4a6e" padding="14" spacing="14"><icon systemName="location.circle.fill" size="44" color="#38bdf8"/><vstack alignment="leading" spacing="4"><text font="caption" color="#7dd3fc">LOCAL WEATHER</text><text font="title2" weight="bold" color="white">Share your location</text><text font="caption" color="#bae6fd">Allow access for a live local forecast.</text></vstack></hstack>
  );
  return;
}

const location = await $location.current();
const lat = location.latitude.toFixed(4);
const lon = location.longitude.toFixed(4);

const url = `https://api.open-meteo.com/v1/forecast?latitude=${lat}&longitude=${lon}&current=temperature_2m,apparent_temperature,weather_code&timezone=auto`;
const result = await fetch(url);
const data = JSON.parse(result);
const current = data.current || {};

$render(
  <vstack frame="max" background="#0f172a" spacing="6">
    <text font="caption" color="#94a3b8">Local Weather</text>
    <text font="title2" color="#e2e8f0">{current.temperature_2m ?? "-"} deg C</text>
    <text font="caption" color="#94a3b8">Feels like {current.apparent_temperature ?? "-"} deg C</text>
    <text font="caption2" color="#64748b">Weather code: {current.weather_code ?? "-"}</text>
  </vstack>
);
