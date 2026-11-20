//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Weather Glance: current conditions, the next hours, and five days.
// Sample data keeps it offline; replace `weather` with a fetch from your
// weather service (declare the domain in widget.json).
//

// $getenv("widget-size") is the size being drawn: "small", "medium", "large", …
const size = $getenv("widget-size");
// Sample data. hours: [label, SF Symbol name, temperature]. days: [label, symbol, low, high].
const weather = {
  city: "Cupertino",
  temp: 24,
  condition: "Mostly Sunny",
  icon: "sun.max.fill",
  high: 27,
  low: 15,
  hours: [
    ["Now", "sun.max.fill", 24],
    ["1PM", "sun.max.fill", 25],
    ["2PM", "cloud.sun.fill", 26],
    ["3PM", "cloud.sun.fill", 26],
    ["4PM", "cloud.fill", 24],
    ["5PM", "cloud.fill", 22],
  ],
  days: [
    ["Today", "sun.max.fill", 15, 27],
    ["Mon", "cloud.sun.fill", 14, 25],
    ["Tue", "cloud.rain.fill", 12, 19],
    ["Wed", "cloud.fill", 13, 21],
    ["Thu", "sun.max.fill", 16, 28],
  ],
};
// $gradient makes a value that fades from one color to another. It is used like a
// color: here as the background, further down as the color of a bar.
const sky = $gradient({
  type: "linear",
  colors: ["#2F80ED", "#56CCF2"],
  startPoint: "top",
  endPoint: "bottom",
});
// Sun icons are yellow, all others white.
const iconColor = (name) => (name.startsWith("sun") ? "#FFD60A" : "white");
const soft = "#E3F2FD";

// The city and the temperature now.
const Header = ({ big }) => (
  <vstack alignment="leading" spacing="0">
    <hstack spacing="4">
      <text font="headline" color="white">
        {weather.city}
      </text>
      <icon systemName="location.fill" size="10" color="white" />
    </hstack>
    <text font={big ? "56" : "44"} fontWeight="thin" color="white">
      {weather.temp}°
    </text>
  </vstack>
);
// The icon, the condition and the day's high and low.
const Summary = () => (
  <vstack alignment="leading" spacing="2">
    <icon systemName={weather.icon} size="18" color={iconColor(weather.icon)} />
    <text font="caption" fontWeight="semibold" color="white">
      {weather.condition}
    </text>
    <text font="caption" color={soft}>
      H:{weather.high}° L:{weather.low}°
    </text>
  </vstack>
);
// The next `count` hours in columns of equal width (each has frame="max").
const Hours = ({ count }) => (
  <hstack>
    {weather.hours.slice(0, count).map(([label, icon, temp], index) => (
      <vstack spacing="5" frame="max">
        <text font="caption2" fontWeight="semibold" color={soft}>
          {label}
        </text>
        <icon systemName={icon} size="16" color={iconColor(icon)} />
        <text font="subheadline" fontWeight="medium" color="white">
          {temp}°
        </text>
      </vstack>
    ))}
  </hstack>
);
// A day's range as a bar on the week's scale.
const lowest = Math.min(...weather.days.map((day) => day[2]));
const highest = Math.max(...weather.days.map((day) => day[3]));
const Days = ({ barWidth }) => (
  <vstack spacing="8">
    {weather.days.map(([label, icon, low, high]) => {
      // Points of bar width per degree.
      const scale = barWidth / (highest - lowest);
      return (
        <hstack spacing="10">
          <text font="subheadline" fontWeight="medium" color="white" frame="48,max,leading">
            {label}
          </text>
          <icon systemName={icon} size="16" color={iconColor(icon)} frame="24" />
          <text font="subheadline" color={soft} frame="28,max,trailing">
            {low}°
          </text>
          {/* A faint track; over it, an invisible rect pushes the colored range into place. */}
          <zstack frame={`${barWidth},5`}>
            <capsule color="white" opacity="0.25" frame={`${barWidth},5`} />
            <hstack spacing="0" frame={`${barWidth},5`}>
              <rect color="clear" frame={`${(low - lowest) * scale},5`} />
              <capsule
                frame={`${(high - low) * scale},5`}
                color={$gradient({
                  type: "linear",
                  colors: ["#A0E7FF", "#FFD60A"],
                  startPoint: "leading",
                  endPoint: "trailing",
                })}
              />
              <spacer />
            </hstack>
          </zstack>
          <text font="subheadline" fontWeight="medium" color="white" frame="28,max,trailing">
            {high}°
          </text>
        </hstack>
      );
    })}
  </vstack>
);

// Choose a layout for the widget size. The "accessory" sizes are Lock Screen widgets
// (iPhone and iPad only).
if (size === "accessoryCircular") {
  $render(
    <vstack spacing="1">
      <icon systemName={weather.icon} size="16" />
      <text font="title3" fontWeight="semibold">
        {weather.temp}°
      </text>
    </vstack>,
  );
} else if (size === "accessoryRectangular") {
  $render(
    <vstack alignment="leading" spacing="1" frame="max,leading">
      <hstack spacing="4">
        <icon systemName={weather.icon} size="14" />
        <text font="headline">
          {weather.temp}° {weather.city}
        </text>
      </hstack>
      <text font="caption">{weather.condition}</text>
      <text font="caption">
        H:{weather.high}° L:{weather.low}°
      </text>
    </vstack>,
  );
} else if (size === "accessoryInline") {
  $render(
    <text>
      {weather.city} {weather.temp}° · {weather.condition}
    </text>,
  );
} else if (size === "small") {
  // Small: city and temperature at the top, the summary at the bottom.
  $render(
    <vstack alignment="leading" frame="max,leading" padding="16" background={sky}>
      <Header />
      <spacer />
      <Summary />
    </vstack>,
  );
} else if (size === "medium") {
  // Medium: header and summary side by side, then six hours.
  $render(
    <vstack spacing="10" padding="16" background={sky}>
      <hstack alignment="top">
        <Header />
        <spacer />
        <Summary />
      </hstack>
      <Hours count={6} />
    </vstack>,
  );
} else {
  // Large and extra large add the five days; the bars are wider in the extra large size.
  const wide = size === "extraLarge";
  $render(
    <vstack spacing="14" padding="16" background={sky}>
      <hstack alignment="top">
        <Header big />
        <spacer />
        <Summary />
      </hstack>
      <Hours count={6} />
      <rect color="white" opacity="0.25" frame="max,1" />
      <Days barWidth={wide ? 360 : 110} />
      <spacer />
    </vstack>,
  );
}
