// Local hydration log. Optional widget-param: {"goal":8,"glassML":250}.
// Legacy current,goal parameters retain the goal only; sample counts are never saved.
// Tap to record a glass. Undo restores the most recent change; Reset clears today only.
// Shows today's water against a goal, with buttons to add a glass, undo and reset.
// Try another goal or glass size with the widget parameter, or change the colors.
// Saving needs the permission "storage" in widget.json; the buttons need its "actions".

// $import runs another file of this package; lib/records.js defines `localRecords`.
// It returns false when the file is missing.
if (!$import("lib/records.js"))
  throw new Error("Install the complete template, including lib/records.js.");
// $getenv("widget-size") is the size being drawn, such as "small" or "accessoryInline".
const size = $getenv("widget-size");
// $getenv("widget-param") is the optional widget parameter, a text you set on each widget.
const parameter = ($getenv("widget-param") || "").trim();
// The settings saved by Records & Configuration (or the defaults), then the parameter.
let options = localRecords.configuration("hydration");
if (parameter.startsWith("{")) {
  try {
    options = { ...options, ...JSON.parse(parameter) };
  } catch (_) {
    throw new Error("Use a JSON object for hydration settings.");
  }
  if (
    !options ||
    Array.isArray(options) ||
    Object.keys(options).some((key) => !["goal", "glassML"].includes(key))
  )
    throw new Error("Hydration settings accept goal and glassML only.");
} else if (parameter) {
  // The older form of the parameter: a number, or "current,goal" where only the goal counts.
  options.goal = Number(parameter.includes(",") ? parameter.split(",")[1] : parameter);
}
// `goal` is in glasses, `glassML` in millilitres per glass.
const goal = options.goal === undefined ? 8 : options.goal;
const glassML = options.glassML === undefined ? 250 : options.glassML;
if (
  !Number.isInteger(goal) ||
  goal < 1 ||
  goal > 32 ||
  !Number.isInteger(glassML) ||
  glassML < 25 ||
  glassML > 2000
)
  throw new Error("Set goal to 1–32 glasses and glassML to 25–2000.");
// One record per day under the key "hydration.v1": the total of the day in mL.
// Store measured millilitres; changing glass size never reinterprets past records.
const log = localRecords.create(
  "hydration.v1",
  (value) => Number.isInteger(value) && value >= 0 && value <= 64000,
  0,
);
// The three functions below are named by the "actions" in widget.json. A tap on a
// <button> with that actionID calls them.
function addGlass() {
  log.edit((value) => {
    if (value > 64000 - glassML)
      throw new Error("Today’s record limit would be exceeded. The saved total has not changed.");
    return value + glassML;
  });
  $render(<text>Glass saved</text>);
}
function undoRecord() {
  const changed = log.undo();
  $render(<text>{changed ? "Change undone" : "Nothing to undo"}</text>);
}
function resetToday() {
  log.reset();
  $render(<text>Today cleared; Undo can restore it</text>);
}
// Read the data. `target` is the goal in mL; `progress` goes from 0 to 1.
const state = log.read(),
  total = log.value(state),
  target = goal * glassML;
const progress = Math.min(1, total / target),
  dark = $device.isdarkmode();
const ink = dark ? "#E0F2FE" : "#0C4A6E",
  muted = dark ? "#7DD3FC" : "#0369A1",
  background = dark ? "#082F49" : "#F0F9FF";
const label = `${total} / ${target} mL`;
// A text to tap. actionID names the action to run.
const Action = ({ name, title }) => (
  <button actionID={name}>
    <text font="caption" color={muted}>
      {title}
    </text>
  </button>
);
// A tap runs this script with the size "function" or "action": draw no widget then.
if (size === "function" || size === "action") {
  // Named handlers alone mutate records.
} else if (size === "accessoryInline") {
  // Lock Screen, inline: one line of text.
  $render(<text>{`Water · ${label}`}</text>);
} else if (size === "accessoryCircular") {
  // Lock Screen, circular: a gauge with the percentage.
  $render(
    <gauge value={progress}>
      <text>{`${Math.round(progress * 100)}%`}</text>
    </gauge>,
  );
} else if (size === "accessoryRectangular") {
  // Lock Screen, rectangular: the total and a progress bar.
  $render(
    <vstack alignment="leading">
      <label title="Water" systemName="drop.fill" />
      <text font="caption">{label}</text>
      <progress value={progress} />
    </vstack>,
  );
} else {
  // Home Screen sizes. Large ones (`expanded`) also list the last 7 days.
  const expanded = !["small", "medium"].includes(size);
  $render(
    <vstack frame="max" alignment="leading" padding="14" spacing="8" background={background}>
      {/* log.today is a day key such as 2026-03-08; slice(5) keeps the 03-08 part. */}
      <hstack>
        <label title="Water" systemName="drop.fill" color={ink} />
        <spacer />
        <text font="caption" color={muted}>
          {log.today.slice(5)}
        </text>
      </hstack>
      {/* Small widget: a progress bar. Other sizes: a ring next to the text. */}
      {size === "small" ? (
        <vstack alignment="leading" spacing="5">
          <text font="headline" color={ink}>
            {label}
          </text>
          <progress value={progress} color="#0EA5E9" />
          <text font="caption2" color={muted}>
            {total === 0
              ? "Start with a glass"
              : progress === 1
                ? "Goal reached"
                : "Every glass counts"}
          </text>
        </vstack>
      ) : (
        <hstack spacing="12">
          <ring
            value={progress}
            thickness="7"
            color="#0EA5E9"
            trackColor={dark ? "#164E63" : "#BAE6FD"}
            frame={60}
          />
          <vstack alignment="leading" spacing="3">
            <text font="headline" color={ink}>
              {label}
            </text>
            <text font="caption2" color={muted}>
              {total === 0
                ? "Start with a glass"
                : progress === 1
                  ? "Goal reached"
                  : "Every glass counts"}
            </text>
          </vstack>
        </hstack>
      )}
      {/* The small widget has no room for Reset. */}
      <hstack spacing="14">
        <Action name="addGlass" title={`+ ${glassML} mL`} />
        <Action name="undoRecord" title="Undo" />
        {size !== "small" && <Action name="resetToday" title="Reset today" />}
      </hstack>
      {expanded && (
        <vstack alignment="leading" spacing="4">
          <text font="caption" color={muted}>
            Last 7 days · mL
          </text>
          {log.recent(state).map((day) => (
            <hstack>
              <text font="caption" color={muted}>
                {day.date.slice(5)}
              </text>
              <spacer />
              <text font="caption" color={ink}>
                {day.recorded ? String(day.value) : "—"}
              </text>
            </hstack>
          ))}
        </vstack>
      )}
    </vstack>,
  );
}
