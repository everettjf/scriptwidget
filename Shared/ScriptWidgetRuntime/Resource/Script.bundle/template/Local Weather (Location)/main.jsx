// Save a city in Records & Configuration; it is used when location is unavailable.
// Optional instance parameter: latitude,longitude,City or JSON weather settings.
// Forecast data: MET Norway (CC BY 4.0). No API key; Expires/conditional requests
// and a bounded four-place cache reduce traffic. No exact refresh guarantee.
// Shows the forecast for where you are, or for a saved city, in every widget size.
// Try the widget parameter: 59.91,10.75,Oslo or {"unit":"f"}.
// The Location API runs on iPhone and iPad, and on Android (widgets see the position
// saved while the app was open); not on Mac, Windows or Linux. There the saved city is
// used. widget.json must declare the permissions "location", "storage" and "network",
// with the host api.met.no.

// $import runs another file of this package; lib/weather.js defines `localWeather`.
// It returns false when the file is missing.
if (!$import("lib/weather.js"))
  throw new Error("Install the complete weather template, including lib/weather.js.");
// The settings: defaults, then what the app saved in $storage, then the widget parameter
// ($getenv("widget-param"), a text you set on each widget you place).
const config = localWeather.options(
  $storage.getString("recordTemplate.config.v1"),
  $getenv("widget-param"),
);
// Read the forecast: from MET Norway when the saved copy is due for a refresh, else from
// $storage. "timeline-is-projection" is "true" when the script runs for a future timeline
// entry; no request is made then.
const weather = await localWeather.load(
  config,
  Date.now(),
  $getenv("timeline-is-projection") === "true",
);
// $getenv("widget-size") is the size being drawn, such as "small" or "accessoryInline".
const size = $getenv("widget-size"),
  compact = size === "small";
// No forecast: show the reason in a form that fits the size.
if (!weather.available) {
  if (size === "accessoryInline") $render(<text>{weather.title}</text>);
  else if (size === "accessoryCircular") $render(<icon systemName="cloud" size="25" />);
  else if (size === "accessoryRectangular")
    $render(
      <vstack alignment="leading" spacing="2">
        <text font="headline">{weather.title}</text>
        <text font="caption2">Open ScriptWidget to configure weather.</text>
      </vstack>,
    );
  else
    $render(
      <vstack frame="max" padding="14" spacing="7" background="#eff6ff">
        <icon systemName="cloud" size="26" color="#3b82f6" />
        <text font="headline" color="#1e3a8a">
          {weather.title}
        </text>
        <text font="caption2" color="#475569">
          {weather.hint}
        </text>
      </vstack>,
    );
} else if (size === "accessoryInline") {
  // Lock Screen, inline: one line of text.
  $render(<text>{weather.temperature + " · " + weather.condition.title}</text>);
} else if (size === "accessoryCircular") {
  // Lock Screen, circular: an icon and the temperature.
  $render(
    <vstack spacing="2">
      <icon systemName={weather.condition.icon} size="23" />
      <text font="caption" weight="bold">
        {weather.temperature}
      </text>
    </vstack>,
  );
} else if (size === "accessoryRectangular") {
  // Lock Screen, rectangular: place, temperature and condition.
  $render(
    <hstack spacing="8">
      <icon systemName={weather.condition.icon} size="26" />
      <vstack alignment="leading" spacing="2">
        <text font="headline">{weather.name + " · " + weather.temperature}</text>
        <text font="caption2">{weather.condition.title}</text>
      </vstack>
    </hstack>,
  );
} else if (compact) {
  // Small widget. Array.from(name).slice(0, 12) keeps the first 12 characters of the name.
  $render(
    <vstack frame="max" alignment="leading" padding="12" spacing="4" background="#eff6ff">
      <text font="caption2" weight="semibold" color="#1e3a8a">
        {Array.from(weather.name).slice(0, 12).join("")}
      </text>
      <hstack frame="max">
        <text font="28" weight="bold" color="#1e3a8a">
          {weather.temperature}
        </text>
        <spacer />
        <icon systemName={weather.condition.icon} size="26" color="#2563eb" />
      </hstack>
      <text font="caption2" color="#1e3a8a">
        {weather.condition.title}
      </text>
      <text font="caption2" color="#475569">
        {weather.statusShort}
      </text>
      <text font="caption2" color="#475569">
        {weather.updated}
      </text>
      <text font="caption2" color="#475569">
        MET Norway
      </text>
    </vstack>,
  );
} else if (size === "medium") {
  // Medium widget: icon, place and temperature in one row.
  $render(
    <vstack frame="max" padding="16" spacing="7" background="#eff6ff">
      <hstack frame="max" spacing="14">
        <icon systemName={weather.condition.icon} size="40" color="#2563eb" />
        <vstack alignment="leading" spacing="3">
          <text font="headline" color="#1e3a8a">
            {weather.name}
          </text>
          <text font="caption" color="#475569">
            {weather.condition.title}
          </text>
        </vstack>
        <spacer />
        <text font="34" weight="bold" color="#1e3a8a">
          {weather.temperature}
        </text>
      </hstack>
      <hstack frame="max">
        <text font="caption2" color="#475569">
          {weather.updated}
        </text>
        <spacer />
        <text font="caption2" color="#475569">
          MET Norway
        </text>
      </hstack>
      <text font="caption2" color="#475569">
        {weather.status}
      </text>
    </vstack>,
  );
} else {
  // Large and extra large widgets: also wind, humidity and the next forecast points.
  $render(
    <vstack frame="max" padding="16" spacing="8" background="#eff6ff">
      <hstack frame="max">
        <vstack alignment="leading" spacing="5">
          <text font="title3" weight="semibold" color="#1e3a8a">
            {weather.name}
          </text>
          <text font="caption" color="#475569">
            {weather.condition.title}
          </text>
        </vstack>
        <spacer />
        <icon systemName={weather.condition.icon} size="34" color="#2563eb" />
      </hstack>
      <text font="40" weight="bold" color="#1e3a8a">
        {weather.temperature}
      </text>
      <hstack frame="max">
        <text font="caption" color="#475569">
          {"Wind " + weather.wind}
        </text>
        <spacer />
        <text font="caption" color="#475569">
          {"Humidity " + weather.humidity}
        </text>
      </hstack>
      <hstack frame="max" spacing="12">
        {weather.upcoming.map((point) => (
          <vstack spacing="4">
            <text font="caption2" color="#475569">
              {point.label}
            </text>
            <icon systemName={point.condition.icon} size="20" color="#2563eb" />
            <text font="caption" color="#1e3a8a">
              {point.temperature}
            </text>
          </vstack>
        ))}
      </hstack>
      <text font="caption2" color="#475569">
        {weather.status + " · " + weather.updated}
      </text>
      <text font="caption2" color="#475569">
        MET Norway · CC BY 4.0
      </text>
    </vstack>,
  );
}
