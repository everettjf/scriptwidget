//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
//
// Weather: the temperature, sky and wind in Beijing now, from open-meteo.com.
// Shows how to call a web service that answers in JSON. Try other coordinates and
// another title.
//

// fetch returns the response body as a string. A package with a widget.json must declare
// the "network" permission and the host in networkDomains for this call to work.
// latitude and longitude choose the place; current= lists the values wanted.
const result = await fetch(
  "https://api.open-meteo.com/v1/forecast?latitude=39.9042&longitude=116.4074&current=temperature_2m,wind_speed_10m,weather_code&timezone=auto",
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

// frame="max" fills the widget; padding is the space around the content, in points.
$render(
  <vstack frame="max" alignment="leading" spacing="5" padding="16" background="#0f766e">
    <hstack frame="max">
      <text font="caption" weight="bold" color="#99f6e4">
        BEIJING NOW
      </text>
      <spacer />
      <icon systemName="wind" size="19" color="#5eead4" />
    </hstack>
    <spacer />
    <text font="largeTitle" weight="bold" color="white">
      {Math.round(data.temperature_2m)}°
    </text>
    <text font="headline" color="white">
      {conditions[data.weather_code] || "Mixed skies"}
    </text>
    <text font="caption" color="#ccfbf1">
      Wind {Math.round(data.wind_speed_10m)} km/h
    </text>
  </vstack>,
);
