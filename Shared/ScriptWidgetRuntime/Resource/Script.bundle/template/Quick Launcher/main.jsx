// Configure web links, app URLs and saved Shortcuts in Records & Configuration.
//
// This template shows tiles to tap: each <link> opens a web page, an app or a Shortcut.
// Try changing the colors below, or the default links in lib/launcher.js.

// $import runs lib/launcher.js from this package and returns false when that fails.
// The file defines quickLauncher.
if (!$import("lib/launcher.js")) throw new Error("Install the complete Quick Launcher template.");
// Read the saved settings from $storage (widget.json declares the "storage" permission)
// and the widget parameter: the parameter text set for this widget, here optional JSON.
// Every item comes back with a ready-to-open `url`.
const config = quickLauncher.options(
  $storage.getString("recordTemplate.config.v1"),
  $getenv("widget-param"),
);
// The size being drawn, and whether the system is in dark mode.
const size = $getenv("widget-size"),
  dark = $device.isdarkmode(),
  small = size === "small";
// Colors for light and dark mode; the accent color is chosen in the settings.
const background = dark ? "#111827" : "#eff6ff",
  text = dark ? "#f8fafc" : "#1e3a8a",
  muted = dark ? "#cbd5e1" : "#475569",
  accent = { blue: "#2563eb", green: "#15803d", rose: "#be185d" }[config.accent];
// One tile: an icon above a title. Tapping it opens item.url.
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
  // Lock Screen sizes (iPhone and iPad only) show the first link only.
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
  // Home Screen sizes: one tile in the small widget, three in the medium, up to six in the
  // larger ones, in rows of `columns` tiles.
  const columns = small ? 1 : 3,
    limit = small ? 1 : size === "medium" ? 3 : 6,
    items = config.items.slice(0, limit),
    rows = [];
  // Cut the list into rows.
  for (let i = 0; i < items.length; i += columns) rows.push(items.slice(i, i + columns));
  // linkurl on the root element is the fallback target, the first link, for a tap that
  // does not open a tile. frame="max" fills the widget; padding is the space around the
  // content, in points.
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
