//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Shows a number computed with the Moment.js library, which ScriptWidget loads when a
// script uses `moment`. Try changing the colors or the icon.
//

// Today's weekday number (0 is Sunday). It only goes to the log; the widget does not use it.
var d = new Date();
var n = d.getDay();
console.log(n);

// Whole days from now to the end of this year: 0 on 31 December.
var a = moment().endOf("year");
var b = moment();
var days = a.diff(b, "days");

// frame="max" fills the widget; padding is the space around the content, in points.
$render(
  <hstack background="#0284c7" frame="max" spacing="6" padding="14">
    <vstack alignment="leading" spacing="3">
      <text font="caption" color="#7dd3fc">
        THIS YEAR
      </text>
      <text font="largeTitle" weight="bold" color="white">
        {days}
      </text>
      <text font="caption" color="#bae6fd">
        days remaining
      </text>
    </vstack>
    <spacer />
    <icon systemName="hourglass" size="28" color="#38bdf8" />
  </hstack>,
);
