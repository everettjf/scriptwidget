// 
// ScriptWidget 
// https://atomsprout.com/scriptwidget
// 
// Usage for api $device
// 

console.log($device.name());
console.log($device.model());
console.log($device.language());
console.log($device.systemVersion());
console.log(JSON.stringify($device.screen(), null, 2));
console.log(JSON.stringify($device.battery(), null, 2));
console.log($device.isdarkmode());
console.log($device.totalDiskSpace());
console.log($device.freeDiskSpace());
