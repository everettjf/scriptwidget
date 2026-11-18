//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
//
// Shows the name of today's weekday. Try translating the names in `weekday`.
//

var d = new Date();

// getDay() gives 0 for Sunday up to 6 for Saturday: the position in this list.
const weekday = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
let day = weekday[d.getDay()];

// $getenv("widget-size") is the size being drawn: "small", "medium", "large", …
if ($getenv("widget-size") === "small") {
  // Small: the weekday in a size that fits "Wednesday", and a short date.
  // frame="max" fills the widget; padding is the space around the content, in points.
  $render(
    <vstack background="#e11d48" frame="max" alignment="leading" spacing="4" padding="14">
      <hstack>
        <text font="caption" color="#fca5a5">
          TODAY
        </text>
        <spacer />
        <icon systemName="calendar.circle.fill" size="20" color="#f87171" />
      </hstack>
      <vstack frame="max,leading" alignment="leading" spacing="3">
        <text font="title3" weight="bold" color="white">
          {day}
        </text>
        {/* A short date such as "Nov 18". */}
        <text font="caption" color="#fecaca">
          {d.toLocaleDateString("en-US", { month: "short", day: "numeric" })}
        </text>
      </vstack>
    </vstack>,
  );
} else {
  // Medium and larger: a bigger weekday, and the date drawn by the <date> element.
  $render(
    <hstack background="#e11d48" frame="max" spacing="16" padding="14">
      <vstack alignment="leading" spacing="3">
        <text font="caption" color="#fca5a5">
          TODAY
        </text>
        <text font="largeTitle" weight="bold" color="white">
          {day}
        </text>
        {/* date="now" with style="date" shows today's date. */}
        <date date="now" style="date" font="caption" color="#fecaca" />
      </vstack>
      <spacer />
      <icon systemName="calendar.circle.fill" size="44" color="#f87171" />
    </hstack>,
  );
}
