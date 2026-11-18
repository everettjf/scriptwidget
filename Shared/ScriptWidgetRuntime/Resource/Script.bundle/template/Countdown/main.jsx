// Save defaults in Records & Configuration. Each widget's parameter can override
// them: 2027-01-01 New Year, 2027-01-01T12:30:00 Flight, or JSON settings.
// Calendar dates follow the device's local Gregorian date. WidgetKit schedules
// updates; this is not a continuously ticking timer.
// widget.json declares the "storage" permission, and a timeline with dailyTimes
// ["00:00"] so the day count changes at midnight.
// Try changing the colors in `palette` or the layouts below.
//
// $import runs another file of this package; the check fails if it could not be loaded.
// lib/countdown.js defines the global CountdownCalendar used below.
if (!$import("lib/countdown.js"))
  throw new Error("Install the complete Countdown template, including lib/countdown.js.");
// Read the settings: the saved defaults from $storage, then the widget's parameter.
const settings = CountdownCalendar.configuration(
  $storage.getString("recordTemplate.config.v1"),
  $getenv("widget-param"),
);
// Work out the texts to show. "timeline-date" is the date this entry is drawn for;
// the current time is used when it is not set.
const moment = CountdownCalendar.describe(
  settings,
  new Date($getenv("timeline-date") || Date.now()),
);
// Three color sets. The `accent` setting chooses one.
const palette = {
  blue: { background: "#eff6ff", ink: "#1e3a8a", soft: "#3b82f6" },
  rose: { background: "#fff1f2", ink: "#881337", soft: "#e11d48" },
  green: { background: "#ecfdf5", ink: "#064e3b", soft: "#059669" },
}[moment.accent];
// Choose a layout for the widget size. The "accessory" sizes are Lock Screen widgets.
const size = $getenv("widget-size");
if (size === "accessoryInline") {
  // Lock Screen line: the title and the summary as text.
  $render(<text>{moment.title + ": " + moment.summary}</text>);
} else if (size === "accessoryCircular") {
  // Lock Screen circle: an icon and the number.
  $render(
    <vstack spacing="2">
      <icon systemName="calendar" size="18" />
      <text font="caption" weight="bold">
        {moment.number}
      </text>
    </vstack>,
  );
} else if (size === "accessoryRectangular") {
  // Lock Screen rectangle: the title above the summary.
  $render(
    <vstack alignment="leading" spacing="3">
      <text font="headline">{moment.title}</text>
      <text font="caption">{moment.summary}</text>
    </vstack>,
  );
} else if (size === "medium") {
  // Medium: the title and date on the left, the number on the right.
  // frame="max" fills the widget; padding and spacing are in points.
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
  // Small: cut the title to 14 characters. Array.from counts whole characters, so an emoji
  // is not cut in half.
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
  // Large and extra-large: the number in the middle, the title and date at the bottom.
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
        {/* A repeat icon for a yearly event, a calendar icon otherwise. */}
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
