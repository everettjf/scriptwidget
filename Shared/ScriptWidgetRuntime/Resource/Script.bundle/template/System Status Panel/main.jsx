//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// System Status Panel
//

const battery = $device.battery();
const totalDisk = $device.totalDiskSpace();
const freeDisk = $device.freeDiskSpace();
const usedDisk = Math.max(0, totalDisk - freeDisk);
const diskRatio = totalDisk > 0 ? usedDisk / totalDisk : 0;
const batteryRatio = battery.level || 0;

const gaugeSections = [
  { color: "#22c55e", value: 0.4 },
  { color: "#fbbf24", value: 0.3 },
  { color: "#ef4444", value: 0.3 }
];

$render(
  <vstack frame="max" background="#111827">
    <text font="caption" color="#9ca3af">System Status</text>
    <hstack spacing="12">
      <vstack>
        <gauge
          angle="220"
          value={batteryRatio}
          thickness="8"
          label={(batteryRatio * 100).toFixed(0) + "%"}
          labelFont="caption2"
          title="BATTERY"
          titleFont="caption2"
          sections={$json(gaugeSections)}
        />
      </vstack>
      <vstack>
        <gauge
          angle="220"
          value={diskRatio}
          thickness="8"
          label={(diskRatio * 100).toFixed(0) + "%"}
          labelFont="caption2"
          title="STORAGE"
          titleFont="caption2"
          sections={$json(gaugeSections)}
        />
      </vstack>
    </hstack>
    <text font="caption2" color="#9ca3af">Low Power: {$system.lowPowerMode() ? "On" : "Off"}</text>
    <text font="caption2" color="#9ca3af">Thermal: {$system.thermalState()}</text>
  </vstack>
);
