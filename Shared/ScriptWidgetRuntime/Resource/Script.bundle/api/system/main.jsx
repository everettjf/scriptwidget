//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Usage for api system
//

const app = $system.appInfo();
const tz = $system.timeZone();
const calendar = $system.calendarInfo();
const memory = $system.memory();
const uptimeHours = ($system.systemUptime() / 3600).toFixed(1);
const cpuCount = $system.processorCount();
const activeCpuCount = $system.activeProcessorCount();

$render(
  <vstack frame="max" background="#0f172a">
    <text font="caption" color="#94a3b8">System</text>
    <text font="title3" color="#e2e8f0">{app.name}</text>
    <text font="caption" color="#94a3b8">Bundle: {app.bundleId}</text>
    <text font="caption" color="#94a3b8">Version: {app.version} ({app.build})</text>

    <spacer />

    <text font="caption" color="#94a3b8">Platform: {$system.platform()}</text>
    <text font="caption" color="#94a3b8">Locale: {$system.locale()}</text>
    <text font="caption" color="#94a3b8">Timezone: {tz.identifier} ({tz.abbreviation})</text>
    <text font="caption" color="#94a3b8">Calendar: {calendar.identifier}</text>
    <text font="caption" color="#94a3b8">Uptime: {uptimeHours}h</text>
    <text font="caption" color="#94a3b8">OS: {$system.osVersionString()}</text>
    <text font="caption" color="#94a3b8">Host: {$system.hostName()}</text>
    <text font="caption" color="#94a3b8">CPU: {cpuCount} ({activeCpuCount} active)</text>
    <text font="caption" color="#94a3b8">Memory: {(memory.physical / 1024 / 1024 / 1024).toFixed(1)} GB</text>
    <text font="caption" color="#94a3b8">Low Power: {$system.lowPowerMode() ? "On" : "Off"}</text>
  </vstack>
);
