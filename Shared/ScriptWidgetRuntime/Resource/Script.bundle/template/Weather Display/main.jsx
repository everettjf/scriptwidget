//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Weather Template
//
// Description: Display weather today
//
// Shows how to call a web service that answers in JSON: open-meteo.com, for Beijing.
// Try other coordinates and another title.
//

// latitude and longitude choose the place; current= lists the values wanted.
// The network permission and this exact host are declared in widget.json.
const url =
  "https://api.open-meteo.com/v1/forecast?latitude=39.9042&longitude=116.4074&current=temperature_2m,apparent_temperature,weather_code&timezone=auto";
let weather;
try {
  const response = JSON.parse(await fetch(url));
  const current = response?.current;
  if (
    !response?.error &&
    Number.isFinite(current?.temperature_2m) &&
    Number.isFinite(current?.apparent_temperature) &&
    Number.isInteger(current?.weather_code)
  ) {
    weather = current;
  }
} catch {
  // Provider and network errors leave the widget in its unavailable state.
}
// The service describes the sky with a number (a WMO weather code). Only a few are
// named here; any other code is shown as "Unknown condition".
const conditions = {
  0: "Clear",
  1: "Mostly clear",
  2: "Partly cloudy",
  3: "Overcast",
  45: "Fog",
  61: "Rain",
  71: "Snow",
  95: "Thunderstorm",
};

// frame="max" fills the widget; padding is the space around the content, in points.
$render(
  <vstack frame="max" alignment="leading" spacing="4" padding="12" background="#1d4ed8">
    <hstack frame="max">
      <text font="caption" weight="bold" color="#bfdbfe">
        BEIJING
      </text>
      <spacer />
      <icon systemName="cloud.sun.fill" size="24" color="#fde68a" />
    </hstack>
    <spacer />
    {weather ? (
      <>
        <text font="largeTitle" weight="bold" color="white">
          {Math.round(weather.temperature_2m)}°
        </text>
        <text font="headline" color="white">
          {conditions[weather.weather_code] ?? "Unknown condition"}
        </text>
        <text font="caption" color="#dbeafe">
          Feels like {Math.round(weather.apparent_temperature)}°
        </text>
      </>
    ) : (
      <text font="caption" color="white">
        Weather unavailable
      </text>
    )}
    <link url="https://open-meteo.com/">
      <text font="caption2" color="#dbeafe">
        Open-Meteo
      </text>
    </link>
  </vstack>,
);
