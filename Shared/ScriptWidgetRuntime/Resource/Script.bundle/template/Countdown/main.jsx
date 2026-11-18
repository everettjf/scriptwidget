// Save defaults in Records & Configuration. Each widget's parameter can override
// them: 2027-01-01 New Year, 2027-01-01T12:30:00 Flight, or JSON settings.
// Calendar dates follow the device's local Gregorian date. WidgetKit schedules
// updates; this is not a continuously ticking timer.
if (!$import("lib/countdown.js"))
  throw new Error("Install the complete Countdown template, including lib/countdown.js.");
const settings = CountdownCalendar.configuration(
  $storage.getString("recordTemplate.config.v1"),
  $getenv("widget-param"),
);
const moment = CountdownCalendar.describe(
  settings,
  new Date($getenv("timeline-date") || Date.now()),
);
const palette = {
  blue: { background: "#eff6ff", ink: "#1e3a8a", soft: "#3b82f6" },
  rose: { background: "#fff1f2", ink: "#881337", soft: "#e11d48" },
  green: { background: "#ecfdf5", ink: "#064e3b", soft: "#059669" },
}[moment.accent];
const size = $getenv("widget-size");
if (size === "accessoryInline") {
  $render(<text>{moment.title + ": " + moment.summary}</text>);
} else if (size === "accessoryCircular") {
  $render(
    <vstack spacing="2">
      <icon systemName="calendar" size="18" />
      <text font="caption" weight="bold">
        {moment.number}
      </text>
    </vstack>,
  );
} else if (size === "accessoryRectangular") {
  $render(
    <vstack alignment="leading" spacing="3">
      <text font="headline">{moment.title}</text>
      <text font="caption">{moment.summary}</text>
    </vstack>,
  );
} else if (size === "medium") {
  $render(
    <hstack frame="max" spacing="16" padding="18" background={palette.background}>
      <vstack alignment="leading" spacing="7">
        <text font="caption2" weight="semibold" color={palette.soft}>
          COUNTDOWN
        </text>
        <text font="headline" weight="semibold" color={palette.ink}>
          {moment.title}
        </text>
        <text font="caption2" color={palette.ink}>
          {moment.date}
        </text>
      </vstack>
      <spacer />
      <vstack spacing="4">
        <text font="38" weight="bold" color={palette.ink}>
          {moment.number}
        </text>
        <text font="caption" color={palette.ink}>
          {moment.unit}
        </text>
      </vstack>
    </hstack>,
  );
} else if (size === "small") {
  const shortTitle =
    Array.from(moment.title).slice(0, 14).join("") +
    (Array.from(moment.title).length > 14 ? "…" : "");
  $render(
    <vstack
      frame="max"
      alignment="leading"
      spacing="5"
      padding="14"
      background={palette.background}
    >
      <text font="caption2" weight="semibold" color={palette.soft}>
        COUNTDOWN
      </text>
      <text font="28" weight="bold" color={palette.ink}>
        {moment.number}
      </text>
      <text font="caption2" color={palette.ink}>
        {moment.unit}
      </text>
      <text font="caption" weight="semibold" color={palette.ink}>
        {shortTitle}
      </text>
      <text font="caption2" color={palette.ink}>
        {moment.date}
      </text>
    </vstack>,
  );
} else {
  $render(
    <vstack
      frame="max"
      alignment="leading"
      spacing="10"
      padding="22"
      background={palette.background}
    >
      <hstack frame="max,20">
        <text font="caption2" weight="semibold" color={palette.ink}>
          COUNTDOWN
        </text>
        <spacer />
        <icon
          systemName={moment.repeatYearly ? "repeat" : "calendar"}
          size="18"
          color={palette.soft}
        />
      </hstack>
      <spacer />
      <text font="48" weight="bold" color={palette.ink}>
        {moment.number}
      </text>
      <text font="callout" color={palette.ink}>
        {moment.unit}
      </text>
      <spacer />
      <text font="title3" weight="semibold" color={palette.ink}>
        {moment.title}
      </text>
      <text font="caption2" color={palette.ink}>
        {moment.date}
      </text>
    </vstack>,
  );
}
