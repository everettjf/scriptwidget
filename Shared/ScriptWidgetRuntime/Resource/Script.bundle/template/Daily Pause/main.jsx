// A short offline reflection. Set the widget parameter to a line of your own, up to 100 characters.
const reflections = [
  "Give one good thing your full attention.",
  "Leave room for a thought you did not plan.",
  "Pick a small step you can finish before lunch.",
  "A quiet minute belongs on the calendar too.",
  "Make tomorrow easier by finishing one loose end.",
  "Notice what gets easier when you slow down.",
  "Let a good question sit with you for a while.",
];

// Count local calendar days with UTC arithmetic so a daylight-saving change cannot skip a line.
const now = new Date($getenv("timeline-date") || Date.now());
const day = Date.UTC(now.getFullYear(), now.getMonth(), now.getDate()) / 86400000;
const index = ((day % reflections.length) + reflections.length) % reflections.length;
const custom = ($getenv("widget-param") || "").trim().replace(/\s+/g, " ");
if (Array.from(custom).length > 100) throw new Error("Use a reflection of up to 100 characters.");

const small = $getenv("widget-size") === "small";
const dark = $device.isdarkmode();
const background = dark ? "#302539" : "#F4EAF4";
const ink = dark ? "#FBEDFF" : "#392544";
const accent = dark ? "#E4AAE8" : "#803E80";

$render(
  <vstack frame="max" alignment="leading" padding="14" spacing="5" background={background}>
    <icon systemName="quote.bubble" size="18" color={accent} />
    <spacer />
    <text font={small ? "callout" : "title3"} fontDesign="serif" weight="semibold" color={ink}>
      {custom || reflections[index]}
    </text>
    <spacer />
    <text font="caption2" color={accent}>
      Daily pause
    </text>
  </vstack>,
);
