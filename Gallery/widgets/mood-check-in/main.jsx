// Choose a mood to save today's entry. Render/refresh never checks in automatically.
// Optional widget-param: an intention, or {"intention":"Take a pause"} (up to 80 characters).
if (!$import("lib/records.js"))
  throw new Error("Install the complete template, including lib/records.js.");
const size = $getenv("widget-size"),
  parameter = ($getenv("widget-param") || "").trim();
let intention = parameter || localRecords.configuration("mood").intention;
if (parameter.startsWith("{")) {
  let config;
  try {
    config = JSON.parse(parameter);
  } catch (_) {
    throw new Error("Use a JSON object or a short intention.");
  }
  if (
    !config ||
    Array.isArray(config) ||
    Object.keys(config).some((key) => key !== "intention") ||
    typeof config.intention !== "string"
  )
    throw new Error("Mood settings accept a text intention only.");
  intention = config.intention.trim();
}
if (intention.length > 80) throw new Error("Keep your intention to 80 characters.");
const moods = ["😔", "😕", "😐", "🙂", "😊"],
  names = ["Low", "Uneasy", "Okay", "Good", "Great"];
const log = localRecords.create(
  "mood.v1",
  (value) => Number.isInteger(value) && value >= 1 && value <= 5,
  0,
);
function saveMood(value) {
  log.edit(() => value);
  $render(<text>Mood saved</text>);
}
function moodOne() {
  saveMood(1);
}
function moodTwo() {
  saveMood(2);
}
function moodThree() {
  saveMood(3);
}
function moodFour() {
  saveMood(4);
}
function moodFive() {
  saveMood(5);
}
function undoRecord() {
  const changed = log.undo();
  $render(<text>{changed ? "Change undone" : "Nothing to undo"}</text>);
}
function resetToday() {
  log.reset();
  $render(<text>Today cleared; Undo can restore it</text>);
}
const actions = ["moodOne", "moodTwo", "moodThree", "moodFour", "moodFive"];
const state = log.read(),
  current = log.value(state),
  dark = $device.isdarkmode();
const ink = dark ? "#F3E8FF" : "#581C87",
  muted = dark ? "#D8B4FE" : "#7E22CE",
  background = dark ? "#3B0764" : "#FAF5FF";
const caption = current ? names[current - 1] : "No check-in yet";
if (size === "function" || size === "action") {
} else if (size === "accessoryInline") {
  $render(<text>{`Mood · ${caption}`}</text>);
} else if (size === "accessoryCircular") {
  $render(
    <vstack>
      <text font="title">{current ? moods[current - 1] : "○"}</text>
      <text font="caption2">Mood</text>
    </vstack>,
  );
} else if (size === "accessoryRectangular") {
  $render(
    <vstack alignment="leading">
      <text font="headline">{caption}</text>
      <text font="caption">{intention}</text>
    </vstack>,
  );
} else {
  $render(
    <vstack frame="max" alignment="leading" padding="14" spacing="8" background={background}>
      <hstack>
        <text font="headline" color={ink}>
          {size === "small" ? "Mood" : "How are you?"}
        </text>
        <spacer />
        <text font="caption" color={muted}>
          {log.today.slice(5)}
        </text>
      </hstack>
      <hstack spacing={size === "small" ? "6" : "14"}>
        {moods.map((mood, index) => (
          <button actionID={actions[index]}>
            <vstack spacing="2">
              <text font={size === "small" ? "body" : "title2"}>{mood}</text>
              <text font="caption2" color={muted}>
                {current === index + 1 ? "●" : "○"}
              </text>
            </vstack>
          </button>
        ))}
      </hstack>
      <text font="caption" color={ink}>
        {caption}
      </text>
      {size !== "small" && (
        <text font="caption2" color={muted}>
          {intention}
        </text>
      )}
      <hstack spacing="16">
        <button actionID="undoRecord">
          <text font="caption" color={muted}>
            Undo
          </text>
        </button>
        <button actionID="resetToday">
          <text font="caption" color={muted}>
            Reset today
          </text>
        </button>
      </hstack>
      {!["small", "medium"].includes(size) && (
        <vstack alignment="leading" spacing="4">
          <text font="caption" color={muted}>
            Last 7 days
          </text>
          {log.recent(state).map((day) => (
            <hstack>
              <text font="caption" color={muted}>
                {day.date.slice(5)}
              </text>
              <spacer />
              <text font="caption" color={ink}>
                {day.recorded ? `${moods[day.value - 1]} ${names[day.value - 1]}` : "—"}
              </text>
            </hstack>
          ))}
        </vstack>
      )}
    </vstack>,
  );
}
