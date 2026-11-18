// Explicit check-ins only. Optional widget-param: your habit name (up to 40 characters).
// The earlier template recorded automatically on refresh. Its original keys stay
// untouched; they are not reliable evidence of completed days and are never imported.
// Shows how many days in a row you checked in, with Check in, Undo and Reset buttons.
// Try changing the colors below, or the habit name in Records & Configuration.
// $storage needs the permission "storage" in widget.json; the buttons need its "actions".

// $import runs another file of this package; lib/records.js defines `localRecords`.
// It returns false when the file is missing.
if (!$import("lib/records.js"))
  throw new Error("Install the complete template, including lib/records.js.");
// $getenv("widget-size") is the size being drawn, such as "small" or "accessoryInline".
// $getenv("widget-param") is the optional widget parameter, a text you set on each widget.
const size = $getenv("widget-size"),
  title = ($getenv("widget-param") || localRecords.configuration("habitStreak").title).trim();
if (!title || title.length > 40) throw new Error("Use a habit name of 1–40 characters.");
// One record per day under the key "habitStreak.v2": 1 means done; no record reads as 0.
const log = localRecords.create("habitStreak.v2", (value) => value === 1, 0);
// The three functions below are named by the "actions" in widget.json. A tap on a
// <button> with that actionID calls them. edit() and undo() return true if they saved.
function checkIn() {
  const changed = log.edit(() => 1);
  $render(<text>{changed ? "Checked in" : "Already checked in"}</text>);
}
function undoRecord() {
  const changed = log.undo();
  $render(<text>{changed ? "Change undone" : "Nothing to undo"}</text>);
}
function resetToday() {
  log.reset();
  $render(<text>Today cleared; Undo can restore it</text>);
}
// Read the data.
const state = log.read(),
  done = log.value(state) === 1;
const completed = new Set(state.entries.map((entry) => entry.date));
// Day key in local time, for example "2026-03-08".
const keyFor = (date) =>
  `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
// Count the streak: start today (or yesterday if today is not done yet) and walk back
// one day at a time while each day has a record. Only 366 days are kept, hence "366+".
let cursor = new Date(),
  streak = 0;
cursor = new Date(cursor.getFullYear(), cursor.getMonth(), cursor.getDate() - (done ? 0 : 1), 12);
while (streak < 366 && completed.has(keyFor(cursor))) {
  streak++;
  cursor = new Date(cursor.getFullYear(), cursor.getMonth(), cursor.getDate() - 1, 12);
}
const streakLabel = `${streak}${streak === 366 ? "+" : ""} ${streak === 1 ? "day" : "days"}`;
// Counters left by the earlier version of this template. They are shown, never changed.
const legacyCount = $storage.getString("habit.streak"),
  legacyDate = $storage.getString("habit.lastDate");
const hasLegacy = legacyCount !== "" || legacyDate !== "";
const legacyLabel = /^\d{1,6}$/.test(legacyCount)
  ? `Earlier automatic count: ${legacyCount} (unverified)`
  : "Earlier automatic records kept unchanged";
const dark = $device.isdarkmode(),
  ink = dark ? "#FFEDD5" : "#7C2D12",
  muted = dark ? "#FDBA74" : "#C2410C",
  background = dark ? "#431407" : "#FFF7ED";
// A tap runs this script with the size "function" or "action": draw no widget then.
if (size === "function" || size === "action") {
} else if (size === "accessoryInline") {
  // Lock Screen, inline: one line of text.
  $render(<text>{`${title} · ${streakLabel}`}</text>);
} else if (size === "accessoryCircular") {
  // Lock Screen, circular: the number of days.
  $render(
    <vstack>
      <icon systemName="flame.fill" />
      <text font="caption">{String(streak) + (streak === 366 ? "+" : "")}</text>
    </vstack>,
  );
} else if (size === "accessoryRectangular") {
  // Lock Screen, rectangular: two short lines.
  $render(
    <vstack alignment="leading">
      <text font="headline">{title}</text>
      <text font="caption">{`${streakLabel} · ${done ? "Done today" : "Check in today"}`}</text>
    </vstack>,
  );
} else {
  // Home Screen sizes. frame="max" fills the widget; padding is the space in points
  // around the content.
  $render(
    <vstack frame="max" alignment="leading" padding="14" spacing="8" background={background}>
      <hstack>
        <icon systemName="flame.fill" size="16" color={muted} />
        <text font="headline" color={ink}>
          {title}
        </text>
      </hstack>
      <text font={size === "small" ? "title2" : "largeTitle"} color={ink}>
        {streakLabel}
      </text>
      <hstack spacing="16">
        <button actionID="checkIn">
          <text font="caption" color={muted}>
            {done ? "Done" : "Check in"}
          </text>
        </button>
        <button actionID="undoRecord">
          <text font="caption" color={muted}>
            Undo
          </text>
        </button>
        {/* The small widget has no room for a third button. */}
        {size !== "small" && (
          <button actionID="resetToday">
            <text font="caption" color={muted}>
              Reset today
            </text>
          </button>
        )}
      </hstack>
      {/* Large sizes: the last 7 days, oldest first. day.date.slice(5) is the MM-DD part. */}
      {!["small", "medium"].includes(size) && (
        <vstack alignment="leading" spacing="5">
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
                {day.recorded ? "✓" : "—"}
              </text>
            </hstack>
          ))}
        </vstack>
      )}
      {/* Shown only when the earlier version left a counter behind. */}
      {hasLegacy && (
        <text font="caption2" color={muted}>
          {size === "small" ? "Earlier counter kept" : legacyLabel}
        </text>
      )}
    </vstack>,
  );
}
