// Hydration Goal
// widget-param: current,goal — for example: 5,8

const parts = ($getenv("widget-param") || "5,8").split(",");
const current = Math.max(0, parseFloat(parts[0]) || 5);
const goal = Math.max(1, parseFloat(parts[1]) || 8);
const progress = Math.min(1, current / goal);

$render(
  <vstack frame="max" background="#0369a1" spacing="8" padding="14">
    <hstack frame="max">
      <label title="Hydration" systemName="drop.fill" color="#38bdf8" />
      <spacer />
      <badge text={`${Math.round(progress * 100)}%`} background="#0c4a6e" color="#bae6fd" />
    </hstack>
    <ring value={progress} thickness="10" color="#38bdf8" trackColor="#164e63" frame="72" />
    <text font="headline" color="#f0f9ff">{current} of {goal} glasses</text>
    <text font="caption2" color="#7dd3fc">Small sips add up.</text>
  </vstack>
);
