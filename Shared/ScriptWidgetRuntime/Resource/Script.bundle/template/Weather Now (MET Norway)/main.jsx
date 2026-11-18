// Save a city in Records & Configuration; it is used when location is unavailable.
// Optional instance parameter: latitude,longitude,City or JSON weather settings.
// Forecast data: MET Norway (CC BY 4.0). No API key; Expires/conditional requests
// and a bounded four-place cache reduce traffic. No exact refresh guarantee.
if (!$import("lib/weather.js"))
  throw new Error("Install the complete weather template, including lib/weather.js.");
const config = localWeather.options(
  $storage.getString("recordTemplate.config.v1"),
  $getenv("widget-param"),
);
const weather = await localWeather.load(
  config,
  Date.now(),
  $getenv("timeline-is-projection") === "true",
);
const size = $getenv("widget-size"),
  compact = size === "small";
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
