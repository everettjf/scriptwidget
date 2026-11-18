// A real daily checklist. Optional widget-param: Passport,Charger,Headphones
// Up to 8 unique labels. Exact labels identify items, so reordering preserves checks.
// Reset affects today only; Undo restores the most recent change. Large shows history.
if (!$import("lib/records.js"))
  throw new Error("Install the complete template, including lib/records.js.");
const size = $getenv("widget-size"),
  parameter = ($getenv("widget-param") || "").trim();
const items = parameter
  ? parameter.split(",").map((item) => item.trim().normalize("NFC"))
  : localRecords.configuration("checklist").items;
if (
  items.length > 8 ||
  items.some((item) => !item || item.length > 60) ||
  new Set(items).size !== items.length
)
  throw new Error("Use 1–8 unique checklist labels, at most 60 characters each.");
const validChecks = (value) =>
  Array.isArray(value) &&
  value.length <= 8 &&
  value.every((item) => typeof item === "string" && item.length > 0 && item.length <= 60) &&
  new Set(value).size === value.length;
const log = localRecords.create("checklist.v1", validChecks, []);
function toggleItem(index) {
  const item = items[index];
  if (!item) throw new Error("Checklist item is unavailable.");
  log.edit((checked) => {
    if (checked.includes(item)) return checked.filter((entry) => entry !== item);
    // Keep only configured labels when adding; prior labels remain in Undo/history.
    return [...checked.filter((entry) => items.includes(entry)), item].sort();
  });
  $render(<text>Checklist saved</text>);
}
function toggleOne() {
  toggleItem(0);
}
function toggleTwo() {
  toggleItem(1);
}
function toggleThree() {
  toggleItem(2);
}
function toggleFour() {
  toggleItem(3);
}
function toggleFive() {
  toggleItem(4);
}
function toggleSix() {
  toggleItem(5);
}
function toggleSeven() {
  toggleItem(6);
}
function toggleEight() {
  toggleItem(7);
}
function undoRecord() {
  const changed = log.undo();
  $render(<text>{changed ? "Change undone" : "Nothing to undo"}</text>);
}
function resetToday() {
  log.reset();
  $render(<text>Today cleared; Undo can restore it</text>);
}
const actions = [
  "toggleOne",
  "toggleTwo",
  "toggleThree",
  "toggleFour",
  "toggleFive",
  "toggleSix",
  "toggleSeven",
  "toggleEight",
];
const state = log.read(),
  checked = log.value(state),
  completed = items.filter((item) => checked.includes(item)).length;
const dark = $device.isdarkmode(),
  ink = dark ? "#E0F2FE" : "#0C4A6E",
  muted = dark ? "#7DD3FC" : "#0369A1",
  background = dark ? "#082F49" : "#F0F9FF";
const summary = `${completed} / ${items.length} ready`;
if (size === "function" || size === "action") {
} else if (size === "accessoryInline") {
  $render(<text>{`Checklist · ${summary}`}</text>);
} else if (size === "accessoryCircular") {
  $render(
    <vstack>
      <icon systemName="checkmark.circle" />
      <text font="caption">{String(completed) + "/" + items.length}</text>
    </vstack>,
  );
} else if (size === "accessoryRectangular") {
  $render(
    <vstack alignment="leading">
      <text font="headline">{summary}</text>
      <text font="caption">{items.find((item) => !checked.includes(item)) || "All packed"}</text>
    </vstack>,
  );
} else {
  const limit = size === "small" ? 2 : size === "medium" ? 3 : 8;
  $render(
    <vstack frame="max" alignment="leading" spacing="6" padding="14" background={background}>
      <hstack>
        <text font="headline" color={ink}>
          {size === "small" ? "Pack" : "Ready to go"}
        </text>
        <spacer />
        <text font="caption" color={muted}>
          {summary}
        </text>
      </hstack>
      {items.slice(0, limit).map((item, index) => (
        <button actionID={actions[index]}>
          <hstack spacing="7">
            <icon
              systemName={checked.includes(item) ? "checkmark.circle.fill" : "circle"}
              size="15"
              color={muted}
            />
            <text font="callout" color={ink}>
              {item}
            </text>
          </hstack>
        </button>
      ))}
      {items.length > limit && (
        <text font="caption2" color={muted}>
          {size === "small"
            ? `+ ${items.length - limit} more · use Large`
            : `+ ${items.length - limit} items · use a larger widget`}
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
        <vstack alignment="leading" spacing="3">
          <text font="caption" color={muted}>
            Recent days · completed items
          </text>
          {log.recent(state, 3).map((day) => (
            <hstack>
              <text font="caption2" color={muted}>
                {day.date.slice(5)}
              </text>
              <spacer />
              <text font="caption2" color={ink}>
                {day.recorded ? String(day.value.length) : "—"}
              </text>
            </hstack>
          ))}
        </vstack>
      )}
    </vstack>,
  );
}
