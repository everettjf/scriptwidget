// Read-only HealthKit card. Configure goals in Records & Configuration.
// Empty results never prove that read permission was granted or denied.
// Shows one Health number (steps, active energy or heart rate) and a ring for its goal.
// Try another metric or goal in Records & Configuration, or with a widget parameter such
// as {"metric":"energy","energyGoal":400}.
// The Health API runs on iPhone and iPad, and on Android through Health Connect (no ring goals
// or stand time); not on Mac, Windows or Linux.
// widget.json must declare the permissions "health", and "storage" for the saved settings.

// $import runs another file of this package; lib/health.js defines `healthCard`.
// It returns false when the file is missing.
if (!$import("lib/health.js")) throw new Error("Install the complete Health Steps Ring template.");
// The settings: defaults, then what the app saved in $storage, then the widget parameter
// ($getenv("widget-param"), a text you set on each widget you place).
const config = healthCard.options(
  $storage.getString("recordTemplate.config.v1"),
  $getenv("widget-param"),
);
// Read the number. "timeline-is-projection" is "true" when the script runs for a future
// timeline entry; Health is not asked then.
const health = await healthCard.load(
  config,
  Date.now(),
  $getenv("timeline-is-projection") === "true",
);
// $getenv("widget-size") is the size being drawn, such as "small" or "accessoryInline".
const size = $getenv("widget-size"),
  small = size === "small";
const dark = $device.isdarkmode(),
  background = dark ? "#111827" : "#eff6ff",
  text = dark ? "#f8fafc" : "#1e3a8a",
  secondary = dark ? "#cbd5e1" : "#475569";
// A progress ring with the icon of the metric in the middle. `value` goes from 0 to 1.
// <zstack> puts its children on top of each other.
const Ring = ({ side }) => (
  <zstack frame={`${side},${side}`}>
    <ring
      value={health.progress || 0}
      thickness="10"
      color={health.color}
      trackColor={dark ? "#334155" : "#dbeafe"}
      frame="max"
    />
    <icon systemName={health.icon} size={side / 3} color={health.color} />
  </zstack>
);
// Choose a layout for the widget size.
if (size === "accessoryInline") {
  // Lock Screen, inline: one line of text.
  $render(
    <text>
      {health.available ? `${health.title}: ${health.value} ${health.unit}` : health.heading}
    </text>,
  );
} else if (size === "accessoryCircular") {
  // Lock Screen, circular: an icon, the number and its unit.
  $render(
    <vstack spacing="0">
      <icon systemName={health.icon} size="16" />
      <text font="caption" weight="bold">
        {health.available ? String(health.value) : "—"}
      </text>
      <text font="caption2">{health.available ? health.unit : "Open app"}</text>
    </vstack>,
  );
} else if (size === "accessoryRectangular") {
  // Lock Screen, rectangular: three short lines.
  $render(
    <vstack alignment="leading" spacing="1">
      <text font="caption" weight="semibold">
        {health.title}
      </text>
      <text font="caption">
        {health.available ? `${health.value} ${health.unit}` : health.heading}
      </text>
      <text font="caption2">{health.available ? health.age : "Open ScriptWidget"}</text>
    </vstack>,
  );
} else if (!health.available) {
  // No number to show: say why.
  $render(
    <vstack frame="max" background={background} padding={small ? "12" : "16"} spacing="8">
      <icon systemName={health.icon} size={small ? "24" : "32"} color={health.color} />
      <text font={small ? "headline" : "title3"} weight="bold" color={text}>
        {health.heading}
      </text>
      <text font="caption" color={secondary}>
        {health.detail}
      </text>
    </vstack>,
  );
} else if (small) {
  // Small widget: the number, without a ring.
  $render(
    <vstack frame="max" alignment="leading" padding="14" spacing="5" background={background}>
      <hstack>
        <icon systemName={health.icon} size="17" color={health.color} />
        <text font="caption" color={secondary}>
          {health.title}
        </text>
      </hstack>
      <spacer />
      <hstack alignment="bottom" spacing="4">
        <text font="largeTitle" weight="bold" color={text}>
          {String(health.value)}
        </text>
        <text font="caption2" color={secondary}>
          {health.unit}
        </text>
      </hstack>
      <text font="caption" color={secondary}>
        {health.detail}
      </text>
      <text font="caption2" color={secondary}>
        {health.age}
      </text>
    </vstack>,
  );
} else if (size === "medium") {
  // Medium widget: the ring on the left. Heart rate has no goal, so it gets an icon.
  $render(
    <hstack frame="max" padding="16" spacing="18" background={background}>
      {health.goal === null ? (
        <icon systemName={health.icon} size="56" color={health.color} />
      ) : (
        <Ring side={100} />
      )}
      <vstack frame="max,leading" alignment="leading" spacing="4">
        <text font="caption" color={secondary}>
          {health.title}
        </text>
        <hstack alignment="bottom" spacing="4">
          <text font="largeTitle" weight="bold" color={text}>
            {String(health.value)}
          </text>
          <text font="caption" color={secondary}>
            {health.unit}
          </text>
        </hstack>
        <text font="caption" color={secondary}>
          {health.detail}
        </text>
        <text font="caption2" color={secondary}>
          {health.age}
        </text>
      </vstack>
    </hstack>,
  );
} else {
  // Large and extra large widgets: the ring above the number.
  $render(
    <vstack frame="max" padding="18" spacing="10" background={background}>
      <text font="headline" color={text}>
        {health.title}
      </text>
      <spacer />
      {health.goal === null ? (
        <icon systemName={health.icon} size="64" color={health.color} />
      ) : (
        <Ring side={120} />
      )}
      <hstack alignment="bottom" spacing="5">
        <text font="largeTitle" weight="bold" color={text}>
          {String(health.value)}
        </text>
        <text font="caption" color={secondary}>
          {health.unit}
        </text>
      </hstack>
      <text font="caption" color={secondary}>
        {health.detail}
      </text>
      <spacer />
      <text font="caption" color={secondary}>
        {health.age}
      </text>
      <text font="caption2" color={secondary}>
        Apple Health · Read-only
      </text>
    </vstack>,
  );
}
