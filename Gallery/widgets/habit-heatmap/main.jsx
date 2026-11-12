//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Tap Check in on a Home Screen widget (iOS 17+ / macOS 14+).
// Rendering never marks a day complete. Records are local to this package;
// renaming a habit's display name preserves its stable id and history.
// Keep up to ten years of local calendar dates per habit. No network required.
// Duplicate copies have separate history; this is not iCloud sync.

if (!$import("lib/records.js")) throw new Error("Install the complete template, including lib/records.js.");
const savedNames = localRecords.configuration("habitHeatmap");
const size = $getenv("widget-size");
const habits = [
  { id: "read", name: savedNames.readName, action: "checkInRead", color: ["#1B2A1E", "#0E4429", "#006D32", "#26A641", "#39D353"] },
  { id: "run", name: savedNames.runName, action: "checkInRun", color: ["#1E1B2A", "#2E2266", "#4434A5", "#6B5BE0", "#9D8CFF"] },
  { id: "meditate", name: savedNames.meditateName, action: "checkInMeditate", color: ["#2A1E1B", "#5C2A10", "#9A4A12", "#D9741C", "#FFA94D"] },
];
const dateKey = (date) => `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
// Calendar arithmetic at noon handles DST without assuming 24-hour days.
const dayOffset = (date, days) => new Date(date.getFullYear(), date.getMonth(), date.getDate() + days, 12);
const today = dayOffset(new Date(), 0);
const todayKey = dateKey(today);
const oldestKey = dateKey(dayOffset(today, -3659));
const storageKey = (habit) => `habitHeatmap.v1.${habit.id}`;
const parseDays = (raw) => {
  if (!raw) return [];
  let days;
  try { days = JSON.parse(raw); } catch (error) { throw new Error("Habit history is unreadable. Restore it before checking in."); }
  if (!Array.isArray(days) || days.length > 3660 || days.some((day) => {
    if (typeof day !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(day)) return true;
    const parts = day.split("-").map(Number);
    return dateKey(new Date(parts[0], parts[1] - 1, parts[2], 12)) !== day;
  })) throw new Error("Invalid habit history. Restore it before checking in.");
  return Array.from(new Set(days)).sort();
};
const readDays = (habit) => parseDays($storage.getString(storageKey(habit)));
function checkIn(habit) {
  // A conflict rereads and revalidates history rather than replacing another
  // process's new day. Rendering and rejected attempts never create records.
  for (let attempt = 0; attempt < 4; attempt++) {
    const raw = $storage.getString(storageKey(habit));
    const days = parseDays(raw);
    if (days.includes(todayKey)) { $render(<text>Already checked in</text>); return; }
    const updated = days.filter((day) => day >= oldestKey);
    updated.push(todayKey);
    updated.sort();
    if (updated.length > 3660 || typeof $storage.compareAndSetString !== "function") break;
    if ($storage.compareAndSetString(storageKey(habit), raw, JSON.stringify(updated))) {
      $render(<text>Checked in</text>);
      return;
    }
  }
  throw new Error("Could not save check-in. Storage may be busy; please try again.");
}
function checkInRead() { return checkIn(habits[0]); }
function checkInRun() { return checkIn(habits[1]); }
function checkInMeditate() { return checkIn(habits[2]); }
const records = habits.map(readDays);
const streak = (days) => {
  const completed = new Set(days);
  let offset = completed.has(todayKey) ? 0 : -1;
  let count = 0;
  while (count < 3660 && completed.has(dateKey(dayOffset(today, offset)))) { count++; offset--; }
  return count;
};
// Monday-first columns; future days in the current week stay blank.
const weekEnd = dayOffset(today, 6 - (today.getDay() + 6) % 7);
const logs = records.map((days) => {
  const completed = new Set(days);
  return Array.from({ length: 26 * 7 }, (_, index) => {
    const key = dateKey(dayOffset(weekEnd, index - 26 * 7 + 1));
    return key > todayKey ? -1 : completed.has(key) ? 4 : 0;
  });
});

const Grid = ({ log, colors, weeks, cell, gap }) => {
  const days = log.slice(-weeks * 7);
  // Columns are weeks, rows are weekdays, as in a contribution graph.
  return (
    <hstack spacing={gap}>
      {Array.from({ length: weeks }, (_, week) => (
        <vstack spacing={gap}>
          {days.slice(week * 7, week * 7 + 7).map((level) => <rect frame={`${cell},${cell}`} corner={cell * 0.25} color={level < 0 ? "clear" : colors[level]} />)}
        </vstack>
      ))}
    </hstack>
  );
};
const daysFor = (habit) => records[habits.findIndex((item) => item.id === habit.id)];
const streakLabel = (habit) => {
  const count = streak(daysFor(habit));
  return `${count} ${count === 1 ? "day" : "days"}`;
};
const Header = ({ habit, font }) => (
  <hstack>
    <text font={font} fontWeight="semibold" color="white">{habit.name}</text>
    <spacer />
    <icon systemName="flame.fill" size="12" color={habit.color[4]} />
    <text font="caption" fontWeight="semibold" color={habit.color[4]}>{streakLabel(habit)}</text>
  </hstack>
);

const CheckIn = ({ habit }) => (
  <button actionID={habit.action}>
    <hstack spacing="4">
      <icon systemName={daysFor(habit).includes(todayKey) ? "checkmark.circle.fill" : "plus.circle"} size="12" color={habit.color[4]} />
      <text font="caption" color={habit.color[4]}>{daysFor(habit).includes(todayKey) ? "Done today" : "Check in"}</text>
    </hstack>
  </button>
);

// App Intent calls the named function after evaluating this source.
if (size === "action") {
  // Do not render a widget while handling a tap.
} else if (size === "accessoryCircular") {
  $render(<vstack spacing="0"><icon systemName="flame.fill" size="16" /><text font="title3" fontWeight="bold">{streak(records[0])}</text></vstack>);
} else if (size === "accessoryRectangular") {
  $render(
    <vstack alignment="leading" spacing="3" frame="max,leading">
      <text font="caption" fontWeight="semibold">{habits[0].name} · {streak(records[0])}-day streak</text>
      <Grid log={logs[0].map((level) => (level < 0 ? -1 : level > 0 ? 4 : 1))} colors={["#444444", "#666666", "#888888", "#AAAAAA", "#FFFFFF"]} weeks={20} cell={5} gap={1.5} />
    </vstack>
  );
} else if (size === "accessoryInline") {
  $render(<text>{habits[0].name} · {streak(records[0])}-day streak</text>);
} else if (size === "small") {
  $render(
    <vstack alignment="leading" spacing="4" padding="12" background="#0D1117">
      <Header habit={habits[0]} font="headline" />
      <Grid log={logs[0]} colors={habits[0].color} weeks={8} cell={9} gap={2} />
      <CheckIn habit={habits[0]} />
    </vstack>
  );
} else if (size === "medium") {
  $render(
    <vstack alignment="leading" spacing="4" padding="12" background="#0D1117">
      <Header habit={habits[0]} font="headline" />
      <Grid log={logs[0]} colors={habits[0].color} weeks={22} cell={10} gap={2} />
      <CheckIn habit={habits[0]} />
    </vstack>
  );
} else if (size === "extraLarge") {
  $render(
    <hstack alignment="top" spacing="28" padding="24" background="#0D1117">
      {habits.map((habit, index) => (
        <vstack alignment="leading" spacing="10" frame="max">
          <Header habit={habit} font="headline" />
          <Grid log={logs[index]} colors={habit.color} weeks={11} cell={12} gap={3} />
          <CheckIn habit={habit} />
        </vstack>
      ))}
    </hstack>
  );
} else {
  $render(
    <vstack alignment="leading" spacing="12" padding="16" background="#0D1117">
      {habits.map((habit, index) => (
        <vstack alignment="leading" spacing="5">
          <hstack><Header habit={habit} font="subheadline" /><CheckIn habit={habit} /></hstack>
          <Grid log={logs[index]} colors={habit.color} weeks={26} cell={7} gap={3} />
        </vstack>
      ))}
    </vstack>
  );
}
