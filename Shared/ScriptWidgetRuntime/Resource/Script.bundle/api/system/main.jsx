//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Usage for api system
// Shows what $system reports about the app and the system. Try showing other values.
// Runs on iPhone, iPad, Mac, Android, Windows and Linux.
//

// Read the values first. Some of them are objects with several fields.
const app = $system.appInfo();
const tz = $system.timeZone();
const calendar = $system.calendarInfo();
const memory = $system.memory();
// systemUptime() is in seconds; dividing by 3600 gives hours.
const uptimeHours = ($system.systemUptime() / 3600).toFixed(1);
const cpuCount = $system.processorCount();
const activeCpuCount = $system.activeProcessorCount();

// frame="max" makes the stack fill the whole widget.
$render(
  <vstack frame="max" background="#0f172a">
    <text font="caption" color="#94a3b8">
      System
    </text>
    <text font="title3" color="#e2e8f0">
      {app.name}
    </text>
    <text font="caption" color="#94a3b8">
      Bundle: {app.bundleId}
    </text>
    <text font="caption" color="#94a3b8">
      Version: {app.version} ({app.build})
    </text>

    {/* <spacer /> takes the free room between the app lines and the system lines. */}
    <spacer />

    {/* platform() names the system the script runs on, for example "android". */}
    <text font="caption" color="#94a3b8">
      Platform: {$system.platform()}
    </text>
    <text font="caption" color="#94a3b8">
      Locale: {$system.locale()}
    </text>
    <text font="caption" color="#94a3b8">
      Timezone: {tz.identifier} ({tz.abbreviation})
    </text>
    <text font="caption" color="#94a3b8">
      Calendar: {calendar.identifier}
    </text>
    <text font="caption" color="#94a3b8">
      Uptime: {uptimeHours}h
    </text>
    <text font="caption" color="#94a3b8">
      OS: {$system.osVersionString()}
    </text>
    <text font="caption" color="#94a3b8">
      Host: {$system.hostName()}
    </text>
    <text font="caption" color="#94a3b8">
      CPU: {cpuCount} ({activeCpuCount} active)
    </text>
    {/* memory.physical is in bytes; dividing by 1024 three times gives GB. */}
    <text font="caption" color="#94a3b8">
      Memory: {(memory.physical / 1024 / 1024 / 1024).toFixed(1)} GB
    </text>
    <text font="caption" color="#94a3b8">
      Low Power: {$system.lowPowerMode() ? "On" : "Off"}
    </text>
  </vstack>,
);
