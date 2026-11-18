// 
// ScriptWidget 
// https://atomsprout.com/scriptwidget
// 
// 

var d = new Date();

const weekday = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
let day = weekday[d.getDay()];


if ($getenv("widget-size") === "small") {
  // Small: the weekday in a size that fits "Wednesday", and a short date.
  $render(
    <vstack background="#e11d48" frame="max" alignment="leading" spacing="4" padding="14">
      <hstack><text font="caption" color="#fca5a5">TODAY</text><spacer/><icon systemName="calendar.circle.fill" size="20" color="#f87171"/></hstack>
      <vstack frame="max,leading" alignment="leading" spacing="3"><text font="title3" weight="bold" color="white">{day}</text><text font="caption" color="#fecaca">{d.toLocaleDateString("en-US", { month: "short", day: "numeric" })}</text></vstack>
    </vstack>
  );
} else {
  $render(
      <hstack background="#e11d48" frame="max" spacing="16" padding="14">
        <vstack alignment="leading" spacing="3"><text font="caption" color="#fca5a5">TODAY</text><text font="largeTitle" weight="bold" color="white">{day}</text><date date="now" style="date" font="caption" color="#fecaca"/></vstack><spacer/><icon systemName="calendar.circle.fill" size="44" color="#f87171"/>
      </hstack>
  );
}
