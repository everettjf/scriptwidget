//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Focus Countdown (25-minute cycle)
//
// Shows the time left in a 25-minute block, taken from the clock, with a gauge.
// Try changing cycleMinutes.
//

const cycleMinutes = 25;
const now = new Date();
// Minutes into the current block. Blocks are counted from the start of each hour.
const minutesInto = now.getMinutes() % cycleMinutes;
const secondsInto = now.getSeconds();
// Seconds passed and seconds left in the block, and the share that has passed (0 to 1).
const elapsed = minutesInto * 60 + secondsInto;
const total = cycleMinutes * 60;
const remaining = total - elapsed;
const progress = elapsed / total;

// The time left as "MM:SS", for example "04:09".
const mm = Math.floor(remaining / 60);
const ss = Math.floor(remaining % 60);
const timeText = `${mm.toString().padStart(2, "0")}:${ss.toString().padStart(2, "0")}`;

// These numbers are worked out when the script runs.
// frame="max" makes the stack fill the whole widget.
$render(
  <vstack frame="max" background="#1e293b">
    <text font="caption" color="#94a3b8">
      Focus Timer
    </text>
    <text font="title2" color="#e2e8f0">
      {timeText}
    </text>
    {/* <gauge> draws an arc and fills it up to `value`, from 0 to 1. */}
    <gauge
      angle="260"
      value={progress}
      thickness="8"
      label={`${Math.round(progress * 100)}%`}
      labelFont="caption"
      title="Session"
      titleFont="caption"
    />
    <text font="caption2" color="#94a3b8">
      Cycle: {cycleMinutes} min
    </text>
  </vstack>,
);
