//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Storage Ring Template
//
// Description: Display how much of the device's storage is used
//
// Shows how to draw a ring from two circles. Try changing the colors or the line width.
//

// Both sizes are in bytes.
let total = $device.totalDiskSpace();
let free = $device.freeDiskSpace();
let used = total - free;
// The used share, from 0 to 1.
let percent = used / total;

// console.log writes to the script's log, not to the widget.
console.log(`total = ${total}, used = ${used}, percent = ${percent}`);

// <zstack> lays its children on top of each other. frame="max" fills the widget;
// padding is the space around the content, in points.
$render(
  <zstack frame="max" padding="12">
    {/* A full yellow ring; stroke is the line width in points. */}
    <circle color="yellow" stroke="20"></circle>
    {/* trim={x} keeps the part of the circle from x to 1, so the green arc is as long as */}
    {/* the used share. rotation, in degrees, turns the arc so that it ends at the top. */}
    <circle color="green" stroke="20" trim={1 - percent} rotation={90 * 3}></circle>
    <text>{`${Math.round(percent * 100)}%`} </text>
  </zstack>,
);
