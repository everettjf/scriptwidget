//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// System Status Panel
//
// Shows two gauges with colored sections, filled from $device and $system.
// Try changing the colors and sizes of the sections.
//

// battery.level is from 0 to 1; the disk sizes are in bytes.
const battery = $device.battery();
const totalDisk = $device.totalDiskSpace();
const freeDisk = $device.freeDiskSpace();
// Shares from 0 to 1. Math.max and the "> 0" test guard against odd device values.
const usedDisk = Math.max(0, totalDisk - freeDisk);
const diskRatio = totalDisk > 0 ? usedDisk / totalDisk : 0;
const batteryRatio = battery.level || 0;

// The colored bands of a gauge: 40% green, 30% yellow, 30% red.
const gaugeSections = [
  { color: "#22c55e", value: 0.4 },
  { color: "#fbbf24", value: 0.3 },
  { color: "#ef4444", value: 0.3 },
];

// frame="max" makes the stack, and with it the background, fill the widget.
$render(
  <vstack frame="max" background="#111827">
    <text font="caption" color="#9ca3af">
      System Status
    </text>
    <hstack spacing="12">
      <vstack>
        {/* sections takes a JSON string; $json(value) is short for JSON.stringify(value). */}
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
    {/* lowPowerMode() is true or false; thermalState() is a word such as "nominal". */}
    <text font="caption2" color="#9ca3af">
      Low Power: {$system.lowPowerMode() ? "On" : "Off"}
    </text>
    <text font="caption2" color="#9ca3af">
      Thermal: {$system.thermalState()}
    </text>
  </vstack>,
);
