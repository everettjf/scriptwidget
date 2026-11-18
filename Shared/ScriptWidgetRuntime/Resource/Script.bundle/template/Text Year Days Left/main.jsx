// 
// ScriptWidget 
// https://atomsprout.com/scriptwidget
// 
// Year Days Left Template
// 
// Description: Show you how many days left this year
// 

var today = new Date();
// Whole days from today's date to 31 December: 0 on the last day of the year.
// Both are counted as calendar dates, so the time of day does not matter.
var perDay = 1000 * 60 * 60 * 24;
var leftDays = Math.round((Date.UTC(today.getFullYear(), 11, 31) - Date.UTC(today.getFullYear(), today.getMonth(), today.getDate())) / perDay);

$render(
  <hstack background="#9f1239" frame="max" spacing="4" padding="14">
    <vstack alignment="leading" spacing="3"><text font="caption" color="#fda4af">今年还剩</text><text font="title" weight="bold" color="white">{leftDays} 天</text><text font="caption" color="#fecdd3">把今天过得有意义</text></vstack><spacer/><icon systemName="sparkles" size="26" color="#fb7185"/>
  </hstack>
);
