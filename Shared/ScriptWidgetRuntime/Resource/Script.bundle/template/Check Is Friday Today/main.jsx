// 
// ScriptWidget 
// https://xnu.app/scriptwidget
// 
// 

var d = new Date();
var n = d.getDay();
console.log(n);

$render(
  <vstack background="#312e81" frame="max" alignment="leading" spacing="8" padding="14">
    <hstack frame="max"><text font="caption" color="#c4b5fd">FRIDAY CHECK</text><spacer/><date date="now" style="date" font="caption" color="#ddd6fe"/></hstack>
    <spacer/>
    <hstack spacing="10"><icon systemName={n == 5 ? "party.popper.fill" : "calendar"} size="28" color="#fbbf24"/><text font="largeTitle" weight="bold" color="white">{n == 5 ? "Yes!" : "Not yet"}</text></hstack>
    <text font="caption" color="#ddd6fe">{n == 5 ? "The weekend starts here." : `${(5-n+7)%7} days to go.`}</text>
  </vstack>
);
