//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Tap Check in on a Home Screen widget (iOS 17+ / macOS 14+).
// Rendering never marks a day complete. Records are local to this package;
// renaming a habit's display name preserves its stable id and history.
// Keep up to ten years of local calendar dates per habit. No network required.
// Duplicate copies have separate history; this is not iCloud sync.
// Shows a grid of the days on which each of three habits was done, like a GitHub
// contribution graph. Try changing the colors in `habits`, or the weeks and cell size
// passed to <Grid>.
// $storage needs the permission "storage" in widget.json; the buttons need its "actions".

// $import runs another file of this package; lib/records.js defines `localRecords`.
// It returns false when the file is missing.
if (!$import("lib/records.js"))
  throw new Error("Install the complete template, including lib/records.js.");
// The habit names set in Records & Configuration, or the defaults Read, Run, Meditate.
const savedNames = localRecords.configuration("habitHeatmap");
// $getenv("widget-size") is the size being drawn, such as "small" or "accessoryInline".
const size = $getenv("widget-size");
// `action` names the function that a tap calls. `color` holds five shades from empty
// to full; a day is either done or not, so only the first and the last are used.
const habits = [
  {
    id: "read",
    name: savedNames.readName,
    action: "checkInRead",
    color: ["#1B2A1E", "#0E4429", "#006D32", "#26A641", "#39D353"],
  },
  {
    id: "run",
    name: savedNames.runName,
    action: "checkInRun",
    color: ["#1E1B2A", "#2E2266", "#4434A5", "#6B5BE0", "#9D8CFF"],
  },
  {
    id: "meditate",
    name: savedNames.meditateName,
    action: "checkInMeditate",
    color: ["#2A1E1B", "#5C2A10", "#9A4A12", "#D9741C", "#FFA94D"],
  },
];
// Day key in local time, for example "2026-03-08".
const dateKey = (date) =>
  `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
// Calendar arithmetic at noon handles DST without assuming 24-hour days.
const dayOffset = (date, days) =>
  new Date(date.getFullYear(), date.getMonth(), date.getDate() + days, 12);
const today = dayOffset(new Date(), 0);
const todayKey = dateKey(today);
// Days older than about ten years (3660 days) are dropped when saving.
const oldestKey = dateKey(dayOffset(today, -3659));
// Each habit's days are saved under its own key, as a JSON list of day keys.
const storageKey = (habit) => `habitHeatmap.v1.${habit.id}`;
// Turn the saved text into a sorted list of day keys, or throw if it is not such a list.
const parseDays = (raw) => {
  if (!raw) return [];
  let days;
  try {
    days = JSON.parse(raw);
  } catch (error) {
    throw new Error("Habit history is unreadable. Restore it before checking in.");
  }
  if (
    !Array.isArray(days) ||
    days.length > 3660 ||
    days.some((day) => {
      if (typeof day !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(day)) return true;
      const parts = day.split("-").map(Number);
      return dateKey(new Date(parts[0], parts[1] - 1, parts[2], 12)) !== day;
    })
  )
    throw new Error("Invalid habit history. Restore it before checking in.");
  return Array.from(new Set(days)).sort();
};
// $storage.getString returns "" when nothing was saved under the key.
const readDays = (habit) => parseDays($storage.getString(storageKey(habit)));
// Mark today as done for one habit. This runs when a Check in button is tapped.
function checkIn(habit) {
  // A conflict rereads and revalidates history rather than replacing another
  // process's new day. Rendering and rejected attempts never create records.
  for (let attempt = 0; attempt < 4; attempt++) {
    const raw = $storage.getString(storageKey(habit));
    const days = parseDays(raw);
    if (days.includes(todayKey)) {
      $render(<text>Already checked in</text>);
      return;
    }
    const updated = days.filter((day) => day >= oldestKey);
    updated.push(todayKey);
    updated.sort();
    // compareAndSetString writes only if the stored text is still `raw`.
    if (updated.length > 3660 || typeof $storage.compareAndSetString !== "function") break;
    if ($storage.compareAndSetString(storageKey(habit), raw, JSON.stringify(updated))) {
      $render(<text>Checked in</text>);
      return;
    }
  }
  throw new Error("Could not save check-in. Storage may be busy; please try again.");
}
// The functions named by the "actions" in widget.json, one per habit.
function checkInRead() {
  return checkIn(habits[0]);
}
function checkInRun() {
  return checkIn(habits[1]);
}
function checkInMeditate() {
  return checkIn(habits[2]);
}
// Read the data: one list of days per habit.
const records = habits.map(readDays);
// Days in a row that are done, ending today, or yesterday if today is not done yet.
const streak = (days) => {
  const completed = new Set(days);
  let offset = completed.has(todayKey) ? 0 : -1;
  let count = 0;
  while (count < 3660 && completed.has(dateKey(dayOffset(today, offset)))) {
    count++;
    offset--;
  }
  return count;
};
// Monday-first columns; future days in the current week stay blank.
// getDay() is 0 on Sunday; (getDay() + 6) % 7 is 0 on Monday. weekEnd is this week's Sunday.
const weekEnd = dayOffset(today, 6 - ((today.getDay() + 6) % 7));
// Per habit, 26 weeks of cells: 4 = done, 0 = not done, -1 = a day still to come.
const logs = records.map((days) => {
  const completed = new Set(days);
  return Array.from({ length: 26 * 7 }, (_, index) => {
    const key = dateKey(dayOffset(weekEnd, index - 26 * 7 + 1));
    return key > todayKey ? -1 : completed.has(key) ? 4 : 0;
  });
});

// Draws the last `weeks` weeks of a log: squares of `cell` points, `gap` points apart.
const Grid = ({ log, colors, weeks, cell, gap }) => {
  const days = log.slice(-weeks * 7);
  // Columns are weeks, rows are weekdays, as in a contribution graph.
  return (
    <hstack spacing={gap}>
      {Array.from({ length: weeks }, (_, week) => (
        <vstack spacing={gap}>
          {days.slice(week * 7, week * 7 + 7).map((level) => (
            <rect
              frame={`${cell},${cell}`}
              corner={cell * 0.25}
              color={level < 0 ? "clear" : colors[level]}
            />
          ))}
        </vstack>
      ))}
    </hstack>
  );
};
// The saved days of a habit.
const daysFor = (habit) => records[habits.findIndex((item) => item.id === habit.id)];
const streakLabel = (habit) => {
  const count = streak(daysFor(habit));
  return `${count} ${count === 1 ? "day" : "days"}`;
};
// The habit name on the left; the streak with a flame on the right.
const Header = ({ habit, font }) => (
  <hstack>
    <text font={font} fontWeight="semibold" color="white">
      {habit.name}
    </text>
    <spacer />
    <icon systemName="flame.fill" size="12" color={habit.color[4]} />
    <text font="caption" fontWeight="semibold" color={habit.color[4]}>
      {streakLabel(habit)}
    </text>
  </hstack>
);

// A label to tap. actionID names an action in widget.json, which names the function
// to call. Needs iOS 17 or macOS 14.
const CheckIn = ({ habit }) => (
  <button actionID={habit.action}>
    <hstack spacing="4">
      <icon
        systemName={daysFor(habit).includes(todayKey) ? "checkmark.circle.fill" : "plus.circle"}
        size="12"
        color={habit.color[4]}
      />
      <text font="caption" color={habit.color[4]}>
        {daysFor(habit).includes(todayKey) ? "Done today" : "Check in"}
      </text>
    </hstack>
  </button>
);

// The flame counts consecutive days and returns to 0 after a missed day; this
// count is every recorded check-in and never goes down.
const Total = ({ habit }) => (
  <text font="caption" color="#8B949E">{`${daysFor(habit).length} total`}</text>
);

// Choose a layout for the widget size. A tap runs this script with the size "action".
// App Intent calls the named function after evaluating this source.
if (size === "action") {
  // Do not render a widget while handling a tap.
} else if (size === "accessoryCircular") {
  // Lock Screen, circular: the streak of the first habit.
  $render(
    <vstack spacing="0">
      <icon systemName="flame.fill" size="16" />
      <text font="title3" fontWeight="bold">
        {streak(records[0])}
      </text>
    </vstack>,
  );
} else if (size === "accessoryRectangular") {
  // Lock Screen, rectangular: the first habit as a gray grid of 20 weeks.
  $render(
    <vstack alignment="leading" spacing="3" frame="max,leading">
      <text font="caption" fontWeight="semibold">
        {habits[0].name} · {streak(records[0])}-day streak
      </text>
      <Grid
        log={logs[0].map((level) => (level < 0 ? -1 : level > 0 ? 4 : 1))}
        colors={["#444444", "#666666", "#888888", "#AAAAAA", "#FFFFFF"]}
        weeks={20}
        cell={5}
        gap={1.5}
      />
    </vstack>,
  );
} else if (size === "accessoryInline") {
  // Lock Screen, inline: one line of text.
  $render(
    <text>
      {habits[0].name} · {streak(records[0])}-day streak
    </text>,
  );
} else if (size === "small") {
  // Small widget: the first habit, 8 weeks.
  $render(
    <vstack alignment="leading" spacing="4" padding="12" background="#0D1117">
      <Header habit={habits[0]} font="headline" />
      <Grid log={logs[0]} colors={habits[0].color} weeks={8} cell={9} gap={2} />
      <hstack>
        <CheckIn habit={habits[0]} />
        <spacer />
        <Total habit={habits[0]} />
      </hstack>
    </vstack>,
  );
} else if (size === "medium") {
  // Medium widget: the first habit, 22 weeks.
  $render(
    <vstack alignment="leading" spacing="4" padding="12" background="#0D1117">
      <Header habit={habits[0]} font="headline" />
      <Grid log={logs[0]} colors={habits[0].color} weeks={22} cell={10} gap={2} />
      <hstack>
        <CheckIn habit={habits[0]} />
        <spacer />
        <Total habit={habits[0]} />
      </hstack>
    </vstack>,
  );
} else if (size === "extraLarge") {
  // Extra large widget: the three habits side by side.
  $render(
    <hstack alignment="top" spacing="28" padding="24" background="#0D1117">
      {habits.map((habit, index) => (
        <vstack alignment="leading" spacing="10" frame="max">
          <Header habit={habit} font="headline" />
          <Grid log={logs[index]} colors={habit.color} weeks={11} cell={12} gap={3} />
          <hstack>
            <CheckIn habit={habit} />
            <spacer />
            <Total habit={habit} />
          </hstack>
        </vstack>
      ))}
    </hstack>,
  );
} else {
  // Large widget: the three habits one below the other, 26 weeks each.
  $render(
    <vstack alignment="leading" spacing="12" padding="16" background="#0D1117">
      {habits.map((habit, index) => (
        <vstack alignment="leading" spacing="5">
          <hstack spacing="8">
            <Header habit={habit} font="subheadline" />
            <Total habit={habit} />
            <CheckIn habit={habit} />
          </hstack>
          <Grid log={logs[index]} colors={habit.color} weeks={26} cell={7} gap={3} />
        </vstack>
      ))}
    </vstack>,
  );
}
