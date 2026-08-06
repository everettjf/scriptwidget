//
// ScriptWidget
// https://xnu.app/scriptwidget
//
// System Insights
//

const memory = $system.memory();
const uptimeHours = ($system.systemUptime() / 3600).toFixed(1);
const cpuCount = $system.processorCount();
const activeCpu = $system.activeProcessorCount();

$render(
  <hstack frame="max" spacing="18" padding="16" background="#0f172a">
    <vstack alignment="leading" spacing="6">
      <hstack spacing="7"><icon systemName="desktopcomputer" size="19" color="#60a5fa"/><text font="caption" weight="bold" color="#93c5fd">SYSTEM</text></hstack>
      <text font="title2" weight="bold" color="white">{$system.platform().toUpperCase()}</text>
      <text font="caption2" color="#64748b">{$system.osVersionString()}</text>
    </vstack>
    <spacer/>
    <vstack alignment="leading" spacing="7">
      <stat title="CPU" value={`${activeCpu} / ${cpuCount}`} subtitle="active" color="#38bdf8"/>
      <stat title="MEMORY" value={`${(memory.physical / 1024 / 1024 / 1024).toFixed(1)} GB`} subtitle="physical" color="#a78bfa"/>
      <stat title="UPTIME" value={`${uptimeHours}h`} subtitle="since boot" color="#34d399"/>
    </vstack>
  </hstack>
);
