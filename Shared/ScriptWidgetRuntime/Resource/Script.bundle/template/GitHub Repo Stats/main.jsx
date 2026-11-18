// Public counts only. Configure owner/repository and accent in Records & Configuration.
if (!$import("lib/repository.js"))
  throw new Error("Install the complete GitHub Repo Stats template.");
const config = repositoryStats.options(
  $storage.getString("recordTemplate.config.v1"),
  $getenv("widget-param"),
);
const stats = await repositoryStats.load(
  config,
  Date.now(),
  $getenv("timeline-is-projection") === "true",
);
const size = $getenv("widget-size"),
  small = size === "small",
  dark = $device.isdarkmode();
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
if (size === "accessoryInline") {
  $render(
    <text>{stats.available ? `${displayRepository} · ${stats.stars} stars` : stats.heading}</text>,
  );
} else if (size === "accessoryCircular") {
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
