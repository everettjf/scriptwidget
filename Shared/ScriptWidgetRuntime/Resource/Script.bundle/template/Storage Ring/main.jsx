// 
// ScriptWidget 
// https://atomsprout.com/scriptwidget
// 
// Battery Percent Template
// 
// Description: Display system battery percentage
// 

let total = $device.totalDiskSpace();
let free = $device.freeDiskSpace();
let used = total - free;
let percent = used/total;

console.log(`total = ${total}, used = ${used}, percent = ${percent}`);

$render(
  <zstack frame="max" padding="12">
    <circle color="yellow" stroke="20"></circle>
    <circle color="green" stroke="20" trim={1-percent} rotation={90 * 3}></circle>
    <text>{ `${Math.round(percent * 100)}%`} </text>
  </zstack>
);
