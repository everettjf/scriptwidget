//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// System Insights
//

const memory = $system.memory();
const uptimeHours = ($system.systemUptime() / 3600).toFixed(1);
const cpuCount = $system.processorCount();
const activeCpu = $system.activeProcessorCount();

if ($getenv("widget-size") === "small") {
  // Small: the platform and the three numbers, one on each line.
  const Line = ({ title, value, color }) => <hstack><text font="caption2" color="#94a3b8">{title}</text><spacer/><text font="caption" weight="bold" color={color}>{value}</text></hstack>;
  $render(
    <vstack frame="max" alignment="leading" spacing="7" padding="14" background="#0f172a">
      <hstack spacing="7"><icon systemName="desktopcomputer" size="17" color="#60a5fa"/><text font="caption" weight="bold" color="#93c5fd">SYSTEM</text></hstack>
      <text font="title3" weight="bold" color="white">{$system.platform().toUpperCase()}</text>
      <Line title="ACTIVE CPU" value={`${activeCpu} / ${cpuCount}`} color="#38bdf8"/>
      <Line title="MEMORY" value={`${(memory.physical / 1024 / 1024 / 1024).toFixed(1)} GB`} color="#a78bfa"/>
      <Line title="UPTIME" value={`${uptimeHours}h`} color="#34d399"/>
    </vstack>
  );
} else {
  $render(
    <hstack frame="max" spacing="18" padding="16" background="#0f172a">
      <vstack alignment="leading" spacing="6">
        <hstack spacing="7"><icon systemName="desktopcomputer" size="19" color="#60a5fa"/><text font="caption" weight="bold" color="#93c5fd">SYSTEM</text></hstack>
        <text font="title2" weight="bold" color="white">{$system.platform().toUpperCase()}</text>
        <text font="caption2" color="#64748b">{$system.osVersionString()}</text>
      </vstack>
      <spacer/>
      <vstack alignment="leading" spacing="7">
        <stat title="ACTIVE CPU" value={`${activeCpu} / ${cpuCount}`} color="#38bdf8"/>
        <stat title="MEMORY" value={`${(memory.physical / 1024 / 1024 / 1024).toFixed(1)} GB`} color="#a78bfa"/>
        <stat title="UPTIME" value={`${uptimeHours}h`} color="#34d399"/>
      </vstack>
    </hstack>
  );
}
