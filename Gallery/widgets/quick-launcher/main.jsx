// Configure web links, app URLs and saved Shortcuts in Records & Configuration.
if (!$import("lib/launcher.js")) throw new Error("Install the complete Quick Launcher template.");
const config = quickLauncher.options(
  $storage.getString("recordTemplate.config.v1"),
  $getenv("widget-param"),
);
const size = $getenv("widget-size"),
  dark = $device.isdarkmode(),
  small = size === "small";
const background = dark ? "#111827" : "#eff6ff",
  text = dark ? "#f8fafc" : "#1e3a8a",
  muted = dark ? "#cbd5e1" : "#475569",
  accent = { blue: "#2563eb", green: "#15803d", rose: "#be185d" }[config.accent];
const Tile = ({ item }) => (
  <link url={item.url}>
    <vstack frame="max" padding="8" spacing="5">
      <icon systemName={item.icon} size={small ? "20" : "26"} color={accent} />
      <text font="caption" color={text}>
        {item.title}
      </text>
    </vstack>
  </link>
);
if (size === "accessoryInline") {
  const first = config.items[0];
  $render(
    <link url={first.url} linkurl={first.url}>
      <text>{first.title}</text>
    </link>,
  );
} else if (size === "accessoryCircular") {
  const first = config.items[0];
  $render(
    <link url={first.url} linkurl={first.url}>
      <vstack spacing="1">
        <icon systemName={first.icon} size="20" />
        <text font="caption2">{first.title}</text>
      </vstack>
    </link>,
  );
} else if (size === "accessoryRectangular") {
  const first = config.items[0];
  $render(
    <link url={first.url} linkurl={first.url}>
      <hstack spacing="8">
        <icon systemName={first.icon} size="20" />
        <vstack alignment="leading" spacing="1">
          <text font="caption">{first.title}</text>
          <text font="caption2">{config.title}</text>
        </vstack>
      </hstack>
    </link>,
  );
} else {
  const columns = small ? 1 : 3,
    limit = small ? 1 : size === "medium" ? 3 : 6,
    items = config.items.slice(0, limit),
    rows = [];
  for (let i = 0; i < items.length; i += columns) rows.push(items.slice(i, i + columns));
  $render(
    <vstack
      frame="max"
      linkurl={config.items[0].url}
      alignment="leading"
      padding={small ? "10" : "14"}
      spacing={small ? "2" : "8"}
      background={background}
    >
      <text font={small ? "caption" : "headline"} weight="semibold" color={text}>
        {config.title}
      </text>
      {rows.map((row) => (
        <hstack frame="max" spacing="4">
          {row.map((item) => (
            <Tile item={item} />
          ))}
        </hstack>
      ))}
      {!small && size !== "medium" && (
        <text font="caption2" color={muted}>
          Tap a link · test and reorder in ScriptWidget
        </text>
      )}
    </vstack>,
  );
}
