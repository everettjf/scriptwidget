// widget-param: name,MM-DD (optional), e.g. Alex,12-18
// Counts the days to the next birthday. Try changing the default name and date below.
//
// $getenv("widget-param") is the parameter set for this widget; the default is used when
// it is empty.
const p = ($getenv("widget-param") || "Alex,12-18").split(",");
const name = p[0].trim();
// [month, day] as numbers, for example [12, 18].
const md = (p[1] || "12-18").split("-").map(Number);
const now = new Date();
// This year's birthday at midnight or, if that has passed, next year's.
let next = new Date(now.getFullYear(), md[0] - 1, md[1]);
if (next < now) next = new Date(now.getFullYear() + 1, md[0] - 1, md[1]);
// 86400000 is the number of milliseconds in a day. Math.ceil rounds a part of a day up.
const days = Math.ceil((next - now) / 86400000);
// frame="max" fills the widget; padding keeps the content 14 points from the edges.
$render(
  <vstack frame="max" spacing="7" padding="14" background="#be185d">
    <hstack>
      <icon systemName="birthday.cake.fill" size="22" color="#fbcfe8" />
      <spacer />
      <text font="caption" color="#fce7f3">
        {name}
      </text>
    </hstack>
    <vstack frame="max" spacing="7">
      <text font="largeTitle" weight="bold" color="white">
        {days}
      </text>
      <text font="callout" color="#fdf2f8">
        days until the celebration
      </text>
    </vstack>
  </vstack>,
);
