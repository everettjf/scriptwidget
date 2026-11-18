// Real read-only HealthKit summaries. Declare health; review access in app Settings.
// Parameter: overview (default), sleep, activity or workouts. Nothing is saved.
// Web Studio supplies editable samples; native widgets never seed Health data.
// Shows the sleep of the last 24 hours, today's activity rings and recent workouts.
// Try the widget parameter (sleep, activity or workouts), or change `colors`.
// $health runs on iPhone and iPad, and on Android through Health Connect (no ring goals
// or stand time); not on Mac, Windows or Linux.
// widget.json must declare the permission "health".

// $getenv("widget-size") is the size being drawn: "small", "medium", "large",
// "extraLarge", or a Lock Screen size whose name starts with "accessory".
const family = $getenv("widget-size"),
  small = family === "small";
const accessory = family.startsWith("accessory"),
  dark = $device.isdarkmode();
// $getenv("widget-param") is the optional widget parameter, a text you set on each widget.
const mode = $getenv("widget-param").trim() || "overview";
// Lock Screen sizes get a clear background and the system's own text colors.
const background = accessory ? "clear" : dark ? "#17242b" : "#f2f8f8";
const foreground = accessory ? "primary" : dark ? "#eaf4f4" : "#23444b";
const secondary = accessory ? "secondary" : dark ? "#a6bec4" : "#58737c";
// The ring colors: move, exercise, stand.
const colors = ["#e67f92", "#70b58b", "#6aadd3"];
// Read the data. A part stays null when it is not asked for or cannot be read.
let sleep = null,
  activity = null,
  workouts = null,
  errors = 0;
// isAvailable() is false on a system without Health data; the calls below would fail there.
const supported = $health.isAvailable();
if (!["overview", "sleep", "activity", "workouts"].includes(mode))
  throw new Error("Use overview, sleep, activity or workouts as the widget parameter.");
if (supported) {
  // `await` waits for the answer. A failed read is counted and the rest still shows.
  if (mode === "overview" || mode === "sleep") {
    try {
      sleep = await $health.sleepSummary();
    } catch {
      errors++;
    }
  }
  if (mode === "overview" || mode === "activity") {
    try {
      activity = await $health.activitySummary();
    } catch {
      errors++;
    }
  }
  if (mode === "overview" || mode === "workouts") {
    try {
      workouts = await $health.workouts();
    } catch {
      errors++;
    }
  }
}
// Seconds as text: 27000 becomes "7h 30m".
function duration(seconds) {
  const minutes = Math.round(seconds / 60);
  return `${Math.floor(minutes / 60)}h ${String(minutes % 60).padStart(2, "0")}m`;
}
// The text for each value, or a dash. hasSamples is false when Health returned nothing,
// which can also mean that the data was not shared with ScriptWidget.
const sleeping = sleep?.hasSamples && sleep.totalSleepSeconds > 0;
const sleepValue = sleeping ? duration(sleep.totalSleepSeconds) : "—";
const move = activity?.hasSamples ? activity.move : null;
const moveValue = move ? `${Math.round(move.value)} ${move.unit}` : "—";
const recent = workouts?.items?.[0];
const workoutValue = workouts?.hasSamples ? String(workouts.items.length) : "—";
const title =
  mode === "sleep"
    ? "Sleep summary"
    : mode === "activity"
      ? "Activity today"
      : mode === "workouts"
        ? "Recent workouts"
        : "Health overview";
// The three activity rings. progress(index) is value / goal, kept between 0 and 1.
const rings = activity?.hasSamples ? [activity.move, activity.exercise, activity.stand] : [];
const progress = (index) =>
  rings[index]?.goal > 0 ? Math.min(1, Math.max(0, rings[index].value / rings[index].goal)) : 0;
