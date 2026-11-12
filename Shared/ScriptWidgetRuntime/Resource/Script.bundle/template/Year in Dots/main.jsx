//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Year in Dots: one dot per day of the year.
//

const size = $getenv("widget-size");
const now = new Date();
const start = new Date(now.getFullYear(), 0, 1);
const total = (new Date(now.getFullYear() + 1, 0, 1) - start) / 86400000;
const today = Math.floor((now - start) / 86400000) + 1;
const percent = Math.round((100 * today) / total);
const paper = "#F5F1E8";
const ink = "#2B2A28";
const accent = "#E4572E";

// Rows of stacks rather than a grid, so spacing is the same in both
// directions. A plain function: component props cannot carry functions.
const field = (count, columns, spacing, cell) => (
  <vstack alignment="leading" spacing={spacing}>
    {Array.from({ length: Math.ceil(count / columns) }, (_, row) => (
      <hstack spacing={spacing}>
        {Array.from({ length: Math.min(columns, count - row * columns) }, (_, column) => cell(row * columns + column))}
      </hstack>
    ))}
  </vstack>
);
const dotColor = (day) => (day === today ? accent : day < today ? ink : "#D9D2C3");
const Dots = ({ count, first, columns, dot, spacing }) => field(count, columns, spacing, (index) => <circle frame={`${dot},${dot}`} color={dotColor(first + index)} />);
const Title = ({ font }) => (
  <hstack alignment="bottom">
    <text font={font} fontWeight="bold" color={ink}>{now.getFullYear()}</text>
    <spacer />
    <text font="caption" fontWeight="semibold" color={accent}>{percent}%</text>
  </hstack>
);

if (size === "accessoryCircular") {
  $render(<zstack><ring value={today / total} thickness="5" frame="max" /><text font="caption" fontWeight="bold">{percent}%</text></zstack>);
} else if (size === "accessoryRectangular") {
  $render(
    <vstack alignment="leading" spacing="3" frame="max,leading">
      <text font="headline">Day {today} of {total}</text>
      <progress value={today} total={total} />
      <text font="caption">{total - today} days left</text>
    </vstack>
  );
} else if (size === "accessoryInline") {
  $render(<text>{now.getFullYear()} · {percent}% · {total - today} days left</text>);
} else if (size === "small") {
  // This month, one dot per day.
  const first = today - now.getDate() + 1;
  const days = new Date(now.getFullYear(), now.getMonth() + 1, 0).getDate();
  const monthName = now.toLocaleString("en-US", { month: "long" });
  $render(
    <vstack alignment="leading" spacing="8" padding="14" background={paper}>
      <hstack alignment="bottom">
        <text font="headline" color={ink}>{monthName}</text>
        <spacer />
        <text font="caption" fontWeight="semibold" color={accent}>{percent}%</text>
      </hstack>
      <Dots count={days} first={first} columns={7} dot={10} spacing={6} />
      <spacer />
      <text font="caption2" color="#8A8273">{total - today} days left in {now.getFullYear()}</text>
    </vstack>
  );
} else if (size === "medium") {
  // The year as weeks.
  const weeks = Math.ceil(total / 7);
  const week = Math.ceil(today / 7);
  $render(
    <vstack alignment="leading" spacing="10" padding="16" background={paper}>
      <Title font="title3" />
      {field(weeks, 18, 5, (index) => <rect frame="11,11" corner="3" color={index + 1 === week ? accent : index + 1 < week ? ink : "#D9D2C3"} />)}
      <spacer />
      <text font="caption2" color="#8A8273">Week {week} of {weeks} · {total - today} days left</text>
    </vstack>
  );
} else {
  const wide = size === "extraLarge";
  $render(
    <vstack alignment="leading" spacing="12" padding={wide ? "24" : "16"} background={paper}>
      <Title font={wide ? "largeTitle" : "title"} />
      <spacer />
      <Dots count={total} first={1} columns={wide ? 31 : 21} dot={wide ? 14 : 6} spacing={wide ? 8 : 5} />
      <spacer />
      <text font="caption" color="#8A8273">Day {today} · {total - today} days left</text>
    </vstack>
  );
}
