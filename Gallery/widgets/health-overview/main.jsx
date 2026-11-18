// Real read-only HealthKit summaries. Declare health; review access in app Settings.
// Parameter: overview (default), sleep, activity or workouts. Nothing is saved.
// Web Studio supplies editable samples; native widgets never seed Health data.
const family = $getenv("widget-size"),
  small = family === "small";
const accessory = family.startsWith("accessory"),
  dark = $device.isdarkmode();
const mode = $getenv("widget-param").trim() || "overview";
const background = accessory ? "clear" : dark ? "#17242b" : "#f2f8f8";
const foreground = accessory ? "primary" : dark ? "#eaf4f4" : "#23444b";
const secondary = accessory ? "secondary" : dark ? "#a6bec4" : "#58737c";
const colors = ["#e67f92", "#70b58b", "#6aadd3"];
let sleep = null,
  activity = null,
  workouts = null,
  errors = 0;
const supported = $health.isAvailable();
if (!["overview", "sleep", "activity", "workouts"].includes(mode))
  throw new Error("Use overview, sleep, activity or workouts as the widget parameter.");
if (supported) {
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
function duration(seconds) {
  const minutes = Math.round(seconds / 60);
  return `${Math.floor(minutes / 60)}h ${String(minutes % 60).padStart(2, "0")}m`;
}
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
const rings = activity?.hasSamples ? [activity.move, activity.exercise, activity.stand] : [];
const progress = (index) =>
  rings[index]?.goal > 0 ? Math.min(1, Math.max(0, rings[index].value / rings[index].goal)) : 0;
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
