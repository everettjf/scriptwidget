// Day Rhythm — local scheduled themes, without network or personal data.
// Change dailyTimes/timeZone in widget.json. Optional widget-param: {"name":"Alex"}.
// Shows one of four themes, chosen by the time of day. widget.json lists four times in
// timeline.dailyTimes (06:00, 12:00, 18:00, 22:00) and the theme changes at each of them.
// Try changing the texts and colors in `phases`.
//
// One theme for each time in dailyTimes, in the same order. `symbol` names a system icon.
const phases = [
  {
    title: "Morning focus",
    hint: "Make room for one good thing.",
    symbol: "sunrise.fill",
    background: "#fff7ed",
    accent: "#9a3412",
    label: "MORNING",
  },
  {
    title: "Afternoon flow",
    hint: "A little progress goes a long way.",
    symbol: "sun.max.fill",
    background: "#eff6ff",
    accent: "#1e40af",
    label: "AFTERNOON",
  },
  {
    title: "Evening reset",
    hint: "Slow down and recharge.",
    symbol: "sunset.fill",
    background: "#f5f3ff",
    accent: "#6b21a8",
    label: "EVENING",
  },
  {
    title: "Quiet hours",
    hint: "Rest is part of the rhythm.",
    symbol: "moon.stars.fill",
    background: "#eef2f6",
    accent: "#334155",
    label: "NIGHT",
  },
];
// "timeline-slot" is the index of the dailyTimes entry now in effect: 0 to 3 here.
let slot = Number($getenv("timeline-slot"));
// Fallback when the slot is missing or out of range: choose by the hour instead.
if (!$getenv("timeline-slot") || !Number.isInteger(slot) || slot < 0 || slot >= phases.length) {
  // "timeline-date" is the date this entry is drawn for; without it, use the time now.
  const date = new Date($getenv("timeline-date") || Date.now());
  const hour = date.getHours();
  slot = hour >= 22 || hour < 6 ? 3 : hour >= 18 ? 2 : hour >= 12 ? 1 : 0;
}
const phase = phases[slot];
// The optional name from the parameter, such as {"name":"Alex"}, cut to 24 characters.
// A parameter that is not valid JSON is ignored.
let name = "";
try {
  const value = JSON.parse($getenv("widget-param") || "{}");
  if (typeof value.name === "string") name = value.name.slice(0, 24);
} catch {}
// Choose a layout for the widget size. The "accessory" sizes are Lock Screen widgets.
const family = $getenv("widget-size");
if (family === "accessoryInline") {
  // Lock Screen line: the title only.
  $render(<text>{phase.title}</text>);
} else if (family === "accessoryCircular") {
  // Lock Screen circle: the icon and the position, such as "2/4".
  $render(
    <vstack spacing="2">
      <icon systemName={phase.symbol} size="24" />
      <text font="caption2">{String(slot + 1) + "/4"}</text>
    </vstack>,
  );
} else if (family === "accessoryRectangular") {
  // Lock Screen rectangle: the icon beside the title and the name.
  $render(
    <hstack spacing="8">
      <icon systemName={phase.symbol} size="24" />
      <vstack alignment="leading" spacing="2">
        <text font="headline">{phase.title}</text>
        <text font="caption2">{name || "Find your daily rhythm"}</text>
      </vstack>
    </hstack>,
  );
} else {
  // Home Screen sizes share one layout; the small one uses less padding and smaller type.
  // frame="max" fills the widget; padding and spacing are in points.
  const compact = family === "small";
  $render(
    <vstack
      frame="max"
      padding={compact ? "14" : "20"}
      spacing={compact ? "7" : "12"}
      background={phase.background}
    >
      <hstack frame="max,18">
        <text font="caption2" weight="semibold" color={phase.accent}>
          {phase.label}
        </text>
        <spacer />
        <text font="caption2" color={phase.accent}>
          {String(slot + 1) + "/4"}
        </text>
      </hstack>
      <icon systemName={phase.symbol} size={compact ? "28" : "36"} color={phase.accent} />
      <text font={compact ? "subheadline" : "title2"} weight="bold" color={phase.accent}>
        {phase.title}
      </text>
      <text font="caption" color={phase.accent}>
        {name ? name + ", " : ""}
        {phase.hint}
      </text>
    </vstack>,
  );
}
