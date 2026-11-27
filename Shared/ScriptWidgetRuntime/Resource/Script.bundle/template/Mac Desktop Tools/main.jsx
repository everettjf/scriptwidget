// Open the native Mac tools. In a small widget, the parameter can choose a single tool:
// launcher, system, music, translation, or appearance.
const tools = [
  { id: "launcher", title: "Launcher", icon: "square.grid.2x2" },
  { id: "system", title: "System", icon: "cpu" },
  { id: "music", title: "Music", icon: "music.note" },
  { id: "translation", title: "Translate", icon: "translate" },
  { id: "appearance", title: "Appearance", icon: "sparkles" },
];

const small = $getenv("widget-size") === "small";
const chosen = tools.find((tool) => tool.id === ($getenv("widget-param") || "").trim()) || tools[0];
const dark = $device.isdarkmode();
const background = dark ? "#213146" : "#E9F2FC";
const accent = dark ? "#A7DDFF" : "#174E78";
const destination = (tool) => "scriptwidget://desktop-tools/" + tool.id;
const Tile = ({ tool }) => (
  <link url={destination(tool)}>
    <vstack padding="6" spacing="5">
      <icon systemName={tool.icon} size="20" color={accent} />
      <text font="caption2" color={accent}>
        {tool.title}
      </text>
    </vstack>
  </link>
);
if ($system.platform() !== "macos") {
  $render(
    <vstack frame="max" padding="14" spacing="8" background={background}>
      <icon systemName="desktopcomputer" size="22" color={accent} />
      <text font="caption" color={accent}>
        Desktop Tools opens on Mac.
      </text>
    </vstack>,
  );
} else {
  $render(
    <vstack
      frame="max"
      padding="10"
      spacing="9"
      background={background}
      linkurl={destination(chosen)}
    >
      <text font="headline" color={accent}>
        Desktop Tools
      </text>
      {small ? (
        <Tile tool={chosen} />
      ) : (
        <hstack spacing="4">
          {tools.map((tool) => (
            <Tile tool={tool} />
          ))}
        </hstack>
      )}
    </vstack>,
  );
}
