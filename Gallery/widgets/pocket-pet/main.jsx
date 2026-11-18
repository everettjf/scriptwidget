// A local virtual companion. Only explicit daily care changes its journal.
if (!$import("lib/records.js")) throw new Error("Install the complete Pocket Pet template.");
const config = localRecords.configuration("pocketPet"),
  title = ($getenv("widget-param") || config.title).trim(),
  order = ["feed", "play", "rest"];
if (!title || title.length > 40) throw new Error("Use a pet name of 1–40 characters.");
const valid = (value) =>
  Array.isArray(value) &&
  value.length >= 1 &&
  value.length <= 3 &&
  new Set(value).size === value.length &&
  value.every((action) => order.includes(action));
const log = localRecords.create(
  "pocketPet.v1",
  valid,
  [],
  new Date($getenv("timeline-date") || Date.now()),
);
function care(action) {
  const changed = log.edit((value) =>
    order.filter((item) => value.includes(item) || item === action),
  );
  $render(<text>{changed ? "Care saved" : "Already done today"}</text>);
}
function feedPet() {
  care("feed");
}
function playPet() {
  care("play");
}
function restPet() {
  care("rest");
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
  today = log.value(state),
  days = state.entries.filter((entry) => entry.date <= log.today),
  careDays = days.length,
  rested = today.includes("rest"),
  complete = today.length === 3;
const last = days
    .map((entry) => entry.date)
    .sort()
    .pop(),
  ordinal = (key) => {
    const [y, m, d] = key.split("-").map(Number);
    return Date.UTC(y, m - 1, d) / 86400000;
  };
const gap = last ? ordinal(log.today) - ordinal(last) : null,
  status = complete
    ? "A lovely day"
    : rested
      ? "Resting happily"
      : today.length
        ? "Enjoying your company"
        : gap !== null && gap >= 3
          ? "Ready to reconnect"
          : "Ready for care",
  level = careDays >= 30 ? "Close companions" : careDays >= 7 ? "Good friends" : "New friends";
const dark = $device.isdarkmode(),
  background = dark ? "#302443" : "#faf5ff",
  ink = dark ? "#f3e8ff" : "#581c87",
  muted = dark ? "#d8b4fe" : "#7e22ce",
  family = $getenv("widget-size");
// Original JSX geometry; static artwork works without animation or network resources.
const Pet = () => (
  <vstack spacing="0">
    <hstack spacing={family === "small" ? "16" : "24"}>
      <roundedrect
        frame={family === "small" ? "9,12" : "12,22"}
        radius="6"
        color="#c4b5fd"
        rotation="-12"
      />
      <roundedrect
        frame={family === "small" ? "9,12" : "12,22"}
        radius="6"
        color="#c4b5fd"
        rotation="12"
      />
    </hstack>
    <zstack>
      <ellipse frame={family === "small" ? "54,32" : "78,49"} color="#ddd6fe" />
      <hstack spacing={family === "small" ? "7" : "13"}>
        <text font={family === "small" ? "caption" : "headline"} color="#4c1d95">
          {rested ? "−" : "•"}
        </text>
        <text font="caption2" color="#7c3aed">
          {complete ? "ᴗ" : "ω"}
        </text>
        <text font={family === "small" ? "caption" : "headline"} color="#4c1d95">
          {rested ? "−" : "•"}
        </text>
      </hstack>
    </zstack>
  </vstack>
);
const CareButton = ({ action }) => (
  <button actionID={action + "Pet"}>
    <text font="caption" color={muted}>
      {today.includes(action)
        ? action === "feed"
          ? "Fed"
          : action === "play"
            ? "Played"
            : "Rested"
        : action === "feed"
          ? "Feed"
          : action === "play"
            ? "Play"
            : "Rest"}
    </text>
  </button>
);
const UndoButton = () => (
  <button actionID="undoRecord">
    <text font="caption" color={muted}>
      Undo
    </text>
  </button>
);
if (family === "function" || family === "action") {
} else if (family === "accessoryInline") {
  $render(<text>{`${title} · ${today.length}/3 care`}</text>);
} else if (family === "accessoryCircular") {
  $render(
    <vstack spacing="2">
      <icon systemName="heart" />
      <text font="caption2">{`${today.length}/3`}</text>
    </vstack>,
  );
} else if (family === "accessoryRectangular") {
  $render(
    <vstack alignment="leading" spacing="3">
      <text font="headline">{title}</text>
      <text font="caption">{status}</text>
    </vstack>,
  );
} else {
  $render(
    <vstack
      frame="max"
      spacing={family === "small" ? "4" : "7"}
      padding={family === "small" ? "12" : "14"}
      background={background}
    >
      <hstack frame="max">
        <text font="headline" weight="bold" color={ink}>
          {title}
        </text>
        <spacer />
        <text font="caption2" color={muted}>{`${today.length}/3`}</text>
      </hstack>
      <hstack frame="max" spacing="14">
        <Pet />
        <vstack frame="max,leading" alignment="leading" spacing="5">
          <text font="subheadline" weight="semibold" color={ink}>
            {status}
          </text>
          {family !== "small" && (
            <text font="caption2" color={muted}>
              {level}
            </text>
          )}
          {family !== "small" && (
            <text font="caption2" color={muted}>{`${careDays} care days · last year`}</text>
          )}
        </vstack>
      </hstack>
      {family === "small" ? (
        <vstack spacing="4">
          <hstack spacing="8">
            <CareButton action="feed" />
            <CareButton action="play" />
          </hstack>
          <hstack spacing="8">
            <CareButton action="rest" />
            <UndoButton />
          </hstack>
        </vstack>
      ) : (
        <hstack spacing="12">
          {order.map((action) => (
            <CareButton action={action} />
          ))}
          <UndoButton />
        </hstack>
      )}
      {!["small", "medium"].includes(family) && (
        <vstack alignment="leading" spacing="4">
          <text font="caption" color={muted}>
            Last 7 days
          </text>
          {log.recent(state).map((day) => (
            <hstack>
              <text font="caption2" color={muted}>
                {day.date.slice(5)}
              </text>
              <spacer />
              <text font="caption2" color={ink}>
                {day.recorded ? `${day.value.length}/3` : "—"}
              </text>
            </hstack>
          ))}
          <text font="caption2" color={muted}>
            Care counts once per day. Nothing to catch up or buy.
          </text>
        </vstack>
      )}
    </vstack>,
  );
}
