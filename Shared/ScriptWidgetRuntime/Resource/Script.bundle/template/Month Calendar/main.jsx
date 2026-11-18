//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Month Calendar: the date, a month grid, and the next events.
// Edit `events` to show your own schedule.
//
// The grid follows today's date; the events are fixed samples.
// Try changing `accent`, or the cell sizes passed to <MonthGrid>.

// $getenv("widget-size") is the size being drawn, such as "small" or "accessoryInline".
const size = $getenv("widget-size");
const now = new Date();
const accent = "#FF3B30";
const events = [
  { time: "9:30", title: "Design review", color: "#FF9F0A" },
  { time: "12:00", title: "Lunch with Mia", color: "#30D158" },
  { time: "16:00", title: "Climbing", color: "#0A84FF" },
  { time: "19:30", title: "Call Mom", color: "#BF5AF2" },
];

// Names in English, such as "Sunday" and "March".
const weekday = now.toLocaleString("en-US", { weekday: "long" });
const month = now.toLocaleString("en-US", { month: "long" });
const day = now.getDate();
// getDay() of the 1st: 0 = Sunday. Day 0 of next month is the last day of this month.
const firstWeekday = new Date(now.getFullYear(), now.getMonth(), 1).getDay();
const dayCount = new Date(now.getFullYear(), now.getMonth() + 1, 0).getDate();
// A month that touches six weeks gets smaller cells, so the grid keeps its height.
const sixWeeks = firstWeekday + dayCount > 35;

// The month as a grid of 7 columns; `cell` is the size of one cell in points.
// <vgrid> takes its columns as JSON text: here seven columns of a fixed width.
const MonthGrid = ({ cell, font, spacing }) => {
  const columns = JSON.stringify(
    Array.from({ length: 7 }, () => ({ type: "fixed", value: String(cell) })),
  );
  const cells = [];
  // First row: the letters of the weekdays.
  ["S", "M", "T", "W", "T", "F", "S"].forEach((name) =>
    cells.push(
      <text font={font} fontWeight="semibold" color="#8E8E93" frame={`${cell},${cell}`}>
        {name}
      </text>,
    ),
  );
  // Empty cells before the 1st.
  for (let i = 0; i < firstWeekday; i++)
    cells.push(
      <text font={font} frame={`${cell},${cell}`}>
        {" "}
      </text>,
    );
  // One cell per day. Today gets a filled circle.
  for (let d = 1; d <= dayCount; d++) {
    const today = d === day;
    cells.push(
      <text
        font={font}
        fontWeight={today ? "bold" : "regular"}
        color={today ? "white" : "#1C1C1E"}
        background={today ? accent : "clear"}
        corner={cell / 2}
        frame={`${cell},${cell}`}
      >
        {d}
      </text>,
    );
  }
  return (
    <vgrid columns={columns} spacing={spacing}>
      {cells}
    </vgrid>
  );
};

// One event: a colored bar, the title and the time.
const EventRow = ({ event, font }) => (
  <hstack spacing="6">
    <capsule frame="3,26" color={event.color} />
    <vstack alignment="leading" spacing="0">
      <text font={font} fontWeight="semibold" color="#1C1C1E">
        {event.title}
      </text>
      <text font="caption2" color="#8E8E93">
        {event.time}
      </text>
    </vstack>
    <spacer />
  </hstack>
);

// The weekday and the day number in large type.
const Today = () => (
  <vstack alignment="leading" spacing="0">
    <text font="caption" fontWeight="bold" color={accent}>
      {weekday.toUpperCase()}
    </text>
    <text font="50" fontWeight="light" color="#1C1C1E">
      {day}
    </text>
  </vstack>
);

// Choose a layout for the widget size.
if (size === "accessoryCircular") {
  // Lock Screen, circular: weekday and day.
  $render(
    <vstack spacing="0">
      <text font="caption2" fontWeight="semibold">
        {weekday.slice(0, 3).toUpperCase()}
      </text>
      <text font="title" fontWeight="bold">
        {day}
      </text>
    </vstack>,
  );
} else if (size === "accessoryRectangular") {
  // Lock Screen, rectangular: the date and the first two events.
  $render(
    <vstack alignment="leading" spacing="1" frame="max,leading">
      <text font="headline">
        {weekday}, {month} {day}
      </text>
      <text font="caption">
        {events[0].time} {events[0].title}
      </text>
      <text font="caption">
        {events[1].time} {events[1].title}
      </text>
    </vstack>,
  );
} else if (size === "accessoryInline") {
  // Lock Screen, inline: one line of text.
  $render(
    <text>
      {weekday.slice(0, 3)} {day} · {events[0].title} {events[0].time}
    </text>,
  );
} else if (size === "small") {
  // Small widget: today and the first event.
  $render(
    <vstack alignment="leading" frame="max,leading" padding="16" background="white">
      <Today />
      <spacer />
      <EventRow event={events[0]} font="caption" />
    </vstack>,
  );
} else if (size === "medium") {
  // Medium widget: today on the left, the month grid on the right.
  $render(
    <hstack spacing="16" padding="16" background="white">
      <vstack alignment="leading" frame="max,leading">
        <Today />
        <spacer />
        <EventRow event={events[0]} font="caption" />
      </vstack>
      <vstack alignment="leading" spacing="4">
        <text font="caption" fontWeight="bold" color={accent}>
          {month.toUpperCase()}
        </text>
        <MonthGrid cell={16} font="9" spacing="1" />
      </vstack>
    </hstack>,
  );
} else {
  // Large widget: the month grid above two events.
  // Extra large widget: the grid and four events side by side.
  const wide = size === "extraLarge";
  const agenda = (
    <vstack alignment="leading" spacing="8" frame="max,leading">
      <text font="caption" fontWeight="bold" color="#8E8E93">
        UP NEXT
      </text>
      {events.slice(0, wide ? 4 : 2).map((event) => (
        <EventRow event={event} font="subheadline" />
      ))}
    </vstack>
  );
  $render(
    <vstack alignment="leading" spacing="10" padding="16" background="white">
      <hstack alignment="bottom">
        <text font="title" fontWeight="bold" color="#1C1C1E">
          {month}
        </text>
        <text font="title" fontWeight="light" color={accent}>
          {now.getFullYear()}
        </text>
        <spacer />
        <text font="subheadline" fontWeight="semibold" color="#8E8E93">
          {wide ? weekday : weekday.slice(0, 3)}
        </text>
      </hstack>
      {wide ? (
        <hstack alignment="top" spacing="24">
          <MonthGrid cell={sixWeeks ? 30 : 36} font="callout" spacing="6" />
          {agenda}
        </hstack>
      ) : (
        <MonthGrid cell={sixWeeks ? 24 : 28} font="footnote" spacing={sixWeeks ? "2" : "3"} />
      )}
      {wide ? null : agenda}
    </vstack>,
  );
}
