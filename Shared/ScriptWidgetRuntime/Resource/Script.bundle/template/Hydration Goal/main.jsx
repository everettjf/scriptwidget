// Local hydration log. Optional widget-param: {"goal":8,"glassML":250}.
// Legacy current,goal parameters retain the goal only; sample counts are never saved.
// Tap to record a glass. Undo restores the most recent change; Reset clears today only.
if (!$import("lib/records.js"))
  throw new Error("Install the complete template, including lib/records.js.");
const size = $getenv("widget-size");
const parameter = ($getenv("widget-param") || "").trim();
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
  options.goal = Number(parameter.includes(",") ? parameter.split(",")[1] : parameter);
}
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
// Store measured millilitres; changing glass size never reinterprets past records.
const log = localRecords.create(
  "hydration.v1",
  (value) => Number.isInteger(value) && value >= 0 && value <= 64000,
  0,
);
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
const state = log.read(),
  total = log.value(state),
  target = goal * glassML;
const progress = Math.min(1, total / target),
  dark = $device.isdarkmode();
const ink = dark ? "#E0F2FE" : "#0C4A6E",
  muted = dark ? "#7DD3FC" : "#0369A1",
  background = dark ? "#082F49" : "#F0F9FF";
const label = `${total} / ${target} mL`;
const Action = ({ name, title }) => (
  <button actionID={name}>
    <text font="caption" color={muted}>
      {title}
    </text>
  </button>
);
if (size === "function" || size === "action") {
  // Named handlers alone mutate records.
} else if (size === "accessoryInline") {
  $render(<text>{`Water · ${label}`}</text>);
} else if (size === "accessoryCircular") {
  $render(
    <gauge value={progress}>
      <text>{`${Math.round(progress * 100)}%`}</text>
    </gauge>,
  );
} else if (size === "accessoryRectangular") {
  $render(
    <vstack alignment="leading">
      <label title="Water" systemName="drop.fill" />
      <text font="caption">{label}</text>
      <progress value={progress} />
    </vstack>,
  );
} else {
  const expanded = !["small", "medium"].includes(size);
  $render(
    <vstack frame="max" alignment="leading" padding="14" spacing="8" background={background}>
      <hstack>
        <label title="Water" systemName="drop.fill" color={ink} />
        <spacer />
        <text font="caption" color={muted}>
          {log.today.slice(5)}
        </text>
      </hstack>
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
