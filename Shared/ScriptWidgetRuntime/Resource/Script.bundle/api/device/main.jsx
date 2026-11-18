//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Usage for api $device
// Prints what $device knows about this device to the Console.
// Nothing is drawn here, so the widget itself only shows "#UI Not Found#".
// Runs on iPhone, iPad, Mac, Android, Windows and Linux.
//

console.log($device.name());
console.log($device.model());
console.log($device.language());
console.log($device.systemVersion());
// screen() and battery() return objects. JSON.stringify(value, null, 2) prints them
// with one field per line.
console.log(JSON.stringify($device.screen(), null, 2));
console.log(JSON.stringify($device.battery(), null, 2));
// true in dark appearance, false in light.
console.log($device.isdarkmode());
console.log($device.totalDiskSpace());
console.log($device.freeDiskSpace());
