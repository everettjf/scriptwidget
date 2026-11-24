// Battery and disk are snapshots taken when the widget refreshes.
// The memory figure is installed capacity in GiB.
const battery = $device.battery();
const total = $device.totalDiskSpace();
const free = $device.freeDiskSpace();
const memory = $system.memory().physical;
const gib = 1024 ** 3;
const charge =
  battery?.state !== "unknown" &&
  Number.isFinite(battery?.level) &&
  battery.level >= 0 &&
  battery.level <= 1
    ? battery.level
    : null;
const disk =
  Number.isFinite(total) && total > 0 && Number.isFinite(free) && free >= 0 && free <= total
    ? (total - free) / total
    : null;
const small = $getenv("widget-size") === "small";
const dark = $device.isdarkmode();
const background = dark ? "#142D2D" : "#E4F3EF";
const ink = dark ? "#E5FCF5" : "#123D38";
const muted = dark ? "#A9D1C8" : "#406761";
const green = dark ? "#78E4BC" : "#096B55";
const blue = dark ? "#9BCFFF" : "#225B92";
const track = dark ? "#355552" : "#C4DDD6";

// Missing measurements keep the track empty and show a dash.
const Meter = ({ title, value, color }) => (
  <vstack spacing="4">
    <zstack>
      <ring
        value={value ?? 0}
        thickness="4"
        color={color}
        trackColor={track}
        frame={small ? "43" : "53"}
      />
      <text font="caption2" weight="bold" color={ink}>
        {value === null ? "—" : `${Math.round(value * 100)}%`}
      </text>
    </zstack>
    <text font="caption2" color={muted}>
      {title}
    </text>
  </vstack>
);
$render(
  <vstack frame="max" alignment="leading" padding="14" spacing="5" background={background}>
    <hstack spacing="5">
      <icon systemName="gauge.with.dots.needle.50percent" size="14" color={green} />
      <text font="caption" color={muted}>
        Desk vitals
      </text>
    </hstack>
    <spacer />
    <hstack spacing={small ? "12" : "22"}>
      <Meter title="Battery" value={charge} color={green} />
      <Meter title="Disk used" value={disk} color={blue} />
    </hstack>
    <spacer />
    <text font="caption" color={ink}>
      {Number.isFinite(memory) && memory > 0 ? `${(memory / gib).toFixed(1)} GiB RAM` : "— RAM"}
    </text>
    {!small && (
      <text font="caption2" color={muted}>
        Installed memory
      </text>
    )}
  </vstack>,
);
