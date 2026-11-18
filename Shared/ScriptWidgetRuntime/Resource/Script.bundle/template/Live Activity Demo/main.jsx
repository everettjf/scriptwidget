// Local state supplied by ScriptWidget's Live Activities screen. Rendering never polls.
// Optional JSON: title, detail, progress+total, endsAt (ISO date). The app updates this state.
const raw = $getenv("live-activity-state") || $getenv("widget-param") || "",
  now = Date.now();
let data = {},
  invalid = false;
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
const deadline = data.endsAt === undefined ? null : Date.parse(data.endsAt),
  expired = deadline !== null && deadline <= now,
  stale = $getenv("live-activity-is-stale") === "true";
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
