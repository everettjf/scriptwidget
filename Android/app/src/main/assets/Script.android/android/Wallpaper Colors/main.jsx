// Android takes a set of Material colors from the wallpaper. Name one as
// "material.<role>" in any color prop and the widget follows the wallpaper,
// in light and in dark mode. iPhone does not know these names and keeps its
// default colors.
const android = $system.platform() === "android";
const small = $getenv("widget-size") === "small";
const roles = [
  "primary",
  "secondary",
  "tertiary",
  "primaryContainer",
  "secondaryContainer",
  "tertiaryContainer",
];

$render(
  <vstack
    frame="max,topLeading"
    alignment="leading"
    spacing="10"
    padding="14"
    background="material.surfaceContainer"
  >
    <text font="headline" color="material.onSurface">
      {small ? "Wallpaper" : "Wallpaper colors"}
    </text>
    <hstack spacing="6">
      {roles.map((role) => (
        <rect corner="8" color={"material." + role} frame="max,26" />
      ))}
    </hstack>
    <hstack spacing="8" padding="10" background="material.primaryContainer" corner="14">
      <icon systemName="paintpalette.fill" size="18" color="material.onPrimaryContainer" />
      <text font="footnote" color="material.onPrimaryContainer">
        {small ? "Follows it" : "Change the wallpaper and this card follows."}
      </text>
    </hstack>
    <spacer />
    <text font="caption2" color="material.onSurfaceVariant">
      {android ? (small ? "Material colors" : "Material colors of this phone") : "Android only"}
    </text>
  </vstack>,
);
