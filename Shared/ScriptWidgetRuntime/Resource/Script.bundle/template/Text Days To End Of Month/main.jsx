//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//

var d = new Date();
var n = d.getDay();
console.log(n);

var a = moment().endOf("month");
var b = moment();
var days = a.diff(b, "days");

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
