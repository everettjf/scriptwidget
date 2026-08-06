// 
// ScriptWidget 
// https://xnu.app/scriptwidget
// 

var d = new Date();
var n = d.getDay();
console.log(n);

var a = moment().endOf('year');
var b = moment();
var days = a.diff(b, 'days');

$render(
  <hstack background="#0284c7" frame="max" spacing="16" padding="14">
    <vstack alignment="leading" spacing="3"><text font="caption" color="#7dd3fc">YEAR PROGRESS</text><text font="largeTitle" weight="bold" color="white">{days}</text><text font="caption" color="#bae6fd">days remaining</text></vstack><spacer/><icon systemName="hourglass" size="42" color="#38bdf8"/>
  </hstack>
);
