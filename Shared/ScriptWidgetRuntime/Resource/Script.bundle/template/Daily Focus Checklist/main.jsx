// Edit the defaults here, or set a comma-separated widget parameter, such as Read,Walk,Plan tomorrow.
// Each tap saves today's checked labels locally. The checklist starts fresh at local midnight.
if (!$import("lib/records.js"))
  throw new Error("Install the complete Daily Focus Checklist template.");

const defaults = [
  "Drink water",
  "Pick one priority",
  "Take a short walk",
  "Read 10 pages",
  "Plan tomorrow",
];
const parameter = ($getenv("widget-param") || "").trim();
const items = parameter
  ? parameter.split(",").map((item) => item.trim().normalize("NFC"))
  : defaults;
const validChecks = (labels) =>
  Array.isArray(labels) &&
  labels.length <= 8 &&
  labels.every((label) => typeof label === "string" && label.length > 0 && label.length <= 30) &&
  new Set(labels).size === labels.length;
if (!validChecks(items)) throw new Error("Enter up to 8 unique items of 1–30 characters each.");

const size = $getenv("widget-size");
const isAction = size === "function" || size === "action";
const date = isAction ? new Date() : new Date($getenv("timeline-date") || Date.now());
const log = localRecords.create("focusChecklist.v1", validChecks, [], date);

function toggleItem(index) {
  const item = items[index];
  if (!item) throw new Error("This checklist item is unavailable.");
  log.edit((checked) => {
    if (checked.includes(item)) return checked.filter((entry) => entry !== item);
    return [...checked.filter((entry) => items.includes(entry)), item];
  });
  $render(<text>Checklist saved</text>);
}

// The manifest declares one named action per row.
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

if (!isAction) {
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
  const checked = log.value(log.read());
  const completed = items.filter((item) => checked.includes(item)).length;
  const next = items.find((item) => !checked.includes(item));
  const dark = $device.isdarkmode();
  const background = dark ? "#172D3B" : "#EAF3F8";
  const ink = dark ? "#EAF8FF" : "#143447";
  const muted = dark ? "#B6CDD9" : "#446578";
  const accent = dark ? "#8CE8D7" : "#066B5E";
  const highlight = dark ? "#24494E" : "#D0EDE8";
  const small = size === "small";
  const compact = small || size === "medium";
  const limit = compact ? 3 : 8;
  const visible = items.slice(0, limit);
  $render(
    <vstack frame="max" alignment="leading" padding="12" spacing="3" background={background}>
      <hstack spacing="4">
        <text font="caption" weight="bold" color={ink}>
          Daily focus
        </text>
        <spacer />
        <text font="caption2" color={accent}>{`${completed}/${items.length}`}</text>
      </hstack>
      <spacer />
      {visible.map((item, index) => (
        <button actionID={actions[index]}>
          <hstack
            frame="max,leading"
            spacing="5"
            padding="3"
            corner="5"
            background={item === next ? highlight : "clear"}
          >
            <icon
              systemName={checked.includes(item) ? "checkmark.square.fill" : "square"}
              size="12"
              color={accent}
            />
            <text font="caption2" color={checked.includes(item) ? muted : ink}>
              {item}
            </text>
          </hstack>
        </button>
      ))}
      <spacer />
      {items.length > limit && (
        <text font="caption2" color={muted}>{`+${items.length - limit} more · use Large`}</text>
      )}
    </vstack>,
  );
}
