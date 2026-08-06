// 
// ScriptWidget 
// https://xnu.app/scriptwidget
// 

var d = new Date();
var n = d.getDay();
console.log(n);

var a = moment().endOf('month');
var b = moment();
var days = a.diff(b, 'days');

$render(
  <hstack background="#7c3aed" frame="max" spacing="16" padding="14">
    <vstack alignment="leading" spacing="3"><text font="caption" color="#d8b4fe">MONTH PROGRESS</text><text font="largeTitle" weight="bold" color="white">{days}</text><text font="caption" color="#e9d5ff">days remaining</text></vstack><spacer/><icon systemName="calendar" size="42" color="#c084fc"/>
  </hstack>
);
