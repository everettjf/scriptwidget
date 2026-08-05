//
// ScriptWidget
// https://xnu.app/scriptwidget
//
// Meeting Countdown
// widget-param: "2026-02-01 09:30" or ISO string
//

const defaultTarget = new Date(Date.now() + 90 * 60000).toISOString();
const param = ($getenv("widget-param") || defaultTarget).trim();
let target = null;

if (param) {
  const normalized = param.includes("T") ? param : param.replace(" ", "T");
  const parsed = new Date(normalized);
  if (!Number.isNaN(parsed.getTime())) {
    target = parsed;
  }
}

if (!target) {
  $render(
    <vstack frame="max" background="#0f172a" padding="14">
      <text font="caption" color="#94a3b8">Meeting Countdown</text>
      <text font="title3" color="#e2e8f0">Set widget-param</text>
      <text font="caption2" color="#64748b">Example: 2026-02-01 09:30</text>
    </vstack>
  );
} else {
  const now = new Date();
  const diffMs = target.getTime() - now.getTime();
  const diffMin = Math.max(0, Math.floor(diffMs / 60000));
  const diffHour = Math.floor(diffMin / 60);
  const diffDay = Math.floor(diffHour / 24);
  const hours = diffHour % 24;
  const minutes = diffMin % 60;

  $render(
    <vstack frame="max" alignment="leading" spacing="7" padding="14" background="#1e293b">
      <hstack frame="max"><text font="caption" color="#93c5fd">NEXT MEETING</text><spacer/><icon systemName="video.fill" size="19" color="#60a5fa"/></hstack>
      <spacer/><text font="largeTitle" weight="bold" color="white">{diffDay > 0 ? `${diffDay}d ${hours}h` : `${hours}h ${minutes}m`}</text>
      <text font="caption" color="#cbd5e1">Starts {target.toLocaleTimeString([], {hour:"2-digit", minute:"2-digit"})}</text><spacer/>
    </vstack>
  );
}
