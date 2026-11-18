// Weekly Planner — highlights today without network access.

const now = new Date();
const day = now.getDay();
const names = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"];

const Day = ({ index }) => (
  <vstack spacing="4">
    <text font="caption2" color={index === day ? "#ffffff" : "#94a3b8"}>{names[index]}</text>
    <circle frame="8" color={index === day ? "#60a5fa" : "#334155"} />
  </vstack>
);

if ($getenv("widget-size") === "small") {
  // Small: one letter for each day, so that the seven fit.
  const Letter = ({ index }) => (
    <vstack spacing="4">
      <text font="caption2" color={index === day ? "#ffffff" : "#94a3b8"}>{names[index][0]}</text>
      <circle frame="8" color={index === day ? "#60a5fa" : "#334155"} />
    </vstack>
  );
  $render(
    <vstack frame="max" background="#0f172a" alignment="leading" spacing="12" padding="14">
      <vstack alignment="leading" spacing="2">
        <text font="headline" color="#f8fafc">This Week</text>
        <text font="caption" color="#94a3b8">{now.toLocaleDateString("en-US", { weekday: "short", month: "short", day: "numeric" })}</text>
      </vstack>
      <hstack frame="max" spacing="8">
        <Letter index={0} /><Letter index={1} /><Letter index={2} /><Letter index={3} />
        <Letter index={4} /><Letter index={5} /><Letter index={6} />
      </hstack>
    </vstack>
  );
} else {
  $render(
    <vstack frame="max" background="#0f172a" spacing="12" padding="14">
      <hstack frame="max" spacing="6">
        <vstack alignment="leading" spacing="2">
          <text font="headline" color="#f8fafc">This Week</text>
          <text font="caption" color="#94a3b8">Make today count</text>
        </vstack>
        <spacer />
        <date date="now" style="date" font="caption" color="#cbd5e1" />
      </hstack>
      <hstack frame="max" spacing="10">
        <Day index={0} /><Day index={1} /><Day index={2} /><Day index={3} />
        <Day index={4} /><Day index={5} /><Day index={6} />
      </hstack>
    </vstack>
  );
}
