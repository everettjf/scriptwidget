//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Focus Countdown (25-minute cycle)
//

const cycleMinutes = 25;
const now = new Date();
const minutesInto = now.getMinutes() % cycleMinutes;
const secondsInto = now.getSeconds();
const elapsed = minutesInto * 60 + secondsInto;
const total = cycleMinutes * 60;
const remaining = total - elapsed;
const progress = elapsed / total;

const mm = Math.floor(remaining / 60);
const ss = Math.floor(remaining % 60);
const timeText = `${mm.toString().padStart(2, "0")}:${ss.toString().padStart(2, "0")}`;

$render(
  <vstack frame="max" background="#1e293b">
    <text font="caption" color="#94a3b8">Focus Timer</text>
    <text font="title2" color="#e2e8f0">{timeText}</text>
    <gauge
      angle="260"
      value={progress}
      thickness="8"
      label={`${Math.round(progress * 100)}%`}
      labelFont="caption"
      title="Session"
      titleFont="caption"
    />
    <text font="caption2" color="#94a3b8">Cycle: {cycleMinutes} min</text>
  </vstack>
);
