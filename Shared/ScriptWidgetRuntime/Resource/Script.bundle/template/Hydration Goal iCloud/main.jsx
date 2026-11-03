// Separate iCloud example. It does not migrate or change Hydration Goal's local records.
// Connect this installation to the same iCloud Data store ID on each device.
if (!$import("lib/cloud-hydration.js")) throw new Error("Install the complete template, including lib/cloud-hydration.js.");
const size = $getenv("widget-size");
const parameter = ($getenv("widget-param") || "").trim();
let options = {goal: 8, glassML: 250};
if (parameter) {
  try { options = {...options, ...JSON.parse(parameter)}; }
  catch (_) { throw new Error('Use a JSON object such as {"goal":8,"glassML":250}.'); }
  if (!options || Array.isArray(options) || Object.keys(options).some((key) => !["goal", "glassML"].includes(key))) {
    throw new Error("Hydration settings accept goal and glassML only.");
  }
}
const {goal, glassML} = options;
if (!Number.isInteger(goal) || goal < 1 || goal > 32 || !Number.isInteger(glassML) || glassML < 25 || glassML > 2000) {
  throw new Error("Set goal to 1–32 glasses and glassML to 25–2000.");
}
async function addGlass() { await cloudHydration.add(glassML); $render(<text>Glass saved locally; iCloud delivery may follow later</text>); }
async function syncRecords() { await cloudHydration.sync(); $render(<text>Cloud exchange requested; delivery may follow later</text>); }

if (size !== "function" && size !== "action") {
  try {
    const {snapshot, data} = await cloudHydration.read();
    const days = cloudHydration.recent(data);
    const today = days[days.length - 1].total;
    const target = goal * glassML;
    const progress = Math.min(1, today / target);
    const dark = $device.isdarkmode();
    const ink = dark ? "#E0F2FE" : "#0C4A6E";
    const muted = dark ? "#7DD3FC" : "#0369A1";
    const background = dark ? "#082F49" : "#F0F9FF";
    const label = `${today} / ${target} mL`;
    const hint = snapshot.state === "conflict" ? "Tap Sync to merge two offline logs" : "Cached on this device · iCloud may be delayed";
    if (size === "accessoryInline") $render(<text>{`Water · ${label}`}</text>);
    else if (size === "accessoryCircular") $render(<gauge value={progress}><text>{`${Math.round(progress * 100)}%`}</text></gauge>);
    else if (size === "accessoryRectangular") $render(<vstack alignment="leading"><label title="Water" systemName="drop.fill"/><text font="caption">{label}</text><progress value={progress}/></vstack>);
    else $render(<vstack frame="max" alignment="leading" padding="14" spacing="8" background={background}>
      <hstack><label title="Water · iCloud" systemName="drop.fill" color={ink}/><spacer/><text font="caption" color={muted}>{days[6].day.slice(5)}</text></hstack>
      {size === "small" ? <vstack alignment="leading" spacing="5"><text font="headline" color={ink}>{label}</text><progress value={progress} color="#0EA5E9"/></vstack> : <hstack spacing="12"><ring value={progress} thickness="7" color="#0EA5E9" trackColor={dark ? "#164E63" : "#BAE6FD"} frame={60}/><text font="headline" color={ink}>{label}</text></hstack>}
      <hstack spacing="14"><button actionID="addGlass"><text font="caption" color={muted}>{`+ ${glassML} mL`}</text></button><button actionID="syncRecords"><text font="caption" color={muted}>Sync</text></button></hstack>
      <text font="caption2" color={muted}>{hint}</text>
      {!(["small", "medium"].includes(size)) && <vstack alignment="leading" spacing="4"><text font="caption" color={muted}>Last 7 days · mL</text>{days.map((day) => <hstack><text font="caption" color={muted}>{day.day.slice(5)}</text><spacer/><text font="caption" color={ink}>{day.recorded ? String(day.total) : "—"}</text></hstack>)}</vstack>}
    </vstack>);
  } catch (error) {
    console.error(String(error));
    $render(<vstack alignment="leading" padding="14" spacing="6"><text font="headline">Hydration Goal iCloud</text><text>Connect iCloud Data in ScriptWidget, then sync.</text><text font="caption">{String(error)}</text></vstack>);
  }
}
