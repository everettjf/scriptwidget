// Local state supplied by ScriptWidget's Live Activities screen. Rendering never polls.
// Optional JSON: title, detail, progress+total, endsAt (ISO date). The app updates this state.
// Shows a Live Activity: a title, a detail line, and a countdown or a progress bar.
// Try starting it from the Live Activities screen of the app with a state such as
// {"title":"Tea","detail":"Steeping","endsAt":"2026-03-08T12:05:00Z"}.

// $getenv("live-activity-state") is the state text the app gave this activity. When it
// is empty, the widget parameter is used instead.
const raw = $getenv("live-activity-state") || $getenv("widget-param") || "",
  now = Date.now();
let data = {},
  invalid = false;
// Check the state: only the five known keys, each of the right type and size.
// Anything else makes the state invalid, and the widget says so.
try {
  if (raw) {
    if (typeof raw !== "string" || raw.length > 4096) throw new Error();
    data = JSON.parse(raw);
  }
  if (
    !data ||
    typeof data !== "object" ||
    Array.isArray(data) ||
    Object.keys(data).some(
      (key) => !["title", "detail", "progress", "total", "endsAt"].includes(key),
    )
  )
    throw new Error();
  if (
    data.title !== undefined &&
    (typeof data.title !== "string" || data.title.length < 1 || data.title.length > 40)
  )
    throw new Error();
  if (data.detail !== undefined && (typeof data.detail !== "string" || data.detail.length > 80))
    throw new Error();
  // progress and total come together: whole numbers with 0 ≤ progress ≤ total.
  if (data.progress !== undefined || data.total !== undefined) {
    if (
      !Number.isInteger(data.progress) ||
      !Number.isInteger(data.total) ||
      data.total < 1 ||
      data.total > 10000 ||
      data.progress < 0 ||
      data.progress > data.total
    )
      throw new Error();
  }
  // endsAt is an ISO date with a time zone, such as 2026-03-08T12:05:00Z.
  if (
    data.endsAt !== undefined &&
    (typeof data.endsAt !== "string" ||
      !/^\d{4}-\d{2}-\d{2}T.*(?:Z|[+-]\d{2}:\d{2})$/.test(data.endsAt) ||
      !Number.isFinite(Date.parse(data.endsAt)))
  )
    throw new Error();
} catch {
  invalid = true;
  data = {};
}
// `deadline` is the end time in milliseconds, or null without one.
// "live-activity-is-stale" is "true" when the system marks the activity as stale.
const deadline = data.endsAt === undefined ? null : Date.parse(data.endsAt),
  expired = deadline !== null && deadline <= now,
  stale = $getenv("live-activity-is-stale") === "true";
// The texts to show, with a fallback for every case.
const title = invalid
    ? "Invalid activity state"
    : data.title || (raw ? "Live activity" : "Ready to start"),
  detail = invalid
    ? "Update valid JSON in ScriptWidget."
    : expired
      ? "Time is up"
      : data.detail ||
        (raw ? "Updated from the app" : "Start or update this activity in ScriptWidget.");
const hasProgress = data.progress !== undefined,
  summary = invalid
    ? "Check state"
    : hasProgress
      ? `${data.progress} / ${data.total}`
      : expired
        ? "Finished"
        : stale
          ? "Needs update"
          : raw
            ? "Active"
            : "Ready";
// A timer while the deadline lies ahead, else the summary text.
// <date style="timer"> shows the time left and keeps counting on its own.
const Countdown = () =>
  deadline !== null && !expired && !invalid ? (
    <date date={deadline} style="timer" font="title2" color="#1e3a8a" />
  ) : (
    <text font="title2" weight="bold" color="#1e3a8a">
      {summary}
    </text>
  );
// Small: the state and the title; the detail needs the width of the medium widget.
if ($getenv("widget-size") === "small")
  $render(
    <vstack frame="max" alignment="leading" spacing="6" padding="14" background="#eff6ff">
      <hstack>
        <icon
          systemName={invalid ? "exclamationmark.circle.fill" : "timer"}
          size="22"
          color="#2563eb"
        />
        <spacer />
      </hstack>
      {deadline !== null && !expired && !invalid ? (
        <date date={deadline} style="timer" font="title3" color="#1e3a8a" />
      ) : (
        <text font="headline" weight="bold" color="#1e3a8a">
          {summary}
        </text>
      )}
      <text font="caption" color="#475569">
        {title}
      </text>
      {hasProgress && <progress value={data.progress / data.total} color="#2563eb" />}
    </vstack>,
  );
else
  // Other sizes, and the Lock Screen view of the Live Activity: icon, texts, countdown.
  $render(
    <hstack frame="max" spacing="14" padding="16" background="#eff6ff">
      <icon
        systemName={invalid ? "exclamationmark.circle.fill" : "timer"}
        size="30"
        color="#2563eb"
      />
      <vstack frame="max,leading" alignment="leading" spacing="5">
        <text font="headline" weight="bold" color="#1e3a8a">
          {title}
        </text>
        <text font="caption" color="#475569">
          {detail}
        </text>
        {hasProgress && <progress value={data.progress / data.total} color="#2563eb" />}
        {stale && !expired && (
          <text font="caption2" color="#92400e">
            Data needs an update
          </text>
        )}
      </vstack>
      <Countdown />
    </hstack>,
  );
// $dynamic_island gives the views for the Dynamic Island: four regions of the expanded
// form, the two sides of the compact form, and the minimal form.
$dynamic_island({
  expanded: {
    leading: (
      <icon systemName={invalid ? "exclamationmark.circle.fill" : "timer"} color="#93c5fd" />
    ),
    trailing:
      deadline !== null && !expired && !invalid ? (
        <date date={deadline} style="timer" font="caption" color="white" />
      ) : (
        <text font="caption" color="white">
          {summary}
        </text>
      ),
    center: (
      <text font="headline" color="white">
        {title}
      </text>
    ),
    bottom: (
      <text font="caption" color="#cbd5e1">
        {detail}
      </text>
    ),
  },
  compactLeading: (
    <icon systemName={invalid ? "exclamationmark.circle.fill" : "timer"} color="#93c5fd" />
  ),
  compactTrailing:
    deadline !== null && !expired && !invalid ? (
      <date date={deadline} style="timer" font="caption2" color="white" />
    ) : (
      <text font="caption2" color="white">
        {invalid ? "!" : hasProgress ? `${data.progress}/${data.total}` : expired ? "Done" : "•"}
      </text>
    ),
  minimal: <icon systemName={invalid ? "exclamationmark.circle.fill" : "timer"} color="#93c5fd" />,
});
