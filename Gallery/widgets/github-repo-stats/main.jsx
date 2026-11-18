// Public counts only. Configure owner/repository and accent in Records & Configuration.
// Shows the stars, forks and open issues of a public GitHub repository, and a star trend
// in the large size. Try another repository: write owner/name in the widget parameter.
// widget.json must declare the permission "network" with the host api.github.com, and
// "storage" for the saved copy of the counts.

// $import runs another file of this package; lib/repository.js defines `repositoryStats`.
// It returns false when the file is missing.
if (!$import("lib/repository.js"))
  throw new Error("Install the complete GitHub Repo Stats template.");
// The settings: defaults, then what the app saved in $storage, then the widget parameter
// ($getenv("widget-param"), a text you set on each widget you place).
const config = repositoryStats.options(
  $storage.getString("recordTemplate.config.v1"),
  $getenv("widget-param"),
);
// Read the counts: from GitHub when the saved copy is due for a refresh, else from $storage.
// "timeline-is-projection" is "true" when the script runs for a future timeline entry;
// no request is made then.
const stats = await repositoryStats.load(
  config,
  Date.now(),
  $getenv("timeline-is-projection") === "true",
);
// $getenv("widget-size") is the size being drawn, such as "small" or "accessoryInline".
const size = $getenv("widget-size"),
  small = size === "small",
  dark = $device.isdarkmode();
// A long owner/name gets its middle replaced by "…".
const nameLimit = small ? 24 : 40;
const displayRepository =
  stats.repository.length <= nameLimit
    ? stats.repository
    : stats.repository.slice(0, Math.floor(nameLimit / 2) - 1) +
      "…" +
      stats.repository.slice(-Math.floor(nameLimit / 2));
const background = dark ? "#111827" : "#eff6ff",
  text = dark ? "#f8fafc" : "#1e3a8a",
  secondary = dark ? "#cbd5e1" : "#475569",
  accent = { blue: "#2563eb", green: "#15803d", rose: "#be185d" }[config.accent];
// A reusable piece of layout: an icon, a number and a title under it.
const NumberCard = ({ title, value, icon }) => (
  <vstack frame="max,leading" alignment="leading" spacing="4">
    <icon systemName={icon} size="18" color={accent} />
    <text font="title2" weight="bold" color={text}>
      {String(value)}
    </text>
    <text font="caption2" color={secondary}>
      {title}
    </text>
  </vstack>
);
// A line chart of the saved daily star counts; it needs two days of history.
// <chart> takes its points as JSON text: [{ label, value }, …].
const Trend = () =>
  stats.history.length >= 2 ? (
    <vstack frame="max,leading" alignment="leading" spacing="4">
      <text font="caption" color={secondary}>
        Stars · saved daily checks
      </text>
      <chart
        type="line"
        hideXAxis="true"
        hideYAxis="true"
        color={accent}
        frame="max,60"
        data={JSON.stringify(
          stats.history.map((point) => ({
            label: new Date(point.time).toISOString().slice(0, 10),
            value: point.stars,
          })),
        )}
      />
      <text
        font="caption2"
        color={secondary}
      >{`${stats.history.length} recorded days · ${new Date(stats.history[0].time).toISOString().slice(0, 10)} onward`}</text>
    </vstack>
  ) : (
    <text font="caption" color={secondary}>
      Daily star history appears after two recorded days.
    </text>
  );
// Choose a layout for the widget size.
if (size === "accessoryInline") {
  // Lock Screen, inline: one line of text.
  $render(
    <text>{stats.available ? `${displayRepository} · ${stats.stars} stars` : stats.heading}</text>,
  );
} else if (size === "accessoryCircular") {
  // Lock Screen, circular: the star count.
  $render(
    <vstack spacing="0">
      <icon systemName="star.fill" size="16" />
      <text font="caption" weight="bold">
        {stats.available ? String(stats.stars) : "—"}
      </text>
      <text font="caption2">{stats.available ? "stars" : "Open app"}</text>
    </vstack>,
  );
} else if (size === "accessoryRectangular") {
  // Lock Screen, rectangular: three short lines.
  $render(
    <vstack alignment="leading" spacing="1">
      <text font="caption" weight="semibold">
        {displayRepository}
      </text>
      <text font="caption">
        {stats.available ? `${stats.stars} stars · ${stats.forks} forks` : stats.heading}
      </text>
      <text font="caption2">{stats.available ? stats.age : "Check public repository"}</text>
    </vstack>,
  );
} else if (!stats.available) {
  // No counts to show: say why (offline, rate limit, unknown repository).
  $render(
    <vstack frame="max" background={background} padding={small ? "12" : "16"} spacing="8">
      <icon systemName="network" size="26" color={accent} />
      <text font="headline" weight="bold" color={text}>
        {stats.heading}
      </text>
      <text font="caption" color={secondary}>
        {stats.detail}
      </text>
    </vstack>,
  );
} else if (small) {
  // Small widget: only the star count.
  $render(
    <vstack frame="max" alignment="leading" padding="14" spacing="5" background={background}>
      <text font="caption" color={secondary}>
        {displayRepository}
      </text>
      <spacer />
      <hstack spacing="5">
        <icon systemName="star.fill" size="18" color={accent} />
        <text font="largeTitle" weight="bold" color={text}>
          {String(stats.stars)}
        </text>
      </hstack>
      <text font="caption2" color={secondary}>
        {stats.age}
      </text>
      <text font="caption2" color={secondary}>
        {stats.status}
      </text>
    </vstack>,
  );
} else if (size === "medium") {
  // Medium widget: the three numbers in a row.
  $render(
    <vstack frame="max" alignment="leading" padding="14" spacing="7" background={background}>
      <text font="headline" weight="semibold" color={text}>
        {displayRepository}
      </text>
      <hstack spacing="12">
        <NumberCard title="Stars" value={stats.stars} icon="star.fill" />
        <NumberCard title="Forks" value={stats.forks} icon="tuningfork" />
        <NumberCard title="Issues + PRs" value={stats.issues} icon="exclamationmark.circle" />
      </hstack>
      <hstack>
        <text font="caption2" color={secondary}>
          {stats.age}
        </text>
        <spacer />
        <text font="caption2" color={secondary}>
          {stats.status}
        </text>
      </hstack>
    </vstack>,
  );
} else {
  // Large and extra large widgets: the three numbers and the trend chart.
  $render(
    <vstack frame="max" alignment="leading" padding="18" spacing="12" background={background}>
      <text font="title3" weight="bold" color={text}>
        {displayRepository}
      </text>
      <spacer />
      <hstack spacing="12">
        <NumberCard title="Stars" value={stats.stars} icon="star.fill" />
        <NumberCard title="Forks" value={stats.forks} icon="tuningfork" />
        <NumberCard title="Issues + PRs" value={stats.issues} icon="exclamationmark.circle" />
      </hstack>
      <spacer />
      <Trend />
      <spacer />
      <text font="caption" color={secondary}>
        {stats.age}
      </text>
      <text font="caption2" color={secondary}>
        {stats.status}
      </text>
    </vstack>,
  );
}
