// Personal Dashboard
// widget-param: your first name (optional)

const name = ($getenv("widget-param") || "Friend").trim();
const hour = new Date().getHours();
const greeting = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening";
const dayProgress = Math.min(1, (hour * 60 + new Date().getMinutes()) / 1440);

$render(
  <vstack frame="max" background="#18181b" spacing="12" padding="14">
    <hstack frame="max">
      <vstack alignment="leading" spacing="2">
        <text font="title3" weight="bold" color="#fafafa">{greeting}, {name}</text>
        <date date="now" style="date" font="caption" color="#a1a1aa" />
      </vstack>
      <spacer />
      <icon systemName="sparkles" size="24" color="#a78bfa" />
    </hstack>
    <divider color="#3f3f46" />
    <stat title="Focus" value="1 thing" subtitle="Keep it simple" color="#a78bfa" />
    <progress value={dayProgress} total="1" color="#8b5cf6" />
    <text font="caption2" color="#71717a">{Math.round(dayProgress * 100)}% of today complete</text>
  </vstack>
);
