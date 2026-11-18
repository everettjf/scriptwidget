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

// fetch returns the response body as a string. A package with a widget.json must declare
// the "network" permission and the host in networkDomains for this call to work.
// latitude and longitude choose the place; current= lists the values wanted.
const result = await fetch(
  "https://api.open-meteo.com/v1/forecast?latitude=39.9042&longitude=116.4074&current=temperature_2m,apparent_temperature,weather_code&timezone=auto",
);
// "|| {}" keeps the lines below from failing when the answer has no `current` part.
const data = JSON.parse(result).current || {};
// The service describes the sky with a number (a WMO weather code). Only a few are
// named here; any other code is shown as "Mixed skies".
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
const condition = conditions[data.weather_code] || "Mixed skies";

// frame="max" fills the widget; padding is the space around the content, in points.
$render(
  <vstack frame="max" alignment="leading" spacing="6" padding="16" background="#2563eb">
    <hstack frame="max">
      <text font="caption" weight="bold" color="#bfdbfe">
        BEIJING
      </text>
      <spacer />
      <icon systemName="cloud.sun.fill" size="24" color="#fde68a" />
    </hstack>
    <spacer />
    <text font="largeTitle" weight="bold" color="white">
      {Math.round(data.temperature_2m)}°
    </text>
    <text font="headline" color="white">
      {condition}
    </text>
    <text font="caption" color="#dbeafe">
      Feels like {Math.round(data.apparent_temperature)}°
    </text>
  </vstack>,
);
