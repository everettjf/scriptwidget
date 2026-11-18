// Save a city in Records & Configuration; it is used when location is unavailable.
// Optional instance parameter: latitude,longitude,City or JSON weather settings.
// Forecast data: MET Norway (CC BY 4.0). No API key; Expires/conditional requests
// and a bounded four-place cache reduce traffic. No exact refresh guarantee.
//
// The location API runs on iPhone and iPad, and on Android, where widgets see the position
// saved while the app was open. It does not run on Mac, Windows or Linux; there the saved
// city is used.
// This template shows a widget that downloads data, keeps a cache and explains every
// failure. That work is in lib/weather.js; try changing the layouts and colors here.
// widget.json declares the "location", "network" and "storage" permissions, and the host
// api.met.no in networkDomains.

// $import runs lib/weather.js from this package and returns false when that fails.
// The file defines localWeather.
if (!$import("lib/weather.js"))
  throw new Error("Install the complete weather template, including lib/weather.js.");
// The settings: those saved in $storage, changed by the widget parameter (the parameter
// text set for this widget) when there is one.
const config = localWeather.options(
  $storage.getString("recordTemplate.config.v1"),
  $getenv("widget-param"),
);
// Load the forecast. The third argument is true when the system draws a future timeline
// entry in advance; such an entry only reads the cache.
const weather = await localWeather.load(
  config,
  Date.now(),
  $getenv("timeline-is-projection") === "true",
);
// $getenv("widget-size") is the size being drawn: "small", "medium", "large", …
const size = $getenv("widget-size"),
  compact = size === "small";
// No forecast to show: a title and a hint, in a form that fits each size.
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
  // Lock Screen sizes (iPhone and iPad only).
  $render(<text>{weather.temperature + " · " + weather.condition.title}</text>);
} else if (size === "accessoryCircular") {
  $render(
    <vstack spacing="2">
      <icon systemName={weather.condition.icon} size="23" />
      <text font="caption" weight="bold">
        {weather.temperature}
      </text>
    </vstack>,
  );
} else if (size === "accessoryRectangular") {
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
  // Small: place, temperature, condition and how fresh the data is. The forecast is
  // licensed CC BY 4.0, so the Home Screen layouts name the source.
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
  // Medium: icon, place and temperature in one row.
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
  // Large and extra large add wind, humidity and the next forecast points.
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