// Three rings inside each other; `side` is the outer size in points.
// <zstack> puts its children on top of each other.
const Rings = ({ side }) => (
  <zstack frame={`${side},${side}`}>
    <ring
      value={progress(0)}
      thickness="7"
      color={colors[0]}
      trackColor={dark ? "#42333d" : "#f4dfe5"}
      frame={`${side},${side}`}
    />
    <ring
      value={progress(1)}
      thickness="7"
      color={colors[1]}
      trackColor={dark ? "#284239" : "#dcefe3"}
      frame={`${side - 22},${side - 22}`}
    />
    <ring
      value={progress(2)}
      thickness="7"
      color={colors[2]}
      trackColor={dark ? "#2a3d49" : "#dcecf5"}
      frame={`${side - 44},${side - 44}`}
    />
  </zstack>
);
// A reusable piece of layout: a small label with its value under it.
const Metric = ({ label, value }) => (
  <vstack alignment="leading" spacing="1">
    <text font="caption2" color={secondary}>
      {label}
    </text>
    <text font="headline" color={foreground}>
      {value}
    </text>
  </vstack>
);
// Nothing to show: there is no Health data on this system, or nothing could be read.
if (!supported || (!sleep && !activity && !workouts)) {
  const message = !supported ? "Use a Health-capable device." : "Review access in app Settings.";
  $render(
    accessory ? (
      <text>Health · Open app</text>
    ) : (
      <vstack frame="max" padding="14" spacing="7" alignment="leading" background={background}>
        <icon systemName="heart" size="22" color={colors[0]} />
        <text font="headline" color={foreground}>
          Health setup
        </text>
        <text font="caption2" frame="max,32" color={secondary}>
          {small
            ? !supported
              ? "Health unavailable\non this device."
              : "Review Health in\napp Settings."
            : message}
        </text>
        <spacer />
        <text font="caption2" color={secondary}>
          {small ? "Read-only" : "Read-only · Apple Health"}
        </text>
      </vstack>
    ),
  );
} else if (family === "accessoryInline") {
  // Lock Screen, inline: one line of text.
  $render(
    <text>
      {mode === "activity"
        ? `Move ${moveValue}`
        : mode === "workouts"
          ? `${workoutValue} workouts · 7d`
          : `Sleep ${sleepValue}`}
    </text>,
  );
} else if (family === "accessoryCircular") {
  // Lock Screen, circular: an icon and one value.
  $render(
    <vstack spacing="2">
      <icon
        systemName={mode === "workouts" ? "figure.run" : mode === "activity" ? "flame" : "moon.zzz"}
        size="18"
      />
      <text font="caption2">
        {mode === "activity"
          ? moveValue
          : mode === "workouts"
            ? workoutValue
            : sleeping
              ? `${(sleep.totalSleepSeconds / 3600).toFixed(1)}h`
              : "—"}
      </text>
    </vstack>,
  );
} else if (accessory) {
  // Lock Screen, rectangular: a title and one value.
  $render(
    <vstack alignment="leading" spacing="3">
      <text font="headline">{title}</text>
      <text font="caption">
        {mode === "activity"
          ? moveValue
          : mode === "workouts"
            ? `${workoutValue} · last 7d`
            : sleepValue}
      </text>
    </vstack>,
  );
} else if (mode === "sleep" && family === "medium") {
  // Sleep, medium widget: the total on the left, the sleep stages on the right.
  $render(
    <hstack frame="max" padding="14" spacing="18" background={background}>
      <vstack alignment="leading" spacing="5">
        <text font="caption" color={secondary}>
          SLEEP · LAST 24H
        </text>
        <text font="title2" weight="bold" color={foreground}>
          {sleepValue}
        </text>
        <text font="caption2" color={secondary}>
          {sleep?.truncated
            ? "Partial window"
            : sleep?.conflictSeconds > 0
              ? "Stage overlap"
              : sleeping
                ? "Known sleep intervals"
                : "No shared stages"}
        </text>
      </vstack>
      <spacer />
      <vstack alignment="leading" spacing="4">
        {["core", "deep", "rem"].map((stage) => (
          <Metric
            label={stage.toUpperCase()}
            value={sleeping ? duration(sleep.stages[stage]) : "—"}
          />
        ))}
      </vstack>
    </hstack>,
  );
} else if (mode === "sleep") {
  // Sleep, other sizes.
  $render(
    <vstack frame="max" padding="14" spacing="7" alignment="leading" background={background}>
      <text font="caption" color={secondary}>
        SLEEP · LAST 24H
      </text>
      <spacer />
      <text font={small ? "title2" : "largeTitle"} weight="bold" color={foreground}>
        {sleepValue}
      </text>
      <text font="caption2" color={secondary}>
        {sleep?.truncated
          ? "Partial sample window"
          : sleep?.conflictSeconds > 0
            ? "Stage overlap"
            : sleeping
              ? "Known sleep intervals"
              : "No shared sleep stages"}
      </text>
      {/* Larger sizes also list the stages. Each one is a number of seconds. */}
      {!small && sleeping && (
        <hstack spacing="14">
          {["core", "deep", "rem"].map((stage) => (
            <Metric label={stage.toUpperCase()} value={duration(sleep.stages[stage])} />
          ))}
        </hstack>
      )}
      <spacer />
      <text font="caption2" color={secondary}>
        {small ? "Read-only" : "Apple Health · Read-only"}
      </text>
    </vstack>,
  );
} else if (mode === "activity" && family === "medium") {
  // Activity, medium widget: the rings on the left, the numbers on the right.
  $render(
    <hstack frame="max" padding="14" spacing="18" background={background}>
      <Rings side={96} />
      <vstack alignment="leading" spacing="6">
        <text font="caption" color={secondary}>
          ACTIVITY · TODAY
        </text>
        <text font="headline" color={foreground}>
          {moveValue}
        </text>
        <text font="caption" color={secondary}>
          {activity?.hasSamples
            ? `Exercise ${Math.round(activity.exercise.value)} min`
            : "No shared activity"}
        </text>
        <text font="caption" color={secondary}>
          {activity?.hasSamples
            ? `Stand ${Math.round(activity.stand.value)} hrs`
            : "Goals unavailable"}
        </text>
      </vstack>
      <spacer />
    </hstack>,
  );
} else if (mode === "activity") {
  // Activity, other sizes.
  $render(
    <vstack frame="max" padding="14" spacing="6" background={background}>
      <text font="caption" color={secondary}>
        ACTIVITY · TODAY
      </text>
      <Rings side={small ? 76 : 100} />
      <text font="headline" color={foreground}>
        {moveValue}
      </text>
      {!small && (
        <hstack spacing="14">
          <Metric
            label="EXERCISE"
            value={activity?.hasSamples ? `${Math.round(activity.exercise.value)} min` : "—"}
          />
          <Metric
            label="STAND"
            value={activity?.hasSamples ? `${Math.round(activity.stand.value)} hrs` : "—"}
          />
        </hstack>
      )}
    </vstack>,
  );
} else if (mode === "workouts") {
  // Workouts: the first one in the list. Its duration is in seconds.
  $render(
    <vstack frame="max" padding="14" spacing="7" alignment="leading" background={background}>
      <text font="caption" color={secondary}>
        WORKOUTS · LAST 7D
      </text>
      <spacer />
      <text font={small ? "headline" : "title2"} weight="bold" color={foreground}>
        {recent ? recent.activity : "—"}
      </text>
      <text font="headline" color={foreground}>
        {recent ? `${Math.round(recent.duration / 60)} min` : "None shared"}
      </text>
      {/* Distance and energy are null when a workout has none; filter(Boolean) drops them. */}
      {!small && recent && (
        <text font="caption" color={secondary}>
          {[
            recent.distanceMeters === null
              ? null
              : `${(recent.distanceMeters / 1000).toFixed(1)} km`,
            recent.energyKcal === null ? null : `${Math.round(recent.energyKcal)} kcal`,
          ]
            .filter(Boolean)
            .join(" · ")}
        </text>
      )}
      <spacer />
      <text font="caption2" color={secondary}>
        {workouts?.truncated
          ? small
            ? "More available"
            : "More results not shown"
          : small
            ? "Read-only"
            : "Apple Health · Read-only"}
      </text>
    </vstack>,
  );
} else if (small) {
  // Overview, small widget: sleep and move only.
  $render(
    <vstack frame="max" padding="14" spacing="6" alignment="leading" background={background}>
      <text font="caption" color={secondary}>
        HEALTH SNAPSHOT
      </text>
      <spacer />
      <text font="title2" weight="bold" color={foreground}>
        {sleepValue}
      </text>
      <text font="caption2" color={secondary}>
        Sleep · last 24h
      </text>
      <spacer />
      <text font="caption" color={foreground}>
        {move ? `Move ${moveValue}` : "No shared activity"}
      </text>
      <text font="caption2" color={secondary}>
        {errors ? "Some data unavailable" : "Apple Health"}
      </text>
    </vstack>,
  );
} else if (family === "medium") {
  // Overview, medium widget: the rings and three values.
  $render(
    <vstack frame="max" padding="14" spacing="8" alignment="leading" background={background}>
      <text font="caption" color={secondary}>
        HEALTH SNAPSHOT
      </text>
      <hstack spacing="18">
        <Rings side={90} />
        <vstack alignment="leading" spacing="5">
          <Metric label="SLEEP · LAST 24H" value={sleepValue} />
          <Metric label="MOVE · TODAY" value={moveValue} />
          <Metric label="WORKOUTS · LAST 7D" value={workoutValue} />
        </vstack>
        <spacer />
      </hstack>
    </vstack>,
  );
} else {
  // Overview, large and extra large widgets.
  $render(
    <vstack frame="max" padding="18" spacing="12" background={background}>
      <text font="headline" color={foreground}>
        Health overview
      </text>
      <Rings side={130} />
      <hstack spacing="30">
        <Metric label="SLEEP · LAST 24H" value={sleepValue} />
        <Metric label="MOVE · TODAY" value={moveValue} />
      </hstack>
      <text font="caption" color={foreground}>
        {recent
          ? `${recent.activity} · ${Math.round(recent.duration / 60)} min`
          : "No shared workouts in 7d"}
      </text>
      <spacer />
      <text font="caption2" color={secondary}>
        {errors ? "Some data unavailable" : "Apple Health · Read-only"}
      </text>
    </vstack>,
  );
}
