//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Month Calendar: the date, a month grid, and the next events.
// Edit `events` to show your own schedule.
//

const size = $getenv("widget-size");
const now = new Date();
const accent = "#FF3B30";
const events = [
  { time: "9:30", title: "Design review", color: "#FF9F0A" },
  { time: "12:00", title: "Lunch with Mia", color: "#30D158" },
  { time: "16:00", title: "Climbing", color: "#0A84FF" },
  { time: "19:30", title: "Call Mom", color: "#BF5AF2" },
];

const weekday = now.toLocaleString("en-US", { weekday: "long" });
const month = now.toLocaleString("en-US", { month: "long" });
const day = now.getDate();
const firstWeekday = new Date(now.getFullYear(), now.getMonth(), 1).getDay();
const dayCount = new Date(now.getFullYear(), now.getMonth() + 1, 0).getDate();

const MonthGrid = ({ cell, font, spacing }) => {
  const columns = JSON.stringify(Array.from({ length: 7 }, () => ({ type: "fixed", value: String(cell) })));
  const cells = [];
  ["S", "M", "T", "W", "T", "F", "S"].forEach((name) => cells.push(<text font={font} fontWeight="semibold" color="#8E8E93" frame={`${cell},${cell}`}>{name}</text>));
  for (let i = 0; i < firstWeekday; i++) cells.push(<text font={font} frame={`${cell},${cell}`}> </text>);
  for (let d = 1; d <= dayCount; d++) {
    const today = d === day;
    cells.push(<text font={font} fontWeight={today ? "bold" : "regular"} color={today ? "white" : "#1C1C1E"} background={today ? accent : "clear"} corner={cell / 2} frame={`${cell},${cell}`}>{d}</text>);
  }
  return <vgrid columns={columns} spacing={spacing}>{cells}</vgrid>;
};

const EventRow = ({ event, font }) => (
  <hstack spacing="6">
    <capsule frame="3,26" color={event.color} />
    <vstack alignment="leading" spacing="0">
      <text font={font} fontWeight="semibold" color="#1C1C1E">{event.title}</text>
      <text font="caption2" color="#8E8E93">{event.time}</text>
    </vstack>
    <spacer />
  </hstack>
);

const Today = () => (
  <vstack alignment="leading" spacing="0">
    <text font="caption" fontWeight="bold" color={accent}>{weekday.toUpperCase()}</text>
    <text font="50" fontWeight="light" color="#1C1C1E">{day}</text>
  </vstack>
);

if (size === "accessoryCircular") {
  $render(
    <vstack spacing="0">
      <text font="caption2" fontWeight="semibold">{weekday.slice(0, 3).toUpperCase()}</text>
      <text font="title" fontWeight="bold">{day}</text>
    </vstack>
  );
} else if (size === "accessoryRectangular") {
  $render(
    <vstack alignment="leading" spacing="1" frame="max,leading">
      <text font="headline">{weekday}, {month} {day}</text>
      <text font="caption">{events[0].time} {events[0].title}</text>
      <text font="caption">{events[1].time} {events[1].title}</text>
    </vstack>
  );
} else if (size === "accessoryInline") {
  $render(<text>{weekday.slice(0, 3)} {day} · {events[0].title} {events[0].time}</text>);
} else if (size === "small") {
  $render(
    <vstack alignment="leading" frame="max,leading" padding="16" background="white">
      <Today />
      <spacer />
      <EventRow event={events[0]} font="caption" />
    </vstack>
  );
} else if (size === "medium") {
  $render(
    <hstack spacing="16" padding="16" background="white">
      <vstack alignment="leading" frame="max,leading">
        <Today />
        <spacer />
        <EventRow event={events[0]} font="caption" />
      </vstack>
      <vstack alignment="leading" spacing="4">
        <text font="caption" fontWeight="bold" color={accent}>{month.toUpperCase()}</text>
        <MonthGrid cell={16} font="9" spacing="1" />
      </vstack>
    </hstack>
  );
} else {
  const wide = size === "extraLarge";
  const agenda = (
    <vstack alignment="leading" spacing="8" frame="max,leading">
      <text font="caption" fontWeight="bold" color="#8E8E93">UP NEXT</text>
      {events.slice(0, wide ? 4 : 2).map((event) => <EventRow event={event} font="subheadline" />)}
    </vstack>
  );
  $render(
    <vstack alignment="leading" spacing="10" padding="16" background="white">
      <hstack alignment="bottom">
        <text font="title" fontWeight="bold" color="#1C1C1E">{month}</text>
        <text font="title" fontWeight="light" color={accent}>{now.getFullYear()}</text>
        <spacer />
        <text font="subheadline" fontWeight="semibold" color="#8E8E93">{weekday}</text>
      </hstack>
      {wide
        ? <hstack alignment="top" spacing="24"><MonthGrid cell={36} font="callout" spacing="6" />{agenda}</hstack>
        : <MonthGrid cell={28} font="footnote" spacing="3" />}
      {wide ? null : agenda}
    </vstack>
  );
}
