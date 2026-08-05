// 
// ScriptWidget 
// https://xnu.app/scriptwidget
// 
// Year Days Left Template
// 
// Description: Show you how many days left this year
// 

var today = new Date();
var lastDay = new Date(today.getFullYear(), 12, 31);
var perDay = 1000 * 60 * 60 * 24;
var leftDays = Math.ceil((lastDay.getTime() - today.getTime()) / perDay);

$render(
  <hstack background="#9f1239" frame="max" spacing="16" padding="14">
    <vstack alignment="leading" spacing="3"><text font="caption" color="#fda4af">今年还剩</text><text font="largeTitle" weight="bold" color="white">{leftDays} 天</text><text font="caption" color="#fecdd3">把今天过得有意义</text></vstack><spacer/><icon systemName="sparkles" size="40" color="#fb7185"/>
  </hstack>
);
