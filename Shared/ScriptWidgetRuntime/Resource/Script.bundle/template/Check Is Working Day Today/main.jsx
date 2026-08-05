// 
// ScriptWidget 
// https://xnu.app/scriptwidget
// 

var d = new Date();
var n = d.getDay();
console.log(n);

const working = n >= 1 && n <= 5;
$render(
  <vstack background={working ? "#0f3d3e" : "#3b1d4a"} frame="max" alignment="leading" spacing="8" padding="14">
    <hstack frame="max"><text font="caption" color={working ? "#99f6e4" : "#f5d0fe"}>DAY STATUS</text><spacer/><date date="now" style="date" font="caption" color="white"/></hstack>
    <spacer/>
    <hstack spacing="10"><icon systemName={working ? "briefcase.fill" : "cup.and.saucer.fill"} size="28" color={working ? "#5eead4" : "#e879f9"}/><text font="title" weight="bold" color="white">{working ? "Work day" : "Day off"}</text></hstack>
    <text font="caption" color={working ? "#ccfbf1" : "#fae8ff"}>{working ? "Choose one meaningful priority." : "Rest, reset, and enjoy."}</text>
  </vstack>
);
