// Public SwiftUI material blurs these shapes inside the widget, not the wallpaper.
// The system supplies Clear/Tinted backgrounds. No timer or private animation.
const dark = $device.isdarkmode();
const family = $getenv("widget-size");
const fullColor = ($getenv("widget-rendering-mode") || "fullColor") === "fullColor";
const ink = dark ? "#EFFAF5" : "#1C4C39";
const muted = dark ? "#C2DCD0" : "#4E7764";
if (family.startsWith("accessory")) {
  $render(
    <text font={family === "accessoryCircular" ? "caption" : "headline"}>
      {family === "accessoryCircular" ? "Calm" : "A little calm"}
    </text>,
  );
} else {
  $render(
    <zstack frame="max" background={dark ? "#142C24" : "#E7F6EE"}>
      <hstack spacing="4" opacity={fullColor ? 0.7 : 0} rotation3d="12,0,1,0">
        <circle frame="80" color="#41B982" />
        <ellipse frame="48,92" rotation="28" color="#F1C486" />
      </hstack>
      <vstack
        spacing="7"
        padding="18"
        corner="20"
        backgroundMaterial="thin"
        background={dark ? "#203E31" : "#FAFFFC"}
      >
        <text font="headline" fontDesign="rounded" color={ink}>
          A little calm
        </text>
        <text font="caption" color={muted}>
          Your own quiet corner.
        </text>
      </vstack>
    </zstack>,
  );
}
