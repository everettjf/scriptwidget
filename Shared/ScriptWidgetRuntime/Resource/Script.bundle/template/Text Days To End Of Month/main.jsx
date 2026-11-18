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

// Whole days from now to the end of this month: 0 on the last day.
var a = moment().endOf("month");
var b = moment();
var days = a.diff(b, "days");

// frame="max" fills the widget; padding is the space around the content, in points.
$render(
  <hstack background="#7c3aed" frame="max" spacing="6" padding="14">
    <vstack alignment="leading" spacing="3">
      <text font="caption" color="#d8b4fe">
        THIS MONTH
      </text>
      <text font="largeTitle" weight="bold" color="white">
        {days}
      </text>
      <text font="caption" color="#e9d5ff">
        days remaining
      </text>
    </vstack>
    <spacer />
    <icon systemName="calendar" size="28" color="#c084fc" />
  </hstack>,
);
