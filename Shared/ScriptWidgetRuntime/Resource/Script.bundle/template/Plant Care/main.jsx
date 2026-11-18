// A personal care journal, not a sensor reading. Rendering never creates records.
//
// This template shows a widget with buttons: a tap runs a function in this file, which
// saves a record in package storage. Try changing the status texts, the level names or the
// colors.

// $import runs lib/records.js from this package and returns false when that fails. The
// file defines localRecords: a diary with one entry per calendar day, kept in package storage
// (widget.json declares the "storage" permission).
if (!$import("lib/records.js")) throw new Error("Install the complete Plant Care template.");
// The saved settings (plant name, days between care) and the widget parameter: the
// parameter text set for this widget, empty when there is none.
const config = localRecords.configuration("plantCare"),
  parameter = $getenv("widget-param") || "";
// Preserve the name from the earlier name,days demo; its invented countdown is not a care record.
const title = parameter ? parameter.split(",")[0].trim() : config.title;
if (!title || title.length > 40) throw new Error("Use a plant name of 1–40 characters.");
// Open the diary stored under the key "plantCare.v1". A day's value is 1 when care was
// recorded; 0 stands for a day without an entry. "timeline-date" is the moment this entry
// is drawn for, which is later than now when the system prepares the widget in advance.
const log = localRecords.create(
  "plantCare.v1",
  (value) => value === 1,
  0,
  new Date($getenv("timeline-date") || Date.now()),
);
// The next three functions are the actions listed in widget.json; a button with
// actionID="waterPlant" runs waterPlant(). Each one changes the diary and renders a short
// confirmation. edit() returns false when today already has that value.
function waterPlant() {
  const changed = log.edit(() => 1);
  $render(<text>{changed ? "Care recorded" : "Already recorded today"}</text>);
}
function undoRecord() {
  const changed = log.undo();
  $render(<text>{changed ? "Change undone" : "Nothing to undo"}</text>);
}
function resetToday() {
  log.reset();
  $render(<text>Today cleared; Undo can restore it</text>);
}
// Read the diary (reading never writes) and work out what to show.
// days: every recorded date up to today, as sorted "YYYY-MM-DD" strings.
const state = log.read(),
  days = state.entries
    .filter((entry) => entry.date <= log.today)
    .map((entry) => entry.date)
    .sort(),
  last = days[days.length - 1] || "",
  done = log.value(state) === 1;
// Turns "YYYY-MM-DD" into a day number, so that two dates can be subtracted.
const ordinal = (key) => {
  const [y, m, d] = key.split("-").map(Number);
  return Date.UTC(y, m - 1, d) / 86400000;
};
// Days since the last care, and days until the next one is due (never below 0).
const elapsed = last ? ordinal(log.today) - ordinal(last) : null,
  remaining = elapsed === null ? null : Math.max(0, config.intervalDays - elapsed);
// The sentence shown in the widget.
const status = done
  ? "Cared for today"
  : last
    ? remaining > 0
      ? `Next care in ${remaining} ${remaining === 1 ? "day" : "days"}`
      : "Care due"
    : "No care recorded";
// A label that grows with the number of recorded days.
const level =
  days.length >= 15 ? "Blooming routine" : days.length >= 5 ? "Growing routine" : "New beginning";
// Colors for light and dark mode, and the size being drawn ("small", "medium", …).
const dark = $device.isdarkmode(),
  background = dark ? "#102a22" : "#f0fdf4",
  ink = dark ? "#dcfce7" : "#14532d",
  muted = dark ? "#86efac" : "#166534",
  family = $getenv("widget-size");
// The plant, drawn from shapes: two leaves, a stem and a pot. frame is "width,height" in
// points; rotation is in degrees.
const Plant = () => (
  <vstack spacing="0">
    <hstack spacing="0">
      <ellipse frame="27,15" color="#4ade80" rotation="25" />
      <ellipse frame="27,15" color="#22c55e" rotation="-25" />
    </hstack>
    <rect frame="5,15" color="#16a34a" />
    <roundedrect frame="43,26" radius="8" color="#d6a177" />
  </vstack>
);
// While a button or a Shortcuts action runs, widget-size is "function" or "action". The
// function above then renders its own message, so nothing is drawn here.
if (family === "function" || family === "action") {
} else if (family === "accessoryInline") {
  // Lock Screen sizes (iPhone and iPad only): text and an icon.
  $render(<text>{`${title} · ${status}`}</text>);
} else if (family === "accessoryCircular") {
  $render(
    <vstack spacing="2">
      <icon systemName="leaf" />
      <text font="caption2">
        {done ? "Done" : remaining === null ? "Start" : remaining === 0 ? "Due" : `${remaining}d`}
      </text>
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
  // Home Screen sizes share one layout; the parts marked family !== "small" are left out
  // where there is no room. frame="max" fills the widget; padding is the space around the
  // content, in points.
  $render(
    <vstack frame="max" spacing="8" padding="14" background={background}>
      <hstack frame="max">
        <text font="headline" weight="bold" color={ink}>
          {title}
        </text>
        <spacer />
        {family !== "small" && (
          <text font="caption2" color={muted}>
            CARE JOURNAL
          </text>
        )}
      </hstack>
      <hstack frame="max" spacing="14">
        <Plant />
        <vstack frame="max,leading" alignment="leading" spacing="5">
          <text font="subheadline" weight="semibold" color={ink}>
            {status}
          </text>
          {family !== "small" && (
            <text
              font="caption2"
              color={muted}
            >{`${days.length} care ${days.length === 1 ? "day" : "days"} · last year`}</text>
          )}
          {family !== "small" && (
            <text font="caption2" color={muted}>
              {level}
            </text>
          )}
        </vstack>
      </hstack>
      {/* Each button runs the action with this id from widget.json. */}
      <hstack spacing="14">
        <button actionID="waterPlant">
          <text font="caption" color={muted}>
            {family === "small" ? (done ? "Done" : "Care") : done ? "Recorded" : "Record care"}
          </text>
        </button>
        <button actionID="undoRecord">
          <text font="caption" color={muted}>
            Undo
          </text>
        </button>
      </hstack>
      {/* Large sizes only: the last care, the interval and the last seven days. */}
      {!["small", "medium"].includes(family) && (
        <vstack alignment="leading" spacing="4">
          <text font="caption" color={muted}>
            {last ? `Last care: ${last}` : "Your first care check-in starts the journal."}
          </text>
          <text
            font="caption2"
            color={muted}
          >{`Personal interval: ${config.intervalDays} days`}</text>
          {log.recent(state).map((day) => (
            <hstack>
              <text font="caption2" color={muted}>
                {day.date.slice(5)}
              </text>
              <spacer />
              <text font="caption2" color={ink}>
                {day.recorded ? "✓" : "—"}
              </text>
            </hstack>
          ))}
        </vstack>
      )}
    </vstack>,
  );
}
