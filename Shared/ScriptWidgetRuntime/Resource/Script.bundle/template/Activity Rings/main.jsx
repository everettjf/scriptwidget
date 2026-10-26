// Activity Rings · an offline design example with editable sample values.
// These values are illustrative, not live Apple Health readings.
const size = $getenv("widget-size");
const dark = $device.isdarkmode();
const palette = {
  background: dark ? "#172522" : "#F5FAF7",
  text: dark ? "#F0F7F3" : "#203D32",
  secondary: dark ? "#B0C5BA" : "#5C7568",
  track: dark ? "#2B4138" : "#E0EBE4",
};
const goals = [
  { name: "Move", value: 420, goal: 500, unit: "cal", color: dark ? "#F2AC83" : "#AC582D" },
  { name: "Exercise", value: 24, goal: 30, unit: "min", color: dark ? "#74C8A2" : "#287A59" },
  { name: "Stand", value: 9, goal: 12, unit: "hr", color: dark ? "#8BBBE0" : "#3D739E" },
];
const week = [["M", 510], ["T", 380], ["W", 620], ["T", 450], ["F", 290], ["S", 540], ["S", 420]];
const Header = () => (
  <hstack frame="max,14" spacing="4">
    <text font="caption" fontWeight="semibold" color={palette.text}>Activity</text>
    <spacer />
    <text font="caption2" color={palette.secondary}>Sample</text>
  </hstack>
);
const Rings = ({ side, thickness }) => (
  <zstack frame={`${side},${side}`}>
    {goals.map((goal, index) => {
      const inset = index * (thickness + 3);
      return <ring value={Math.min(1, goal.value / goal.goal)} thickness={thickness} color={goal.color} trackColor={palette.track} frame={`${side - inset * 2},${side - inset * 2}`} />;
    })}
  </zstack>
);
const Stat = ({ goal }) => (
  <hstack spacing="5" frame="max,20">
    <circle color={goal.color} frame="5,5" />
    <text font="caption" color={palette.secondary}>{goal.name}</text>
    <spacer />
    <text font="headline" fontWeight="semibold" color={palette.text}>{goal.value}</text>
    <text font="caption2" color={palette.secondary}>{goal.unit}</text>
  </hstack>
);
const Summary = () => (
  <hstack spacing="8" frame="max,38">
    {goals.map((goal) => <vstack spacing="2" frame="max">
      <hstack spacing="2"><text font="headline" fontWeight="semibold" color={goal.color}>{goal.value}</text><text font="caption2" color={palette.secondary}>{goal.unit}</text></hstack>
      <text font="caption2" color={palette.secondary}>{goal.name}</text>
    </vstack>)}
  </hstack>
);
const Week = () => (
  <vstack alignment="leading" spacing="6" frame="max,82">
    <hstack><text font="caption2" fontWeight="semibold" color={palette.secondary}>MOVE THIS WEEK</text><spacer /><text font="caption2" color={palette.secondary}>500 cal goal</text></hstack>
    <hstack alignment="bottom" frame="max,42">
      {week.map(([, calories]) => <capsule frame={`12,${Math.round(42 * calories / 620)}`} color={calories >= goals[0].goal ? goals[0].color : palette.track} />).flatMap((bar, index) => index ? [<spacer />, bar] : [bar])}
    </hstack>
    <hstack>
      {week.map(([day]) => <text font="caption2" color={palette.secondary} frame="12">{day}</text>).flatMap((label, index) => index ? [<spacer />, label] : [label])}
    </hstack>
  </vstack>
);
if (size === "accessoryCircular") {
  $render(<zstack><ring value={goals[0].value / goals[0].goal} thickness="5" frame="max" /><text font="caption" fontWeight="bold">{Math.round(100 * goals[0].value / goals[0].goal)}%</text></zstack>);
} else if (size === "accessoryRectangular") {
  $render(<hstack spacing="8" frame="max,leading"><Rings side={44} thickness={4} /><vstack alignment="leading" spacing="0">{goals.map((goal) => <text font="caption">{goal.value}/{goal.goal} {goal.unit}</text>)}</vstack></hstack>);
} else if (size === "accessoryInline") {
  $render(<text>Move {goals[0].value}/{goals[0].goal} · Exercise {goals[1].value} min</text>);
} else if (size === "small") {
  $render(<vstack frame="max" spacing="8" padding="14" background={palette.background}><Header /><Rings side={76} thickness={8} /><hstack frame="max">{goals.map((goal) => <vstack frame="max" spacing="0"><text font="caption" fontWeight="semibold" color={goal.color}>{goal.value}</text><text font="caption2" color={palette.secondary}>{goal.unit}</text></vstack>)}</hstack></vstack>);
} else if (size === "medium") {
  $render(<vstack frame="max" spacing="10" padding="16" background={palette.background}><Header /><hstack spacing="20" frame="max,96"><Rings side={96} thickness={10} /><vstack frame="max,96,leading" spacing="10">{goals.map((goal) => <Stat goal={goal} />)}</vstack></hstack></vstack>);
} else if (size === "extraLarge") {
  $render(<vstack frame="max" spacing="18" padding="22" background={palette.background}><Header /><hstack spacing="28" frame="max"><Rings side={148} thickness={16} /><vstack frame="140,148,leading" spacing="16">{goals.map((goal) => <Stat goal={goal} />)}</vstack><Week /></hstack></vstack>);
} else {
  $render(<vstack frame="max" spacing="12" padding="18" background={palette.background}><Header /><spacer /><Rings side={110} thickness={12} /><Summary /><spacer /><Week /></vstack>);
}
