//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Check Is Friday Today
// Shows a different icon and text on Fridays. Try another day number, or other texts.
//

var d = new Date();
// getDay() returns the day of the week: 0 is Sunday, 1 is Monday, … 5 is Friday.
var n = d.getDay();
// console.log writes a line to the log, which helps while testing.
console.log(n);

// $render draws the widget. frame="max" fills it; padding (the distance to the edges)
// and spacing (the gap between children) are in points.
$render(
  <vstack background="#4f46e5" frame="max" alignment="leading" spacing="8" padding="14">
    <hstack frame="max">
      <text font="caption" color="#c4b5fd">
        FRIDAY CHECK
      </text>
      <spacer />
      <text font="caption" color="#ddd6fe">
        {d.toLocaleDateString("en-US", { month: "short", day: "numeric" })}
      </text>
    </hstack>
    <spacer />
    {/* Values in braces are JavaScript: here the icon and the text depend on the day. */}
    <hstack spacing="10">
      <icon systemName={n == 5 ? "party.popper.fill" : "calendar"} size="28" color="#fbbf24" />
      <text font="title2" weight="bold" color="white">
        {n == 5 ? "Yes!" : "Not yet"}
      </text>
    </hstack>
    {/* (5 - n + 7) % 7 is the number of days until the next Friday. */}
    <text font="caption" color="#ddd6fe">
      {n == 5 ? "The weekend starts here." : `${(5 - n + 7) % 7} days to go.`}
    </text>
  </vstack>,
);
