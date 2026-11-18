// Separate iCloud example. It does not migrate or change Hydration Goal's local records.
// Connect this installation to the same iCloud Data store ID on each device.
// Shows today's water like Hydration Goal, but keeps the log in iCloud so that several
// devices can share it. Try another goal or glass size with the widget parameter.
// The iCloud API runs on iPhone, iPad and Mac, and on Android with a sync folder the user picks
// (it cannot exchange data with an iPhone); not on Windows or Linux.
// widget.json must declare the permission "icloud"; the buttons need its "actions".

// $import runs another file of this package; lib/cloud-hydration.js defines `cloudHydration`.
// It returns false when the file is missing.
if (!$import("lib/cloud-hydration.js"))
  throw new Error("Install the complete template, including lib/cloud-hydration.js.");
// $getenv("widget-size") is the size being drawn, such as "small" or "accessoryInline".
const size = $getenv("widget-size");
// The optional widget parameter, JSON such as {"goal":8,"glassML":250}.
const parameter = ($getenv("widget-param") || "").trim();
let options = { goal: 8, glassML: 250 };
if (parameter) {
  try {
    options = { ...options, ...JSON.parse(parameter) };
  } catch (_) {
    throw new Error('Use a JSON object such as {"goal":8,"glassML":250}.');
  }
  if (
    !options ||
    Array.isArray(options) ||
    Object.keys(options).some((key) => !["goal", "glassML"].includes(key))
  ) {
    throw new Error("Hydration settings accept goal and glassML only.");
  }
}
// `goal` is in glasses, `glassML` in millilitres per glass.
const { goal, glassML } = options;
if (
  !Number.isInteger(goal) ||
  goal < 1 ||
  goal > 32 ||
  !Number.isInteger(glassML) ||
  glassML < 25 ||
  glassML > 2000
) {
  throw new Error("Set goal to 1–32 glasses and glassML to 25–2000.");
}
// The two functions below are named by the "actions" in widget.json; a tap on a <button>
// with that actionID calls them. They are async because the iCloud calls must be awaited.
async function addGlass() {
  await cloudHydration.add(glassML);
  $render(<text>Glass saved locally; iCloud delivery may follow later</text>);
}
async function syncRecords() {
  await cloudHydration.sync();
  $render(<text>Cloud exchange requested; delivery may follow later</text>);
}

// A tap runs this script with the size "function" or "action": draw no widget then.
if (size !== "function" && size !== "action") {
  try {
    // Read the data. `snapshot` is what iCloud returned and `data` the checked log.
    // `days` holds the last 7 days and ends with today; the totals are in mL.
    const { snapshot, data } = await cloudHydration.read();
    const days = cloudHydration.recent(data);
    const today = days[days.length - 1].total;
    const target = goal * glassML;
    const progress = Math.min(1, today / target);
    const dark = $device.isdarkmode();
    const ink = dark ? "#E0F2FE" : "#0C4A6E";
    const muted = dark ? "#7DD3FC" : "#0369A1";
    const background = dark ? "#082F49" : "#F0F9FF";
    const label = `${today} / ${target} mL`;
    // The state is "conflict" when two devices saved different logs while offline.
    const hint =
      snapshot.state === "conflict"
        ? "Tap Sync to merge two offline logs"
        : "Cached on this device · iCloud may be delayed";
    // Choose a layout: the three Lock Screen sizes first, then the Home Screen sizes.
    if (size === "accessoryInline") $render(<text>{`Water · ${label}`}</text>);
    else if (size === "accessoryCircular")
      $render(
        <gauge value={progress}>
          <text>{`${Math.round(progress * 100)}%`}</text>
        </gauge>,
      );
    else if (size === "accessoryRectangular")
      $render(
        <vstack alignment="leading">
          <label title="Water" systemName="drop.fill" />
          <text font="caption">{label}</text>
          <progress value={progress} />
        </vstack>,
      );
    else
      $render(
        <vstack frame="max" alignment="leading" padding="14" spacing="8" background={background}>
          <hstack>
            <label title="Water · iCloud" systemName="drop.fill" color={ink} />
            <spacer />
            <text font="caption" color={muted}>
              {days[6].day.slice(5)}
            </text>
          </hstack>
          {/* Small widget: a progress bar. Other sizes: a ring next to the text. */}
          {size === "small" ? (
            <vstack alignment="leading" spacing="5">
              <text font="headline" color={ink}>
                {label}
              </text>
              <progress value={progress} color="#0EA5E9" />
            </vstack>
          ) : (
            <hstack spacing="12">
              <ring
                value={progress}
                thickness="7"
                color="#0EA5E9"
                trackColor={dark ? "#164E63" : "#BAE6FD"}
                frame={60}
              />
              <text font="headline" color={ink}>
                {label}
              </text>
            </hstack>
          )}
          <hstack spacing="14">
            <button actionID="addGlass">
              <text font="caption" color={muted}>{`+ ${glassML} mL`}</text>
            </button>
            <button actionID="syncRecords">
              <text font="caption" color={muted}>
                Sync
              </text>
            </button>
          </hstack>
          <text font="caption2" color={muted}>
            {hint}
          </text>
          {/* Large sizes also list the 7 days. day.day.slice(5) is the MM-DD part. */}
          {!["small", "medium"].includes(size) && (
            <vstack alignment="leading" spacing="4">
              <text font="caption" color={muted}>
                Last 7 days · mL
              </text>
              {days.map((day) => (
                <hstack>
                  <text font="caption" color={muted}>
                    {day.day.slice(5)}
                  </text>
                  <spacer />
                  <text font="caption" color={ink}>
                    {day.recorded ? String(day.total) : "—"}
                  </text>
                </hstack>
              ))}
            </vstack>
          )}
        </vstack>,
      );
  } catch (error) {
    // Reading failed, for example because iCloud Data is not connected: say what to do.
    console.error(String(error));
    $render(
      <vstack alignment="leading" padding="14" spacing="6">
        <text font="headline">Hydration Goal iCloud</text>
        <text>Connect iCloud Data in ScriptWidget, then sync.</text>
        <text font="caption">{String(error)}</text>
      </vstack>,
    );
  }
}
