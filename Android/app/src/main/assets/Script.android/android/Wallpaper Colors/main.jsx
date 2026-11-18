// Android takes a set of Material colors from the wallpaper. Name one as
// "material.<role>" in any color prop and the widget follows the wallpaper,
// in light and in dark mode. iPhone does not know these names and keeps its
// default colors.
// Try: replace a role in the list with another one, such as "surfaceVariant" or "outline".
// Used only for the last line of text, which says where the widget runs.
const android = $system.platform() === "android";
// A small widget gets shorter texts.
const small = $getenv("widget-size") === "small";
// The roles shown as color swatches.
const roles = [
  "primary",
  "secondary",
  "tertiary",
  "primaryContainer",
  "secondaryContainer",
  "tertiaryContainer",
];

// frame="max,topLeading" fills the widget and puts the content in the top left corner.
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
    {/* One swatch per role. frame="max,26": as wide as possible and 26 points high. */}
    <hstack spacing="6">
      {roles.map((role) => (
        <rect corner="8" color={"material." + role} frame="max,26" />
      ))}
    </hstack>
    {/* A card in a container color. Its text uses the matching "on" color to stay readable. */}
    <hstack spacing="8" padding="10" background="material.primaryContainer" corner="14">
      <icon systemName="paintpalette.fill" size="18" color="material.onPrimaryContainer" />
      <text font="footnote" color="material.onPrimaryContainer">
        {small ? "Follows it" : "Change the wallpaper and this card follows."}
      </text>
    </hstack>
    {/* <spacer /> takes the free room, so the last line sits at the bottom. */}
    <spacer />
    <text font="caption2" color="material.onSurfaceVariant">
      {android ? (small ? "Material colors" : "Material colors of this phone") : "Android only"}
    </text>
  </vstack>,
);
