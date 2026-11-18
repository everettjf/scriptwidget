// Day Rhythm — local scheduled themes, without network or personal data.
// Change dailyTimes/timeZone in widget.json. Optional widget-param: {"name":"Alex"}.
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
let slot = Number($getenv("timeline-slot"));
if (!$getenv("timeline-slot") || !Number.isInteger(slot) || slot < 0 || slot >= phases.length) {
  const date = new Date($getenv("timeline-date") || Date.now());
  const hour = date.getHours();
  slot = hour >= 22 || hour < 6 ? 3 : hour >= 18 ? 2 : hour >= 12 ? 1 : 0;
}
const phase = phases[slot];
let name = "";
try {
  const value = JSON.parse($getenv("widget-param") || "{}");
  if (typeof value.name === "string") name = value.name.slice(0, 24);
} catch {}
const family = $getenv("widget-size");
if (family === "accessoryInline") {
  $render(<text>{phase.title}</text>);
} else if (family === "accessoryCircular") {
  $render(
    <vstack spacing="2">
      <icon systemName={phase.symbol} size="24" />
      <text font="caption2">{String(slot + 1) + "/4"}</text>
    </vstack>,
  );
} else if (family === "accessoryRectangular") {
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
