// Personal Dashboard
// widget-param: your first name (optional)
// Shows a greeting for the time of day and how much of today has passed.
// Try changing the greetings, the colors or the Focus line.

// $getenv("widget-param") is the optional widget parameter, a text you set on each widget.
const name = ($getenv("widget-param") || "Friend").trim();
// The hour in local time, 0 to 23.
const hour = new Date().getHours();
const greeting = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening";
// The share of the day that has passed, from 0 to 1. A day has 1440 minutes.
const dayProgress = Math.min(1, (hour * 60 + new Date().getMinutes()) / 1440);

if ($getenv("widget-size") === "small") {
  // Small: how much of today has passed, under a two-line greeting.
  $render(
    <vstack frame="max" background="#18181b" alignment="leading" spacing="6" padding="14">
      <hstack>
        <vstack alignment="leading" spacing="1">
          <text font="caption" color="#a1a1aa">
            {greeting},
          </text>
          <text font="subheadline" weight="bold" color="#fafafa">
            {name}
          </text>
        </vstack>
        <spacer />
        <icon systemName="sparkles" size="18" color="#a78bfa" />
      </hstack>
      <vstack frame="max,bottomLeading" alignment="leading" spacing="6">
        <text font="title" weight="bold" color="#a78bfa">
          {Math.round(dayProgress * 100)}%
        </text>
        <progress value={dayProgress} total="1" color="#8b5cf6" />
        <text font="caption2" color="#71717a">
          of today complete
        </text>
      </vstack>
    </vstack>,
  );
} else {
  // Other sizes: greeting and date, then a Focus line and the progress of the day.
  $render(
    <vstack frame="max" background="#18181b" spacing="8" padding="14">
      <hstack frame="max">
        <vstack alignment="leading" spacing="2">
          <text font="title3" weight="bold" color="#fafafa">
            {greeting}, {name}
          </text>
          <date date="now" style="date" font="caption" color="#a1a1aa" />
        </vstack>
        <spacer />
        <icon systemName="sparkles" size="24" color="#a78bfa" />
      </hstack>
      {/* <divider> draws a line; <stat> shows a title with its value. */}
      <divider color="#3f3f46" />
      <stat title="Focus" value="1 thing" color="#a78bfa" />
      <progress value={dayProgress} total="1" color="#8b5cf6" />
      <text font="caption2" color="#71717a">
        {Math.round(dayProgress * 100)}% of today complete
      </text>
    </vstack>,
  );
}
